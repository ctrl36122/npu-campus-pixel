"""把 OGA 的 CC0 公园长椅铺进 assets/props_bench.png。

来源：OpenGameArt "Park - Mini Sprite Pack"，CC0（见 assets/oga_src/mini_park/LICENSE.txt）
      https://opengameart.org/content/park-mini-sprite-pack
MiniPark.png 是 100x100 的纯色绿底 (59,125,79) 素材图，含长椅 / 花灌木 /
草 / 石头 / 树；(37,43)-(96,72) 那张木长椅是斜俯视、有网格靠背和条板座面，
比原来那几块棕色矩形正式得多。

⚠️ 花坛 / 花盆**故意不换**：试过同一包的花灌木和 Shabby Chic Exterior
（CC0）的开花枝，压到 36x18 / 24x24 后都变成一地碎叶、比原来整齐的一排
十字花和实心绿球更暗更散。这个尺寸下最多只有 6x6 px 画一朵花，做不出
「有花瓣层次」的效果，保留原版才是更好看的选择。别再拿大素材硬压。

为什么只改 PNG、不改 world.json：
  贴图尺寸保持 24x26，props[].x 是左边缘格、baseY 是底边格，渲染按贴图高度
  底对齐。尺寸不变 ⇒ 176 张长椅的位置和碰撞多边形全都不用动，场景也不用重建。

⚠️ 缩放一律 NEAREST + alpha 二值，别用 LANCZOS（会糊出半透明毛边）。

用法：
  python tools/import_oga_props.py          # 写入 props_bench.png
  python tools/import_oga_props.py --dry    # 只出 build/_oga_props_preview.png
写完需 godot --headless --import 刷缓存。
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

GAME = Path(__file__).resolve().parent.parent
ASSETS = GAME / "assets"
SRC = ASSETS / "oga_src" / "mini_park" / "MiniPark.png"
DST = ASSETS / "props_bench.png"

PARK_BG = (59, 125, 79)
BENCH_BOX = (37, 43, 96, 72)
SIZE = (24, 26)


def build() -> Image.Image:
    a = np.asarray(Image.open(SRC).convert("RGBA")).copy()
    hit = (a[:, :, :3] == np.array(PARK_BG, dtype=np.uint8)).all(axis=2)
    a[:, :, 3] = np.where(hit, 0, 255).astype(np.uint8)
    park = Image.fromarray(a, "RGBA")
    bench = park.crop(BENCH_BOX).resize(SIZE, Image.NEAREST)
    b = np.asarray(bench).copy()
    b[:, :, 3] = np.where(b[:, :, 3] >= 96, 255, 0).astype(np.uint8)
    return Image.fromarray(b, "RGBA")


def preview(new: Image.Image, path: Path) -> None:
    Z = 12
    old = Image.open(DST).convert("RGBA")
    W = SIZE[0] * Z * 2 + 60
    H = SIZE[1] * Z + 50
    board = Image.new("RGBA", (W, H), (248, 249, 251, 255))
    dr = ImageDraw.Draw(board)
    for i, (nm, im) in enumerate([("OLD · 原长椅", old), ("NEW · OGA CC0", new)]):
        x = 20 + i * (SIZE[0] * Z + 20)
        dr.text((x, 8), nm, fill=(20, 26, 34, 255))
        board.alpha_composite(im.resize((im.width * Z, im.height * Z), Image.NEAREST), (x, 30))
    path.parent.mkdir(parents=True, exist_ok=True)
    board.convert("RGB").save(path)
    print(f"  预览 -> {path}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry", action="store_true")
    args = ap.parse_args()
    new = build()
    print(f"  props_bench.png {new.width}x{new.height}")
    preview(new, GAME / "build" / "_oga_bench_preview.png")
    if args.dry:
        print("[oga-props] --dry，未写贴图")
        return
    new.save(DST)
    print("[oga-props] 已写 props_bench.png（尺寸与位置不变）")


if __name__ == "__main__":
    main()
