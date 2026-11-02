#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 world.json 里「桥下新增水道」烘进地面图 assets/ground/g*.png。

为什么需要这一步
----------------
地面是 28 张烘焙好的分块图（每块 1024×1024 像素 = 128×128 格，末列 320 宽 / 末行 256 高），
湖面的水色抖动、岸边那一圈沙岸都是**像素级烘死**在图里的，运行时没有画水面的代码
（WaterFX 只叠波光）。所以 world.json 里新加的水格如果只改数据，地上一片草 ——
船会从草地上划过去。

做法
----
1. 从 world.json 的 bridges[].rows 求出「新水格」（河道逐行的 [y, x0, x1]），
   再扣掉本来就属于原有水面的格 —— 只重绘真正新增的那部分。
2. 每个新水格贴一块 8×8 的**纯水格**（从原图里挑，底色/抖动/斑块全一致）。
   相邻格大概率沿用同一块，形成 2~3 格的连续水面，不会出现拼贴感。
3. 与原有水面接壤的那一圈像素做随机混合（越靠边概率越高，取自邻格真实水面的
   镜像行/列）—— 边界逐像素连续，不会留下一条横线。
4. 新水与陆地的接触面补一圈沙岸：陆地格整格铺沙（保留少量原像素做颗粒感）。
5. 只有内容真的变了的块才写回；原图先备份到 assets/ground_bak/。

用法（项目根目录）：
  python3 tools/fit_channels.py         # 先算河道形状，写回 world.json
  python3 tools/bake_channels.py        # 再烘进地面图
  python3 tools/bake_channels.py --dry  # 只报告要改哪些块，不写文件
"""
import json
import os
import random
import shutil
import sys

from PIL import Image, ImageChops

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fit_channels import rows_to_rects        # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CELL = 8
CHUNK = 1024                      # 每块 1024×1024 像素（末列/末行是补边的小块）

# 水面调色板（从烘焙图里采样得到）
WATER_BASE = (94, 169, 201)
WATER_LIGHT = (104, 179, 209)
WATER_DARK = (79, 155, 187)
WATER_SPARK = (118, 193, 223)
WATER_COLORS = {WATER_BASE, WATER_LIGHT, WATER_DARK, WATER_SPARK}

SAND = (201, 187, 150)
SAND_LIGHT = (213, 199, 162)
SAND_COLORS = {SAND, SAND_LIGHT}


def load_world():
    with open(os.path.join(ROOT, "assets/world.json"), encoding="utf-8") as f:
        return json.load(f)


def color_mask(img, colors):
    """返回 L 模式掩码：像素颜色正好是 colors 之一 → 255，否则 0。

    用 difference + 查表，全走 PIL 的 C 实现，比逐像素 Python 循环快两三个数量级。
    """
    lut = [255 if i == 0 else 0 for i in range(256)]
    out = Image.new("L", img.size, 0)
    for c in colors:
        diff = ImageChops.difference(img, Image.new("RGB", img.size, c))
        out = ImageChops.lighter(out, diff.convert("L").point(lut))
    return out


def main():
    dry = "--dry" in sys.argv
    d = load_world()
    W, H = int(d["map"]["W"]), int(d["map"]["H"])
    img_w, img_h = W * CELL, H * CELL

    bridges = d.get("bridges", [])
    if not bridges:
        print("world.json 没有 bridges，跳过")
        return

    # ---------------------------------------------------------------- 新水格 / 原有水格
    chan_cells = set()
    chan_rect_keys = set()
    for b in bridges:
        rows = b.get("rows") or []
        if not rows:
            print("!! 桥缺 rows 字段，先跑 tools/fit_channels.py")
            return
        for y, x0, x1 in rows:
            for x in range(x0, x1 + 1):
                chan_cells.add((x, y))
        for r in rows_to_rects(rows):
            chan_rect_keys.add((r["x"], r["y"], r["w"], r["h"]))

    old_water = set()
    for r in d["water"]:
        if (r["x"], r["y"], r["w"], r["h"]) in chan_rect_keys:
            continue                     # 这一条就是河道本身，不算原有水
        for y in range(r["y"], r["y"] + r["h"]):
            for x in range(r["x"], r["x"] + r["w"]):
                old_water.add((x, y))

    # ---------------------------------------------------------------- 拼整图
    canvas = Image.new("RGB", (img_w, img_h))
    origin = {}
    for cy in range((img_h + CHUNK - 1) // CHUNK):
        for cx in range((img_w + CHUNK - 1) // CHUNK):
            p = os.path.join(ROOT, "assets/ground/g%d_%d.png" % (cx, cy))
            if not os.path.exists(p):
                print("缺少地面块:", p)
                return
            im = Image.open(p).convert("RGB")
            origin[(cx, cy)] = (cx * CHUNK, cy * CHUNK, im)
            canvas.paste(im, (cx * CHUNK, cy * CHUNK))

    # 8×8 全水的格 → 可当贴图模板（整块缩成 1 像素，全 255 才是纯水）
    block_mask = color_mask(canvas, WATER_COLORS).reduce(CELL)
    blk = block_mask.load()
    is_pure = lambda gx, gy: (0 <= gx < W and 0 <= gy < H and blk[gx, gy] == 255)
    rs = random.Random(20261102)

    # 真正要画水的格 = 河道格里「图上还不是纯水」的那些。
    # 不能只用 old_water 过滤：world.json 的矩形是整格取整，比美术多边形大一圈，
    # 河道两端常有「数据算水、图上却是岸线沙」的格，跳过它们就会在水里留一片沙。
    new_water = {(x, y) for (x, y) in chan_cells if not is_pure(x, y)}
    print("河道格 %d，需要重绘 %d" % (len(chan_cells), len(new_water)))

    # ---------------------------------------------------------------- 贴水纹（镜像平铺）
    # 逐格拼贴会在格与格之间留下 8px 的横向条带（每格一块不同贴图）。
    # 改成整条河道用同一块大水面镜像平铺：图案本身是原图真实水色，镜像让平铺边界
    # 逐像素连续，河道内部就完全看不出接缝。
    TILE = 96                                  # 12 格
    factor = TILE // CELL
    tile_blocks = block_mask.reduce(factor)
    tb = tile_blocks.load()
    tw, th = tile_blocks.size
    cands = [(x, y) for y in range(th) for x in range(tw) if tb[x, y] == 255]
    if not cands:
        print("!! 找不到 %dx%d 的纯水区当水纹" % (TILE, TILE))
        return
    tcx, tcy = cands[rs.randrange(len(cands))]
    tile = canvas.crop((tcx * TILE, tcy * TILE, tcx * TILE + TILE, tcy * TILE + TILE))
    tpx = tile.load()
    period = 2 * TILE

    def tile_px(px, py):
        mx = px % period
        if mx >= TILE:
            mx = period - 1 - mx
        my = py % period
        if my >= TILE:
            my = period - 1 - my
        return tpx[mx, my]

    for (x, y) in new_water:
        for j in range(CELL):
            for i in range(CELL):
                px, py = x * CELL + i, y * CELL + j
                canvas.putpixel((px, py), tile_px(px, py))
    print("贴水纹: %dx%d 像素（镜像平铺，周期 %d）" % (TILE, TILE, period))

    # ---------------------------------------------------------------- 接缝过渡
    # 与原有水面相邻的一圈像素：越靠边，越大概率换成邻格真实水面镜像过来的那一个像素。
    # 只在「边界带」内混，内部保持整块贴图，所以既没有硬边也不会整体发花。
    before = canvas.copy()
    n_mix = 0
    for (x, y) in new_water:
        for (dx, dy) in ((0, -1), (0, 1), (-1, 0), (1, 0)):
            nb = (x + dx, y + dy)
            if nb not in old_water:
                continue
            # 邻格的像素原点，以及镜像时要翻的那条轴
            nx0, ny0 = nb[0] * CELL, nb[1] * CELL
            for j in range(CELL):
                for i in range(CELL):
                    dist = j if dy == -1 else (CELL - 1 - j) if dy == 1 \
                        else i if dx == -1 else (CELL - 1 - i)
                    w = 1.0 - dist / float(CELL)
                    if rs.random() >= w:
                        continue
                    if dy != 0:
                        sx2, sy2 = nx0 + i, ny0 + (CELL - 1 - j)
                    else:
                        sx2, sy2 = nx0 + (CELL - 1 - i), ny0 + j
                    src = before.getpixel((sx2, sy2))
                    if src not in WATER_COLORS:
                        continue             # 邻格边上那圈沙不能混进来
                    canvas.putpixel((x * CELL + i, y * CELL + j), src)
                    n_mix += 1
    print("接缝过渡像素:", n_mix)

    # ---------------------------------------------------------------- 水道口清沙
    # 美术是按多边形 rasterize 的，岸线常比 world.json 的矩形边内缩一格 ——
    # 那一格在数据里算水、图上却是沙。水道打通后它就成了横在水道口的一道沙埂。
    def cell_sand_count(x, y):
        return sum(1 for j in range(CELL) for i in range(CELL)
                   if canvas.getpixel((x * CELL + i, y * CELL + j)) in SAND_COLORS)

    def find_pure_near(x, y, radius=6):
        for rad in range(1, radius + 1):
            for dy in range(-rad, rad + 1):
                for dx in range(-rad, rad + 1):
                    if max(abs(dx), abs(dy)) == rad and is_pure(x + dx, y + dy):
                        return (x + dx, y + dy)
        return None

    cleaned = 0
    for (x, y) in new_water:
        for (dx, dy) in ((0, -1), (0, 1), (-1, 0), (1, 0)):
            nb = (x + dx, y + dy)
            if nb not in old_water:
                continue
            if cell_sand_count(*nb) < 32:
                continue
            src_cell = find_pure_near(*nb)
            if src_cell is None:
                continue
            sx, sy = src_cell[0] * CELL, src_cell[1] * CELL
            canvas.paste(canvas.crop((sx, sy, sx + CELL, sy + CELL)),
                         (nb[0] * CELL, nb[1] * CELL))
            cleaned += 1
    print("水道口清沙格:", cleaned)

    # ---------------------------------------------------------------- 新岸线补沙
    ring = set()
    for (x, y) in new_water:
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if (nx, ny) in new_water or (nx, ny) in old_water:
                continue
            if not (0 <= nx < W and 0 <= ny < H):
                continue
            ring.add((nx, ny))
    print("新增岸线格:", len(ring))

    rs2 = random.Random(1125)
    for (cx, cy) in ring:
        base = canvas.crop((cx * CELL, cy * CELL, cx * CELL + CELL, cy * CELL + CELL))
        out = Image.new("RGB", (CELL, CELL))
        for j in range(CELL):
            for i in range(CELL):
                r = rs2.random()
                if r < 0.84:
                    out.putpixel((i, j), SAND)
                elif r < 0.92:
                    out.putpixel((i, j), SAND_LIGHT)
                else:
                    out.putpixel((i, j), base.getpixel((i, j)))
        canvas.paste(out, (cx * CELL, cy * CELL))

    # ---------------------------------------------------------------- 比较并写回
    os.makedirs(os.path.join(ROOT, "assets/ground_bak"), exist_ok=True)
    changed = {}
    for (cx, cy), (ox, oy, im) in origin.items():
        after = canvas.crop((ox, oy, ox + im.size[0], oy + im.size[1]))
        if ImageChops.difference(im, after).getbbox() is None:
            continue
        changed[(cx, cy)] = after

    if not changed:
        print("没有需要修改的地面块")
        return
    print("需要写回的块:", sorted(changed))
    if dry:
        print("--dry：不写文件")
        return
    for (cx, cy), after in changed.items():
        p = os.path.join(ROOT, "assets/ground/g%d_%d.png" % (cx, cy))
        bak = os.path.join(ROOT, "assets/ground_bak/g%d_%d.png" % (cx, cy))
        if not os.path.exists(bak):
            shutil.copy2(p, bak)
        after.save(p)
        print("  写入", p)
    print("完成。备份在 assets/ground_bak/")


if __name__ == "__main__":
    main()
