#!/usr/bin/env python
"""把外部家具 / 书籍素材打包成房间能直接用的贴图。

源素材留在下载目录，不进仓库：
  * 书籍包自带 EULA，允许「集成进作品后分发」，但禁止把原始素材当素材包再分发；
  * 沙发包没有授权文件，来源不明，按 .gitignore 处理。
所以这里只输出**已经缩到游戏内尺寸**的贴图，房间缺图时自动回退程序绘制。

用法：
    python tools/pack_room_assets.py
    python tools/pack_room_assets.py --check     # 只检查源在不在

产物：
    assets/room_books.png   4 本摊开的书，32x18，横排
    assets/room_seats.png   2 张三人沙发（64x53）+ 4 把扶手椅（22x24）
    assets/room_sky_bg.png      背后那片天的上沿（含日月星空），4 时段 x 640x176
    assets/room_sky_fill.png    同一片天往下的渐变底，4 时段 x 640x512
    assets/room_sky_clouds.png  云层（横向无缝，游戏里滚动），4 时段 x 640x512

布局是固定网格，RoomProp 里直接按索引算 Rect2，不另外存 json。
"""
from __future__ import annotations

import argparse
import os
import random
import sys

try:
    from PIL import Image, ImageOps
except ImportError:
    sys.exit("需要 Pillow：pip install pillow")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

BOOK_SRC = os.environ.get(
    "BOOK_ASSET_DIR",
    r"C:\Users\35725\Desktop\Animated Old Book (4 colors) Asset\Animated Old Book (4 colors) Asset",
)
SEAT_SRC = os.environ.get(
    "SEAT_ASSET_DIR",
    r"C:\Users\35725\Downloads\cf055256c97b3396\Couch & Armchairs",
)

# 窗外天空：pixel-sky 的四时段视差背景（dawn / noon / sunset / night）。
# 四档共用同一套地形轮廓，只会换光线，所以在两档之间混合时山脊不会跳动，
# 正好可以跟着游戏里 DayNight 的真实时间走。
SKY_SRC = os.environ.get(
    "SKY_ASSET_DIR",
    r"D://buddy//2026-11-14-18-29-46//pixel-sky",
)

# ── 输出的固定网格 ────────────────────────────────────────────────────────
BOOK_W, BOOK_H = 32, 18
# 沙发格是 8 格宽（64px）、5 格高（54px）；两张源图高度都是 90，宽度不同，
# 所以按宽度 64 等比缩放、在格子里底部对齐 —— 硬拉成同一宽高比会把扶手压扁。
SOFA_W, SOFA_H = 64, 54
CHAIR_W, CHAIR_H = 22, 26

# ── 源图里的裁切框（对图集逐格量出来的）──────────────────────────────────
# 书：512x512 里正文实际占 (13,134)-(483,406)，四色一致
BOOK_BBOX = (13, 134, 483, 406)
BOOK_FILES = [
    ("Brown Book/Book Open.png", "brown"),
    ("Green Book/Book Open.png", "green"),
    ("Blue Book/Book Open.png", "blue"),
    ("Red Book/Red Open.png", "red"),
]

# 沙发：整本图集里只有这一块是「完整 + 正面视角 + 比例自然」的三人沙发。
# 左上角那组灰蓝看着像，其实是两件叠在一起的俯视/正面拼版，按 90px 高裁
# 会一次切到两行；砖红那几块都缺沙发腿。这块 141x93 有靠背、坐垫、扶手和裙板。
SOFA_BBOX = [
    (433, 47, 574, 140),
]
# 扶手椅只有前两行是正面款（后两行是俯视和边几），每行前两把都是正脸，
# 第二把略带斜角，凑一对摆着比两把完全一样自然。
CHAIR_BBOX = [
    (48, 40, 96, 96),     # 灰蓝 · 正脸
    (96, 40, 144, 96),    # 灰蓝 · 略斜
    (48, 136, 96, 192),   # 砖红 · 正脸
    (96, 136, 144, 192),  # 砖红 · 略斜
]


def resize_sharp(im: Image.Image, w: int, h: int) -> Image.Image:
    """先平滑缩到 2 倍，再最近邻落到目标尺寸。

    源图缩比在 4~15 倍之间，直接 NEAREST 会丢线、断边；直接 LANCZOS 又会
    把黑边磨成灰边，和房间里其他硬边色块对不上。两步走能保住轮廓。
    """
    mid = im.resize((max(1, w * 2), max(1, h * 2)), Image.LANCZOS)
    return mid.resize((w, h), Image.NEAREST)


def fit_bottom(im: Image.Image, box_w: int, box_h: int) -> Image.Image:
    """等比缩放到 box 内、水平居中、贴底对齐。

    家具的「落脚线」在下沿：贴底放，RoomProp 里按 rect 底边对齐才不会被
    后面那格的地板缝切开；水平居中则左右扶手对称。
    """
    scale = min(box_w / im.width, box_h / im.height)
    w = max(1, round(im.width * scale))
    h = max(1, round(im.height * scale))
    t = resize_sharp(im, w, h)
    out = Image.new("RGBA", (box_w, box_h), (0, 0, 0, 0))
    out.alpha_composite(t, ((box_w - w) // 2, box_h - h))
    return out


def pack_books() -> bool:
    frames = []
    for rel, name in BOOK_FILES:
        p = os.path.join(BOOK_SRC, rel)
        if not os.path.exists(p):
            print(f"  跳过：找不到 {p}")
            return False
        im = Image.open(p).convert("RGBA").crop(BOOK_BBOX)
        frames.append(resize_sharp(im, BOOK_W, BOOK_H))
        print(f"  {name:6s} {im.size} -> {BOOK_W}x{BOOK_H}")

    sheet = Image.new("RGBA", (BOOK_W * len(frames), BOOK_H), (0, 0, 0, 0))
    for i, f in enumerate(frames):
        sheet.paste(f, (i * BOOK_W, 0))
    out = os.path.join(ROOT, "assets", "room_books.png")
    sheet.save(out)
    print(f"  -> {out} ({sheet.size[0]}x{sheet.size[1]})")
    return True


def pack_seats() -> bool:
    p = os.path.join(SEAT_SRC, "Couch.png")
    q = os.path.join(SEAT_SRC, "Armchairs.png")
    if not (os.path.exists(p) and os.path.exists(q)):
        print(f"  跳过：找不到 {SEAT_SRC}")
        return False

    couch = Image.open(p).convert("RGBA")
    chairs = Image.open(q).convert("RGBA")

    sofas = []
    for i, bbox in enumerate(SOFA_BBOX):
        im = couch.crop(bbox)
        sofas.append(fit_bottom(im, SOFA_W, SOFA_H))
        print(f"  sofa{i}  {im.size} -> {SOFA_W}x{SOFA_H}")

    seat_chairs = []
    for i, bbox in enumerate(CHAIR_BBOX):
        im = chairs.crop(bbox)
        seat_chairs.append(fit_bottom(im, CHAIR_W, CHAIR_H))
        print(f"  chair{i} {im.size} -> {CHAIR_W}x{CHAIR_H}")

    width = max(SOFA_W * len(sofas), CHAIR_W * len(seat_chairs))
    sheet = Image.new("RGBA", (width, SOFA_H + CHAIR_H), (0, 0, 0, 0))
    for i, s in enumerate(sofas):
        sheet.paste(s, (i * SOFA_W, 0))
    for i, c in enumerate(seat_chairs):
        sheet.paste(c, (i * CHAIR_W, SOFA_H))
    out = os.path.join(ROOT, "assets", "room_seats.png")
    sheet.save(out)
    print(f"  -> {out} ({sheet.size[0]}x{sheet.size[1]})")
    return True


# ── 房间背后的天空 ───────────────────────────────────────────────────────
# 拆成三层，运行时叠起来：这样云能飘，天光和日月星空不会跟着一起动。
#   01_sky  → 上沿一带（渐变 + 日月 + 星空），窗外那片天
#   gradient→ 往下渐浅的一大块，给中庭的大洞垫底（夜里另撒一把星）
#   02_clouds → 云层，单独一张，游戏里按不同速度横向滚动
# 山脊和树线一概不要：房间本身盖在中间，背后再有一条地平线就成了两层世界。
#
# 全部按 1:1 存，放大交给游戏里的最近邻绘制：贴图小、像素网格还是整的。
# 上沿只取天空层最上面那 176 行：这一段是「好看的中间天空」，往下就发白发灰了。
# 游戏里上沿和纵深都按 2 倍画（2 个局部像素一块），云按 1:1 画 ——
# 放大 2 倍的云会大到一扇窗只装得下半朵，那是「半朵云」的来历。
BG_SRC_TOP, BG_SRC_BOTTOM = 0, 176
SKY_W = 640
BAND_H = BG_SRC_BOTTOM - BG_SRC_TOP          # 176
FILL_H = 512         # 竖着一个块就够铺满整间房（游戏里画 1024 高）
CLOUD_H = 512
# 天空往下越接近地平线越浅，这块比例就是从带子底到房间底的提亮量
FILL_LIGHTEN = 0.10
NIGHT_STARS = 240

# 行顺序固定，RoomProp.sky_pair() 按它做时段插值
SKY_TIMES = ["dawn", "noon", "sunset", "night"]


def _row_color(im: Image.Image, y: int) -> tuple[int, int, int]:
    """整行平均色。取天空层（不含云）的行，渐变才不会被一朵云带偏。"""
    band = im.crop((0, y, im.width, y + 1)).convert("RGB")
    px = list(band.getdata())
    n = len(px)
    return tuple(sum(c[i] for c in px) // n for i in range(3))


def _cloud_field(cloud: Image.Image, h: int) -> Image.Image:
    """把 176 行高的云层竖向排成 h 高的一整片。

    奇数块水平镜像再错位 213px（640 的 1/3）：镜像保证上下接缝连续，
    错位打散「一列一列对齐」的栅格感。镜像图仍然是水平无缝的，
    所以这一整块可以继续横向滚动。
    """
    src = cloud.crop((0, BG_SRC_TOP, cloud.width, BG_SRC_BOTTOM))
    out = Image.new("RGBA", (src.width, h), (0, 0, 0, 0))
    for k in range((h + src.height - 1) // src.height):
        tile = ImageOps.mirror(src) if k % 2 else src.copy()
        if k:
            dx = (k * 213) % tile.width
            shifted = Image.new("RGBA", tile.size, (0, 0, 0, 0))
            shifted.paste(tile.crop((0, 0, tile.width - dx, tile.height)), (dx, 0))
            shifted.paste(tile.crop((tile.width - dx, 0, tile.width, tile.height)),
                          (0, 0))
            tile = shifted
        out.alpha_composite(tile.crop((0, 0, tile.width,
                                       min(tile.height, h - k * src.height))),
                            (0, k * src.height))
    return out


def pack_sky() -> bool:
    """出三张图：room_sky_bg / room_sky_fill / room_sky_clouds，各 4 行。"""
    band_sheet = Image.new("RGB", (SKY_W, BAND_H * len(SKY_TIMES)), (191, 227, 245))
    fill_sheet = Image.new("RGB", (SKY_W, FILL_H * len(SKY_TIMES)), (191, 227, 245))
    cloud_sheet = Image.new("RGBA", (SKY_W, CLOUD_H * len(SKY_TIMES)), (0, 0, 0, 0))
    for row, name in enumerate(SKY_TIMES):
        p_sky = os.path.join(SKY_SRC, "layers", name, "01_sky.png")
        p_cloud = os.path.join(SKY_SRC, "layers", name, "02_clouds.png")
        if not os.path.exists(p_sky):
            print(f"  跳过：找不到 {p_sky}")
            return False
        sky = Image.open(p_sky).convert("RGBA")

        # 上沿：只有天光 / 日月 / 星空，云交给下面那张自己飘
        band_sheet.paste(sky.crop((0, BG_SRC_TOP, sky.width, BG_SRC_BOTTOM)).convert("RGB"),
                         (0, row * BAND_H))

        # 纵深：从带子底行的颜色接着往下渐变成更浅的天光
        top_c = _row_color(sky, BG_SRC_BOTTOM - 1)
        bot_c = tuple(min(255, int(c + (255 - c) * FILL_LIGHTEN)) for c in top_c)
        fill = Image.new("RGBA", (SKY_W, FILL_H))
        for y in range(FILL_H):
            t = y / float(FILL_H - 1)
            c = tuple(int(round(a + (b - a) * t)) for a, b in zip(top_c, bot_c))
            fill.paste(c + (255,), (0, y, SKY_W, y + 1))
        if name == "night":
            # 星星本来就该是钉死的，放在不动的这张里；云再飘过它们上方
            rng = random.Random(20261114)
            for _ in range(NIGHT_STARS):
                x = rng.randrange(SKY_W)
                y = rng.randrange(FILL_H)
                v = rng.choice((255, 255, 230, 200))
                fill.putpixel((x, y), (v, v, min(255, v + 20), 255))
        fill_sheet.paste(fill.convert("RGB"), (0, row * FILL_H))

        # 云：整块云场（含镜像错位），运行时横向滚动 + 两档天色交叉淡入
        if os.path.exists(p_cloud):
            field = _cloud_field(Image.open(p_cloud).convert("RGBA"), CLOUD_H)
            cloud_sheet.alpha_composite(field, (0, row * CLOUD_H))
        print(f"  {name:7s} 上沿/纵深/云 各 {SKY_W}px 宽，底色 "
              f"#{top_c[0]:02x}{top_c[1]:02x}{top_c[2]:02x}")
    for fname, sheet in (("room_sky_bg.png", band_sheet),
                         ("room_sky_fill.png", fill_sheet),
                         ("room_sky_clouds.png", cloud_sheet)):
        out = os.path.join(ROOT, "assets", fname)
        sheet.save(out)
        print(f"  -> {out} ({sheet.size[0]}x{sheet.size[1]})")
    return True


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只检查源素材是否就位")
    args = ap.parse_args()

    ok_books = os.path.isdir(BOOK_SRC)
    ok_seats = os.path.isdir(SEAT_SRC)
    ok_sky = os.path.isdir(SKY_SRC)
    print(f"书籍素材 {BOOK_SRC} -> {'在' if ok_books else '缺失'}")
    print(f"沙发素材 {SEAT_SRC} -> {'在' if ok_seats else '缺失'}")
    print(f"天空素材 {SKY_SRC} -> {'在' if ok_sky else '缺失'}")
    if args.check:
        return

    if ok_books:
        print("打包书籍：")
        pack_books()
    if ok_seats:
        print("打包家具：")
        pack_seats()
    if ok_sky:
        print("打包房间背后的天空：")
        pack_sky()


if __name__ == "__main__":
    main()
