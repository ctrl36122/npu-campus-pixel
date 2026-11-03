#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给 4 个基础英雄（SkyOffice，MIT）生成「换装」变体，扩充选角/闲逛 NPC 的可用角色。

做法：用 PIL 把精灵里**只属于衣服**的像素做色相旋转（皮肤/暗描边/高光不动），
写出新的 52 帧 32x48 图集 PNG。服装色由高饱和 + 中明度 + 非肤色区间三个条件锁定，
所以换出来的角色衣服变了、脸和轮廓都还在，不会出现「绿脸」。

生成的新 PNG（assets/sandbox/heroes/<id>.png）随后由
    godot --headless --script res://tools/gen_hero_variant.gd -- --sheet ... --out ...
生成对应的 frames_<id>.tres（改 atlas 指向新 PNG，动画布局沿用原版），
再在 scripts/sandbox/hero_db.gd 的 HEROES 里加一行即可。

用法：python tools/make_hero_variants.py
"""
import colorsys
import os

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HEROES_DIR = os.path.join(ROOT, "assets", "sandbox", "heroes")

# (新 id, 基础文件, 色相旋转量[0,1), 显示名)
VARIANTS = [
    ("adam_r",   "adam.png",   0.30, "亚当·蓝"),
    ("adam_p",   "adam.png",   0.55, "亚当·紫"),
    ("ash_g",    "ash.png",    0.46, "艾什·青"),
    ("ash_o",    "ash.png",    0.70, "艾什·橙"),
    ("lucy_b",   "lucy.png",   0.15, "露西·粉"),
    ("lucy_t",   "lucy.png",   0.45, "露西·金"),
    ("nancy_v",  "nancy.png",  0.35, "南希·堇"),
    ("nancy_c",  "nancy.png",  0.62, "南希·红"),
]


def recolor(src_path, delta):
    im = Image.open(src_path).convert("RGBA")
    W, H = im.size
    px = im.load()
    out = Image.new("RGBA", (W, H))
    op = out.load()
    for y in range(H):
        for x in range(W):
            r, g, b, a = px[x, y]
            if a < 128:
                op[x, y] = (r, g, b, a)
                continue
            rf, gf, bf = r / 255.0, g / 255.0, b / 255.0
            h, s, v = colorsys.rgb_to_hsv(rf, gf, bf)
            # 只动「衣服」：饱和够高、明度居中（排除暗描边与高光）、且不是肤色橙黄区
            if s > 0.16 and 0.30 <= v <= 0.92 and not (0.0 <= h * 360.0 <= 40.0):
                h2 = (h + delta) % 1.0
                r2, g2, b2 = colorsys.hsv_to_rgb(h2, s, v)
                op[x, y] = (int(round(r2 * 255)), int(round(g2 * 255)),
                            int(round(b2 * 255)), a)
            else:
                op[x, y] = (r, g, b, a)
    return out


def main():
    for vid, base, delta, _name in VARIANTS:
        src = os.path.join(HEROES_DIR, base)
        dst = os.path.join(HEROES_DIR, vid + ".png")
        recolor(src, delta).save(dst)
        print("[variant] %s <- %s (hue +%.0f deg)" % (vid, base, delta * 360))


if __name__ == "__main__":
    main()
