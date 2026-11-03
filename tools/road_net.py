#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""OSM 路网：读折线 → 定级定宽 → 描边成掩码。

为什么要回到矢量数据：地面图里的路是**烘死**的像素（基本都是 1 格宽、边缘毛糙），
想加宽只能按像素腐蚀/膨胀，宽窄全凭猜，边缘还越弄越糙。
`../sxgd-tiled-vertion/data/map.osm` 经 `parse_osm.py` 生成的
`../sxgd-tiled-vertion/src/data.js` 里保留了 73 条道路折线（含路名），
实测按 `px = 格 × 8` 画回去有 99.7% 的点落在现有路面内 —— 当年地面图就是拿
这批折线烘的，坐标系完全一致。

有了中心线就能：
  · 按长度分级定宽（主干道 / 次干道 / 步道），同一条路从头到尾一样宽，
    不会像腐蚀法那样在路口鼓包；
  · 用矢量线画边，边缘是干净的斜线，而不是像素级的锯齿；
  · 主干道能在正中画虚线中线（有中心线才谈得上「车道」）。

折线单位是**格**（W=424, H=800），乘 CELL 得像素。
"""
import json
import math
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_JS = os.path.abspath(os.path.join(ROOT, "..", "sxgd-tiled-vertion", "src", "data.js"))
CACHE = os.path.join(ROOT, "assets", "roads_src.json")

CELL = 8
WORLD_W, WORLD_H = 3392, 6400

# ---- 分级：按道路长度（格）。73 条全是 residential / service，没有
#      highway=primary 这类标签可用，只能拿长度当重要性代理。
MAIN_LEN = 300          # ≥300 格（≈840 m）→ 主干道
SEC_LEN = 120           # ≥120 格 → 次干道，其余步道
W_MAIN, W_SEC, W_PATH = 40, 22, 16     # 铺装宽度（px），8 px = 1 格；主干道 5 格 ≈ 14 m


def _parse_js(path):
    """从 data.js 里抠出 r:[ ["名字","类型",[x,y,x,y,...]], ... ]。"""
    s = open(path, encoding="utf-8").read()
    i = s.index(",r:[") + 4
    j = s.index("],w:[", i)
    out = []
    for name, typ, pts in re.findall(r'\["([^"]*)","([^"]*)",\[([^\]]*)\]\]', s[i:j]):
        v = [float(t) for t in pts.split(",")]
        out.append({
            "name": name,
            "type": typ,
            "pts": [[v[k], v[k + 1]] for k in range(0, len(v) - 1, 2)],
        })
    return out


def load():
    """折线 + 长度 + 宽度等级。优先读缓存 assets/roads_src.json。"""
    if os.path.exists(CACHE):
        raw = json.load(open(CACHE, encoding="utf-8"))
    else:
        if not os.path.exists(DATA_JS):
            raise SystemExit("[road_net] 找不到 %s" % DATA_JS)
        raw = _parse_js(DATA_JS)
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        with open(CACHE, "w", encoding="utf-8") as f:
            json.dump(raw, f, ensure_ascii=False, indent=0)

    roads = []
    for r in raw:
        pts = [(float(p[0]), float(p[1])) for p in r["pts"]]
        L = sum(math.dist(pts[k], pts[k + 1]) for k in range(len(pts) - 1))
        if L >= MAIN_LEN:
            w, cls = W_MAIN, 2
        elif L >= SEC_LEN:
            w, cls = W_SEC, 1
        else:
            w, cls = W_PATH, 0
        roads.append({"name": r.get("name") or "", "type": r.get("type") or "",
                      "pts": pts, "len": L, "w": w, "cls": cls})
    return roads


def strokes(roads, cls=None, size=(WORLD_W, WORLD_H)):
    """把折线描成掩码。线宽取每条路自己的 w；首尾补圆头，避免接缝处断口。"""
    from PIL import Image, ImageDraw
    m = Image.new("L", size, 0)
    d = ImageDraw.Draw(m)
    for r in roads:
        if cls is not None and r["cls"] != cls:
            continue
        w = r["w"]
        xy = [(x * CELL, y * CELL) for x, y in r["pts"]]
        if len(xy) == 1:
            x, y = xy[0]
            d.ellipse([x - w // 2, y - w // 2, x + w // 2, y + w // 2], fill=255)
            continue
        d.line(xy, fill=255, width=w, joint="curve")
        h = w / 2.0
        for x, y in (xy[0], xy[-1]):
            d.ellipse([x - h, y - h, x + h, y + h], fill=255)
    return m


def sample_grid(roads, step=1.0):
    """把每条路按 1 格步长采样进「格 → 路序号集合」，用来判路口。

    路口 = 该格附近存在**别的**路。虚线中线在路口断开靠它。
    """
    grid = {}
    for idx, r in enumerate(roads):
        pts = r["pts"]
        for k in range(len(pts) - 1):
            (x0, y0), (x1, y1) = pts[k], pts[k + 1]
            seg = math.dist((x0, y0), (x1, y1))
            n = max(1, int(seg / step))
            for q in range(n + 1):
                t = q / n
                key = (int(x0 + (x1 - x0) * t), int(y0 + (y1 - y0) * t))
                grid.setdefault(key, set()).add(idx)
    return grid


def at_junction(grid, x, y, my_idx, gap=2.4):
    r = int(math.ceil(gap))
    xi, yi = int(x), int(y)
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            s = grid.get((xi + dx, yi + dy))
            if s and (len(s) > 1 or my_idx not in s):
                return True
    return False


def _pt_seg(p, a, b):
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    L2 = dx * dx + dy * dy
    t = 0.0 if L2 == 0 else max(0.0, min(1.0, ((p[0] - ax) * dx + (p[1] - ay) * dy) / L2))
    return math.hypot(p[0] - (ax + dx * t), p[1] - (ay + dy * t))


def crowded(road, roads, near=6.0, step=2.0):
    """这条路沿线有多少比例的采样点，6 格内还有**别的**路。

    华山路在 OSM 里被拆成两条平行折线（双向车道），各自都够长、都会被判成主干道；
    两条 26px 的路并排画出来会拼成一条 60px 宽的带子，中间还各有一条白虚线 ——
    看着像高速路。所以「挤」的路不画中线，只当作一条宽路。
    """
    pts = road["pts"]
    hit = tot = 0
    for k in range(len(pts) - 1):
        (x0, y0), (x1, y1) = pts[k], pts[k + 1]
        seg = math.dist((x0, y0), (x1, y1))
        n = max(1, int(seg / step))
        for q in range(n + 1):
            t = q / n
            x, y = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
            tot += 1
            for other in roads:
                if other is road:
                    continue
                op = other["pts"]
                if any(_pt_seg((x, y), op[j], op[j + 1]) < near for j in range(len(op) - 1)):
                    hit += 1
                    break
    return hit / max(1, tot)


def dash_segments(roads, grid, on=1.6, off=2.6, gap=2.4, crowd_frac=0.22):
    """主干道中线虚线（像素坐标段列表）。路口断开，平行双线不画。"""
    segs = []
    period = on + off
    for idx, r in enumerate(roads):
        if r["cls"] != 2:
            continue
        if crowded(r, roads) > crowd_frac:
            continue
        pts = r["pts"]
        acc = 0.0
        for k in range(len(pts) - 1):
            (x0, y0), (x1, y1) = pts[k], pts[k + 1]
            seg = math.dist((x0, y0), (x1, y1))
            if seg < 1e-6:
                continue
            n = max(1, int(seg * 2))
            prev = None
            for q in range(n + 1):
                t = q / n
                x, y = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
                acc += seg / n
                on_dash = (acc % period) < on and not at_junction(grid, x, y, idx, gap)
                if on_dash and prev is not None:
                    segs.append((prev[0] * CELL, prev[1] * CELL, x * CELL, y * CELL))
                prev = (x, y) if on_dash else None
    return segs


if __name__ == "__main__":
    import collections
    rs = load()
    print("道路 %d 条，总长 %.0f 格" % (len(rs), sum(r["len"] for r in rs)))
    c = collections.Counter({2: "主干道", 1: "次干道", 0: "步道"}[r["cls"]] for r in rs)
    print(dict(c))
