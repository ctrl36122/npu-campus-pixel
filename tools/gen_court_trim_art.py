#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成球场围网与高杆灯贴图。

- props_fence_h.png   8 格宽 × 3 格高的围网横段，可平铺（左端一根立柱）
- props_light_tower.png  9 格高的球场投光灯杆

画风和 props_lamp.png 保持一致：深蓝灰骨架 + 暖光，线条落实在整像素。
"""
import os

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "assets")

POST = (66, 74, 86, 255)        # 立柱 / 杆
POST_HI = (98, 108, 122, 255)   # 受光面
RAIL = (92, 102, 116, 255)      # 横杆
NET_A = (46, 54, 66, 120)       # 网面竖线（深色细网，比浅色半透明更清楚）
NET_B = (52, 60, 72, 84)        # 网面横线
SHADOW = (26, 32, 40, 80)


def fence_h(seg_w=64, h=19):
    """一段围网：左端立柱 + 顶横杆 + 细网面。压低到 19px，远看是一条线不是一排柱子。"""
    im = Image.new("RGBA", (seg_w, h + 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    net_top = 3
    net_bot = h - 2

    # 网面：竖线 4px 一道、横线 4px 一道，深色细线
    for x in range(1, seg_w, 4):
        d.line([(x, net_top), (x, net_bot)], fill=NET_A)
    for y in range(net_top, net_bot, 4):
        d.line([(1, y), (seg_w - 1, y)], fill=NET_B)

    # 顶横杆
    d.line([(0, net_top), (seg_w - 1, net_top)], fill=RAIL)

    # 立柱（左端 2px），带 1px 受光边
    d.rectangle([0, 0, 1, h - 1], fill=POST)
    d.line([(0, 0), (0, h - 1)], fill=POST_HI)

    # 地面接触阴影
    d.line([(0, h), (seg_w - 1, h)], fill=SHADOW)
    return im


def light_tower(w=20, h=76):
    """球场投光灯：底座 + 细杆 + 顶部灯箱。"""
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    cx = w // 2

    # 底座
    d.rectangle([cx - 3, h - 5, cx + 3, h - 1], fill=POST)
    d.line([(cx - 3, h - 5), (cx + 3, h - 5)], fill=POST_HI)
    # 杆（越往上越细：下段 3px、上段 2px）
    d.rectangle([cx - 1, 16, cx + 1, h - 6], fill=POST)
    d.line([(cx - 1, 16), (cx - 1, h - 6)], fill=POST_HI)

    # 顶部灯箱：一条横梁 + 4 个灯头，朝下打光
    d.rectangle([1, 6, w - 2, 14], fill=(38, 46, 56, 255))
    d.rectangle([1, 6, w - 2, 7], fill=POST_HI)
    lamp_w = 4
    gap = (w - 2 - 4 * lamp_w) // 5
    for i in range(4):
        lx = 2 + gap + i * (lamp_w + gap)
        d.rectangle([lx, 9, lx + lamp_w - 1, 13], fill=(255, 226, 150, 255))
        d.line([(lx, 13), (lx + lamp_w - 1, 13)], fill=(255, 246, 208, 255))

    # 灯箱与杆之间的斜撑
    d.line([(cx, 14), (cx - 4, 18)], fill=POST)
    d.line([(cx, 14), (cx + 4, 18)], fill=POST)
    return im


def main():
    f = fence_h()
    f.save(os.path.join(OUT, "props_fence_h.png"))
    print("props_fence_h.png  %dx%d" % f.size)

    t = light_tower()
    t.save(os.path.join(OUT, "props_light_tower.png"))
    print("props_light_tower.png  %dx%d" % t.size)


if __name__ == "__main__":
    main()
