#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生活小物件贴图：小汽车（4 色 × 横竖）、停车场地面、路牌。

风格与现有 props 一致：深描边 + 平涂 + 不抗锯齿，1 艺术像素 = 1 校园像素（8px/格）。
尺寸参照：真实小车 ≈ 4.6×1.8 m ≈ 1.6×0.65 格 ≈ 13×5 px。
这里画到 9×16，比真实略胖一圈 —— 纯 13×5 在屏幕上会糊成一团，适度夸张更易辨认。

用法：python tools/gen_parking_cars.py
生成后：godot --headless --import
"""
import os

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "assets")

EDGE = (24, 28, 36, 255)
TIRE = (38, 42, 50, 255)
GLASS = (46, 62, 84, 255)
GLASS_L = (92, 120, 150, 255)
LIGHT = (246, 226, 148, 255)
TAIL = (208, 74, 62, 255)

# 车身配色：(主色, 暗面, 亮面)
CAR_COLORS = {
    "white": ((226, 230, 234, 255), (168, 176, 186, 255), (250, 252, 255, 255)),
    "silver": ((176, 182, 190, 255), (128, 134, 144, 255), (212, 218, 226, 255)),
    "blue": ((58, 96, 158, 255), (36, 64, 112, 255), (96, 140, 200, 255)),
    "red": ((176, 62, 58, 255), (128, 38, 38, 255), (214, 100, 92, 255)),
    "black": ((58, 62, 70, 255), (36, 40, 46, 255), (96, 102, 112, 255)),
}


def car_art(body, dark, light):
    """竖着放的轿车（车头朝上），9×16。逐行画，形状才读得出来：
    前保险杠/引擎盖/前挡风/车顶/后窗/后备箱/后保险杠，两侧各两个轮子。"""
    w, h = 9, 16
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)

    def row(y, x0, x1, col):
        d.rectangle([x0, y, x1, y], fill=col)

    # 车身主块（留出左右各 1px 给轮子和描边）
    for y in range(1, h - 1):
        row(y, 1, w - 2, body)
    # 前低后高的"腰"：车头略窄
    for y in (1, 2):
        d.point([(1, y), (w - 2, y)], fill=(0, 0, 0, 0))
        row(y, 2, w - 3, body)
    # 引擎盖 / 后备箱压暗
    for y in (3, 4, 12, 13):
        row(y, 2, w - 3, dark)
    # 前挡风 + 后窗
    for y in (5, 6):
        row(y, 2, w - 3, GLASS)
        d.point([(3, y)], fill=GLASS_L)
    row(11, 2, w - 3, GLASS)
    # 车顶（受光）
    for y in range(7, 11):
        row(y, 2, w - 3, light)
    row(9, 3, w - 4, body)          # 车顶中间一道色带，别太亮
    # 车轮：左右各两个
    for y in (4, 5, 10, 11):
        d.point([(0, y), (w - 1, y)], fill=TIRE)
    for y in (4, 10):
        d.point([(0, y + 1), (w - 1, y + 1)], fill=TIRE)
    # 灯
    d.point([(2, 2), (w - 3, 2)], fill=LIGHT)
    d.point([(2, 14), (w - 3, 14)], fill=TAIL)
    # 描边（外轮廓）
    for y in range(1, h - 1):
        d.point([(1, y), (w - 2, y)], fill=EDGE)
    row(1, 1, w - 2, EDGE)
    row(h - 2, 1, w - 2, EDGE)
    return im


def lot_art(row_stalls=8, aisle=26):
    """停车场地面：两排车位 + 中间车道。回车位图，尺寸随车位数量变。"""
    stall_w, stall_d = 15, 19
    pad = 4
    w = row_stalls * stall_w + pad * 2
    h = pad * 2 + stall_d * 2 + aisle
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    asphalt = (100, 106, 112, 255)
    asphalt_d = (92, 98, 104, 255)
    line = (228, 232, 236, 255)
    curb = (168, 172, 176, 255)
    # 沥青底 + 一条细噪点，避免死平
    d.rectangle([0, 0, w - 1, h - 1], fill=asphalt)
    for i in range(0, w, 7):
        d.point([(i, (i * 5) % h), ((i * 3) % w, (i * 11) % h)], fill=asphalt_d)
    # 路缘
    d.rectangle([0, 0, w - 1, 0], fill=curb)
    d.rectangle([0, h - 1, w - 1, h - 1], fill=curb)
    # 两排车位线
    for r in (0, 1):
        y0 = pad + r * (stall_d + aisle)
        d.line([pad, y0, w - pad, y0], fill=line)
        for i in range(row_stalls + 1):
            x = pad + i * stall_w
            d.line([x, y0, x, y0 + stall_d], fill=line)
    return im


def sign_art():
    """停车场「P」牌：28×40，蓝底白 P + 单立柱 + 底座。
    线宽/描边跟项目里的既有路牌（props_sign_red/yellow，36×30 广告牌）对齐：
    2px 深描边 + 1px 内侧亮线 + 深色立柱，不能画成细线条小人。"""
    w, h = 28, 40
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    BLUE = (42, 92, 156, 255)
    WHITE = (244, 248, 252, 255)
    POST = (150, 156, 164, 255)

    # 立柱（双柱）：宽度必须 ≥3px，2px 的话描边会把填充吃光，看起来是一根黑棍
    d.rectangle([9, 28, 11, 39], fill=POST, outline=EDGE)
    d.rectangle([16, 28, 18, 39], fill=POST, outline=EDGE)
    # 横档
    d.rectangle([9, 27, 18, 28], fill=(96, 102, 112, 255), outline=EDGE)
    # 牌面
    d.rectangle([1, 1, 26, 26], fill=BLUE, outline=EDGE, width=2)
    d.rectangle([4, 4, 23, 23], outline=(214, 228, 244, 255))
    # 字母 P
    px, py = 9, 7
    d.rectangle([px, py, px + 1, py + 12], fill=WHITE)          # 竖笔
    d.rectangle([px, py, px + 7, py + 1], fill=WHITE)           # 顶横
    d.rectangle([px + 6, py, px + 7, py + 4], fill=WHITE)       # 右竖
    d.rectangle([px, py + 4, px + 7, py + 5], fill=WHITE)       # 中横
    return im


BIN_ART = [
    " EEEEEEEEE ",
    " ELLLLLLLE ",
    " EEEEEEEEE ",
    " EbbbEgggE ",
    " EbbbEgggE ",
    " EbWbEgWgE ",
    " EbWbEgWgE ",
    " EbbbEgggE ",
    " EbbbEgggE ",
    " EbbbEgggE ",
    " EBBBBBBBE ",
    " EEEEEEEEE ",
]


def bin_art():
    """街头分类垃圾桶：11×12（1.4×1.5 格）。
    尺寸约束来自人物：角色精灵在屏幕上只有 13px 高，垃圾桶画到 18px 会比人还高。
    这个尺寸下用 draw 的矩形拼会糊成一团，所以直接逐像素排：
    盖 / 投口一排深色 / 左蓝右灰两格 / 白色标识。
    E=深描边 L=盖 l=盖高光 B=箱体 b=可回收 g=其他 W=标识"""
    pal = {
        "E": EDGE,
        "L": (92, 98, 108, 255),
        "l": (128, 134, 144, 255),
        "B": (156, 162, 172, 255),
        "b": (52, 102, 170, 255),
        "g": (112, 118, 128, 255),
        "W": (238, 242, 248, 255),
    }
    w, h = len(BIN_ART[0]), len(BIN_ART)
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    px = im.load()
    for y, row in enumerate(BIN_ART):
        for x, ch in enumerate(row):
            if ch in pal:
                px[x, y] = pal[ch]
    return im


def main():
    n = 0
    for name, (body, dark, light) in CAR_COLORS.items():
        v = car_art(body, dark, light)
        v.save(os.path.join(OUT, "props_car_%s_v.png" % name))
        v.transpose(Image.FLIP_TOP_BOTTOM).save(os.path.join(OUT, "props_car_%s_vd.png" % name))
        h = v.transpose(Image.ROTATE_90)
        h.save(os.path.join(OUT, "props_car_%s_h.png" % name))
        h.transpose(Image.FLIP_TOP_BOTTOM).save(os.path.join(OUT, "props_car_%s_hd.png" % name))
        n += 4
    lot_art().save(os.path.join(OUT, "props_parking_lot.png"))
    sign_art().save(os.path.join(OUT, "props_sign_blue.png"))
    bin_art().save(os.path.join(OUT, "props_bin_street.png"))
    n += 3
    print("[gen] %d 张贴图已写入 assets/" % n)


if __name__ == "__main__":
    main()
