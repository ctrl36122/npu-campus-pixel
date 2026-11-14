#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""重做草坪小广场的地贴：从「一块灰绿色贴纸」换成真石材铺装。

原来的 props_lawn_disc.png 是一整个橄榄灰的圆，里面随手画了几道同心圈 ——
放在新纹理的草地上就是一张贴纸：颜色不搭、没有材质、边缘还是硬切的。

现在按铺装的做法重画：
  * 主体用 cobblestone_bricks（灰色石板）16px 平铺，按全局格对齐；
  * 外圈一道 3px 深色路缘石，让圆嵌进草地而不是浮在上面；
  * 中间一圈浅色环带 + 圆心用 marble_bricks3，把喷泉托起来；
  * 最外 1px 压暗（接触阴影），没有半透明羽化 —— 全项目都是实线硬边。

用法：
    python tools/make_plaza_disc.py            # 只出预览 shot_plaza_disc.png
    python tools/make_plaza_disc.py --apply    # 写回 assets/props_lawn_disc.png
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageEnhance

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BLOCKS = os.path.join(ROOT, "assets", "blocks")
OUT = os.path.join(ROOT, "assets", "props_lawn_disc.png")
PREVIEW = os.path.join(ROOT, "shot_plaza_disc.png")

SIZE = 192
R_OUT = 95          # 铺装外半径
CURB = 3            # 路缘石宽度
R_BAND_OUT = 70     # 米色分色环外半径
R_BAND_IN = 62      # 米色分色环内半径（8px 宽）
R_MID = 32          # 圆心铺装半径
TILE = 16
SEED = 20261114

# 材料：浅灰白石板打底，米色石材做一道分色环，圆心换略深的灰白
# （cobblestone_bricks 太深太碎，远看像一块摊开的沥青，压不住广场的体量）
PAVE_TEX = "marble_bricks3.png"
BAND_TEX = "limestone_bricks.png"
CORE_TEX = "marble_bricks2.png"
# 分色缝 / 路缘：浅灰，不用纯黑，免得一圈圈像井盖
SEAM = (150, 146, 138, 255)
CURB_DARK = (110, 107, 100, 255)
CURB_LIGHT = (138, 134, 126, 255)
CURB_SHADOW = (86, 84, 79, 255)
# 整盘压暗一档：marble 原色太亮，铺在草地上像一块白盘子
PAVE_SHADE = 0.88


def _tex(name):
    p = os.path.join(BLOCKS, name)
    im = Image.open(p).convert("RGBA")
    if im.size != (TILE, TILE):
        im = im.resize((TILE, TILE), Image.NEAREST)
    return im


def _tile_into(canvas, tex, box, rng_seed):
    """在 box 里铺 tex，16px 对齐，逐格随机旋转/镜像 + 明度微调。"""
    x0, y0, x1, y1 = box
    for ty in range(y0 // TILE * TILE, y1, TILE):
        for tx in range(x0 // TILE * TILE, x1, TILE):
            h = (tx * 374761393 + ty * 668265263 + rng_seed * 1442695041) & 0xFFFFFFFF
            h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
            k = ((h ^ (h >> 16)) & 0xFF)
            t = tex
            if k & 0x80:
                t = t.transpose(Image.FLIP_LEFT_RIGHT)
            if k & 0x40:
                t = t.transpose(Image.FLIP_TOP_BOTTOM)
            if k & 0x20:
                t = t.transpose(Image.ROTATE_90)
            f = 1.0 + (k % 7 - 3) * 0.012
            t = ImageEnhance.Brightness(t).enhance(f)
            canvas.alpha_composite(t, (tx, ty))


def _ring(size, c, r_out, r_in, fill=255):
    """实心圆环掩码：外圆填充后把内圆挖掉。

    不用 `ellipse(outline=..., width=n)` —— 小曲率处 outline 会跳像素，
    叠三圈就成了虚线，远看像画的圈而不是石头路缘。
    """
    m = Image.new("L", size, 0)
    d = ImageDraw.Draw(m)
    d.ellipse([c - r_out, c - r_out, c + r_out, c + r_out], fill=fill)
    if r_in > 0:
        d.ellipse([c - r_in, c - r_in, c + r_in, c + r_in], fill=0)
    return m


def _disc(size, c, r, fill=255):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).ellipse([c - r, c - r, c + r, c + r], fill=fill)
    return m


def build():
    c = SIZE // 2
    base = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    _tile_into(base, _tex(PAVE_TEX), (0, 0, SIZE, SIZE), SEED)

    paved = ImageEnhance.Brightness(base).enhance(PAVE_SHADE)

    # 米色分色环：只留 8px 宽的一道窄圈（宽了会像靶心）
    band = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    _tile_into(band, _tex(BAND_TEX), (0, 0, SIZE, SIZE), SEED + 11)
    band = ImageEnhance.Brightness(band).enhance(PAVE_SHADE)
    paved.paste(band, (0, 0), _ring((SIZE, SIZE), c, R_BAND_OUT, R_BAND_IN))

    # 圆心：换略深一档的灰白石板，喷泉坐上去有个基座感
    core = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    _tile_into(core, _tex(CORE_TEX), (0, 0, SIZE, SIZE), SEED + 23)
    paved.paste(ImageEnhance.Brightness(core).enhance(PAVE_SHADE * 0.97), (0, 0),
                _disc((SIZE, SIZE), c, R_MID))

    out = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    out.paste(paved, (0, 0), _disc((SIZE, SIZE), c, R_OUT))

    d = ImageDraw.Draw(out)
    # 分色缝：1px 浅灰，两道
    for r in (R_BAND_OUT, R_BAND_IN, R_MID):
        d.ellipse([c - r, c - r, c + r, c + r], outline=SEAM, width=1)

    # 路缘石：实心 3px 环，内沿浅、外沿深、最外 1px 接触阴影
    out.paste(CURB_DARK, (0, 0), _ring((SIZE, SIZE), c, R_OUT, R_OUT - CURB))
    out.paste(CURB_LIGHT, (0, 0), _ring((SIZE, SIZE), c, R_OUT - CURB + 1,
                                        R_OUT - CURB))
    out.paste(CURB_SHADOW, (0, 0), _ring((SIZE, SIZE), c, R_OUT + 1, R_OUT))

    # 圆心四方向的十字分格
    for dx, dy in ((0, -1), (0, 1), (-1, 0), (1, 0)):
        d.line([(c, c), (c + dx * R_MID, c + dy * R_MID)], fill=SEAM, width=1)
    return out


def main():
    im = build()
    prev = Image.new("RGB", (im.width * 2, im.height), (30, 30, 34))
    prev.paste(im.resize((im.width, im.height), Image.NEAREST), (0, 0), im)
    if os.path.exists(OUT):
        old = Image.open(OUT).convert("RGBA")
        prev.paste(old, (im.width, 0), old)
    prev.save(PREVIEW)
    print("[disc] 预览 -> %s（左新右旧）" % os.path.basename(PREVIEW))
    if "--apply" in sys.argv:
        im.save(OUT)
        print("[disc] 已写回 %s" % os.path.basename(OUT))


if __name__ == "__main__":
    main()
