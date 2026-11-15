"""把 OpenGameArt 的 CC0 像素树铺进 assets/decor_0.png 的前 5 个槽位。

来源： OpenGameArt "Trees & Bushes" —— Luis Zuno (@ansimuz)，CC0
       https://opengameart.org/content/trees-bushes
CC0 允许分发，所以可复现所需的透明层 + 授权放在 assets/oga_src/trees_bushes/；
完整原包（含 PSD、带草地背景的预览图）另存于项目根 references/oga/trees_bushes/，
那份不入库。vegetation.png 是从 PSD 的 `vegetation` 图层导出的**透明底**素材
（原包里那张 trees-and-bushes.png 带草地背景，直接抠会留噪点，别用）。

为什么只动前 5 格：
  world.json 的 decor[0..4] 是同一棵「渐变绿球」的 5 个尺寸变体，
  260 棵树的 instances[].sp 全部落在这 5 个索引上；decor[5..10] 是
  飞机和设施，跟树无关。所以这个函数是**幂等**的：每次只清空并重写
  这 5 个矩形，图集其余部分一个像素都不碰；world.json / world.tscn /
  地面烘焙链（按 instances 数组下标画树影）全都不受影响。

⚠️ 缩放一律 NEAREST + alpha 二值：像素字/像素画一旦被 LANCZOS 抹出
半透明边，实机就会糊成一团。

用法：
  python tools/import_oga_trees.py             # 写入 assets/decor_0.png
  python tools/import_oga_trees.py --dry       # 只出 build/_oga_trees_preview.png
  python tools/import_oga_trees.py --lift 0.30 # 调提亮强度（0 = 原色）
写完后要跑一次 godot --headless --import 才能刷新导入缓存。
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

GAME = Path(__file__).resolve().parent.parent
SRC_DIR = GAME / "assets" / "oga_src" / "trees_bushes"
ATLAS = GAME / "assets" / "decor_0.png"
WORLD = GAME / "assets" / "world.json"

# vegetation.png 里各棵树的包围盒（原图 288x160）
# (bbox, 水平镜像, 相对提亮, 纵向拉伸, 名字)
# 两种主形交替 + 小幅明暗差，避免 260 棵树看起来是同一张图复制的
TREES = [
    ((120, 7, 222, 137), False, 1.00, 1.08, "高冠树"),
    ((0, 7, 113, 120), True, 1.06, 1.12, "圆冠树·镜像"),
    ((120, 7, 222, 137), True, 0.96, 1.06, "高冠树·镜像·略深"),
    ((0, 7, 113, 120), False, 1.10, 1.12, "圆冠树·亮"),
    ((240, 116, 272, 153), False, 1.05, 1.05, "小圆树"),
]


def lift_colors(im: Image.Image, amount: float) -> Image.Image:
    """暗部多提、亮部少提，保持 RGB 比例（色相不变），层次不会压平成一团灰。

    原素材主体是 (52,97,37) 的深青绿，草地却是 (101,141,65) 的亮黄绿，
    直接铺上去树会像一坨深色污渍。这个非线性提亮把主体抬到接近草地、
    又不动亮部的黄绿高光。
    """
    a = np.asarray(im).astype(np.float32)
    rgb = a[..., :3]
    lum = rgb.mean(axis=2) / 255.0
    scale = 1.0 + amount * (1.0 - lum) ** 1.2
    out = rgb * scale[..., None]
    # 极暗的紫黑色（树冠阴影）往深绿靠一点，别在绿草地上发紫
    dark = lum < 0.28
    out[dark] = out[dark] * 0.78 + np.array([28.0, 58.0, 32.0]) * 0.22
    out = np.clip(out, 0, 255).astype(np.uint8)
    return Image.fromarray(np.dstack([out, a[..., 3].astype(np.uint8)]), "RGBA")


def prepare(im: Image.Image, amount: float, flip: bool,
            target_w: int, target_h_max: int, stretch: float) -> Image.Image:
    if flip:
        im = im.transpose(Image.FLIP_LEFT_RIGHT)
    px = im.load()
    for y in range(im.height):
        for x in range(im.width):
            r, g, b, a = px[x, y]
            px[x, y] = (r, g, b, 255 if a >= 110 else 0)
    im = lift_colors(im, amount)
    k = target_w / im.width
    w = max(1, round(target_w))
    h = max(1, min(target_h_max, round(im.height * k * stretch)))
    return im.resize((w, h), Image.NEAREST)


def build(amount: float) -> Image.Image:
    veg = Image.open(SRC_DIR / "vegetation.png").convert("RGBA")
    defs = json.loads(WORLD.read_text(encoding="utf-8"))["decor"]
    out = Image.open(ATLAS).convert("RGBA")
    for i, (box, flip, rel, stretch, name) in enumerate(TREES):
        d = defs[i]
        rx, ry, w, h = int(d["rx"]), int(d["ry"]), int(d["w"]), int(d["h"])
        cut = veg.crop(box)
        tree = prepare(cut, amount * rel, flip, w - 2, h - 8, stretch)
        # 清空原槽位（绿球），树底部留 6px、水平居中
        out.paste((0, 0, 0, 0), (rx, ry, rx + w, ry + h))
        out.alpha_composite(tree, (rx + (w - tree.width) // 2, ry + h - tree.height - 6))
        print(f"  槽位 {i} {w:3d}x{h:<3d} <- {name:16s} {tree.width}x{tree.height}")
    return out


def preview(atlas: Image.Image, defs: list, path: Path) -> None:
    """把 5 个树槽位并排放大，方便不进游戏就比对配色。"""
    Z = 3
    tiles = [atlas.crop((d["rx"], d["ry"], d["rx"] + d["w"], d["ry"] + d["h"]))
             for d in defs[:5]]
    W = sum(t.width * Z + 16 for t in tiles)
    H = max(t.height for t in tiles) * Z + 40
    board = Image.new("RGBA", (W, H), (250, 250, 252, 255))
    dr = ImageDraw.Draw(board)
    x = 8
    for i, t in enumerate(tiles):
        z = t.resize((t.width * Z, t.height * Z), Image.NEAREST)
        board.alpha_composite(z, (x, 32))
        dr.text((x, 10), f"{i}  {t.width}x{t.height}", fill=(30, 36, 44, 255))
        x += t.width * Z + 16
    path.parent.mkdir(parents=True, exist_ok=True)
    board.convert("RGB").save(path)
    print(f"  预览 -> {path}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--lift", type=float, default=0.26,
                    help="提亮强度，0=素材原色，0.26=贴合草地又不荧光（默认）")
    ap.add_argument("--dry", action="store_true", help="不写图集，只出预览")
    args = ap.parse_args()

    if not (SRC_DIR / "vegetation.png").exists():
        raise SystemExit(f"缺素材：{SRC_DIR / 'vegetation.png'}")
    print(f"[oga-trees] lift={args.lift}")
    out = build(args.lift)
    defs = json.loads(WORLD.read_text(encoding="utf-8"))["decor"]
    preview(out, defs, GAME / "build" / "_oga_trees_atlas.png")
    if args.dry:
        print("[oga-trees] --dry，未写 assets/decor_0.png")
        return
    out.save(ATLAS)
    print(f"[oga-trees] 已写 {ATLAS}（其余 6 个槽位保持原样）")


if __name__ == "__main__":
    main()
