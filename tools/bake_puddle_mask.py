"""烘雨天积水用的两张图：硬面掩码 + 造波纹理。

照那个雨夜效果视频的做法，积水形状不在烘焙期定死，而是运行时算：
  - `puddle_mask.png`：积水「允许出现在哪」—— 不渗水的硬质铺装
    （沥青路 + 米色石板），湖面扣除。相当于视频里 sprite 放在地面的底图。
  - `wave_noise.png`：造波纹理 —— 平滑的两级 value noise（6 格 + 2.5 格），
    shader 里用 step 裁出连片水洼、向内切一层做边缘；GDScript 读同一张图
    给雨点涟漪挑落点，两边数值完全一致。

两张都是 1px=1格（512×896）。全程序生成，幂等，重跑结果一致。

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
WAVE_SEED = 20261115
WAVE_SEED2 = 917331


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


def wave_value(cx, cy):
    """造波值：两级噪声，大块定势、小块破边。0..1（近似归一）"""
    n = _vnoise(cx / 6.0, cy / 6.0, WAVE_SEED) * 0.72
    n += _vnoise(cx / 2.5, cy / 2.5, WAVE_SEED2) * 0.28
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
    n_hard = sum(1 for v in hard.getdata() if v)

    # 3) 造波纹理：平滑灰度图，shader 用 step 裁形、内切一层做边缘
    wave = Image.new("L", (mw, mh))
    wave.putdata([
        int(round(wave_value(x, y) * 255.0))
        for y in range(mh) for x in range(mw)
    ])

    dst = os.path.join(ROOT, "assets", "puddle_mask.png")
    hard.save(dst, optimize=True)
    dst2 = os.path.join(ROOT, "assets", "wave_noise.png")
    wave.save(dst2, optimize=True)

    print("[puddle] 硬面 %d 格（%d KB）→ %s" % (
        n_hard, os.path.getsize(dst) // 1024, dst))
    print("[puddle] 造波纹理（%d KB）→ %s" % (
        os.path.getsize(dst2) // 1024, dst2))
    # 各阈值下的水洼覆盖率，shader 里挑 step 阈值时参考
    hd = hard.load()
    wd = wave.load()
    for th in (0.55, 0.58, 0.60, 0.62, 0.65):
        n = 0
        for y in range(mh):
            for x in range(mw):
                if hd[x, y] and wd[x, y] / 255.0 >= th:
                    n += 1
        print("[puddle]   阈值 %.2f → 水洼 %d 格（占硬面 %.1f%%）" % (
            th, n, 100.0 * n / max(1, n_hard)))


if __name__ == "__main__":
    main()
