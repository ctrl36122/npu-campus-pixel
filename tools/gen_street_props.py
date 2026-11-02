#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""校园生活设施贴图（快递柜 / 垃圾桶 / 自行车 / 售货机 / 店招）。

风格对齐现有道具：深描边 + 平涂 + 少量明暗分区，全程不抗锯齿。
尺寸按人物 26px 高做参照（垃圾桶到腰、快递柜比人高、自行车到膝）。

用法：python tools/gen_street_props.py
生成后需要 `godot --headless --import` 让 Godot 建 .import。
"""
import os

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "assets")

# 描边与基础灰阶（取自现有 props 的观感）
EDGE = (27, 32, 41, 255)
STEEL_D = (86, 94, 106, 255)
STEEL = (122, 131, 143, 255)
STEEL_L = (154, 164, 176, 255)
STEEL_XL = (186, 196, 208, 255)
DARK = (58, 64, 75, 255)
YELLOW = (232, 179, 58, 255)
YELLOW_D = (186, 138, 36, 255)
RED = (192, 57, 43, 255)
RED_D = (146, 40, 30, 255)
BLUE = (59, 127, 212, 255)
BLUE_D = (42, 92, 156, 255)
GLASS = (34, 48, 63, 255)
WHITE = (238, 242, 247, 255)


def new(w, h):
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    return im, ImageDraw.Draw(im)


def bin_art():
    """垃圾桶：14x20。桶身带腰线，左侧高光，蓝色可回收标。"""
    w, h = 14, 20
    im, d = new(w, h)
    # 投影
    d.rectangle([2, 18, 11, 19], fill=(24, 28, 35, 90))
    # 桶身
    d.rectangle([2, 5, 11, 18], fill=STEEL, outline=EDGE)
    d.rectangle([3, 6, 4, 17], fill=STEEL_L)          # 左侧高光
    d.rectangle([2, 11, 11, 12], fill=STEEL_D)        # 腰线
    d.rectangle([9, 6, 10, 17], fill=STEEL_D)         # 右侧暗面
    # 桶盖
    d.rectangle([1, 2, 12, 5], fill=DARK, outline=EDGE)
    d.rectangle([2, 3, 11, 3], fill=STEEL_L)
    d.rectangle([6, 1, 7, 2], fill=DARK)              # 提手
    # 可回收标
    d.rectangle([5, 14, 8, 16], fill=BLUE)
    d.line([(5, 14), (8, 14)], fill=(120, 176, 236, 255))
    return im


def locker_art():
    """快递柜：46x42。3x3 格柜门 + 顶部黄牌 + 底部台座。"""
    w, h = 46, 42
    im, d = new(w, h)
    d.rectangle([3, 39, 42, 41], fill=(24, 28, 35, 100))
    # 柜体
    d.rectangle([2, 6, 43, 39], fill=STEEL, outline=EDGE)
    d.rectangle([2, 6, 3, 39], fill=STEEL_L)
    d.rectangle([41, 7, 42, 38], fill=STEEL_D)
    # 顶部黄牌（快递柜的识别色）
    d.rectangle([2, 8, 43, 15], fill=YELLOW, outline=EDGE)
    d.rectangle([2, 8, 43, 9], fill=(246, 206, 112, 255))
    for i in range(4):                                # 牌上一排"字"
        x = 8 + i * 8
        d.rectangle([x, 11, x + 4, 13], fill=(120, 84, 18, 255))
    # 3x3 柜门
    gx0, gy0 = 5, 19
    cw, ch = 12, 6
    for r in range(3):
        for c in range(3):
            x = gx0 + c * (cw + 1)
            y = gy0 + r * (ch + 1)
            d.rectangle([x, y, x + cw - 1, y + ch - 1], fill=STEEL_L, outline=DARK)
            d.line([(x + 1, y + 1), (x + cw - 2, y + 1)], fill=STEEL_XL)
            d.rectangle([x + 1, y + 2, x + 2, y + ch - 3], fill=DARK)   # 把手
    # 台座
    d.rectangle([4, 38, 41, 39], fill=DARK)
    return im


def bike_art():
    """自行车：24x20。侧面两轮 + 蓝车架 + 深色车把车座。"""
    w, h = 24, 20
    im, d = new(w, h)
    d.rectangle([2, 18, 21, 19], fill=(24, 28, 35, 80))
    # 轮子（外圈描边 + 内圈镂空感用深色填充）
    for cx in (5, 18):
        d.ellipse([cx - 4, 11, cx + 4, 19], outline=EDGE, fill=(0, 0, 0, 0))
        d.ellipse([cx - 3, 12, cx + 3, 18], fill=(70, 78, 90, 255))
        d.ellipse([cx - 2, 13, cx + 2, 17], fill=(44, 50, 60, 255))
        d.point((cx, 15), fill=STEEL_L)
    # 车架
    d.line([(5, 15), (11, 9)], fill=BLUE)
    d.line([(11, 9), (17, 9)], fill=BLUE)
    d.line([(11, 9), (12, 15)], fill=BLUE)
    d.line([(12, 15), (18, 15)], fill=BLUE_D)
    d.line([(5, 15), (9, 15)], fill=BLUE_D)
    d.line([(9, 15), (12, 15)], fill=BLUE)
    # 车把 / 车座
    d.line([(17, 9), (18, 7)], fill=EDGE)
    d.line([(16, 7), (20, 7)], fill=DARK)
    d.rectangle([9, 7, 12, 8], fill=DARK)              # 车座
    # 脚蹬
    d.point((10, 16), fill=STEEL_L)
    return im


def vending_art():
    """售货机：20x32。红机身 + 玻璃橱窗 + 取货口。"""
    w, h = 20, 32
    im, d = new(w, h)
    d.rectangle([2, 30, 17, 31], fill=(24, 28, 35, 100))
    d.rectangle([2, 2, 17, 30], fill=RED, outline=EDGE)
    d.rectangle([2, 2, 3, 30], fill=(214, 82, 66, 255))    # 左侧高光
    d.rectangle([16, 3, 17, 29], fill=RED_D)
    # 顶部灯条
    d.rectangle([4, 4, 15, 5], fill=(255, 226, 170, 255))
    # 玻璃橱窗：3 排商品
    d.rectangle([5, 7, 14, 20], fill=GLASS, outline=EDGE)
    for r in range(3):
        y = 9 + r * 4
        for c in range(3):
            x = 6 + c * 3
            col = [(255, 214, 120, 255), (120, 200, 160, 255), (240, 160, 170, 255)][(r + c) % 3]
            d.rectangle([x, y, x + 1, y + 2], fill=col)
        d.line([(5, y + 3), (14, y + 3)], fill=(58, 74, 92, 255))
    # 取货口 + 按钮
    d.rectangle([5, 23, 12, 26], fill=(40, 46, 56, 255), outline=EDGE)
    d.rectangle([6, 27, 11, 28], fill=STEEL_D)
    d.rectangle([13, 24, 14, 25], fill=STEEL_XL)
    return im


def shop_sign_art(base, dark, light):
    """店招：36x30。灯箱 + 雨棚 + 两根立柱，颜色按业态区分。"""
    w, h = 36, 30
    im, d = new(w, h)
    d.rectangle([4, 28, 31, 29], fill=(24, 28, 35, 90))
    # 立柱
    d.rectangle([6, 14, 8, 29], fill=STEEL_D, outline=EDGE)
    d.rectangle([27, 14, 29, 29], fill=STEEL_D, outline=EDGE)
    # 灯箱
    d.rectangle([3, 3, 32, 14], fill=base, outline=EDGE)
    d.rectangle([4, 4, 31, 4], fill=light)             # 顶边高光
    d.rectangle([4, 13, 31, 13], fill=dark)            # 底边暗面
    # 灯箱上的"字位"：四块方块，不画真字（8px 分辨率下不可读）
    for i in range(4):
        x = 8 + i * 6
        d.rectangle([x, 7, x + 4, 11], fill=light)
        d.line([(x, 7), (x + 4, 7)], fill=(255, 255, 255, 200))
    # 雨棚（灯箱下沿伸出的斜条）
    d.polygon([(2, 15), (33, 15), (31, 18), (4, 18)], fill=dark, outline=EDGE)
    for i in range(5):                                 # 雨棚条纹
        x = 5 + i * 6
        d.line([(x, 16), (x, 17)], fill=light)
    return im


def main():
    items = [
        ("props_bin.png", bin_art()),
        ("props_locker.png", locker_art()),
        ("props_bike.png", bike_art()),
        ("props_vending.png", vending_art()),
        ("props_sign_red.png", shop_sign_art(RED, RED_D, (240, 140, 120, 255))),
        ("props_sign_yellow.png", shop_sign_art(YELLOW, YELLOW_D, (250, 220, 140, 255))),
    ]
    for name, im in items:
        path = os.path.join(OUT, name)
        im.save(path)
        print("%-26s %dx%d" % (name, im.width, im.height))


if __name__ == "__main__":
    main()
