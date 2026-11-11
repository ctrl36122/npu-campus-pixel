#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""地面第 8 层 —— 路缘石分段缝 + 人行道分界 + 树影斑驳光斑。

接在已铺开的第 7 层（广场石板）之后，成为幂等链的新末端：

    _ground_src -> bake_roads.build() -> detail.apply()
                -> refine.apply()     -> layer8.apply() -> E.save()

## 为什么独立成文件
第 7 层已经写回 assets/ground/，`bake_ground_refine.py --verify` 的基准是
「当前地面 == 第 7 层链重算」。把新层塞进 refine.apply() 会让那条 --verify
立刻失效。独立脚本自己从第 7 层链重算，不修改任何既有脚本；铺开后验收入口
改为本脚本的 --verify（refine 的 --verify 届时作废）。

## 三处新增（全部只动「已判定类别内部」的像素）
  * 路缘石分段缝：road 掩码最外 1px 环上，按路缘走向每 16px 一道 1px 竖/横缝，
    读起来是一块块石条，而不是一条连续带。不覆盖已有的方向性 bevel 明暗。
  * 人行道分界：road 掩码内距边界 2px 的环上画一条连续浅灰分界线，
    每 8px 一个暗缝点，把「人行道带」和「车行道」分开。
  * 树影斑驳：复用 bake_ground_detail 的树冠椭圆公式，在影内按确定性哈希撒
    亮/暗碎斑（叶隙透光），替代现在一整片均匀压暗的软影。

## 颜色红线（改一处就会连锁破坏道具摆放 / 光照图 / 小地图）
  * place_life_props 认路：`max-min<=12 and 92<=r<=182`；认草：
    `g>r+14 and g>b+28 and g>100`（即 R._strict_grass）
  * D.grass_mask：`g>=r and g>=b` 且非路非水；D.water_mask：精确 4 色容差 8
  * 路面系新色全是中性灰、r∈[104,160]，仍判 road，且只画在 road 掩码内；
  * 草地系新色全是 g 主导（g-r>=40 / g-b>=72 / g>=158），仍判严格草，
    且只画在严格草掩码内；
  * 水面像素一个都不碰，米色铺装（r>g>b）也不会命中草系新色。
结果：road / grass / water 三张掩码逐像素 0 差异，401 个道具候选格不变。

## 确定性 / 幂等
所有落笔都是固定色覆盖，掩码由输入图算出且颜色不改分类 —— 二次 apply 写的是
同一批固定色到同一批位置，apply(apply(x)) == apply(x) 逐字节成立。
缝线按全局坐标周期生成（gxp / gyp），斑块参数按 (树 idx, 斑 k) 一次性预生成，
裁剪区外不消耗随机序列，所以小样所见 == 全图铺开所得。

## 用法
    python tools/bake_ground_layer8.py                    # 小样对比图，不写任何资源
    python tools/bake_ground_layer8.py --dry             # 铺开前：全图零写回预演
    python tools/bake_ground_layer8.py --apply --force   # 全图铺开（覆盖 28 张地面贴图）
    python tools/bake_ground_layer8.py --verify          # 铺开后：链重算验收
"""
import hashlib
import glob
import json
import math
import os
import random
import sys
import tempfile
from functools import lru_cache

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
ROOT = os.path.dirname(HERE)

import bake_road_edge as E          # noqa: E402
import bake_roads as B              # noqa: E402
import bake_ground_detail as D      # noqa: E402
import bake_ground_refine as R      # noqa: E402

WORLD_JSON = os.path.join(ROOT, "assets", "world.json")
CELL = 8
WORLD_W, WORLD_H = E.WORLD_W, E.WORLD_H
SEED = 20261111

OUT_LIB = os.path.join(ROOT, "shot_layer8_lib.png")
OUT_JUNCTION = os.path.join(ROOT, "shot_layer8_junction.png")
OUT_CURB = os.path.join(ROOT, "shot_layer8_curb.png")
OUT_TREE = os.path.join(ROOT, "shot_layer8_tree.png")
OUT_SCENE = os.path.join(ROOT, "shot_layer8_scene.png")

# 小样取景对齐全局 8px 网格
LIB_BOX = (1560, 2360, 2376, 3176)        # 图书馆周边：草地 / 弧路 / 水岸 / 树
JUNCTION_BOX = (544, 0, 1360, 816)        # 街角：多条宽路 + 路口
CURB_BOX = (1568, 2688, 1952, 2976)       # 384x288，道路边缘 3 倍放大看缝
TREE_BOX = (1900, 200, 2260, 520)         # 360x320，树影斑驳近景

# ---- 路缘石分段缝（仍是 road）----
CURB_LEN = 16                 # 每 16px 一块石条
CURB_JOINT = (104, 106, 110)  # 缝色：spread=6 / r=104，仍判 road
CURB_INSET = 3                # 分界线从路缘沿法线向内平移 3px
AXIS_PROBE = 6                # 判定「规则直路」时沿走向探 6px

# ---- 人行道分界（仍是 road）----
SIDEWALK_RING = 2             # 距路面边界 2px 的腐蚀环
SIDEWALK_LINE = (138, 140, 143)   # 分界线：spread=5 / r=138（只比路面亮 18 级，去描边感）
SIDEWALK_DOT = (124, 126, 130)    # 缝点：spread=6 / r=124
SIDEWALK_TILE = 8
# 只有「宽路」才配人行道：1 格宽(8px)的斜支路被腐蚀 2 次后会碎成孤立胶囊，
# 再画亮线就成了一串空心椭圆环。用 erode(CORE_ERODE) 找到宽路核心，
# dilate 回去得到允许落笔的带；窄路不落笔，保持原样。
CORE_ERODE = 4
CORE_DILATE = 6

# ---- 树影斑驳（仍是严格草）----
# 第一版用 (158,214,116)/(104,144,74) 拉开 40 级，8x 特写里是突兀的亮绿/暗绿
# 方块，像彩色噪点。改成「相对树影区草色 (127,171,98) 只偏 ±10~16 级」的
# 低对比两档 + 少量更淡的一档，形状用 2x2/3x2 椭圆，读作叶隙明暗而非色块。
DAPPLE_LIGHT = (140, 186, 104)    # 叶隙透光：g-r=46 / g-b=82 / g=186
DAPPLE_MID = (128, 174, 98)       # 过渡：g-r=46 / g-b=76 / g=174
DAPPLE_DARK = (116, 158, 88)      # 叶簇密处：g-r=42 / g-b=70 / g=158
DAPPLE_TONES = (DAPPLE_LIGHT, DAPPLE_MID, DAPPLE_DARK)
DAPPLE_R0 = 0.14               # 斑块只在椭圆半径 14%~92% 内（避开硬边）
DAPPLE_R1 = 0.92
DAPPLE_TREES = True


def load_world():
    with open(WORLD_JSON, encoding="utf-8") as f:
        return json.load(f)


# ---------------------------------------------------------------- 通用工具
def _world_margin(size, ox, oy):
    """排除世界最外 4px，防止 E.shift 的环绕伪影在贴图边缘造出假缝。

    用全局坐标判定（不是裁剪框坐标），所以小样框内部永远不触发，
    小样与全图仍然逐像素一致。
    """
    W, H = size
    m = Image.new("L", size, 255)
    d = ImageDraw.Draw(m)
    # 覆盖所有 offset 平移 / 方向探针的最大距离（CURB_INSET=3, AXIS_PROBE=6）
    pad = 8
    # 世界边界落在当前裁剪图里的矩形（可能是负坐标 -> 画到图外即可）
    x0, y0 = -ox, -oy
    x1, y1 = WORLD_W - ox, WORLD_H - oy
    d.rectangle([x0 - 8, y0 - 8, x0 + pad, y1 + 8], fill=0)
    d.rectangle([x1 - pad, y0 - 8, x1 + 8, y1 + 8], fill=0)
    d.rectangle([x0 - 8, y0 - 8, x1 + 8, y0 + pad], fill=0)
    d.rectangle([x0 - 8, y1 - pad, x1 + 8, y1 + 8], fill=0)
    return m


def _stripes(size, ox, oy, period, axis, offset=0):
    """按全局坐标生成的 1px 周期条纹 L 掩码。"""
    W, H = size
    m = Image.new("L", size, 0)
    d = ImageDraw.Draw(m)
    if axis == "x":
        first = (ox // period) * period + offset
        for gx in range(first, ox + W + period, period):
            lx = gx - ox
            if 0 <= lx < W:
                d.line([(lx, 0), (lx, H)], fill=255, width=1)
    else:
        first = (oy // period) * period + offset
        for gy in range(first, oy + H + period, period):
            ly = gy - oy
            if 0 <= ly < H:
                d.line([(0, ly), (W, ly)], fill=255, width=1)
    return m


def _xor(a, b):
    """两张 0/255 掩码的异或。"""
    return ImageChops.lighter(ImageChops.subtract(a, b),
                              ImageChops.subtract(b, a))


def _rings(road, n=4):
    """从外到内的 1px 腐蚀环：rings[0] 是最外圈，rings[k] 距边界 k px。"""
    out = []
    m = road
    for _ in range(n):
        inner = m.filter(ImageFilter.MinFilter(3))
        out.append(ImageChops.subtract(m, inner))
        m = inner
    return out


# ---------------------------------------------------------------- 路缘 + 人行道
def _sub(a, b):
    return ImageChops.subtract(a, b)


@lru_cache(maxsize=1)
def _global_masks(_stamp):
    """在全图上一次性算出三张落笔掩码，之后按 (ox,oy,W,H) 裁剪。

    为什么必须全图算：
      * 方向判定和平移用 ImageChops.offset，在裁剪框边缘会「环绕」进对侧内容；
      * 腐蚀环在 1 格宽(8px)的斜支路上会碎成一串孤立胶囊（第一版亮线把
        它们勾成白色椭圆环，就是这么来的）。
    改用「最外 1px 环 + 沿法线平移 CURB_INSET」：环本身在斜路上是连续阶梯线，
    平移后仍连续，不会碎。再按走向分水平/竖直两组，分别配竖缝/横缝条纹。
    """
    full = D.load_ground((0, 0, WORLD_W, WORLD_H))
    road = D.road_mask(full)
    ring0 = _rings(road, 1)[0]
    margin = _world_margin((WORLD_W, WORLD_H), 0, 0)

    # 1px 邻域判方向：ring0 上「上/下/左/右哪一侧不是路」= 它是哪条边
    n = _sub(ring0, E.shift(road, 0, 1))     # 上边缘（上方是草）
    s = _sub(ring0, E.shift(road, 0, -1))    # 下边缘
    w = _sub(ring0, E.shift(road, 1, 0))     # 左边缘
    e = _sub(ring0, E.shift(road, -1, 0))    # 右边缘
    n = ImageChops.multiply(n, margin)
    s = ImageChops.multiply(s, margin)
    w = ImageChops.multiply(w, margin)
    e = ImageChops.multiply(e, margin)

    stripe16x = _stripes((WORLD_W, WORLD_H), 0, 0, CURB_LEN, "x")
    stripe16y = _stripes((WORLD_W, WORLD_H), 0, 0, CURB_LEN, "y")
    stripe8x = _stripes((WORLD_W, WORLD_H), 0, 0, SIDEWALK_TILE, "x", 4)
    stripe8y = _stripes((WORLD_W, WORLD_H), 0, 0, SIDEWALK_TILE, "y", 4)

    # 路缘石分段缝：画在最外环上，水平路缘配竖缝、竖直路缘配横缝
    seam = ImageChops.lighter(
        ImageChops.multiply(ImageChops.lighter(n, s), stripe16x),
        ImageChops.multiply(ImageChops.lighter(w, e), stripe16y))
    seam = ImageChops.multiply(seam, road)

    # 人行道分界：四条边各自沿法线向内平移 CURB_INSET，再夹回路面内。
    # 平移而非腐蚀 -> 斜路不会碎成胶囊。
    ni = ImageChops.offset(n, 0, CURB_INSET)
    si = ImageChops.offset(s, 0, -CURB_INSET)
    wi = ImageChops.offset(w, CURB_INSET, 0)
    ei = ImageChops.offset(e, -CURB_INSET, 0)
    line = ImageChops.multiply(
        ImageChops.lighter(ImageChops.lighter(ni, si),
                           ImageChops.lighter(wi, ei)), road)

    # 分界线上的铺装缝点，方向同上
    dots = ImageChops.lighter(
        ImageChops.multiply(ImageChops.lighter(ni, si), stripe8x),
        ImageChops.multiply(ImageChops.lighter(wi, ei), stripe8y))
    dots = ImageChops.multiply(dots, road)

    # 「规则宽路」门槛：沿走向探 AXIS_PROBE 仍都是路，说明不是 1 格窄支路。
    # 只用来约束分界线（窄支路不硬塞人行道），路缘缝在任何路上都保留。
    axis_h = ImageChops.multiply(E.shift(road, AXIS_PROBE, 0),
                                 E.shift(road, -AXIS_PROBE, 0))
    axis_v = ImageChops.multiply(E.shift(road, 0, AXIS_PROBE),
                                 E.shift(road, 0, -AXIS_PROBE))
    axis = ImageChops.multiply(ImageChops.lighter(axis_h, axis_v), margin)
    line = ImageChops.multiply(line, axis)
    dots = ImageChops.multiply(dots, axis)
    return seam, line, dots


def _crop(mask, ox, oy, W, H):
    return mask.crop((ox, oy, ox + W, oy + H))


def _curb_and_sidewalk(im, road, ox, oy):
    W, H = im.size
    seam, line, dots = (_crop(m, ox, oy, W, H)
                        for m in _global_masks(0))
    # 兜底：掩码都必须落在当前输入的 road 掩码内
    seam = ImageChops.multiply(seam, road)
    line = ImageChops.multiply(line, road)
    dots = ImageChops.multiply(dots, road)

    layer = Image.new("RGB", im.size, CURB_JOINT)
    out = Image.composite(layer, im, seam)
    layer2 = Image.new("RGB", im.size, SIDEWALK_LINE)
    out = Image.composite(layer2, out, line)
    layer3 = Image.new("RGB", im.size, SIDEWALK_DOT)
    out = Image.composite(layer3, out, dots)
    return out, {
        "curb_seam_px": D._nz(seam),
        "sidewalk_line_px": D._nz(line),
        "sidewalk_dot_px": D._nz(dots),
    }


# ---------------------------------------------------------------- 树影斑驳
@lru_cache(maxsize=1)
def _dapple_specs(_stamp):
    """按 (树 idx, 斑 k) 一次性预生成全局坐标参数表，与裁剪区无关。"""
    world = load_world()
    specs = []
    for idx, t in enumerate(world.get("instances", [])):
        if t.get("k") != "tree":
            continue
        x = float(t["x"]) * CELL
        y = float(t["y"]) * CELL
        s = float(t.get("s", 1) or 1)
        r = (6.0 * s + 4.0) * random.Random(
            D.DETAIL_SEED + idx * 7919).uniform(0.8, 1.25)
        cx, cy = x + 7.0 * s, y + 5.0 * s
        n = 14 + int(s * 5)
        for k in range(n):
            s0 = SEED + idx * 131
            h1 = D._hash8(s0, k, 1)
            h2 = D._hash8(s0, k, 2)
            h3 = D._hash8(s0, k, 3)
            h4 = D._hash8(s0, k, 4)
            ang = 2.0 * math.pi * h1 / 255.0
            rho = math.sqrt(DAPPLE_R0 ** 2 +
                            (h2 / 255.0) * (DAPPLE_R1 ** 2 - DAPPLE_R0 ** 2))
            gx = cx + math.cos(ang) * r * rho
            gy = cy + math.sin(ang) * r * 0.62 * rho
            # 暗斑为主（h3<110 暗 / 110~205 过渡 / >205 亮），亮斑只作少量点缀
            ti = 2 if h3 < 110 else (1 if h3 < 205 else 0)
            w = 2 if h4 < 170 else 3
            ht = 2
            specs.append((int(round(gx)), int(round(gy)),
                          DAPPLE_TONES[ti], w, ht))
    return tuple(specs)


def _dapple(im, strict, ox, oy, world):
    W, H = im.size
    painted = im.copy()
    pd = ImageDraw.Draw(painted)
    marks = Image.new("L", im.size, 0)
    md = ImageDraw.Draw(marks)
    n = 0
    for gx, gy, color, bw, bh in _dapple_specs(id(world)):
        if not (ox - 4 <= gx < ox + W and oy - 4 <= gy < oy + H):
            continue
        lx, ly = gx - ox, gy - oy
        pd.ellipse([lx, ly, lx + bw - 1, ly + bh - 1], fill=color)
        md.ellipse([lx, ly, lx + bw - 1, ly + bh - 1], fill=255)
        n += 1
    # 只落在严格草内：路 / 水 / 米色铺装 / 路肩过渡像素一律不碰
    marks = ImageChops.multiply(marks, strict)
    return Image.composite(painted, im, marks), n


# ---------------------------------------------------------------- 主入口
def apply(im, ox=0, oy=0, world=None):
    """确定性、幂等。输入是第 7 层地面（或它的任意 8px 对齐裁剪）。"""
    if world is None:
        world = load_world()
    original = im.copy()
    road = D.road_mask(im)
    water = D.water_mask(im)
    grass = D.grass_mask(im, road, water)
    strict = R._strict_grass(im)

    out, cs = _curb_and_sidewalk(im, road, ox, oy)
    n_dapple = 0
    if DAPPLE_TREES:
        out, n_dapple = _dapple(out, strict, ox, oy, world)

    # 分类回滚兜底：任何让三张掩码变化的像素都恢复原值
    road2 = D.road_mask(out)
    water2 = D.water_mask(out)
    grass2 = D.grass_mask(out, road2, water2)
    cls_bad = ImageChops.lighter(ImageChops.lighter(
        D._diff_mask(road, road2), D._diff_mask(water, water2)),
        D._diff_mask(grass, grass2))
    # 水像素无条件恢复：即使分类没变，只要被写过就还原
    water_bad = ImageChops.multiply(
        water, D._pix_changed(original, out))
    restore = ImageChops.lighter(cls_bad, water_bad)
    restored = D._nz(cls_bad)
    if D._nz(restore):
        out = Image.composite(im, out, restore)

    stats = {
        "size": im.size, "ox": ox, "oy": oy,
        "grass_px": D._nz(grass), "road_px": D._nz(road), "water_px": D._nz(water),
        "restored_px": restored, "water_restored_px": D._nz(water_bad),
        "dapple_marks": n_dapple,
    }
    stats.update(cs)
    return out, stats


def check(stats):
    need = lambda ok, msg: None if ok else (_ for _ in ()).throw(AssertionError(msg))
    # water 本身会被无条件恢复计入 restored，分类级回滚必须为 0
    need(stats["restored_px"] == 0,
         "分类回滚 %d px：新层颜色破坏了 road/grass/water 掩码" % stats["restored_px"])
    need(stats["grass_px"] > 0 and stats["road_px"] > 0, "小样区域缺少草地或路面")
    return True


def _chain7(world):
    """从真源重算到第 7 层（当前已铺开的地面）。"""
    mid = R._chain(world)
    return R.apply(mid, 0, 0, world)[0]


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
    d.text((14, 38), "LEFT: BEFORE (layer 7)    RIGHT: AFTER (layer 8)",
           font=_font(16), fill=(150, 160, 172))
    canvas.paste(a, (0, top))
    canvas.paste(b, (W + gap, top))
    d.rectangle([0, top, W - 1, top + H - 1], outline=(70, 76, 84), width=1)
    d.rectangle([W + gap, top, W * 2 + gap - 1, top + H - 1],
                outline=(70, 76, 84), width=1)
    d.text((12, top + H + 10), note, font=_font(16), fill=(160, 170, 180))
    canvas.save(path)
    print("[layer8] 对比图 -> %s (%dx%d, %d B)" %
          (os.path.basename(path), canvas.width, canvas.height, os.path.getsize(path)))


def _local_scene(ground_crop, world, box):
    """按游戏里的 (x*CELL, y*CELL) + baseY 顺序贴建筑 sprite，看真实遮挡。"""
    x0, y0, x1, y1 = box
    g = ground_crop.convert("RGBA")
    g.putalpha(255)
    bl = []
    for i, b in enumerate(world["buildings"]):
        x = float(b.get("x", 0.0)) * CELL
        y = float(b.get("y", 0.0)) * CELL
        p = os.path.join(ROOT, "assets", "buildings", "b%d.png" % i)
        if not os.path.exists(p):
            continue
        im = Image.open(p).convert("RGBA")
        if x >= x1 or x + im.width <= x0 or y >= y1 or y + im.height <= y0:
            continue
        bl.append((float(b.get("baseY", y / CELL)), x, y, im))
    bl.sort(key=lambda t: t[0])
    for _, x, y, im in bl:
        dx, dy = int(x - x0), int(y - y0)
        sx0, sy0 = max(0, -dx), max(0, -dy)
        sx1, sy1 = min(im.width, g.width - dx), min(im.height, g.height - dy)
        if sx1 <= sx0 or sy1 <= sy0:
            continue
        g.alpha_composite(im.crop((sx0, sy0, sx1, sy1)), (max(0, dx), max(0, dy)))
    return g.convert("RGB")


# ---------------------------------------------------------------- 全图验收
def _validate(world, expect_layer8):
    import preview_full_apply as V

    tag = "verify" if expect_layer8 else "dry"
    base7 = _chain7(world)
    cur = D.load_ground((0, 0, WORLD_W, WORLD_H))
    d7 = D._nz(D._pix_changed(base7, cur))
    print("[%s] 第 7 层链重算 vs 当前地面: %d px 差异" % (tag, d7))
    if not expect_layer8 and d7:
        raise SystemExit("[dry] 当前地面不是第 7 层链产物，基准漂移")

    candidate, st = apply(base7, 0, 0, world)
    check(st)
    ref = candidate if expect_layer8 else base7
    dchain = D._nz(D._pix_changed(ref, cur))
    print("[%s] %s vs 当前地面: %d px 差异（应为 0）" %
          (tag, "第 8 层链重算" if expect_layer8 else "第 7 层链重算", dchain))
    if dchain:
        raise SystemExit("[%s] 当前地面与幂等链不一致" % tag)

    again, _ = apply(base7, 0, 0, world)
    ok = candidate.tobytes() == again.tobytes()
    print("[%s] 二次 apply 一致: %s" % (tag, ok))
    if not ok:
        raise SystemExit("[%s] apply 不是确定性的" % tag)
    twice, _ = apply(candidate, 0, 0, world)
    idem = D._nz(D._pix_changed(candidate, twice))
    print("[%s] apply² 幂等差异: %d px" % (tag, idem))
    if idem:
        raise SystemExit("[%s] apply² 不是幂等的" % tag)

    nd = D._nz(D._pix_changed(base7, candidate))
    print("[%s] 第 8 层新增差异 %d px（路缘缝 %d + 分界线 %d + 缝点 %d + 斑块 %d 处）" %
          (tag, nd, st["curb_seam_px"], st["sidewalk_line_px"],
           st["sidewalk_dot_px"], st["dapple_marks"]))

    # 分类掩码：第 7 层 vs 第 8 层
    for name, fn in (("road", D.road_mask), ("water", D.water_mask)):
        d = D._nz(D._diff_mask(fn(base7), fn(candidate)))
        print("[%s] %s 掩码 diff: %d px" % (tag, name, d))
        if d:
            raise SystemExit("[%s] %s 掩码变了" % tag)
    gm = D.grass_mask(base7, D.road_mask(base7), D.water_mask(base7))
    gc = D.grass_mask(candidate, D.road_mask(candidate), D.water_mask(candidate))
    d = D._nz(D._diff_mask(gm, gc))
    print("[%s] grass 掩码 diff: %d px" % (tag, d))
    if d:
        raise SystemExit("[%s] grass 掩码变了" % tag)

    # 道具候选网格（401 个道具的选址依据）
    with tempfile.TemporaryDirectory(prefix="xgd_layer8_" + tag + "_") as td:
        rb, gb = V.prop_grids(base7, td, "before")
        ra, ga = V.prop_grids(candidate, td, "after")
    for name, a, b in (("road", rb, ra), ("grass", gb, ga)):
        diff = V.grid_diff(a, b)
        print("[%s] %s 道具网格 diff: %d 格" % (tag, name, diff))
        if diff:
            raise SystemExit("[%s] %s 道具候选网格变了" % tag)

    pats = ["assets/world.json", "assets/osm_tags.json", "assets/ground/g*_*.png",
            "assets/_ground_src/g*_*.png", "assets/buildings/b*.png",
            "assets/glow_winb_*.png"]
    h = hashlib.sha256()
    for pat in pats:
        for p in sorted(glob.glob(os.path.join(ROOT, pat))):
            h.update(os.path.relpath(p, ROOT).encode("utf-8"))
            h.update(open(p, "rb").read())
    print("[%s] 174 资源总哈希 %s" % (tag, h.hexdigest()[:16]))
    print("[%s] ALL PASS" % tag)
    return candidate, base7


def _apply_full(world):
    base7 = _chain7(world)
    out, st = apply(base7, 0, 0, world)
    check(st)
    E.save(out)
    print("[layer8] 已全图写回 assets/ground/：路缘缝 %d px / 分界线 %d px / "
          "缝点 %d px / 树影斑块 %d 处 / 回滚 %d px"
          % (st["curb_seam_px"], st["sidewalk_line_px"], st["sidewalk_dot_px"],
             st["dapple_marks"], st["restored_px"]))
    print("[layer8] 记得升 Arena.gd 的 MINIMAP_CACHE 并跑 godot --headless --path . --import")


def main():
    args = sys.argv[1:]
    world = load_world()
    if "--apply" in args:
        if "--force" not in args:
            raise SystemExit("[layer8] 全图铺开会覆盖 28 张地面贴图，请显式加 --force")
        _apply_full(world)
        return
    if "--dry" in args or "--verify" in args:
        _validate(world, "--verify" in args)
        return

    note = ("Curb joints + sidewalk division + dappled tree shade. "
            "Grass / water untouched; road / grass / water masks unchanged.")
    boxes = ((LIB_BOX, OUT_LIB, 1.4, "Library area - ground layer 8 (SAMPLE ONLY)"),
             (JUNCTION_BOX, OUT_JUNCTION, 1.4, "Street corners - ground layer 8 (SAMPLE ONLY)"),
             (CURB_BOX, OUT_CURB, 3.0, "Curb + sidewalk - closeup (3x)"),
             (TREE_BOX, OUT_TREE, 2.0, "Tree shade dapple - closeup (2x)"))
    for box, path, scale, title in boxes:
        before = D.load_ground(box)
        after, st = apply(before, box[0], box[1], world)
        check(st)
        again, _ = apply(before, box[0], box[1], world)
        if after.tobytes() != again.tobytes():
            raise SystemExit("[layer8] 同输入两次结果不一致: %s" % str(box))
        twice, _ = apply(after, box[0], box[1], world)
        idem = D._nz(D._pix_changed(after, twice))
        if idem:
            raise SystemExit("[layer8] apply² 不是幂等的: %s (%d px)" % (str(box), idem))
        print("[layer8] 小样 %s：路缘缝 %d / 分界线 %d / 缝点 %d / 斑块 %d / "
              "回滚 %d / apply² %d" %
              (str(box), st["curb_seam_px"], st["sidewalk_line_px"],
               st["sidewalk_dot_px"], st["dapple_marks"], st["restored_px"], idem))
        _compare(before, after, path, scale, title, note)

    jb = JUNCTION_BOX
    _compare(_local_scene(D.load_ground(jb), world, jb),
             _local_scene(apply(D.load_ground(jb), jb[0], jb[1], world)[0], world, jb),
             OUT_SCENE, 1.0, "In-game view (1:1) - ground layer 8", note)


if __name__ == "__main__":
    main()
