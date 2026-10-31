#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成运动场地贴图（像素风）。

输入 tools/pitches_raw.json（extract_pitches.py 的产物，格坐标多边形），
输出 assets/pitches/*.png + 一份 props 片段 tools/pitches_props.json。

规模换算：1 格 ≈ 2.496 m，1 px = 0.312 m（8 px/格）。
每个场地都按真实尺寸画，再居中摆进 OSM 给的 bbox —— 所以比例不会走样。
体育馆 / 游泳馆有实体楼，跳过。
"""
import json
import os

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, "pitches_raw.json")
OUT_DIR = os.path.join(HERE, "..", "assets", "pitches")

PX = 8
OUTLINE = (27, 36, 48, 255)
M2PX = 0.4006 * PX          # 米 → 像素

# 真实场地尺寸（米）
SIZE = {
    "basketball": (28.0, 15.0),
    "tennis":     (23.77, 10.97),
    "volleyball": (18.0, 9.0),
    "badminton":  (13.4, 6.1),
    "football":   (105.0, 68.0),
}

PALETTE = {
    "football":   ((74, 122, 66), (56, 96, 52)),
    "basketball": ((168, 104, 64), (132, 80, 48)),    # 橙红，和跑道区分
    "volleyball": ((178, 134, 76), (140, 102, 56)),
    "tennis":     ((58, 124, 104), (44, 98, 82)),
    "badminton":  ((78, 106, 146), (60, 82, 116)),
    "track":      ((166, 82, 62), (92, 140, 82)),      # 跑道砖红，内场草
    "generic":    ((100, 118, 94), (80, 96, 76)),
}
LINE = (238, 238, 228, 225)
LINE_DIM = (238, 238, 228, 110)
GRASS_IN = (92, 140, 82, 255)


def kind_of(name):
    n = name or ""
    for kw, k in (("足球", "football"), ("篮球", "basketball"), ("排球", "volleyball"),
                  ("网球", "tennis"), ("羽毛球", "badminton"), ("操场", "track"), ("田径", "track")):
        if kw in n:
            return k
    return "generic"


def rect(d, box, col, width=2):
    d.rectangle([int(v) for v in box], outline=col, width=width)


def fit(w_m, h_m, W, H, pad):
    """按真实尺寸等比缩放，塞进 (W,H) 的可用区，返回 (宽,高)。"""
    aw, ah = W - pad * 2, H - pad * 2
    tw, th = w_m * M2PX, h_m * M2PX
    s = min(aw / tw, ah / th)
    return max(8, int(tw * s)), max(8, int(th * s))


def draw_track(d, W, H):
    """400 米跑道：圆角环 + 内场草地 + 足球场线。跑道宽约 9.8 m。"""
    lane = int(9.8 * M2PX)
    r_out = int(min(W, H) * 0.42)
    d.rounded_rectangle([1, 1, W - 2, H - 2], radius=r_out, fill=PALETTE["track"][0])
    d.rounded_rectangle([1, 1, W - 2, H - 2], radius=r_out, outline=OUTLINE, width=2)
    ix0, iy0 = lane, lane
    ix1, iy1 = W - lane - 1, H - lane - 1
    r_in = max(4, r_out - lane)
    d.rounded_rectangle([ix0, iy0, ix1, iy1], radius=r_in, fill=GRASS_IN)
    d.rounded_rectangle([ix0, iy0, ix1, iy1], radius=r_in, outline=LINE, width=2)
    # 分道线（3 条）
    for k in (1 / 4, 2 / 4, 3 / 4):
        off = int(lane * k)
        if off < 3:
            continue
        d.rounded_rectangle([1 + off, 1 + off, W - 2 - off, H - 2 - off],
                            radius=max(4, r_out - off), outline=LINE, width=1)
    # 内场足球场
    cx, cy = W // 2, H // 2
    fw, fh = fit(105, 68, ix1 - ix0, iy1 - iy0, 3)
    fx0, fy0 = cx - fw // 2, cy - fh // 2
    rect(d, (fx0, fy0, fx0 + fw, fy0 + fh), LINE, 1)
    d.line([(cx, fy0), (cx, fy0 + fh)], fill=LINE, width=1)
    r = max(4, int(fh * 0.16))
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=LINE, width=1)


def draw_football(d, W, H):
    fw, fh = fit(105, 68, W, H, 3)
    x0, y0 = (W - fw) // 2, (H - fh) // 2
    x1, y1 = x0 + fw, y0 + fh
    d.rectangle([x0, y0, x1, y1], fill=PALETTE["football"][0])
    rect(d, (x0, y0, x1, y1), LINE, 1)
    cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
    d.line([(cx, y0), (cx, y1)], fill=LINE, width=1)
    r = max(4, int(fh * 0.15))
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=LINE, width=1)
    pa_w, pa_h = int(fw * 0.16), int(fh * 0.55)
    d.rectangle([x0, cy - pa_h // 2, x0 + pa_w, cy + pa_h // 2], outline=LINE, width=1)
    d.rectangle([x1 - pa_w, cy - pa_h // 2, x1, cy + pa_h // 2], outline=LINE, width=1)


def draw_grid(d, W, H, kind):
    """多个标准场地铺成阵列：单个场地用真实尺寸，能放几个放几个，整体居中。"""
    pw, ph = int(SIZE[kind][0] * M2PX), int(SIZE[kind][1] * M2PX)
    if pw > W - 10 or ph > H - 10:          # bbox 装不下一个标准场，等比缩小
        pw, ph = fit(*SIZE[kind], W, H, 5)
    base, _edge = PALETTE[kind]
    gap = 5
    nx = max(1, (W - 10) // (pw + gap))
    ny = max(1, (H - 10) // (ph + gap))
    total_w = nx * pw + (nx - 1) * gap
    total_h = ny * ph + (ny - 1) * gap
    ox = (W - total_w) // 2
    oy = (H - total_h) // 2
    for j in range(ny):
        for i in range(nx):
            x0 = ox + i * (pw + gap)
            y0 = oy + j * (ph + gap)
            x1, y1 = x0 + pw, y0 + ph
            d.rectangle([x0, y0, x1, y1], fill=base, outline=LINE, width=2)
            mx, my = (x0 + x1) // 2, (y0 + y1) // 2
            if kind == "basketball":
                d.line([(mx, y0 + 2), (mx, y1 - 2)], fill=LINE, width=2)
                r = max(3, int(ph * 0.12))
                d.ellipse([mx - r, my - r, mx + r, my + r], outline=LINE, width=2)
                for bx in (x0 + max(4, pw // 9), x1 - max(4, pw // 9)):
                    d.line([(bx, my - ph // 5), (bx, my + ph // 5)], fill=LINE, width=2)
            elif kind == "tennis":
                d.line([(mx, y0 + 2), (mx, y1 - 2)], fill=LINE, width=2)
                ins_y, ins_x = max(2, ph // 4), max(2, pw // 4)
                d.rectangle([x0 + ins_x, y0 + ins_y, x1 - ins_x, y1 - ins_y],
                            outline=LINE, width=1)
            elif kind == "volleyball":
                d.line([(mx, y0 + 2), (mx, y1 - 2)], fill=LINE, width=2)
                ins = max(2, ph // 6)
                d.rectangle([x0 + 2, y0 + ins, x1 - 2, y1 - ins], outline=LINE_DIM, width=1)
            else:
                d.line([(mx, y0 + 2), (mx, y1 - 2)], fill=LINE, width=2)
                ins = max(2, ph // 5)
                d.rectangle([x0 + ins, y0 + ins, x1 - ins, y1 - ins], outline=LINE_DIM, width=1)


def build():
    data = json.load(open(RAW, encoding="utf-8"))
    os.makedirs(OUT_DIR, exist_ok=True)
    props = []
    n = 0
    for p in data["pitches"]:
        if p["kind"] in ("sports_centre", "stadium"):
            print("  跳过 %-12s（%s，有实体楼）" % (p["name"][:10], p["kind"]))
            continue
        xs = [q[0] for q in p["pts"]]
        ys = [q[1] for q in p["pts"]]
        minx, miny = min(xs), min(ys)
        gw, gh = max(xs) - minx, max(ys) - miny
        W, H = max(24, int(round(gw * PX))), max(24, int(round(gh * PX)))
        kind = kind_of(p["name"])

        img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        base, edge = PALETTE[kind]
        if kind == "track":
            draw_track(d, W, H)
        else:
            d.rectangle([0, 0, W - 1, H - 1], fill=edge)
            rect(d, (0, 0, W - 1, H - 1), OUTLINE, 2)
            if kind == "football":
                draw_football(d, W, H)
            elif kind == "generic":
                rect(d, (5, 5, W - 6, H - 6), LINE, 2)
            else:
                draw_grid(d, W, H, kind)

        slug = "pitch_%02d_%s" % (n, kind)
        img.save(os.path.join(OUT_DIR, slug + ".png"))
        print("  %-12s %-10s %3dx%-3d 格 → %4dx%-4d px  %s" % (
            p["name"][:10], kind, round(gw), round(gh), W, H, slug))
        n += 1
        props.append({
            "name": p["name"] + "场地",
            "sprite": "res://assets/pitches/%s.png" % slug,
            "x": round(minx, 1),
            "baseY": round(miny + gh, 1),
            "bottom": 0,
            "layer": "ground",
            # 场上不长树：构建场景时按这个轮廓排除装饰
            "poly": [[round(q[0], 1), round(q[1], 1)] for q in p["pts"]],
        })

    json.dump(props, open(os.path.join(HERE, "pitches_props.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)
    print("\n共 %d 块场地" % len(props))


if __name__ == "__main__":
    build()
