#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成路口斑马线地贴（Ground 层 sprite，不改任何地面 PNG）。

实测校园主路只有 3 格（24px）宽，沥青有渐变、中心白虚线与路缘会打断
「逐格颜色分类」。所以地贴做成 24x24 的紧凑方块，4 条白条共 22px，
两侧各留 1px 透明，靠摆位脚本按路面横截面自动对齐中心。

    props_zebra_ns.png  24x24  南北向道路用，4 条竖向白条
    props_zebra_ew.png  24x24  东西向道路用，4 条横向白条

白条用偏暖的灰白 (226,228,220)，不用纯白，避免日间 CanvasModulate 过曝；
每条白条下沿 / 右沿 1px 暗边，保持像素风实线硬边又不至于贴纸味太重。
"""
import os
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets")

WHITE = (226, 228, 220)
SHADE = (158, 163, 158)

SIZE = 24
BAR_W = 4                    # 白条短边
BAR_L = 20                   # 白条长边
GAP = 2
N = 4
SPAN = N * BAR_W + (N - 1) * GAP       # 22px
START = (SIZE - SPAN) // 2             # 1
PAD_L = (SIZE - BAR_L) // 2            # 2


def _bar(d, x0, y0, vertical):
    """画一条带下沿 / 右沿暗边的白条。"""
    if vertical:
        x1, y1 = x0 + BAR_W - 1, y0 + BAR_L - 1
        d.line([(x0 + 1, y1 + 1), (x1, y1 + 1)], fill=SHADE + (255,))
    else:
        x1, y1 = x0 + BAR_L - 1, y0 + BAR_W - 1
        d.line([(x1 + 1, y0 + 1), (x1 + 1, y1)], fill=SHADE + (255,))
    d.rectangle([x0, y0, x1, y1], fill=WHITE + (255,))


def zebra_ns():
    im = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    for i in range(N):
        _bar(d, START + i * (BAR_W + GAP), PAD_L, vertical=True)
    return im


def zebra_ew():
    im = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    for i in range(N):
        _bar(d, PAD_L, START + i * (BAR_W + GAP), vertical=False)
    return im


def main():
    for name, fn in (("props_zebra_ns.png", zebra_ns),
                     ("props_zebra_ew.png", zebra_ew)):
        im = fn()
        im.save(os.path.join(OUT, name))
        print("[road_marks] %s %s alpha=%s"
              % (name, im.size, im.getchannel("A").getbbox()))


if __name__ == "__main__":
    main()
