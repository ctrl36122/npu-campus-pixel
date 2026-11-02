#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把「桥下通道」从一根等宽矩形，拟合成有宽窄变化、会拐弯的自然河道。

为什么
------
上一版通道是 6~7 格宽的直条矩形：两端开口可能宽到 11 格、中间又只需要 5 格，
直条要么切进草地鼓出一个方角，要么比开口窄、接不上岸线。看上去就是「在地上
刷了一条蓝色长方形」。

做法
----
1. 每处陆地颈量出上下游真实开口（world.json 里原有水的 span），作为两端的控制点。
2. 沿 y 逐行插值「中心 x」和「宽度」（分段 smoothstep），中间塞收窄/放开的控制点，
   再叠一层低频摆动 —— 河道有腰身、也会拐弯。
3. 逐行输出水格的 [x0, x1]，写成 rows 存进 world.json 的 bridges 项：
   `rows: [[y, x0, x1], ...]`；同时按行合并成矩形追加进 water（船的水域掩码靠它）。
4. 桥面（deck 足迹）自动挑「最窄的一小段」横跨过去，保证桥不长在宽水面上。

用法（项目根目录）：
  python3 tools/fit_channels.py          # 重算并写回 world.json
  python3 tools/fit_channels.py --dry    # 只打印形状
之后必须跑 tools/bake_channels.py 把新河道烘进地面图，再重建 world.tscn。
"""
import json
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 每处颈的控制点：(t, 中心 x, 宽度/格)。t=0 是北端、t=1 是南端。
# 端点值来自上下游真实开口 span（量于 world.json 的原有水），中间是拟合出来的腰身。
PROFILES = {
    0: [(0.00, 262.5, 10.0), (0.45, 261.6, 8.0), (1.00, 260.5, 8.0)],
    1: [(0.00, 285.0, 11.0), (0.50, 285.5, 7.0), (1.00, 285.0, 11.0)],
    2: [(0.00, 286.5, 6.0), (0.50, 287.0, 5.6), (1.00, 287.5, 6.0)],
    3: [(0.00, 291.5, 6.4), (0.22, 292.0, 5.8), (0.45, 290.2, 6.2),
        (0.68, 288.4, 6.8), (1.00, 289.5, 10.0)],
}
# 两端必须严丝合缝贴住原有水面的真实 span，否则河道口会错出一格（岸线上留个小凸起）。
ENDS = {
    0: ((258, 267), (257, 264)),
    1: ((280, 290), (280, 290)),
    2: ((284, 289), (285, 290)),
    3: ((289, 294), (285, 294)),
}
# 摆动幅度（格）：中心线左右摆、宽度呼吸。太小像直筒，太大就歪出开口。
WOBBLE_X = {0: 0.30, 1: 0.35, 2: 0.22, 3: 0.95}
WOBBLE_W = {0: 0.35, 1: 0.45, 2: 0.25, 3: 0.95}
MIN_W = 5.0                       # 船体约 3.5 格，再窄就过不去


def smoothstep(s):
    s = max(0.0, min(1.0, s))
    return s * s * (3.0 - 2.0 * s)


def sample(profile, t):
    """在控制点之间用 smoothstep 插值 (center, width)。"""
    if t <= profile[0][0]:
        return profile[0][1], profile[0][2]
    for i in range(len(profile) - 1):
        t0, c0, w0 = profile[i]
        t1, c1, w1 = profile[i + 1]
        if t <= t1:
            s = smoothstep((t - t0) / max(1e-9, t1 - t0))
            return c0 + (c1 - c0) * s, w0 + (w1 - w0) * s
    return profile[-1][1], profile[-1][2]


def build_rows(idx, cy, ch):
    prof = PROFILES[idx]
    wob_x = WOBBLE_X[idx]
    wob_w = WOBBLE_W[idx]
    phase = 0.37 * (idx + 1)
    head, tail = ENDS[idx]
    rows = []
    for k in range(ch):
        if k == 0:                       # 北端：严格贴住上游真实开口
            rows.append([cy, head[0], head[1]])
            continue
        if k == ch - 1:                  # 南端：严格贴住下游真实开口
            rows.append([cy + k, tail[0], tail[1]])
            continue
        t = (k + 0.5) / ch
        c, w = sample(prof, t)
        # 端点附近把摆动收掉，否则第一行和开口对不齐
        fade = min(1.0, k / 2.0, (ch - 1 - k) / 2.0)
        c += wob_x * fade * math.sin(2.0 * math.pi * (t * 1.9 + phase))
        w += wob_w * fade * math.sin(2.0 * math.pi * (t * 1.4 + phase * 1.7))
        w = max(MIN_W, w)
        x0 = int(round(c - w * 0.5))
        x1 = x0 + int(round(w)) - 1
        rows.append([cy + k, x0, x1])
    return rows


def rows_to_rects(rows):
    """连续行若 x 范围相同就合并成一个矩形，减少 water 项数。"""
    out = []
    for y, x0, x1 in rows:
        w = x1 - x0 + 1
        if out and out[-1]["x"] == x0 and out[-1]["w"] == w \
                and out[-1]["y"] + out[-1]["h"] == y:
            out[-1]["h"] += 1
        else:
            out.append({"x": x0, "y": y, "w": w, "h": 1})
    return out


def pick_deck(rows, d):
    """固定进深 d，在该进深的所有窗口里挑「最窄 + 最居中」的一段当桥位。"""
    d = min(d, len(rows))
    best = None
    center = len(rows) * 0.5
    for start in range(0, len(rows) - d + 1):
        seg = rows[start:start + d]
        lo = min(r[1] for r in seg)
        hi = max(r[2] for r in seg)
        score = (hi - lo + 1) + 0.5 * abs(start + d * 0.5 - center)
        if best is None or score < best[0]:
            best = (score, seg[0][0], d, lo, hi)
    return best[1], best[2], best[3], best[4]


def main():
    dry = "--dry" in sys.argv
    path = os.path.join(ROOT, "assets/world.json")
    with open(path, encoding="utf-8") as f:
        d = json.load(f)

    bridges = d["bridges"]
    # 先删掉上一版通道水（按 bridges 的旧 rows / 旧矩形）
    old_keys = set()
    for b in bridges:
        for r in rows_to_rects(b.get("rows") or []):
            old_keys.add((r["x"], r["y"], r["w"], r["h"]))
        old_keys.add((b.get("cx"), b.get("cy"), b.get("cw"), b.get("ch")))
    before = len(d["water"])
    d["water"] = [w for w in d["water"]
                  if (w["x"], w["y"], w["w"], w["h"]) not in old_keys]
    print("移除旧通道水矩形:", before - len(d["water"]))

    for i, b in enumerate(bridges):
        cy, ch = int(b["cy"]), int(b["ch"])
        rows = build_rows(i, cy, ch)
        rects = rows_to_rects(rows)
        for r in rects:
            d["water"].append(r)
        x0s = [r[1] for r in rows]
        x1s = [r[2] for r in rows]
        b["rows"] = rows
        b["cx"], b["cw"] = min(x0s), max(x1s) - min(x0s) + 1
        # 桥面：跨最窄的一段，左右各留 1 格桥台。短颈少跨两行，南北才留得出水面。
        deck_d = 5 if len(rows) >= 10 else (4 if len(rows) >= 7 else max(3, len(rows) - 2))
        dy, dh, lo, hi = pick_deck(rows, deck_d)
        b["x"], b["y"] = lo - 1, dy
        b["w"], b["h"] = hi - lo + 3, dh
        print("桥%d: %d 行, 中心 x %d..%d, 桥面 x[%d..%d] y[%d..%d]"
              % (i, len(rows), min(x0s), max(x1s),
                 b["x"], b["x"] + b["w"] - 1, b["y"], b["y"] + b["h"] - 1))
        if dry:
            for y, a, c in rows:
                print("     y=%d  x %d..%d  (%d 格)" % (y, a, c, c - a + 1))

    print("water 总数:", len(d["water"]))
    if dry:
        print("--dry：不写文件")
        return
    with open(path, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False, separators=(",", ":"))
    print("已写回", path)


if __name__ == "__main__":
    main()
