#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""路网分级前后对比图：旧「按长度猜级」 vs 新「按真实 OSM highway」。

只画矢量折线，**不读也不写 assets/ground/*.png**，不调 bake_road_edge 的
ensure_src / load_mosaic / save，不改任何游戏数据。纯 Pillow 出图。

左：road_net.load(mode='length')  → cls 7 / 29 / 37
右：road_net.load(mode='osm')     → cls 0 / 69 / 4
    另叠加 9 条被 parse_osm.py:250 过滤掉的真实干道（半透明青色虚线），
    以及旧 cls2 那 7 条在右面板的红色空心圈（被长度误判为主干）。

用法：
    python tools/draw_road_grade_compare.py
    python tools/draw_road_grade_compare.py --scale 3 --out shot_xxx.png
    python tools/draw_road_grade_compare.py --no-osm-tags   # 验证 fallback
"""
import argparse
import collections
import json
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import road_net as N  # noqa: E402

# 放项目根目录并沿用 shot_*.png 命名：.gitignore 与 export_presets.cfg 的
# exclude_filter 都已排除它；放 tools/ 会被 Godot 当成资源导入出多余的 .import。
DEFAULT_OUT = os.path.join(ROOT, "shot_osm_grade_before_after.png")
OSM_TAGS = os.path.join(ROOT, "assets", "osm_tags.json")
MISSING_TAGS = os.path.join(ROOT, "assets", "__no_such_osm_tags__.json")

W, H = 424, 800
TOP, BOTTOM, GAP = 76, 52, 12
BG = (22, 24, 28)
PANEL_BG = (28, 31, 36)
GRID = (42, 46, 52)
C_CLS2 = (222, 66, 66)
C_CLS1 = (224, 192, 76)
C_CLS0 = (128, 134, 142)
C_DROPPED = (64, 224, 224)
C_CIRCLE = (255, 96, 96)
C_TEXT = (226, 232, 238)
C_MUTED = (150, 160, 170)


def font(size):
    try:
        return ImageFont.load_default(size=size)
    except TypeError:
        return ImageFont.load_default()


def dashed(draw, pts, color, width, dash=12.0, gap=8.0):
    """按累积长度把折线切成短段画虚线；返回实际画出的段数。"""
    period = dash + gap
    acc = 0.0
    drawn = 0
    for k in range(len(pts) - 1):
        x0, y0 = pts[k]
        x1, y1 = pts[k + 1]
        seg = math.hypot(x1 - x0, y1 - y0)
        if seg < 1e-9:
            continue
        n = max(1, int(seg / 2.0))
        prev = None
        for q in range(n + 1):
            t = q / n
            x, y = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
            acc += seg / n
            on = (acc % period) < dash
            if on and prev is not None:
                draw.line([prev, (x, y)], fill=color, width=width)
                drawn += 1
            prev = (x, y) if on else None
    return drawn


def draw_roads(draw, roads, scale, xoff, yoff):
    """按 roads_src 索引升序画 73 条；线宽取每条路自己的 w（体现分级差异）。"""
    for r in roads:
        color = {2: C_CLS2, 1: C_CLS1, 0: C_CLS0}[r["cls"]] + (255,)
        width = max(1, int(round(r["w"] * scale / N.CELL)))
        pts = [(xoff + x * scale, yoff + y * scale) for x, y in r["pts"]]
        if len(pts) == 1:
            x, y = pts[0]
            h = width / 2.0
            draw.ellipse([x - h, y - h, x + h, y + h], fill=color)
            continue
        draw.line(pts, fill=color, width=width, joint="curve")
        h = width / 2.0
        for x, y in (pts[0], pts[-1]):
            draw.ellipse([x - h, y - h, x + h, y + h], fill=color)


def midpoint(pts):
    """折线按累计长度取中点，比按点数取中点更接近视觉中心。"""
    total = sum(math.dist(pts[k], pts[k + 1]) for k in range(len(pts) - 1))
    half = total / 2.0
    acc = 0.0
    for k in range(len(pts) - 1):
        d = math.dist(pts[k], pts[k + 1])
        if acc + d >= half and d > 0:
            t = (half - acc) / d
            return (pts[k][0] + (pts[k + 1][0] - pts[k][0]) * t,
                    pts[k][1] + (pts[k + 1][1] - pts[k][1]) * t)
        acc += d
    return pts[len(pts) // 2]


def main():
    ap = argparse.ArgumentParser(description="路网分级前后对比图")
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--scale", type=int, default=2)
    ap.add_argument("--no-osm-tags", action="store_true",
                    help="模拟 osm_tags.json 缺失，验证 load_from_osm 的 fallback")
    args = ap.parse_args()
    scale = max(1, args.scale)

    tags_path = MISSING_TAGS if args.no_osm_tags else N.OSM_TAGS
    old = N.load(mode="length")
    new = N.load(mode="osm", osm_tags_path=tags_path)

    # ---- 参考层：9 条被过滤的真实干道
    dropped = []
    if os.path.exists(OSM_TAGS):
        with open(OSM_TAGS, encoding="utf-8") as f:
            doc = json.load(f)
        dropped = [r for r in doc.get("roads", []) if r.get("parse_osm_dropped")]

    pw, ph = W * scale, H * scale
    canvas = Image.new("RGB", (pw * 2 + GAP, TOP + ph + BOTTOM), BG)
    d = ImageDraw.Draw(canvas)
    f_title, f_note = font(19), font(15)

    # 顶部标题
    d.text((12, 8), "OLD  length-based  :  7 cls2 / 29 cls1 / 37 cls0",
           font=f_title, fill=C_TEXT)
    d.text((pw + GAP + 12, 8),
           "NEW  real OSM highway  :  0 cls2 / 69 cls1 / 4 cls0",
           font=f_title, fill=C_TEXT)

    # 图例
    lx, ly = 12, 40
    for color, label in ((C_CLS2, "cls2 arterial"), (C_CLS1, "cls1"),
                         (C_CLS0, "cls0"), (C_DROPPED, "9 filtered arterials"),
                         (C_CIRCLE, "old cls2 (misgraded)")):
        d.rectangle([lx, ly + 3, lx + 16, ly + 15], fill=color)
        d.text((lx + 22, ly), label, font=f_note, fill=C_MUTED)
        lx += 22 + int(d.textlength(label, font=f_note)) + 18

    # 两个面板各自独立成图再贴回：9 条干道里有负坐标，独立面板能让
    # 界外段被自动裁掉，绝不串到另一侧（早期版本曾把虚线画进左面板）。
    panels = [(old, 0, False), (new, pw + GAP, True)]
    drawn = 0
    for roads, xoff, is_new in panels:
        panel = Image.new("RGBA", (pw, ph), PANEL_BG + (255,))
        pd = ImageDraw.Draw(panel)
        for gx in range(0, W + 1, 64):
            pd.line([(gx * scale, 0), (gx * scale, ph)],
                    fill=GRID + (255,), width=1)
        for gy in range(0, H + 1, 64):
            pd.line([(0, gy * scale), (pw, gy * scale)],
                    fill=GRID + (255,), width=1)
        draw_roads(pd, roads, scale, 0, 0)

        if is_new:
            layer = Image.new("RGBA", (pw, ph), (0, 0, 0, 0))
            ld = ImageDraw.Draw(layer)
            for r in dropped:
                pts = [(x * scale, y * scale) for x, y in r["grid_polyline"]]
                drawn += dashed(ld, pts, C_DROPPED + (170,), max(2, scale),
                                dash=12.0 * scale, gap=8.0 * scale)
            panel = Image.alpha_composite(panel, layer)
            pd = ImageDraw.Draw(panel)
            # 旧 cls2 的 7 条在右面板标红圈
            for r in old:
                if r["cls"] != 2:
                    continue
                mx, my = midpoint(r["pts"])
                cx, cy = mx * scale, my * scale
                rad = 13 * scale
                pd.ellipse([cx - rad, cy - rad, cx + rad, cy + rad],
                           outline=C_CIRCLE + (255,), width=max(2, scale))
        canvas.paste(panel.convert("RGB"), (xoff, TOP))

    d = ImageDraw.Draw(canvas)
    note = ("Same 73 polylines, identical geometry - only grade/width differs.  "
            "The 9 cyan dashed arterials were dropped by parse_osm.py:250 and "
            "are NOT in roads_src.json.")
    d.text((12, TOP + ph + 14), note, font=f_note, fill=C_MUTED)
    if not args.no_osm_tags:
        canvas.save(args.out)
        print("[grade_compare] 已写出 %s（%d×%d, %d B）" %
              (args.out, canvas.width, canvas.height, os.path.getsize(args.out)))
    else:
        print("[grade_compare] --no-osm-tags 仅验证回退，未写图片")

    # ---- 自检
    errs = []
    def need(cond, msg):
        if not cond:
            errs.append(msg)
    need(len(old) == 73 and len(new) == 73,
         "两面板折线数应为 73/73，实为 %d/%d" % (len(old), len(new)))
    need(all(a["pts"] == b["pts"] and a["len"] == b["len"]
             and a["name"] == b["name"] and a["type"] == b["type"]
             for a, b in zip(old, new)), "两面板几何必须完全相同")
    co = collections.Counter(r["cls"] for r in old)
    cn = collections.Counter(r["cls"] for r in new)
    need((co[2], co[1], co[0]) == (7, 29, 37), "旧分级应为 7/29/37：%s" % dict(co))
    if args.no_osm_tags:
        # osm_tags.json 缺失时 load_from_osm 直接返回，必须完全不改变分级、
        # 也不追加任何 osm_* 字段 —— 这正是生产环境最安全的降级路径。
        need(dict(cn) == dict(co), "回退模式应完全保留旧长度分级：%s" % dict(cn))
        need(all("osm_highway" not in r for r in new),
             "回退模式不应追加 osm_* 字段")
    else:
        need((cn[2], cn[1], cn[0]) == (0, 69, 4),
             "新分级应为 0/69/4：%s" % dict(cn))
    need(len(dropped) == 9 and drawn > 0,
         "9 条参考层应全部画出且至少有一段可见：条数=%d 段数=%d" %
         (len(dropped), drawn))
    print("[grade_compare] OLD %s  NEW %s" % (dict(co), dict(cn)))
    print("[grade_compare] 参考层 %d 条 / %d 段虚线；osm 来源 %s" %
          (len(dropped), drawn,
           dict(collections.Counter(r.get("osm_match") for r in new))))
    if errs:
        for e in errs:
            print("  - " + e, file=sys.stderr)
        raise SystemExit(1)
    print("[grade_compare] 自检通过")


if __name__ == "__main__":
    main()
