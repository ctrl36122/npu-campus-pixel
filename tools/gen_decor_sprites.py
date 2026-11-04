#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""程序化生成两个新装饰 sprite（零素材、像素风），供 place_decor_forge 布点使用：
  - assets/props_flowerbed.png  小花坛 / 花境（贴路边草地）
  - assets/props_stonetable.png 石桌 + 两石凳（楼前 / 广场休憩小品）
用法：python tools/gen_decor_sprites.py
"""
import os
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def new_canvas(w, h):
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    return im, ImageDraw.Draw(im)


def gen_flowerbed():
    W, H = 36, 18
    im, d = new_canvas(W, H)
    # 砖框（底部 + 左右）
    brick = (181, 101, 74, 255)
    d.rectangle([0, 13, W - 1, H - 1], fill=brick)
    d.rectangle([0, 9, 3, H - 1], fill=brick)
    d.rectangle([W - 4, 9, W - 1, H - 1], fill=brick)
    # 土
    soil = (91, 70, 54, 255)
    d.rectangle([3, 9, W - 4, 12], fill=soil)
    # 花（茎 + 花冠），多种花色
    flowers = [
        (6, (226, 74, 74)), (12, (242, 193, 78)), (18, (232, 154, 192)),
        (24, (155, 107, 214)), (30, (226, 74, 74)),
    ]
    leaf = (79, 143, 74, 255)
    for fx, col in flowers:
        # 茎
        d.rectangle([fx, 4, fx, 9], fill=(70, 120, 60, 255))
        # 叶
        d.rectangle([fx - 2, 7, fx - 1, 8], fill=leaf)
        d.rectangle([fx + 1, 6, fx + 2, 7], fill=leaf)
        # 花冠（五瓣小圆 + 花心）
        d.ellipse([fx - 2, 1, fx + 2, 5], fill=col)
        d.ellipse([fx - 3, 2, fx - 1, 4], fill=col)
        d.ellipse([fx + 1, 2, fx + 3, 4], fill=col)
        d.ellipse([fx - 1, 0, fx + 1, 2], fill=col)
        d.ellipse([fx - 1, 3, fx + 1, 5], fill=(255, 230, 120, 255))
    # 草点缀
    for gx in (2, 9, 15, 22, 28, 33):
        d.rectangle([gx, 11, gx, 12], fill=leaf)
    out = os.path.join(ROOT, "assets/props_flowerbed.png")
    im.save(out)
    print("wrote", out, im.size)


def gen_stonetable():
    W, H = 34, 26
    im, d = new_canvas(W, H)
    stone = (184, 178, 166, 255)
    stone_d = (150, 144, 132, 255)
    top = (205, 199, 187, 255)
    shadow = (110, 105, 96, 255)
    # 地面阴影
    d.ellipse([3, 22, 31, 25], fill=(60, 60, 60, 70))
    # 左石凳
    d.rectangle([3, 18, 11, 24], fill=stone)
    d.rectangle([3, 18, 11, 20], fill=top)
    d.rectangle([3, 18, 4, 24], fill=stone_d)
    # 右石凳
    d.rectangle([22, 18, 30, 24], fill=stone)
    d.rectangle([22, 18, 30, 20], fill=top)
    d.rectangle([29, 18, 30, 24], fill=stone_d)
    # 石桌柱
    d.rectangle([14, 14, 19, 24], fill=stone_d)
    # 桌面
    d.rectangle([10, 7, 23, 14], fill=stone)
    d.rectangle([10, 7, 23, 9], fill=top)
    d.rectangle([10, 7, 11, 14], fill=stone_d)
    d.rectangle([22, 7, 23, 14], fill=shadow)
    # 桌面纹理点
    for tx in (13, 17, 20):
        d.rectangle([tx, 10, tx, 11], fill=stone_d)
    out = os.path.join(ROOT, "assets/props_stonetable.png")
    im.save(out)
    print("wrote", out, im.size)


if __name__ == "__main__":
    gen_flowerbed()
    gen_stonetable()
