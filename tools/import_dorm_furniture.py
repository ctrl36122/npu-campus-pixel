#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 OGA「Top-Down Home Furniture」（hooded-crow，CC-BY 3.0）切出宿舍家具，
2:1 最近邻缩小后打包成 assets/room_dorm.png 图集。

源图：assets/oga_src/dorm_furniture/top_down_bed_room.png（400×400）
2:1 缩小的原因：源图的像素密度是我们世界像素的 2 倍（人物 18px 高的房间里，
床按源尺寸是 49×26 ≈ 4.6m×2.4m，太大）；整除 2 的最近邻缩小不产生半像素混色，
缩完的 1px 像素块和程序画的家具颗粒感一致。

输出图集是横向一排，每个 cell 左对齐、顶对齐、间隔 2px；
cell 的 atlas 矩形同步打印成 GDScript 常量（贴进 room_prop.gd 的 DORM_CELLS）。
幂等：同一份源图反复跑，输出逐字节一致。
"""
import os
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "assets", "oga_src", "dorm_furniture",
                   "top_down_bed_room.png")
OUT = os.path.join(ROOT, "assets", "room_dorm.png")

# (名字, 源图 crop (x, y, w, h))。crop 全部偶数宽高，保证 2:1 最近邻缩小干净。
# 坐标来自对源图的连通域检测（见 build/_oga 的分析记录），留 1~2px 余量。
CELLS = [
    ("bed",       (204, 38, 50, 28)),   # 单人床，俯视、床头朝左
    ("wardrobe",  (212, 122, 30, 40)),  # 衣柜（正面带柜门缝）
    ("bookshelf", (326, 38, 22, 40)),   # 高书柜（顶天立地那款）
    ("shelf",     (324, 122, 22, 40)),  # 矮书架
    ("desk_pc",   (256, 290, 40, 30)),  # 带显示器和键盘的书桌
    ("desk",      (206, 212, 40, 28)),  # 桌面堆了东西的书桌（俯视带桌腿）
    ("table",     (312, 216, 40, 24)),  # 空桌
    ("chair",     (268, 218, 16, 22)),  # 靠背椅
    ("stool",     (250, 356, 16, 18)),  # 圆凳
    ("box",       (288, 354, 14, 20)),  # 纸箱
]

MARGIN = 2


def main() -> int:
    src = Image.open(SRC).convert("RGBA")
    out_cells = []
    x = 0
    max_h = 0
    for name, (cx, cy, cw, ch) in CELLS:
        assert cw % 2 == 0 and ch % 2 == 0, name
        im = src.crop((cx, cy, cx + cw, cy + cy * 0 + ch))
        im = im.resize((cw // 2, ch // 2), Image.NEAREST)
        out_cells.append((name, x, 0, im))
        x += im.width + MARGIN
        max_h = max(max_h, im.height)
    atlas = Image.new("RGBA", (x, max_h), (0, 0, 0, 0))
    for name, ox, oy, im in out_cells:
        atlas.paste(im, (ox, oy))
        print('  "%s": Rect2(%d, %d, %d, %d),' % (
            name, ox, oy, im.width, im.height))
    atlas.save(OUT)
    print("-> %s (%dx%d)" % (OUT, atlas.width, atlas.height))
    return 0


if __name__ == "__main__":
    sys.exit(main())
