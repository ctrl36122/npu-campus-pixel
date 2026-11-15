"""把 OGA 的公园长椅铺进 assets/props_bench.png（v2：Cozy Farm Village Lite）。

来源：OpenGameArt "Cozy Farm Village Lite" by Bramble & Byte，**CC-BY 4.0**
      https://opengameart.org/content/cozy-farm-village-lite-16x16-cottage-cobblestone-baker
      源图 assets/oga_src/cozy_farm/bench_2x.png = 原包 props/2x/bench.png (64x32)
      授权全文 assets/oga_src/cozy_farm/LICENSE.txt（署名要求见 README「数据与声明」）

⚠️ 为什么换掉上一版（Park - Mini Sprite Pack，CC0）：
  那张长椅是 59x29 的**正面横向**图，硬压进 24x26 的近方形贴图后比例被压掉一半，
  靠背的网格被 NEAREST 抽成黑白棋盘、座板变成橙色竖条，实机像一扇窗户/公告栏。
  换素材时也试过别的包：LPC「Bench with Flowers」是俯视竖条凳且花太多、
  Mage City Arcanos 的 64x64 LPC 木长椅缩到 24px 只剩一片木栅栏、
  Christmas Village 的 16x16 俯视长椅放大后像双层床。**别再拿横向大素材硬压成方形。**

⚠️ 贴图必须保持 24x26：world.json 里 176 张长椅的 props[].x 是左边缘格、
  baseY 是底边格，渲染按贴图高度底对齐；尺寸不变 ⇒ 位置和 collide 多边形全不用动。

算法（核心是「保住横向 2:1 比例」）：
  1. 裁掉透明边，取 (6,10)-(58,32) → 52x22 的 2x 像素密度长椅
  2. 分块众数降采样到 24x11（≈2:1 等比；2x→1x 顺带去掉木纹细点，留住条板与描边）
  3. 纵向 NEAREST 拉到 24x18：实机里 12px 高只像一条木板，18px 才有长椅体量；
     20px 以上又开始像柜子，别再往上拉
  4. 底对齐放进 24x26（不画额外阴影：草地本身有 8px 纹理，深色椅腿已经压得住地，
     半透明椭圆在浅色底上反而会变成一块「白板」）

⚠️ 花坛 / 花盆**故意不换**：试过同批素材和 Shabby Chic Exterior（CC0）的开花枝，
  压到 36x18 / 24x24 后变成一地碎叶，比原来整齐的一排十字花和实心绿球更暗更散。
  这个尺寸下最多只有 6x6px 画一朵花，做不出花瓣层次。别再拿大素材硬压。

用法：
  python tools/import_oga_props.py          # 写入 assets/props_bench.png
  python tools/import_oga_props.py --dry    # 只出 build/_oga_bench_preview.png
写完需 godot --headless --path . --import 刷缓存。
"""

from __future__ import annotations

import argparse
from collections import Counter
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

GAME = Path(__file__).resolve().parent.parent
ASSETS = GAME / "assets"
SRC = ASSETS / "oga_src" / "cozy_farm" / "bench_2x.png"
DST = ASSETS / "props_bench.png"

# 源图内容边界（64x32，四周是透明留白）
CROP = (6, 10, 58, 32)
SIZE = (24, 26)
FLAT_H = 11          # 等比 2:1 降采样后的高度
DRAW_H = 18          # 实机纵向拉伸到的高度


def _mode_resize(a: np.ndarray, tw: int, th: int) -> np.ndarray:
    """按输出像素分块取 RGBA 众数：2x→1x 时保留条板/描边、丢掉木纹噪点。"""
    sh, sw = a.shape[:2]
    out = np.zeros((th, tw, 4), dtype=np.uint8)
    for j in range(th):
        y0 = round(j * sh / th)
        y1 = max(y0 + 1, round((j + 1) * sh / th))
        for i in range(tw):
            x0 = round(i * sw / tw)
            x1 = max(x0 + 1, round((i + 1) * sw / tw))
            block = a[y0:y1, x0:x1].reshape(-1, 4)
            out[j, i] = Counter(map(tuple, block.tolist())).most_common(1)[0][0]
    return out


def build() -> Image.Image:
    src = np.asarray(Image.open(SRC).convert("RGBA"))
    x0, y0, x1, y1 = CROP
    flat = _mode_resize(src[y0:y1, x0:x1], SIZE[0], FLAT_H)
    # 纵向 NEAREST 行复制（不做插值，像素块保持方正）
    rows = [min(FLAT_H - 1, int((j + 0.5) * FLAT_H / DRAW_H)) for j in range(DRAW_H)]
    bench = Image.fromarray(flat[rows, :, :], "RGBA")
    b = np.asarray(bench).copy()
    b[:, :, 3] = np.where(b[:, :, 3] >= 128, 255, 0).astype(np.uint8)

    out = Image.new("RGBA", SIZE, (0, 0, 0, 0))
    out.alpha_composite(Image.fromarray(b, "RGBA"), (0, SIZE[1] - DRAW_H))
    return out


def preview(new: Image.Image, path: Path) -> None:
    Z = 12
    before = Image.open(DST).convert("RGBA")
    W = SIZE[0] * Z * 2 + 60
    H = SIZE[1] * Z + 50
    board = Image.new("RGBA", (W, H), (248, 249, 251, 255))
    dr = ImageDraw.Draw(board)
    for i, (nm, im) in enumerate([("BEFORE · 当前磁盘贴图", before), ("NEW · Cozy Farm CC-BY 4.0", new)]):
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
    assert new.size == SIZE, f"贴图尺寸必须是 {SIZE}，否则 176 张长椅的位置/碰撞全要重算"
    print(f"  props_bench.png {new.width}x{new.height}（长椅内容 24x{DRAW_H}）")
    preview(new, GAME / "build" / "_oga_bench_preview.png")
    if args.dry:
        print("[oga-props] --dry，未写贴图")
        return
    new.save(DST)
    print("[oga-props] 已写 props_bench.png（尺寸与位置不变）")


if __name__ == "__main__":
    main()
