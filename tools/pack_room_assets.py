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

布局是固定网格，RoomProp 里直接按索引算 Rect2，不另外存 json。
"""
from __future__ import annotations

import argparse
import os
import sys

try:
    from PIL import Image
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


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只检查源素材是否就位")
    args = ap.parse_args()

    ok_books = os.path.isdir(BOOK_SRC)
    ok_seats = os.path.isdir(SEAT_SRC)
    print(f"书籍素材 {BOOK_SRC} -> {'在' if ok_books else '缺失'}")
    print(f"沙发素材 {SEAT_SRC} -> {'在' if ok_seats else '缺失'}")
    if args.check:
        return

    if ok_books:
        print("打包书籍：")
        pack_books()
    if ok_seats:
        print("打包家具：")
        pack_seats()


if __name__ == "__main__":
    main()
