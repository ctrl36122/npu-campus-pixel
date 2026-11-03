#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""路面「形状」烘焙：按 OSM 折线重新画路 —— 分级加宽 + 材质分层 + 标线。

原来的路面是当年一次性烘进 `assets/ground/*.png` 的：一条条 1 格宽、边缘毛糙的
灰色带子，主干道和小径一样宽，看着像踩出来的土道，不像规划过的路。

这里换成「矢量重画」：
    1. 从 data.js 取 73 条道路中心线（与现有路面 99.7% 对齐，见 road_net.py）
    2. 按长度分三级定宽：主干道 28px / 次干道 20px / 步道 14px（8px = 1 格）
    3. 主干道铺沥青 + 正中白虚线；次干道/步道保留石材铺装
    4. 新铺出来的像素从旧路面「邻居取色」填进去，纹理自然接上
    5. 最后交给 bake_road_edge.py 统一做路肩/倒角/颗粒

幂等：始终从 `assets/_ground_src/` 的源图重算，反复跑不会叠加。

用法：
    python tools/bake_roads.py              # 写回 assets/ground/
    python tools/bake_roads.py --preview    # 只出对比图 road_before_after.png
    python tools/bake_roads.py --mask       # 出一张掩码诊断图 road_mask_dbg.png
之后：
    godot --headless --path . --import
    python tools/place_life_props.py        # 路变宽了，停车场/垃圾桶要重挑位置
    godot --headless --path . --script res://tools/build_world_scene.gd -- --force
"""
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

import bake_road_edge as E
import road_net as N

ROOT = E.ROOT
CELL = 8
SIZE = (E.WORLD_W, E.WORLD_H)

# ---- 材质与标线 ----
ASPHALT_BASE = 124               # 沥青基色（r 通道）。下限要 ≥92：place_life_props 用 92~182 认路面
ASPHALT_HI = 24                  # 颗粒明暗幅度（±24 → r 96~144，仍 ≥92）
DASH_W = 1                       # 中线虚线宽（px）
DASH_COLOR = (232, 234, 228)
EDGE_LINE = False                # 内侧白边线（试过：两侧各一条，16~22px 的路会读成自行车道）
EDGE_COLOR = (208, 210, 204)     # 边线色：不用纯白，免得像画上去的
CURB = True                      # 路缘石（最外接缝 + 第 2px 浅石条），与停车场贴图同一套
CURB_COLOR = (168, 170, 174)
SEAM = 0.80
ASPHALT = True                   # 整条路重铺沥青（路面材质统一，不会和旧砖纹打架）
EDGE_W = 1
EDGE_INSET = 4
# 水色（与 bake_channels.py 一致）：加宽的路不能铺到水面上，否则桥两侧会变「漫水桥」
WATER_COLORS = [(104, 146, 132), (120, 164, 146), (88, 128, 116), (142, 188, 164)]
WATER_TOL = 8


def water_mask(im):
    """水面掩码。逐色做容差匹配，取并集。"""
    m = Image.new("L", im.size, 0)
    for c in WATER_COLORS:
        d = ImageChops.difference(im, Image.new("RGB", im.size, c))
        r, g, b = d.split()
        near = ImageChops.lighter(ImageChops.lighter(r, g), b)
        m = ImageChops.lighter(m, near.point(lambda v: 255 if v <= WATER_TOL else 0))
    return m


def inpaint(im, known, target, rounds=14):
    """把 target 里 known 之外的部分，用「已填充像素的邻居」一格格补满。

    路加宽是一圈 4~7px 的窄环，从旧路面往外扩几轮就够了；
    比直接涂一个平均色自然 —— 旧路的石缝、明暗会被带着走。
    """
    out = im.copy()
    known = known.copy()
    todo = ImageChops.subtract(target, known)
    for _ in range(rounds):
        if not todo.getbbox():
            break
        moved = False
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, -1), (1, -1), (-1, 1)):
            k = ImageChops.offset(known, dx, dy)
            src = ImageChops.offset(out, dx, dy)
            fill = ImageChops.multiply(todo, k)
            if fill.getbbox():
                out = Image.composite(src, out, fill)
                known = ImageChops.lighter(known, fill)
                todo = ImageChops.subtract(todo, fill)
                moved = True
        if not moved:
            break
    return out


def asphalt_layer(size):
    """沥青底：半分辨率噪声再最近邻放大 = 2×2 的粗颗粒，跟路面颗粒同一套语言。
    再撒 1.5% 的深浅石子点 —— 只有均匀噪声时，远看是一块死板的中灰。"""
    import random
    n = Image.effect_noise((size[0] // 2, size[1] // 2), 24).resize(size, Image.NEAREST)
    l = n.point(lambda v: ASPHALT_BASE + (v - 128) * ASPHALT_HI // 128)
    r = l.point(lambda v: max(0, min(255, v - 4)))
    g = l.point(lambda v: max(0, min(255, v + 2)))
    b = l.point(lambda v: max(0, min(255, v + 7)))
    out = Image.merge("RGB", (r, g, b))
    from PIL import ImageDraw
    d = ImageDraw.Draw(out)
    rnd = random.Random(20261103)
    for _ in range(size[0] * size[1] // 68):
        x, y = rnd.randrange(size[0]), rnd.randrange(size[1])
        v = rnd.choice((ASPHALT_BASE - 16, ASPHALT_BASE - 10, ASPHALT_BASE + 10, ASPHALT_BASE + 15))
        d.point((x, y), fill=(v - 4, v + 2, v + 7))
    return out


def build(src):
    """返回 (新图, 路面掩码)。"""
    R_old = E.road_mask(src).filter(ImageFilter.MedianFilter(5))
    roads = N.load()
    S_all = N.strokes(roads)
    S_main = N.strokes(roads, cls=2)

    water = water_mask(src)
    # 加宽部分不铺到水面上，否则桥两侧会变成「漫水桥」
    S_all = ImageChops.subtract(S_all, water)
    S_main = ImageChops.subtract(S_main, water)

    target = ImageChops.lighter(R_old, S_all)

    # ① 新铺出来的部分：从旧路面邻居取色（保持石材铺装的纹理连续）
    out = inpaint(src, R_old, target)

    # ② 路面材质：整条描边范围内重铺，而不是只补边。
    #    只补边的话，旧路自己那条毛糙边缘会留在新路中间，成了一道锯齿接缝。
    if ASPHALT:
        A = ImageChops.lighter(S_all, ImageChops.multiply(R_old, E.dilate(S_all, 6)))
        out = Image.composite(asphalt_layer(SIZE), out, A)

    # ③ 边缘：路肩 + 方向性倒角 + 颗粒
    out = E.build(out, target)

    if CURB and ASPHALT:
        # ④ 路缘石：最外 1px 压成接缝、第 2px 换成浅色石条。
        # 和停车场贴图（gen_parking_cars.py 的 lot_art）用同一套边：
        # 只有明暗倒角的沥青路，远看是一条软塌塌的灰带子，边界交代不清。
        seam = ImageChops.subtract(A, E.erode(A, 1))
        curb = ImageChops.subtract(E.erode(A, 1), E.erode(A, 2))
        out = E.paint(out, SEAM, seam)
        out = Image.composite(Image.new("RGB", SIZE, CURB_COLOR), out, curb)

    # ⑤ 标线（画在边缘处理之后，不然会被倒角压暗）
    grid = N.sample_grid(roads)
    segs = N.dash_segments(roads, grid)
    d = ImageDraw.Draw(out)
    for x0, y0, x1, y1 in segs:
        d.line([(x0, y0), (x1, y1)], fill=DASH_COLOR, width=DASH_W)

    if EDGE_LINE and ASPHALT:
        # 边线画在「整个铺装区」的内侧，不是每条路各自的内侧 ——
        # 后者会在路口把线切断、把两条路的线交叉着画进路口里。
        # A = 沥青区，erode(A, 3) 减 erode(A, 4) 就是贴着外轮廓往里 3px 的一圈。
        inner = E.erode(A, EDGE_INSET)
        outer = E.erode(A, EDGE_INSET + EDGE_W)
        ring = ImageChops.subtract(inner, outer)
        line = Image.new("RGB", SIZE, EDGE_COLOR)
        out = Image.composite(line, out, ring)

    return out, target


def main():
    E.ensure_src()
    src = E.load_mosaic()
    out, mask = build(src)

    if "--mask" in sys.argv:
        ov = out.copy()
        red = Image.new("RGB", SIZE, (220, 40, 40))
        ov = Image.composite(red, ov, mask.point(lambda v: 120 if v else 0))
        ov.crop((1400, 1200, 2200, 2000)).save(os.path.join(ROOT, "road_mask_dbg.png"))
        print("[roads] 掩码诊断图 -> road_mask_dbg.png")
        return

    if "--preview" in sys.argv:
        boxes = [(1580, 1560, 1880, 1740), (760, 2560, 1060, 2740)]
        s = 2.1
        panels = []
        for box in boxes:
            w, h = box[2] - box[0], box[3] - box[1]
            panels.append((src.crop(box).resize((int(w * s), int(h * s)), Image.NEAREST),
                           out.crop(box).resize((int(w * s), int(h * s)), Image.NEAREST)))
        pw, ph = panels[0][0].size
        cmp = Image.new("RGB", (pw * 2 + 12, ph * 2 + 12), (18, 18, 18))
        for i, (a, b) in enumerate(panels):
            cmp.paste(a, (0, i * (ph + 12)))
            cmp.paste(b, (pw + 12, i * (ph + 12)))
        cmp.save(os.path.join(ROOT, "road_before_after.png"))
        print("[roads] 对比图 -> road_before_after.png（左=原, 右=新）")
        return

    E.save(out)
    print("[roads] 已写回 assets/ground/（记得 godot --headless --path . --import）")


if __name__ == "__main__":
    main()
