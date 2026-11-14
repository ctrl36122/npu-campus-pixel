#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第 11 层：给草地和路面「换材质」——去 8px 平板 + 铺真实像素纹理。

为什么现在要动：
  前十层把形状做对了（路缘、路肩、树影、石板广场），但底子是**一格一色的
  8×8 平板**：草地是一张 8px 的绿色马赛克，每格内部完全均匀，格与格之间硬跳。
  放大看就是「棋盘」，正常距离看是一块晕开的水彩。建筑、树、道具都是 1px
  硬边的像素图，地面却是软的、还带网格 —— 这就是「怪」的来源。
  这一层只动这两件事：
    A. 去平板：把「每格平均值」这一层低频重采样成连续场，再把格边界抹平；
    B. 铺纹理：16×16 方块材质当明暗颗粒叠上去（草地 grass_top / 路面 gravel）。

怎么保证不破坏前十层：
  * 去平板用的是「原图 + (平滑场 - 平板场)」的**加性修正**，格内的 1px 细节、
    树影、墙脚 AO 全部原样保留，只把格与格之间的 DC 台阶拉平。
  * 纹理同样是三通道加同一个增量 → g-r / g-b / 通道极差逐像素不变。
  * 落笔前掩码收缩 + 羽化，路缘那圈高光边、草路过渡像素永远不碰；
    米色铺装、水面、非草非路的像素一律跳过。
  * 分类若还是被改动，--dry / --verify 直接报错（掩码 diff 必须为 0）。

纹理怎么不看出重复：
  每 16×16 一格独立地从 8 个「旋转/镜像」变体里挑一个（坐标哈希决定），
  格内接缝照旧连续，跨格不会出现整齐的棋盘。

用法：
    python tools/bake_ground_texture.py                  # 出对比小样，不写回
    python tools/bake_ground_texture.py --dry            # 全图零写回预演（分类必须 0 diff）
    python tools/bake_ground_texture.py --apply --force  # 全图铺开
"""
import os
import sys
from functools import lru_cache
from math import sin, tau as TAU

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont, ImageMath, ImageStat

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
ROOT = os.path.dirname(HERE)

import bake_road_edge as E
import bake_ground_detail as D
import bake_ground_refine as R

BLOCK_DIR = os.path.join(ROOT, "assets", "blocks")
WORLD_W, WORLD_H = E.WORLD_W, E.WORLD_H
CHUNK = E.CHUNK
COLS, ROWS = E.COLS, E.ROWS
CELL = 8
SEED = 20261114

# ---- A. 去平板 -------------------------------------------------------
DEBLOCK = True
DEBLOCK_CLAMP = 14          # 单像素最大修正量（格间差的一半左右，留余量）
DEBLOCK_BLUR = 1            # 格分辨率上的额外平滑，抹掉插值振铃
# 草地要比路面多跑一遍 4px：detail 层第三档噪声是 `scale=4 + NEAREST`，
# 它在地面上留下 4px 见方的方块迷彩，正常视距看就是「深浅不一的小格子」。
DEBLOCK_CELLS_GRASS = ((8, 32), (4, 20))
DEBLOCK_CELLS_ROAD = ((8, 20),)

# ---- A2. 压大斑 -------------------------------------------------------
# detail 层铺了三尺度噪声，其中「几十像素到一百多像素」那一档在正常视距下
# 就是一坨坨深浅不一的色斑 —— 格台阶拉平了它也还在，是「水彩晕开」观感的
# 另一半来源。这里按亮度取大尺度低频，只保留 LOW_KEEP 的比例。
LOW_FLATTEN = True
LOW_RADIUS = 40             # px：吃掉的斑块尺度（要大于 8px 格，远小于地图）
LOW_KEEP = 0.26             # 保留 26% 的自然起伏，全抹平会像一块塑料
LOW_CLAMP = 20              # 单像素最大修正量，防止把墙脚 AO / 树影啃掉

# ---- B. 材质与强度 ---------------------------------------------------
GRASS_TEX = "grass_top.png"
GRASS_SIGMA = 10.0
GRASS_CLIP = 26
# 整体压暗一档：grass_top 归一化后把草地推向「荧光绿」，压 4 级就沉稳了，
# 和建筑/树的色板也更搭。三通道同 delta，分类不受影响。
GRASS_SHADE = -4
ROAD_TEX = "gravel.png"
ROAD_SIGMA = 9.0
ROAD_CLIP = 22
# 掩码收缩：路缘 1px 高光边、草路交界那圈过渡像素都不动
ERODE_GRASS = 2
ERODE_ROAD = 1
FEATHER = 3

OUT_PRE = os.path.join(ROOT, "shot_texture_sample.png")
OUT_PRE2 = os.path.join(ROOT, "shot_texture_closeup.png")

PRE_BOX = (1560, 2360, 2380, 3180)      # 图书馆前那一片：草 / 弧形路 / 水岸都有
CLOSE_BOX = (2600, 3344, 2700, 3400)    # 10x 特写：只看草地本身（8px 对齐）


# ---------------------------------------------------------------- 基础
def _div255(a, b):
    """a/b*255 的逐像素除法（b 为 L 图，可能为 0 → 用 b+1 兜底）。"""
    expr = "convert(a*255.0/(b+1.0),'L')"
    for fn in ("lambda_eval", "unsafe_eval", "eval"):
        f = getattr(ImageMath, fn, None)
        if f is None:
            continue
        try:
            return f(expr, a=a, b=b)
        except Exception:
            continue
    raise RuntimeError("ImageMath 除法不可用")


def _cell_field(im, mask, cell=CELL):
    """每 cell×cell 格的**掩码内平均色**（跳过格内非掩码像素）。

    返回 (cell_mean_rgb, valid_cells)，尺寸都是 (cw, ch)。
    只统计掩码内的像素 → 路面的灰色绝不会渗进旁边的草地格。
    """
    W, H = im.size
    cw, ch = (W + cell - 1) // cell, (H + cell - 1) // cell
    if (cw * cell, ch * cell) != (W, H):
        big = Image.new("RGB", (cw * cell, ch * cell), (0, 0, 0))
        big.paste(im, (0, 0))
        mb = Image.new("L", (cw * cell, ch * cell), 0)
        mb.paste(mask, (0, 0))
    else:
        big, mb = im, mask
    den = mb.resize((cw, ch), Image.BOX)
    chans = []
    for c in big.split():
        num = ImageChops.multiply(c, mb).resize((cw, ch), Image.BOX)
        chans.append(_div255(num, den))
    valid = den.point(lambda v: 255 if v > 96 else 0)
    return Image.merge("RGB", chans), valid


def _inpaint_cells(field, valid, passes=6):
    """无效格（掩码占比太低）用邻居均值填掉，避免平滑场在路边塌陷。"""
    f = field
    v = valid
    for _ in range(passes):
        if v.getextrema()[1] == 255 and _nz(v) == v.width * v.height:
            break
        blur = f.filter(ImageFilter.GaussianBlur(1.2))
        vblur = v.filter(ImageFilter.GaussianBlur(1.2))
        filled = Image.new("L", v.size, 0)
        filled = ImageChops.subtract(vblur.point(lambda x: 255 if x > 40 else 0), v)
        f = Image.composite(blur, f, filled)
        v = ImageChops.lighter(v, filled)
    return f


def _deblock(im, mask, ox, oy, cell=CELL, clamp=None):
    """把 cell 大小的平板台阶拉平，返回「有符号修正量」图（L，128 = 不变）。

    草地要跑两遍：一遍 8px（地面烘焙的格），一遍 4px（detail 层第三档
    `scale=4 + NEAREST` 噪声留下的 4px 方块迷彩）。只拉平格间 DC 差，
    格内 1px 细节和草簇线原样不动。
    """
    if clamp is None:
        clamp = DEBLOCK_CLAMP
    fld, valid = _cell_field(im, mask, cell)
    fld = _inpaint_cells(fld, valid)
    if DEBLOCK_BLUR > 0:
        fld = fld.filter(ImageFilter.GaussianBlur(DEBLOCK_BLUR))
    W, H = im.size
    cw, ch = fld.size
    # 格心对齐：NEAREST / BICUBIC 都以格中心为采样点
    big = (cw * cell, ch * cell)
    soft = fld.resize(big, Image.BICUBIC).crop((0, 0, W, H))
    flat = fld.resize(big, Image.NEAREST).crop((0, 0, W, H))
    corr = ImageChops.subtract(soft, flat)
    corr = corr.convert("L")
    corr = corr.point(lambda v: max(128 - clamp, min(128 + clamp, v)))
    return corr


def _flatten_low(im, mask, ox, oy):
    """把跨格的大尺度明暗斑压平，返回「有符号修正量」图（L，128 = 不变）。

    只看**亮度**：色相（g-r / g-b）一个像素都不动，所以草地分类不受影响；
    修正量再夹到 ±LOW_CLAMP，树影、墙脚 AO 这种真阴影不会被抹掉。
    掩码外（路面、水、铺装）不在均值和低频里，但按掩码合成的，落不到那里。
    """
    lum = im.convert("L")
    st = ImageStat.Stat(lum, mask)
    mean = int(round(st.mean[0]))
    # 掩码外先填成均值再模糊：否则旁边的沥青/水面会把草地边缘拉出一圈亮边
    src = Image.composite(lum, Image.new("L", lum.size, mean), mask)
    low = src.filter(ImageFilter.GaussianBlur(LOW_RADIUS))
    dev = ImageChops.subtract(low, Image.new("L", low.size, mean))
    ratio = 1.0 - LOW_KEEP
    # 128 ± clamp(dev*ratio)
    corr = dev.point(lambda v: max(128 - LOW_CLAMP,
                                   min(128 + LOW_CLAMP,
                                       128 - int(round((v - 128) * ratio)))))
    return corr


def _nz(mask):
    return D._nz(mask)


# ---- C. 水面 ---------------------------------------------------------
# 湖水是 4 种精确色画出来的 8px 马赛克（bake_channels 认水、道具候选都靠这 4 个值）。
# 直接改颜色会连锁破坏那些判定，所以这里**一个像素值都不改**，只把那 4 种色按
# 波纹重新排布：色值集合不变 → water_mask 逐像素等价，但空间上从棋盘变成水波。
WATER_ORDER = [(88, 128, 116), (104, 146, 132), (120, 164, 146), (142, 188, 164)]
WATER_LEVELS = (0.46, 0.66, 0.86)   # 分档阈值：大部分落在中深两档，浅色成碎光
## 波纹：主波是横纹（沿 y 变化），相位被 x 上的慢波推着走 → 波纹自然起伏；
## 再叠一个幅度很小的斜向高频，只用来打散「同一条纹从东到西都一样亮」。
## 单频正弦叠加容易算出规则点阵（像鱼鳞），所以第二项幅度必须小。
WATER_WAVE = (0.118, 0.0135, 1.35, 0.052, -0.031, 0.11)


def _repaint_water(im, ox, oy):
    """把水面 4 色马赛克重排成波纹。返回 (新图, 处理像素数)。"""
    mask = D.water_mask(im)
    if _nz(mask) == 0:
        return im, 0
    W, H = im.size
    out = im.copy()
    po = out.load()
    pm = mask.load()
    cols = WATER_ORDER
    lv = WATER_LEVELS
    ky, kx, kamp, sx, sy, samp = WATER_WAVE
    n = 0
    for y in range(H):
        wy = oy + y
        for x in range(W):
            if pm[x, y] < 128:
                continue
            wx = ox + x
            ph = wy * ky + kamp * sin(wx * kx * TAU)
            t = 0.5 + 0.30 * sin(ph * TAU) + samp * sin((wx * sx + wy * sy) * TAU)
            k = 0
            for th in lv:
                if t > th:
                    k += 1
            po[x, y] = cols[k]
            n += 1
    return out, n


class _Field:
    """一张 16×16 材质铺满整个世界后的「明暗增量」图。

    按全局像素网格铺，所以在任意裁剪框里取值都与全图一致（小样 == 铺开）。
    每格独立地从 8 个旋转/镜像变体里挑一个，避免出现整齐的棋盘重复。
    """

    def __init__(self, name, sigma, clip):
        im = Image.open(os.path.join(BLOCK_DIR, name)).convert("L")
        self.tw, self.th = im.size
        st = ImageStat.Stat(im)
        mean, sd = st.mean[0], (st.stddev[0] or 1.0)
        lut = [max(128 - clip, min(128 + clip, 128 + int(round((p - mean) / sd * sigma))))
               for p in range(256)]
        self.tiles = []
        for k in range(8):
            v = im
            if k & 1:
                v = v.transpose(Image.FLIP_LEFT_RIGHT)
            if k & 2:
                v = v.transpose(Image.FLIP_TOP_BOTTOM)
            if k & 4:
                v = v.transpose(Image.ROTATE_90)
            self.tiles.append(v.point(lut))

    def build(self, size, ox, oy):
        """返回 L 图：128 = 不变，值域 [128-clip, 128+clip]。"""
        W, H = size
        out = Image.new("L", (W, H), 128)
        tw, th = self.tw, self.th
        for ty in range(oy // th, (oy + H - 1) // th + 1):
            for tx in range(ox // tw, (ox + W - 1) // tw + 1):
                out.paste(self.tiles[D._hash8(SEED, tx, ty) % 8],
                          (tx * tw - ox, ty * th - oy))
        return out


@lru_cache(maxsize=1)
def _grass_field():
    return _Field(GRASS_TEX, GRASS_SIGMA, GRASS_CLIP)


@lru_cache(maxsize=1)
def _road_field():
    return _Field(ROAD_TEX, ROAD_SIGMA, ROAD_CLIP)


def _add_l(im, delta):
    """三通道加同一个有符号增量 → g-r / g-b / 通道极差逐像素不变。"""
    return ImageChops.add(im, Image.merge("RGB", (delta, delta, delta)),
                          scale=1.0, offset=-128)


def _classes(im):
    """五类掩码，全部是**逐像素**判定（不看邻居），所以「原样回填差异像素」
    一定能恢复原分类。"""
    road = D.road_mask(im)
    water = D.water_mask(im)
    return (
        road,
        water,
        D.grass_mask(im, road, water),
        R._strict_grass(im),
        R._beige_mask(im),
    )


def _enforce(before, out, rounds=3):
    """把「分类和原来不一样」的像素逐个回填成原样。

    去平板和纹理都是加性修正，主要靠 g-r / g-b / 通道极差维持分类；但草要求
    g>100、路要求 r 在 92~182，逼近阈值的那一小撮像素仍会被推过界。
    这些像素回填原色即可 —— 一百来个孤立像素改回去，肉眼看不出来，
    但道具候选网格（按格的草/路占比算）就不会漂。
    """
    a = _classes(before)
    total = 0
    for _ in range(rounds):
        b = _classes(out)
        bad = None
        for x, y in zip(a, b):
            d = D._diff_mask(x, y)
            bad = d if bad is None else ImageChops.lighter(bad, d)
        if bad is None:
            return out, 0, total
        n = _nz(bad)
        if n == 0:
            return out, 0, total
        total += n
        out = Image.composite(before, out, bad)
    b = _classes(out)
    left = 0
    for x, y in zip(a, b):
        left += _nz(D._diff_mask(x, y))
    return out, left, total


# ---------------------------------------------------------------- 主逻辑
def apply(im, ox=0, oy=0):
    W, H = im.size
    road, water, grass, _strict, beige = _classes(im)
    hard = ImageChops.lighter(water, beige)

    gm = grass.filter(ImageFilter.MinFilter(2 * ERODE_GRASS + 1))
    gm = ImageChops.subtract(gm, hard)
    gm = ImageChops.subtract(gm, road)

    rm = road.filter(ImageFilter.MinFilter(2 * ERODE_ROAD + 1))
    rm = ImageChops.subtract(rm, hard)

    gw = gm.filter(ImageFilter.GaussianBlur(FEATHER))
    rw = rm.filter(ImageFilter.GaussianBlur(1))

    out = im
    n_g = _nz(gm)
    n_r = _nz(rm)

    if DEBLOCK and n_g:
        for cell, clamp in DEBLOCK_CELLS_GRASS:
            corr = _deblock(out, gm, ox, oy, cell, clamp)
            out = Image.composite(_add_l(out, corr), out, gw)
    if LOW_FLATTEN and n_g:
        corr = _flatten_low(out, gm, ox, oy)
        out = Image.composite(_add_l(out, corr), out, gw)
    if n_g:
        out = Image.composite(_add_l(out, _grass_field().build((W, H), ox, oy)),
                              out, gw)
        if GRASS_SHADE:
            out = Image.composite(
                _add_l(out, Image.new("L", (W, H), 128 + GRASS_SHADE)), out, gw)
    if DEBLOCK and n_r:
        for cell, clamp in DEBLOCK_CELLS_ROAD:
            corr = _deblock(out, rm, ox, oy, cell, clamp)
            out = Image.composite(_add_l(out, corr), out, rw)
    if LOW_FLATTEN and n_r:
        corr = _flatten_low(out, rm, ox, oy)
        out = Image.composite(_add_l(out, corr), out, rw)
    if n_r:
        out = Image.composite(_add_l(out, _road_field().build((W, H), ox, oy)),
                              out, rw)

    out, left, total = _enforce(im, out)
    n_w = 0
    if WATER_WAVE is not None:
        out, n_w = _repaint_water(out, ox, oy)
    return out, {"grass_px": n_g, "road_px": n_r, "water_px": n_w,
                 "reverted_px": total,
                 "size": (W, H), "ox": ox, "oy": oy}


def check(stats):
    if stats["grass_px"] <= 0:
        raise AssertionError("小样没有落上草地纹理")
    return True


# ---------------------------------------------------------------- 对比图
def _font(size):
    p = os.path.join(ROOT, "assets", "fonts", "noto_sc_game.ttf")
    if os.path.exists(p):
        return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def _compare(before, after, path, scale, title, note):
    w, h = before.size
    W, H = int(w * scale), int(h * scale)
    a = before.resize((W, H), Image.NEAREST)
    b = after.resize((W, H), Image.NEAREST)
    top, gap, foot = 62, 14, 54
    canvas = Image.new("RGB", (W * 2 + gap, H + top + foot), (24, 26, 30))
    d = ImageDraw.Draw(canvas)
    d.text((14, 10), title, font=_font(24), fill=(238, 240, 244))
    d.text((14, 38), "LEFT: BEFORE (layer 10)    RIGHT: AFTER (deblock + block texture)",
           font=_font(16), fill=(150, 160, 172))
    canvas.paste(a, (0, top))
    canvas.paste(b, (W + gap, top))
    d.rectangle([0, top, W - 1, top + H - 1], outline=(70, 76, 84), width=1)
    d.rectangle([W + gap, top, W * 2 + gap - 1, top + H - 1],
                outline=(70, 76, 84), width=1)
    d.text((12, top + H + 10), note, font=_font(16), fill=(160, 170, 180))
    canvas.save(path)
    print("[texture] 对比图 -> %s (%dx%d)" %
          (os.path.basename(path), canvas.width, canvas.height))


# ---------------------------------------------------------------- 验收
def _verify_box(box):
    before = D.load_ground(box)
    after, st = apply(before, box[0], box[1])
    check(st)
    bad = []
    names = ("road", "water", "grass_loose", "grass_strict", "beige")
    for name, x, y in zip(names, _classes(before), _classes(after)):
        d = _nz(D._diff_mask(x, y))
        print("[texture] %-13s 掩码 diff: %d px   (回填 %d px)" %
              (name, d, st["reverted_px"]))
        if d:
            bad.append(name)
    return bad


def _apply_full():
    for cy in range(ROWS):
        for cx in range(COLS):
            x0, y0 = cx * CHUNK, cy * CHUNK
            sw, sh = min(CHUNK, WORLD_W - x0), min(CHUNK, WORLD_H - y0)
            if sw <= 0 or sh <= 0:
                continue
            box = (x0, y0, x0 + sw, y0 + sh)
            im = D.load_ground(box)
            out, st = apply(im, x0, y0)
            p = os.path.join(ROOT, "assets", "ground", "g%d_%d.png" % (cx, cy))
            out.save(p)
            print("[texture] g%d_%d  草 %6d px  路 %6d px  水 %5d px" %
                  (cx, cy, st["grass_px"], st["road_px"], st["water_px"]))
    print("[texture] 已全图写回 assets/ground/")


def main():
    args = sys.argv[1:]
    if "--apply" in args:
        if "--force" not in args:
            raise SystemExit("[texture] 会覆盖 28 张地面贴图，请显式加 --force")
        _apply_full()
        return
    if "--dry" in args or "--verify" in args:
        bad = []
        for box in ((0, 0, 512, 512), (2048, 3072, 2560, 3584), PRE_BOX, CLOSE_BOX):
            print("[texture] 检查 %s" % (box,))
            bad += _verify_box(box)
        if bad:
            raise SystemExit("[texture] 分类被改动: %s" % ", ".join(sorted(set(bad))))
        print("[texture] ALL PASS（分类零改动）")
        return

    for box, path, scale, title, note in (
        (PRE_BOX, OUT_PRE, 1, "Grass / road texture - sample",
         "Shapes identical; 8px plateaus flattened, 1px grain added."),
        (CLOSE_BOX, OUT_PRE2, 10, "Lawn closeup (10x)",
         "No 8px checkerboard left; grain must read as grass, not noise."),
    ):
        before = D.load_ground(box)
        after, st = apply(before, box[0], box[1])
        check(st)
        _compare(before, after, path, scale, title, note)
        print("      草 %d px / 路 %d px" % (st["grass_px"], st["road_px"]))


if __name__ == "__main__":
    main()
