#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
地形调色：把「泳池蓝的水」和「满校园红砖路」改成接近真实校园的材质。
纯调色板级的改动，不动几何、不加渲染系统 —— 像素游戏里这样改最划算。

1) 水：4 种水色 → 灰绿色系（真实校园湖是浑绿，不是泳池蓝）。
   亮度顺序保持不变，所以原有的深浅层次/波纹照样在。
2) 路：红砖 → 石材/沥青。按「路有多宽」自动分级：
     宽路（>约 3 格）：沥青年色（深灰蓝、几乎无杂色）
     窄路：青灰色石材铺装（保留原有砖缝纹理，只是换成冷灰）
   分级用「腐蚀-膨胀」量宽度：先腐蚀若干次，只有够宽的路才留得下核心，
   再把核心膨胀回原宽度，就得到「宽路区域」。

用法（项目根目录）：
    python3 tools/bake_water_road.py [--dry]

注意：写完要重跑 tools/build_world_scene.gd 重打包场景（世界里的地面
Sprite 引用的是这些 PNG），并升 Arena 里的小地图缓存版本号。
"""
import os
import sys
from PIL import Image, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 旧水色 → 新水色（保持明暗顺序）
WATER_MAP = {
    (79, 155, 187): (88, 128, 116),
    (94, 169, 201): (104, 146, 132),
    (104, 179, 209): (120, 164, 146),
    (118, 193, 223): (142, 188, 164),
}

# 宽路阈值：腐蚀半径（像素）。一格 8px，半径 9px ≈ 路宽 >18px（≈2.2 格）算主路。
# 调大只会让更少的路被算成沥青（校园里绝大多数路本来就窄）。
ERODE_R = 9


def is_brick(c):
    r, g, b = c
    return r > 110 and r > g + 30 and g >= b and g > 55


def luma(c):
    r, g, b = c
    return 0.299 * r + 0.587 * g + 0.114 * b


def paver(c):
    """窄路：青灰色石材。保留原砖的明暗起伏，只换色相。"""
    l = luma(c)
    v = 122.0 + (l - 110.0) * 0.62
    v = max(100.0, min(172.0, v))
    return (int(v - 3), int(v + 1), int(v + 3))


def asphalt(c):
    """宽路：沥青年色，杂色压到很窄的一段，看着更"平"。"""
    l = luma(c)
    v = 90.0 + (l - 110.0) * 0.16
    v = max(80.0, min(104.0, v))
    return (int(v - 1), int(v + 2), int(v + 5))


def erode(mask, r):
    return mask.filter(ImageFilter.MinFilter(r * 2 + 1))


def dilate(mask, r):
    return mask.filter(ImageFilter.MaxFilter(r * 2 + 1))


def process(path, dry=False):
    im = Image.open(path).convert("RGB")
    px = im.load()
    w, h = im.size

    # ---- 1) 建三张掩码：水、砖路 ----
    water = Image.new("L", (w, h), 0)
    road = Image.new("L", (w, h), 0)
    wp, rp = water.load(), road.load()
    for y in range(h):
        for x in range(w):
            c = px[x, y]
            if c in WATER_MAP:
                wp[x, y] = 255
            elif is_brick(c):
                rp[x, y] = 255

    # ---- 2) 宽路 = 腐蚀后的核心再膨胀回去 ----
    core = erode(road, ERODE_R)
    wide = dilate(core, ERODE_R)
    wp2 = wide.load()

    wm = water.load()
    rmp = road.load()
    changed = 0
    for y in range(h):
        for x in range(w):
            c = px[x, y]
            if wm[x, y]:
                nc = WATER_MAP[c]
            elif rmp[x, y]:
                nc = asphalt(c) if wp2[x, y] else paver(c)
            else:
                continue
            if nc != c:
                px[x, y] = nc
                changed += 1

    print(f"  {os.path.basename(path)}: {changed} px")
    if not dry and changed:
        im.save(path)
    return changed


def main():
    dry = "--dry" in sys.argv
    total = 0
    for cy in range(7):
        for cx in range(4):
            p = os.path.join(ROOT, "assets/ground/g%d_%d.png" % (cx, cy))
            if not os.path.exists(p):
                continue
            total += process(p, dry)
    print("[done] %d px%s" % (total, " (dry)" if dry else ""))


if __name__ == "__main__":
    main()
