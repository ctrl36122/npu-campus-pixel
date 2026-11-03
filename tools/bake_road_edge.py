#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给路面烘一层「路缘石 + 倒角」，让它从贴纸变成有厚度的铺装。

⚠️ 这个脚本现在只管**边缘**这一段。整条流程（按 OSM 中心线分级加宽 + 重铺材质 +
路缘石 + 标线 + 边缘）走 `tools/bake_roads.py`，它会 import 本文件的 `build(im, R)`。
单独跑本文件 = 只做倒角，没有矢量加宽。

背景：路面是烘死在 assets/ground/g{cx}_{cy}.png 里的（8px/格），最初是平涂灰、
和草地硬切 —— 远看就像在草坪上刷了块灰漆。这里不动路的位置，只在**路面内侧**加一圈边：

    最外 1px   ：压暗（路缘石背光的那一道竖面）
    向内 1px    ：提亮（路缘石顶面，受光）
    再向内      ：原样（铺装本身，砖缝纹理还在）
    草地一侧 1px：轻微压暗（落地接触影，让路面「压」在草上）

方向性：上/左边缘更亮、下/右边缘更暗，形成「凸起的边」而不是「描边」。

幂等：第一次跑会把当前地面图拷进 assets/_ground_src/（带 .gdignore，Godot 不导入），
以后每次都从源图重算 —— 反复跑不会越描越黑。改参数直接重跑即可。

用法：
    python tools/bake_road_edge.py            # 烘焙写回 assets/ground/
    python tools/bake_road_edge.py --preview  # 只出一张对比图 road_edge_preview.png
然后（改了 assets/ground/ 之后必须）：
    godot --headless --path . --import
"""
import os
import shutil
import sys

from PIL import Image, ImageChops, ImageEnhance, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, "assets", "_ground_src")
OUT = os.path.join(ROOT, "assets", "ground")

CHUNK = 1024
COLS, ROWS = 4, 7
WORLD_W, WORLD_H = 3392, 6400          # 424×8, 800×8

# ---- 强度（亮度倍率，1.0 = 不变）----
SHOULDER = 0.72        # 路肩：草地被踩出来的土，向 DIRT 混色的比例
DIRT = (163, 150, 118)  # 土色
BEVEL_N = 1.22         # 受光侧（上/左）最外 1px：路沿的高光边
BEVEL_W = 1.12
BEVEL_S = 0.78         # 背光侧（下/右）最外 1px：路沿的立面
BEVEL_E = 0.90
SHADOW = 0.82          # 背光侧路肩上再压一道（土也要有影子）
DOT_LIGHT = 1.05       # 路面碎石高光点
DOT_DARK = 0.95        # 路面碎石暗点

# 路面判定：中性灰（石材铺装 / 沥青）。注意水是灰绿色、沙是土黄，都不会命中。
ROAD_MIN, ROAD_MAX, ROAD_SPREAD = 92, 182, 12

SRC_FILES = ["g%d_%d.png" % (cx, cy) for cy in range(ROWS) for cx in range(COLS)]


def ensure_src():
    """把当前地面图存成源图（只做一次）。"""
    os.makedirs(SRC, exist_ok=True)
    missing = [f for f in SRC_FILES if not os.path.exists(os.path.join(SRC, f))]
    if len(missing) == len(SRC_FILES):
        for f in SRC_FILES:
            p = os.path.join(OUT, f)
            if os.path.exists(p):
                shutil.copy2(p, os.path.join(SRC, f))
        print("[road_edge] 首次运行：已把当前地面图备份到 assets/_ground_src/")
    elif missing:
        raise SystemExit("[road_edge] 源图不全（%d 个缺失），先删掉 assets/_ground_src/ 重跑"
                         % len(missing))


def load_mosaic():
    canvas = Image.new("RGB", (COLS * CHUNK, ROWS * CHUNK), (0, 0, 0))
    for cy in range(ROWS):
        for cx in range(COLS):
            p = os.path.join(SRC, "g%d_%d.png" % (cx, cy))
            canvas.paste(Image.open(p).convert("RGB"), (cx * CHUNK, cy * CHUNK))
    return canvas.crop((0, 0, WORLD_W, WORLD_H))


def road_mask(im):
    """中性灰 = 路面。返回 L 掩码（255 = 路）。"""
    r, g, b = im.split()
    mx = ImageChops.lighter(ImageChops.lighter(r, g), b)
    mn = ImageChops.darker(ImageChops.darker(r, g), b)
    spread = ImageChops.subtract(mx, mn)
    flat = spread.point(lambda v: 255 if v <= ROAD_SPREAD else 0)
    lum = r.point(lambda v: 255 if ROAD_MIN <= v <= ROAD_MAX else 0)
    return ImageChops.multiply(flat, lum)


def shift(m, dx, dy):
    return ImageChops.offset(m, dx, dy)


def erode(m, n=1):
    for _ in range(n):
        m = m.filter(ImageFilter.MinFilter(3))
    return m


def dilate(m, n=1):
    for _ in range(n):
        m = m.filter(ImageFilter.MaxFilter(3))
    return m


def and_not(a, b):
    return ImageChops.subtract(a, b)


def paint(base, factor, mask):
    """把 mask 覆盖的区域按 factor 调亮度（1.0 = 不变）。"""
    if factor == 1.0:
        return base
    adj = ImageEnhance.Brightness(base).enhance(factor)
    return Image.composite(adj, base, mask)


def build(im, R=None):
    """R：路面掩码。给 None 时从图里认（只做边缘）；由 bake_roads.py 传入的
    是「矢量分级加宽后」的掩码 —— 边缘必须贴着新形状走，不能自己再认一遍。"""
    W, H = im.size
    if R is None:
        R = road_mask(im)
    inner1 = erode(R, 1)

    ring0 = and_not(R, inner1)          # 路面最外 1px

    out = im

    # ① 路肩：路面外侧 1px 的草地混成土色（草坪被踩秃的过渡带）
    shoulder = ImageChops.lighter(and_not(shift(R, 0, 1), R), and_not(shift(R, 0, -1), R))
    shoulder = ImageChops.lighter(shoulder, and_not(shift(R, 1, 0), R))
    shoulder = ImageChops.lighter(shoulder, and_not(shift(R, -1, 0), R))
    dirt = Image.new("RGB", (W, H), DIRT)
    out = Image.composite(Image.blend(out, dirt, SHOULDER), out, shoulder)

    # ② 背光侧（下/右）的路肩再压暗一层，土也要有影子
    shadow = ImageChops.lighter(and_not(shift(R, 0, 1), R), and_not(shift(R, 1, 0), R))
    out = paint(out, SHADOW, shadow)

    # ③ 方向性倒角：路面最外 1px，受光侧亮、背光侧暗 —— 这条是「厚度」的主要来源，
    #    1 格宽的小路全靠它才不像贴纸
    n_edge = and_not(ring0, shift(R, 0, 1))    # 上邻是草地
    s_edge = and_not(ring0, shift(R, 0, -1))
    w_edge = and_not(ring0, shift(R, 1, 0))
    e_edge = and_not(ring0, shift(R, -1, 0))
    out = paint(out, BEVEL_N, n_edge)
    out = paint(out, BEVEL_W, w_edge)
    out = paint(out, BEVEL_S, s_edge)
    out = paint(out, BEVEL_E, e_edge)

    # ④ 路面碎石纹理：现在是纯色平涂，放大看是一块死灰
    dot_n = Image.effect_noise((W // 2, H // 2), 26).resize((W, H), Image.NEAREST)
    lit = ImageChops.multiply(R, dot_n.point(lambda v: 255 if v > 172 else 0))
    drk = ImageChops.multiply(R, dot_n.point(lambda v: 255 if v < 84 else 0))
    out = paint(out, DOT_LIGHT, lit)
    out = paint(out, DOT_DARK, drk)
    return out


def save(mosaic):
    """按**源图各自的尺寸**写回（最后一列是 320 宽、最后一行是 256 高）。
    统一成 1024 会让引擎按 1024 去摆，整块地面歪掉。"""
    for cy in range(ROWS):
        for cx in range(COLS):
            name = "g%d_%d.png" % (cx, cy)
            sw, sh = Image.open(os.path.join(SRC, name)).size
            x0, y0 = cx * CHUNK, cy * CHUNK
            part = mosaic.crop((x0, y0, x0 + sw, y0 + sh))
            part.save(os.path.join(OUT, name))


def main():
    preview = "--preview" in sys.argv
    ensure_src()
    im = load_mosaic()
    out = build(im)
    if preview:
        box = (1400, 1300, 1900, 1800)
        a = im.crop(box).resize((1000, 1000), Image.NEAREST)
        b = out.crop(box).resize((1000, 1000), Image.NEAREST)
        cmp = Image.new("RGB", (2010, 1000), (20, 20, 20))
        cmp.paste(a, (0, 0))
        cmp.paste(b, (1010, 0))
        cmp.save(os.path.join(ROOT, "road_edge_preview.png"))
        print("[road_edge] 对比图 -> road_edge_preview.png（左=原, 右=新）")
        return
    save(out)
    print("[road_edge] 已写回 assets/ground/（记得 godot --headless --path . --import）")


if __name__ == "__main__":
    main()
