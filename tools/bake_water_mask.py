"""烘一张「水在哪」的掩码图给天气 shader 用。

晴天要给湖水单独调色（更蓝更清），但湖水的颜色又是烘焙链的判水依据，
不能改贴图。所以出这张 1px=1格 的黑白图，shader 按世界坐标采样它，
命中的像素才做额外调色 —— 与地面贴图完全解耦。

尺寸：世界 3392×6400 像素、8px 一格 → 424×800。
     这一分辨率正好一格一个像素，缩略图级别的精度，够用且只有几百 KB。

用法：python tools/bake_water_mask.py
"""
import os
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import bake_ground_detail as D  # noqa: E402

CELL = 8              # 一格 8px
THRESHOLD = 0.34      # 一格里有 1/3 是水就算水（岸边别糊掉整格）


def main():
    ww, wh = D.COLS * D.CHUNK, D.ROWS * D.CHUNK
    print("[water] 世界尺寸 %dx%d → 掩码 %dx%d" % (ww, wh, ww // CELL, wh // CELL))
    out = Image.new("L", (ww // CELL, wh // CELL), 0)
    total = 0
    for cy in range(D.ROWS):
        for cx in range(D.COLS):
            p = os.path.join(D.GROUND, "g%d_%d.png" % (cx, cy))
            if not os.path.exists(p):
                continue
            im = Image.open(p).convert("RGB")
            m = D.water_mask(im)
            n = D._nz(m)
            if n == 0:
                continue
            total += n
            # 块内按 8×8 求水像素占比，超过阈值就点亮
            cw, ch = (im.width + CELL - 1) // CELL, (im.height + CELL - 1) // CELL
            frac = m.convert("L").resize((cw, ch), Image.BOX)   # 0..255 的平均
            cell = frac.point(lambda v: 255 if v >= int(THRESHOLD * 255) else 0)
            out.paste(cell, (cx * D.CHUNK // CELL, cy * D.CHUNK // CELL))
    dst = os.path.join(ROOT, "assets", "water_mask.png")
    out.save(dst, optimize=True)
    nz = sum(1 for v in out.getdata() if v)
    print("[water] 水像素 %d（地面 %d px），掩码亮格 %d" % (
        total, ww * wh, nz))
    print("[water] 已写 %s（%d KB）" % (dst, os.path.getsize(dst) // 1024))


if __name__ == "__main__":
    main()
