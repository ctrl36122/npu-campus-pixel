"""烘一张「雨天积水在哪」的掩码图给积水 shader 用。

思路来自那个雨夜效果视频：积水不是盖满地面，而是用噪声在硬质铺装上
裁出一块块的水洼。我们不改地面贴图（判水 4 档色、道具候选网格都动不得），
照 water_mask 的路子出一张 1px=1格 的黑白图，shader 采样它做湿面 + 波纹。

积水只落在不渗水的表面上：
  - 沥青路 / 广场石板（beige）—— 路面坑洼最容易存水
  - 草地不留积水（泥土渗水快，而且草地上盖蓝片会像污渍，之前否决过）

形状：两级 value noise（6 格 + 2.5 格），阈值裁出连片但不规则的洼，
再抠掉湖面（那里本来就是水）。全程序生成，幂等，重跑结果一致。

用法：python tools/bake_puddle_mask.py
"""
import os
import sys

from PIL import Image, ImageChops

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import bake_ground_detail as D      # noqa: E402
import bake_ground_refine as R      # noqa: E402  _beige_mask

CELL = 8            # 一格 8px，与 water_mask 同规格
THRESHOLD = 0.615   # 噪声高于这个值才积水（调它控制水洼覆盖率）


def _hash(ix, iy, seed):
    """整点哈希 → 0..1。和烘焙链同款风格，纯确定性。"""
    h = ix * 374761393 + iy * 668265263 + seed * 1442695041
    h = (h ^ (h >> 13)) * 1274126177
    h &= 0xFFFFFFFF
    return ((h ^ (h >> 16)) & 0xFFFF) / 65535.0


def _vnoise(x, y, seed):
    """value noise，格点双线性插值。x/y 以格为单位。"""
    ix, iy = int(x // 1), int(y // 1)
    fx, fy = x - ix, y - iy
    fx = fx * fx * (3.0 - 2.0 * fx)
    fy = fy * fy * (3.0 - 2.0 * fy)
    a = _hash(ix, iy, seed)
    b = _hash(ix + 1, iy, seed)
    c = _hash(ix, iy + 1, seed)
    d = _hash(ix + 1, iy + 1, seed)
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def puddle_noise(cx, cy):
    """两级噪声：大块定势、小块破边。0..1"""
    n = _vnoise(cx / 6.0, cy / 6.0, 20261115) * 0.72
    n += _vnoise(cx / 2.5, cy / 2.5, 917331) * 0.28
    return n


def main():
    ww, wh = D.COLS * D.CHUNK, D.ROWS * D.CHUNK
    mw, mh = ww // CELL, wh // CELL
    print("[puddle] 世界 %dx%d → 掩码 %dx%d" % (ww, wh, mw, mh))

    # 1) 硬质表面格子（路 + 米色石板），一路按块裁
    hard = Image.new("L", (mw, mh), 0)
    for cy in range(D.ROWS):
        for cx in range(D.COLS):
            p = os.path.join(D.GROUND, "g%d_%d.png" % (cx, cy))
            if not os.path.exists(p):
                continue
            im = Image.open(p).convert("RGB")
            m = ImageChops.lighter(D.road_mask(im), R._beige_mask(im))
            cw = (im.width + CELL - 1) // CELL
            ch = (im.height + CELL - 1) // CELL
            frac = m.convert("L").resize((cw, ch), Image.BOX)
            cell = frac.point(lambda v: 255 if v >= 128 else 0)
            hard.paste(cell, (cx * D.CHUNK // CELL, cy * D.CHUNK // CELL))

    # 2) 湖面不算积水
    wp = os.path.join(ROOT, "assets", "water_mask.png")
    if os.path.exists(wp):
        water = Image.open(wp).convert("L")
        if water.size == (mw, mh):
            hard = ImageChops.subtract(hard, water)

    # 3) 噪声裁形
    out = Image.new("L", (mw, mh), 0)
    px = out.load()
    hp = hard.load()
    n_hard = n_pud = 0
    for y in range(mh):
        for x in range(mw):
            if hp[x, y] == 0:
                continue
            n_hard += 1
            if puddle_noise(x, y) >= THRESHOLD:
                px[x, y] = 255
                n_pud += 1

    dst = os.path.join(ROOT, "assets", "puddle_mask.png")
    out.save(dst, optimize=True)
    print("[puddle] 硬面 %d 格，积水 %d 格（占硬面 %.1f%%）" % (
        n_hard, n_pud, 100.0 * n_pud / max(1, n_hard)))
    print("[puddle] 已写 %s（%d KB）" % (dst, os.path.getsize(dst) // 1024))


if __name__ == "__main__":
    main()
