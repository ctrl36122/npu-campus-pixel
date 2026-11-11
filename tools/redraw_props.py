#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""重绘道具 sprite（目前只有长椅）。

为什么要有这个脚本：`props_bench.png` 原来是一块深棕色平板（靠背和坐面各一条
纯色横带、2px 藏青描边），在 8px/格的画面里 24×26 只有几十个屏幕像素，读出来
就是「带腿的木板箱」。改法是在同样的 24×26 画布里补上：

  · 靠背 4 根竖条板（有亮边）—— 一眼能看出是「椅子」而不是箱子；
  · 坐面分三层：受光顶面 / 前立面 / 下沿，做出厚度；
  · 底部椭圆接地阴影 —— 不画阴影的小物件在草地上像浮着（参考树的画法）。

尺寸和锚点必须与旧版一致（24×26，原点在底边中心），否则 world.json 里
已有 14 张长椅的 `collide` 和 baseY 会全部错位。

用法：python tools/redraw_props.py     # 直接覆盖 assets/props_bench.png
"""
import os

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

W, H = 24, 26
OUT = (42, 44, 58)        # 描边（和垃圾桶、售票机同一支藏青，全场统一）
SHADOW = (26, 42, 28, 64)  # 接地阴影（半透明暗绿，压在草上不发灰）
SLAT = (150, 100, 60)     # 靠背条板
SLAT_HI = (186, 132, 84)  # 条板上沿受光
SEAT_HI = (208, 158, 106)  # 坐面顶面
SEAT = (174, 122, 76)     # 坐面前立面
SEAT_LO = (140, 96, 60)   # 坐面下沿
LEG = (100, 64, 42)


def bench():
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)

    d.ellipse([3, 21, 20, 25], fill=SHADOW)

    # 靠背外框 + 4 根竖条板（条板和靠背同高，不出尖角）
    d.rectangle([3, 4, 20, 13], fill=OUT)
    for i in range(4):
        x = 5 + i * 4
        d.rectangle([x, 5, x + 2, 12], fill=SLAT)
        d.rectangle([x, 5, x + 2, 5], fill=SLAT_HI)

    # 坐面：描边 → 受光顶面 → 前立面 → 下沿
    d.rectangle([2, 14, 21, 19], fill=OUT)
    d.rectangle([3, 15, 20, 15], fill=SEAT_HI)
    d.rectangle([3, 16, 20, 17], fill=SEAT)
    d.rectangle([3, 18, 20, 18], fill=SEAT_LO)

    # 腿
    d.rectangle([4, 19, 6, 23], fill=OUT)
    d.rectangle([5, 19, 5, 22], fill=LEG)
    d.rectangle([17, 19, 19, 23], fill=OUT)
    d.rectangle([18, 19, 18, 22], fill=LEG)
    return im


def main():
    out = os.path.join(ROOT, "assets", "props_bench.png")
    bench().save(out)
    print("[redraw] 已重绘 %s (%dx%d)" % (os.path.relpath(out, ROOT), W, H))
    print("[redraw] 接着跑 godot --headless --path . --import")


if __name__ == "__main__":
    main()
