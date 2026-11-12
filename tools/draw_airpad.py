# -*- coding: utf-8 -*-
"""生成「航空展示区」停机坪地贴（Ground 层精灵）。

不修改任何 ground/g*_*.png：地贴是独立的半透明精灵，铺在地面贴图之上、
Objects 之下。因此 road / grass / water 掩码与道具候选网格都保持 0 差异。

用法：
  python tools/draw_airpad.py            # 生成 assets/props_airpad3.png / props_airpad1.png
"""
import os
import random
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "assets")

# 偏灰绿、压低亮度：日间 CanvasModulate 会把浅色抬得很亮，
# 太白会盖过草地变成「一片水泥广场」，也会把飞机自带的矩形机影衬成补丁。
BASE = (162, 168, 154)
EDGE = (104, 110, 100)
DASH = (206, 210, 194)
SEP = (142, 148, 136)
TIE = (112, 118, 108)


def make(width, height, slots, out_name, seed):
    rnd = random.Random(seed)
    # 基底：低对比的 2x2 色块噪声，保持像素风
    base = Image.new("RGB", (width, height), BASE)
    bd = ImageDraw.Draw(base)
    for _ in range(width * height // 90):
        x, y = rnd.randrange(0, width - 1), rnd.randrange(0, height - 1)
        d = rnd.choice((-6, -4, -2, 2, 4, 6))
        bd.rectangle([x, y, x + 1, y + 1],
                     fill=(BASE[0] + d, BASE[1] + d, BASE[2] + d))

    radius = 26
    mask = Image.new("L", (width, height), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [2, 2, width - 3, height - 3], radius=radius, fill=255)
    inner = mask.filter(ImageFilter.MinFilter(5))
    rim = Image.new("L", (width, height), 0)
    rim.paste(255, (0, 0), Image.frombytes(
        "L", (width, height),
        bytes(255 if a and not b else 0 for a, b in
              zip(mask.tobytes(), inner.tobytes()))))

    im = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    im.paste(base, (0, 0), mask)
    im.paste(EDGE + (255,), (0, 0), rim)

    dr = ImageDraw.Draw(im)
    # 内侧白色虚线（上下两条水平 + 左右两条竖直，避开圆角）
    for y in (16, height - 17):
        for x in range(radius, width - radius, 22):
            dr.rectangle([x, y, x + 12, y + 1], fill=DASH + (255,))
    for x in (16, width - 17):
        for y in range(radius, height - radius, 22):
            dr.rectangle([x, y, x + 1, y + 12], fill=DASH + (255,))
    # 停机位分隔线 + 每个机位的四个系留点
    step = width // slots
    for i in range(1, slots):
        x = step * i
        dr.rectangle([x - 1, 26, x, height - 27], fill=SEP + (255,))
    for i in range(slots):
        cx = step * i + step // 2
        for dx in (-step // 3, step // 3):
            for dy in (-height // 3, height // 3):
                dr.rectangle([cx + dx - 3, height // 2 + dy - 3,
                              cx + dx + 3, height // 2 + dy + 3],
                             fill=TIE + (255,))

    path = os.path.join(ASSETS, out_name)
    im.save(path)
    print("[airpad] %s %dx%d slots=%d" % (out_name, width, height, slots))


if __name__ == "__main__":
    make(960, 224, 3, "props_airpad3.png", 20261112)
    make(480, 224, 1, "props_airpad1.png", 20261113)
