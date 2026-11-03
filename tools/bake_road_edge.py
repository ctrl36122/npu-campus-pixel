#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给路面烘一层「路缘石 + 倒角」，让它从贴纸变成有厚度的铺装。

背景：路面是烘死在 assets/ground/g{cx}_{cy}.png 里的平涂灰色（8px/格），
和草地之间是硬切的 —— 远看就像在草坪上刷了块灰漆。这里不动路的位置，
只在**路面内侧**加一圈 1~2px 的边：

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
SHADOW = 0.90          # 紧贴路缘的接触影（只打在背光侧 下/右）
INNER_RIM = 0.82       # 路面最外 1px 压暗 = 与地面的接缝
LIP = 1.10             # 受光侧（上/左）内侧倒角
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


def build(im):
    W, H = im.size
    R = road_mask(im)
    inner1 = erode(R, 1)
    inner2 = erode(R, 2)

    ring0 = and_not(R, inner1)          # 路面最外 1px
    ring1 = and_not(inner1, inner2)     # 向内第 2px

    out = im

    # ① 路肩：路面外侧 1px 的草地混成土色（草坪被踩秃的过渡带）
    shoulder = ImageChops.lighter(and_not(shift(R, 0, 1), R), and_not(shift(R, 0, -1), R))
    shoulder = ImageChops.lighter(shoulder, and_not(shift(R, 1, 0), R))
    shoulder = ImageChops.lighter(shoulder, and_not(shift(R, -1, 0), R))
    dirt = Image.new("RGB", (W, H), DIRT)
    out = Image.composite(Image.blend(out, dirt, SHOULDER), out, shoulder)

    # ② 接触影：只打在背光侧（下/右），1px 压深
    shadow = ImageChops.lighter(and_not(shift(R, 0, 1), R), and_not(shift(R, 1, 0), R))
    out = paint(out, SHADOW, shadow)

    # ③ 内圈：接缝压暗 + 受光侧倒角
    out = paint(out, INNER_RIM, ring0)
    lip = and_not(ring1, shift(R, 0, 1))                     # 上邻是草地
    lip = ImageChops.lighter(lip, and_not(ring1, shift(R, 1, 0)))
    out = paint(out, LIP, lip)

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
