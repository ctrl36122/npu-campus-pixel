#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第 9 层：硬质铺装边缘的绿化带（灌木绿篱）。

为什么单开一层而不是塞进第 8 层：
  第 8 层脚本的 `--verify` 基准是「当前地面 == 第 8 层链重算」。把第 9 层直接
  加进 `bake_ground_layer8.apply()` 会让那条断言永远失败。层与层之间保持
  「一层一个脚本、各自的基准是自己的上一版」，验收才能一直有效。

做什么：
  在**道路与米色铺装**（两者都是硬质面）的草侧，沿边缘画一条 6px 宽、
  按全局网格切成 9~14px 一段的深绿灌木带。解决的是「广场和道路直接切到
  草地、两侧光秃秃」的问题。

颜色红线：
  三种绿都必须同时满足
    * `place_life_props` 严格草：g-r>14 / g-b>28 / g>100
    * `D.grass_mask`：g 是最大通道
    * 不是 road：spread=max-min<=6 且 92<=r<=182 —— 深绿 r 只有 50~90，天然不命中
  所以画完之后 road / grass / water 三张掩码一格都不变，道具候选网格也不变。

幂等：
  落笔位置由「硬质面距离场 + 全局坐标条纹」决定，颜色是固定值；灌木像素画完
  仍然是严格草、仍然在距离场内 -> 第二次 apply 命中完全相同的像素、写完全
  相同的颜色 -> `apply²` 逐字节相等。

用法：
    python tools/bake_ground_layer9.py                 # 出对比小样，不写回
    python tools/bake_ground_layer9.py --dry           # 全图零写回预演
    python tools/bake_ground_layer9.py --apply --force # 全图铺开（覆盖 28 张地面贴图）
    python tools/bake_ground_layer9.py --verify        # 铺开后：链重算验收
"""
import json
import os
import sys
from functools import lru_cache

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
ROOT = os.path.dirname(HERE)

import bake_road_edge as E
import bake_ground_detail as D
import bake_ground_refine as R
import bake_ground_layer8 as L8

WORLD_JSON = os.path.join(ROOT, "assets", "world.json")
CELL = 8
SEED = 20261111
WORLD_W, WORLD_H = E.WORLD_W, E.WORLD_H

OUT_LIB = os.path.join(ROOT, "shot_layer9_lib.png")
OUT_JUNCTION = os.path.join(ROOT, "shot_layer9_junction.png")
OUT_EDGE = os.path.join(ROOT, "shot_layer9_edge.png")
OUT_SCENE = os.path.join(ROOT, "shot_layer9_scene.png")
OUT_PLAZA = os.path.join(ROOT, "shot_layer9_plaza.png")

LIB_BOX = (1560, 2360, 2376, 3176)
JUNCTION_BOX = (544, 0, 1360, 816)
EDGE_BOX = (1568, 2688, 1952, 2976)      # 与第 8 层路缘特写同一取景，便于纵向对比
PLAZA_BOX = (1704, 3800, 2520, 4616)     # 图书馆广场边缘

# ---- 灌木绿篱（整体仍是严格草）----
HEDGE_SKIP = 1                 # 最贴硬质面的 1px 留空（路肩过渡像素不算严格草）
HEDGE_W = 8                    # 绿篱最大带宽（px），从 HEDGE_SKIP+1 起算
HEDGE_DEEP = (68, 112, 54)     # 贴硬质面一侧（根部阴影）：g-r=44 / g-b=58 / g=112
HEDGE_MID = (88, 136, 70)      # 主体：g-r=48 / g-b=66 / g=136
HEDGE_TOP = (108, 158, 84)     # 远离硬质面一侧（受光叶尖）：g-r=50 / g-b=74 / g=158
NOISE_STEP = 4                 # 起伏噪声的块边长（px）：越小越碎
NOISE_CUT = (80, 170)          # 噪声分档阈值：<80 削 3px，<170 削 1px，否则不削
WATER_KEEP = 7                 # 水岸 N px 内不画绿篱（路边到水边常常只有几 px）
GRASS_CORE_ERODE = 3           # 草面腐蚀次数：滤掉 <7px 的窄缝，那里不长绿篱
GRASS_REACH = 10               # 从宽草核心向外允许落笔的距离（px）


def load_world():
    with open(WORLD_JSON, encoding="utf-8") as f:
        return json.load(f)


# ---------------------------------------------------------------- 全图掩码（缓存）
@lru_cache(maxsize=1)
def _noise_map():
    """全局 4px 块噪声（0..255），用来让绿篱外侧有凹凸。

    纯 PIL 实现：先在 1/NOISE_STEP 分辨率上用 `_hash8` 填一张字节图，再
    NEAREST 放大。用 `frombytes` 而不是 putpixel —— 后者 135 万次会慢到分钟级。
    结果与裁剪框无关，所以小样 == 全图。
    """
    sw, sh = WORLD_W // NOISE_STEP, WORLD_H // NOISE_STEP
    buf = bytearray(sw * sh)
    i = 0
    h = D._hash8
    for y in range(sh):
        for x in range(sw):
            buf[i] = h(SEED, x, y)
            i += 1
    small = Image.frombytes("L", (sw, sh), bytes(buf))
    return small.resize((WORLD_W, WORLD_H), Image.NEAREST)


@lru_cache(maxsize=1)
def _global_masks(_stamp):
    """在全图上一次性算出绿篱落笔掩码，之后按 (ox,oy,W,H) 裁剪。

    全图算的原因同第 8 层：`MaxFilter` 在裁剪框边缘会吃不到邻域，小样会
    和全图铺开出现 1px 级差异。
    """
    full = D.load_ground((0, 0, WORLD_W, WORLD_H))
    size = (WORLD_W, WORLD_H)

    road = D.road_mask(full)
    beige = R._beige_mask(full)
    hard = ImageChops.lighter(road, beige)
    hard = ImageChops.multiply(hard, L8._world_margin(size, 0, 0))

    grass = R._strict_grass(full)

    # 距离场：lvl[k] = 距硬质面 <= k px 的区域
    span = HEDGE_SKIP + HEDGE_W
    lvl = [hard]
    for _ in range(span):
        lvl.append(lvl[-1].filter(ImageFilter.MaxFilter(3)))

    # depth 图：值 = 该像素距硬质面几 px（1..HEDGE_W）
    depth = Image.new("L", size, 0)
    for k in range(1, HEDGE_W + 1):
        ring = ImageChops.subtract(lvl[HEDGE_SKIP + k], lvl[HEDGE_SKIP + k - 1])
        depth = Image.composite(Image.new("L", size, k), depth, ring)

    # 允许深度：噪声分三档，削 0/1/2 px —— 绿篱外侧因此有连续的凹凸轮廓。
    # 存 allow+1，这样 `subtract(allow, depth) > 0` 等价于 `depth <= allow`。
    lo, hi = NOISE_CUT
    allow_lut = [(HEDGE_W + 1) if v >= hi else
                 ((HEDGE_W) if v >= lo else (HEDGE_W - 2)) for v in range(256)]
    allow = _noise_map().point(allow_lut)
    inside = ImageChops.subtract(allow, depth).point(
        [255 if v > 0 else 0 for v in range(256)])

    # 水岸保护：路边到水边往往只有 3~5px，长满绿篱会把溪流勾成一圈水沟。
    water = D.water_mask(full)
    wet = water
    for _ in range(WATER_KEEP):
        wet = wet.filter(ImageFilter.MaxFilter(3))
    inside = ImageChops.subtract(inside, wet)

    # 只在「成片的草地」边缘长绿篱：两条路之间 3~6px 的窄缝不长，
    # 否则每块草坪都被完整包一圈，网格状路网看起来像一排笼子。
    gcore = grass
    for _ in range(GRASS_CORE_ERODE):
        gcore = gcore.filter(ImageFilter.MinFilter(3))
    reach = gcore
    for _ in range(GRASS_REACH):
        reach = reach.filter(ImageFilter.MaxFilter(3))
    inside = ImageChops.multiply(inside, reach)

    # 分档落笔：只有严格草、在起伏轮廓内
    # 注意用 256 长 LUT 而不是 point(lambda)：后者是 C 层逐像素回调 Python，
    # 全图 2100 万像素跑 8 次要几分钟；LUT 是纯查表，亚秒级。
    layers = []
    for k in range(1, HEDGE_W + 1):
        lk = [255 if v == k else 0 for v in range(256)]
        m = depth.point(lk)
        m = ImageChops.multiply(m, inside)
        m = ImageChops.multiply(m, grass)
        if k == 1:
            color = HEDGE_DEEP
        elif k <= 3:
            color = HEDGE_MID
        else:
            color = HEDGE_TOP
        layers.append((m, color))
    return tuple(layers)


def _crop(mask, ox, oy, W, H):
    if ox == 0 and oy == 0 and mask.width == W and mask.height == H:
        return mask
    return mask.crop((ox, oy, ox + W, oy + H))


# ---------------------------------------------------------------- 主入口
def apply(im, ox=0, oy=0, world=None):
    """在裁剪块 im（左上角对应世界坐标 ox,oy）上叠加第 9 层。"""
    W, H = im.size
    out = im
    stats = {"hedge_px": 0, "size": (W, H), "ox": ox, "oy": oy}

    for mask, color in _global_masks(id(world)):
        local = _crop(mask, ox, oy, W, H)
        n = D._nz(local)
        if not n:
            continue
        out = Image.composite(Image.new("RGB", (W, H), color), out, local)
        stats["hedge_px"] += n
    return out, stats


def check(stats):
    need = lambda ok, msg: None if ok else (_ for _ in ()).throw(AssertionError(msg))
    need(stats["hedge_px"] > 0, "小样区域没有落上绿篱")
    return True


def _chain8(world):
    """从真源重算到第 8 层（当前已铺开的地面）。"""
    base7 = L8._chain7(world)
    return L8.apply(base7, 0, 0, world)[0]


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
    d.text((14, 38), "LEFT: BEFORE (layer 8)    RIGHT: AFTER (layer 9)",
           font=_font(16), fill=(150, 160, 172))
    canvas.paste(a, (0, top))
    canvas.paste(b, (W + gap, top))
    d.rectangle([0, top, W - 1, top + H - 1], outline=(70, 76, 84), width=1)
    d.rectangle([W + gap, top, W * 2 + gap - 1, top + H - 1],
                outline=(70, 76, 84), width=1)
    d.text((12, top + H + 10), note, font=_font(16), fill=(160, 170, 180))
    canvas.save(path)
    print("[layer9] 对比图 -> %s (%dx%d, %d B)" %
          (os.path.basename(path), canvas.width, canvas.height, os.path.getsize(path)))


def _local_scene(ground_crop, world, box):
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
        bim = Image.open(p).convert("RGBA")
        if x >= x1 or x + bim.width <= x0 or y >= y1 or y + bim.height <= y0:
            continue
        bl.append((float(b.get("baseY", y / CELL)), x, y, bim))
    bl.sort(key=lambda t: t[0])
    for _, x, y, bim in bl:
        dx, dy = int(x - x0), int(y - y0)
        sx0, sy0 = max(0, -dx), max(0, -dy)
        sx1 = min(bim.width, g.width - dx)
        sy1 = min(bim.height, g.height - dy)
        if sx1 <= sx0 or sy1 <= sy0:
            continue
        g.alpha_composite(bim.crop((sx0, sy0, sx1, sy1)),
                          (max(0, dx), max(0, dy)))
    return g.convert("RGB")


# ---------------------------------------------------------------- 全图验收
def _validate(world, expect_layer9):
    import preview_full_apply as V
    import tempfile

    tag = "verify" if expect_layer9 else "dry"
    base8 = _chain8(world)
    cur = D.load_ground((0, 0, WORLD_W, WORLD_H))
    d8 = D._nz(D._pix_changed(base8, cur))
    print("[%s] 第 8 层链重算 vs 当前地面: %d px 差异" % (tag, d8))
    if not expect_layer9 and d8:
        raise SystemExit("[dry] 当前地面不是第 8 层链产物，基准漂移")

    candidate, st = apply(base8, 0, 0, world)
    check(st)
    ref = candidate if expect_layer9 else base8
    dchain = D._nz(D._pix_changed(ref, cur))
    print("[%s] %s vs 当前地面: %d px 差异（应为 0）" %
          (tag, "第 9 层链重算" if expect_layer9 else "第 8 层链重算", dchain))
    if dchain:
        raise SystemExit("[%s] 当前地面与幂等链不一致" % tag)

    again, _ = apply(base8, 0, 0, world)
    ok = candidate.tobytes() == again.tobytes()
    print("[%s] 二次 apply 一致: %s" % (tag, ok))
    if not ok:
        raise SystemExit("[%s] apply 不是确定性的" % tag)
    twice, _ = apply(candidate, 0, 0, world)
    idem = D._nz(D._pix_changed(candidate, twice))
    print("[%s] apply² 幂等差异: %d px" % (tag, idem))
    if idem:
        raise SystemExit("[%s] apply² 不是幂等的" % tag)

    nd = D._nz(D._pix_changed(base8, candidate))
    print("[%s] 第 9 层新增差异 %d px（灌木绿篱）" % (tag, nd))

    for name, fn in (("road", D.road_mask), ("water", D.water_mask)):
        d = D._nz(D._diff_mask(fn(base8), fn(candidate)))
        print("[%s] %s 掩码 diff: %d px" % (tag, name, d))
        if d:
            raise SystemExit("[%s] %s 掩码变了" % (tag, name))
    gm = D.grass_mask(base8, D.road_mask(base8), D.water_mask(base8))
    gc = D.grass_mask(candidate, D.road_mask(candidate), D.water_mask(candidate))
    d = D._nz(D._diff_mask(gm, gc))
    print("[%s] grass 掩码 diff: %d px" % (tag, d))
    if d:
        raise SystemExit("[%s] grass 掩码变了" % tag)

    with tempfile.TemporaryDirectory(prefix="xgd_layer9_" + tag + "_") as td:
        rb, gb = V.prop_grids(base8, td, "before")
        ra, ga = V.prop_grids(candidate, td, "after")
        dr = sum(1 for a, b in zip(rb, ra) if a != b)
        dg = sum(1 for a, b in zip(gb, ga) if a != b)
    print("[%s] road 道具网格 diff: %d 格" % (tag, dr))
    print("[%s] grass 道具网格 diff: %d 格" % (tag, dg))
    if dr or dg:
        raise SystemExit("[%s] 道具候选网格变了" % tag)

    h = V.resource_hash() if hasattr(V, "resource_hash") else None
    if h:
        print("[%s] 资源总哈希 %s" % (tag, h))
    print("[%s] ALL PASS" % tag)
    return candidate


def _apply_full(world):
    base8 = _chain8(world)
    out, st = apply(base8, 0, 0, world)
    check(st)
    E.save(out)
    print("[layer9] 已全图写回 assets/ground/：灌木绿篱 %d px" % st["hedge_px"])
    print("[layer9] 记得升 Arena.gd 的 MINIMAP_CACHE 并跑 godot --headless --path . --import")


def main():
    args = sys.argv[1:]
    world = load_world()

    if "--apply" in args:
        if "--force" not in args:
            raise SystemExit("[layer9] 全图铺开会覆盖 28 张地面贴图，请显式加 --force")
        _apply_full(world)
        return

    if "--dry" in args or "--verify" in args:
        _validate(world, "--verify" in args)
        return

    # 默认：出小样对比图，不写回
    for box, path, scale, title, note in (
        (LIB_BOX, OUT_LIB, 1, "Library area - ground layer 9 (SAMPLE ONLY)",
         "Road edge used to cut straight into grass; now a hedge band with a broken outline."),
        (JUNCTION_BOX, OUT_JUNCTION, 1, "Street corners - ground layer 9 (SAMPLE ONLY)",
         "Hedge on the grass side of every arm; the junction itself stays clear."),
        (EDGE_BOX, OUT_EDGE, 3, "Road edge - closeup (3x)",
         "Check hedge width, broken outline, three-tone shading; nothing eaten into the shoulder."),
        (PLAZA_BOX, OUT_PLAZA, 1, "Library plaza - beige paving meets grass",
         "Plaza used to cut hard into grass; now the rim has a planting transition."),
    ):
        before = D.load_ground(box)
        after, st = apply(before, box[0], box[1], world)
        check(st)
        _compare(before, after, path, scale, title, note)
        print("      绿篱 %d px / 块内 %d px" % (st["hedge_px"], before.width * before.height))

    # 实景合成（贴上建筑 sprite 看真实遮挡）
    before = D.load_ground(PLAZA_BOX)
    after, _ = apply(before, PLAZA_BOX[0], PLAZA_BOX[1], world)
    sb = _local_scene(before, world, PLAZA_BOX)
    sa = _local_scene(after, world, PLAZA_BOX)
    _compare(sb, sa, OUT_SCENE, 1, "Library plaza with building sprites composited",
             "Hedge is correctly occluded where building sprites overlap.")


if __name__ == "__main__":
    main()
