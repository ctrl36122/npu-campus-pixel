#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第 10 层：建筑墙脚的绿化。

为什么不用 world.json 的 `poly`：
  `poly` 是**俯视占地**多边形，而建筑 sprite 是 2.5D 立面 —— sprite 的底边
  比 poly 的南边缘还要低 20~30px（自带一条浅色散水裙边）。拿 poly 外扩出来
  的那一圈，整圈都被 sprite 自己盖住，画了也看不见。

做法：
  逐列读 sprite 的 alpha，取每列**最底部**的不透明像素作为「墙脚接触点」，
  再从接触点向下 5px 铺一条绿化带。这样绿化带始终紧贴建筑实际的落地线，
  楼是斜的、有台阶门廊突出的，绿化带就跟着斜、跟着缩进。

颜色红线（与第 9 层同源，但更暗一档 —— 墙脚本来就背光）：
  三档都必须满足严格草 g-r>14 / g-b>28 / g>100，且 spread 远大于 6，不命中 road。

用法：
    python tools/bake_ground_layer10.py                 # 出对比小样，不写回
    python tools/bake_ground_layer10.py --dry           # 全图零写回预演
    python tools/bake_ground_layer10.py --apply --force # 全图铺开
    python tools/bake_ground_layer10.py --verify        # 铺开后验收
"""
import json
import os
import sys
from functools import lru_cache

from PIL import Image, ImageChops, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
ROOT = os.path.dirname(HERE)

import bake_road_edge as E
import bake_ground_detail as D
import bake_ground_refine as R
import bake_ground_layer8 as L8
import bake_ground_layer9 as L9

WORLD_JSON = os.path.join(ROOT, "assets", "world.json")
BUILDING_DIR = os.path.join(ROOT, "assets", "buildings")
CELL = 8
SEED = 20261112
WORLD_W, WORLD_H = E.WORLD_W, E.WORLD_H

OUT_CAMPUS = os.path.join(ROOT, "shot_layer10_campus.png")
OUT_CLOSE = os.path.join(ROOT, "shot_layer10_close.png")
OUT_SCENE = os.path.join(ROOT, "shot_layer10_scene.png")

CAMPUS_BOX = (2500, 3200, 3100, 3620)     # 自动化学院（b0）楼底那一段，下方留草地
CLOSE_BOX = (2700, 3430, 2920, 3540)      # 5x 特写：只看楼底那条接触线
ALPHA_MIN = 32                            # 认定「不透明」的 alpha 阈值

# ---- 墙脚绿化（整体仍是严格草）----
APRON_H = 12                   # 绿化带高度（px），从墙脚接触线向下
APRON_DEEP = (68, 112, 54)     # 贴墙一侧：g-r=44 / g-b=58 / g=112
APRON_MID = (88, 136, 70)      # 主体：g-r=48 / g-b=66 / g=136
APRON_TOP = (106, 156, 84)     # 远离墙一侧：g-r=50 / g-b=72 / g=156
NOISE_STEP = 4
NOISE_CUT = (85, 175)


def load_world():
    with open(WORLD_JSON, encoding="utf-8") as f:
        return json.load(f)


@lru_cache(maxsize=1)
def _contact_points(_stamp):
    """每个建筑 sprite 的墙脚接触点（世界像素坐标）。

    逐列 `crop + getbbox` 找最底部不透明行 —— 比在 Python 里逐像素扫
    alpha 快两个数量级（扫描在 C 层）。58 栋楼约 2.6 万列，1~2 秒。
    """
    with open(WORLD_JSON, encoding="utf-8") as f:
        world = json.load(f)
    pts = []
    for i, b in enumerate(world["buildings"]):
        p = os.path.join(BUILDING_DIR, "b%d.png" % i)
        if not os.path.exists(p):
            continue
        im = Image.open(p).convert("RGBA")
        alpha = im.split()[3].point([255 if v > ALPHA_MIN else 0 for v in range(256)])
        ox = int(round(float(b.get("x", 0.0)) * CELL))
        oy = int(round(float(b.get("y", 0.0)) * CELL))
        w, h = alpha.size
        for lx in range(w):
            bb = alpha.crop((lx, 0, lx + 1, h)).getbbox()
            if bb is None:
                continue
            pts.append((ox + lx, oy + bb[3] - 1))
    return tuple(pts)


@lru_cache(maxsize=1)
def _noise_map():
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
    """全图算一次，之后按 (ox,oy,W,H) 裁剪（同第 8/9 层）。"""
    full = D.load_ground((0, 0, WORLD_W, WORLD_H))
    size = (WORLD_W, WORLD_H)

    # 落笔条件必须是**严格草**，不能用宽松草：楼前压着建筑投影的那几 px 只满足
    # 宽松草，一旦在上面画严格草色，它们就从「宽松草」升级成「严格草」，
    # 某些格子的严格草比例跨过阈值 -> 道具候选网格会漂 7 格（实测）。
    road = D.road_mask(full)
    water = D.water_mask(full)
    grass = R._strict_grass(full)
    hard = ImageChops.lighter(road, R._beige_mask(full))
    margin = L8._world_margin(size, 0, 0)

    # 墙脚接触线：先点成掩码，再逐行向下平移 1..APRON_H 取并集 = 向下的带。
    contact = Image.new("L", size, 0)
    cd = ImageDraw.Draw(contact)
    for gx, gy in _contact_points(id(full)):
        if 0 <= gx < WORLD_W and 0 <= gy < WORLD_H:
            cd.point((gx, gy), fill=255)

    band = Image.new("L", size, 0)
    for k in range(1, APRON_H + 1):
        band = ImageChops.lighter(band, ImageChops.offset(contact, 0, k))

    # 外侧起伏：噪声分三档削 0/1/2px
    lo, hi = NOISE_CUT
    allow_lut = [(APRON_H + 1) if v >= hi else
                 (APRON_H if v >= lo else (APRON_H - 1)) for v in range(256)]
    # 该像素在带内的「深度」= 距接触线几 px，用向下平移的差分求
    depth = Image.new("L", size, 0)
    for k in range(1, APRON_H + 1):
        ring = ImageChops.subtract(
            ImageChops.offset(contact, 0, k),
            ImageChops.offset(contact, 0, k - 1) if k > 1 else contact)
        depth = Image.composite(Image.new("L", size, k), depth, ring)

    inside = ImageChops.subtract(_noise_map().point(allow_lut), depth).point(
        [255 if v > 0 else 0 for v in range(256)])
    inside = ImageChops.multiply(inside, band)
    inside = ImageChops.multiply(inside, grass)
    inside = ImageChops.subtract(inside, hard)
    inside = ImageChops.multiply(inside, margin)

    layers = []
    for k in range(1, APRON_H + 1):
        lk = [255 if v == k else 0 for v in range(256)]
        m = ImageChops.multiply(depth.point(lk), inside)
        if k == 1:
            color = APRON_DEEP
        elif k <= 3:
            color = APRON_MID
        else:
            color = APRON_TOP
        layers.append((m, color))
    return tuple(layers)


def apply(im, ox=0, oy=0, world=None):
    W, H = im.size
    out = im
    stats = {"apron_px": 0, "size": (W, H), "ox": ox, "oy": oy}
    for mask, color in _global_masks(id(world)):
        local = L9._crop(mask, ox, oy, W, H)
        n = D._nz(local)
        if not n:
            continue
        out = Image.composite(Image.new("RGB", (W, H), color), out, local)
        stats["apron_px"] += n
    return out, stats


def check(stats):
    need = lambda ok, msg: None if ok else (_ for _ in ()).throw(AssertionError(msg))
    need(stats["apron_px"] > 0, "小样区域没有落上墙脚绿化")
    return True


def _chain9(world):
    return L9.apply(L8.apply(L8._chain7(world), 0, 0, world)[0], 0, 0, world)[0]


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
    d.text((14, 38), "LEFT: BEFORE (layer 9)    RIGHT: AFTER (layer 10)",
           font=_font(16), fill=(150, 160, 172))
    canvas.paste(a, (0, top))
    canvas.paste(b, (W + gap, top))
    d.rectangle([0, top, W - 1, top + H - 1], outline=(70, 76, 84), width=1)
    d.rectangle([W + gap, top, W * 2 + gap - 1, top + H - 1],
                outline=(70, 76, 84), width=1)
    d.text((12, top + H + 10), note, font=_font(16), fill=(160, 170, 180))
    canvas.save(path)
    print("[layer10] 对比图 -> %s (%dx%d, %d B)" %
          (os.path.basename(path), canvas.width, canvas.height, os.path.getsize(path)))


def _local_scene(ground_crop, world, box):
    x0, y0, x1, y1 = box
    g = ground_crop.convert("RGBA")
    g.putalpha(255)
    bl = []
    for i, b in enumerate(world["buildings"]):
        x = float(b.get("x", 0.0)) * CELL
        y = float(b.get("y", 0.0)) * CELL
        p = os.path.join(BUILDING_DIR, "b%d.png" % i)
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
        g.alpha_composite(bim.crop((sx0, sy0, sx1, sy1)), (max(0, dx), max(0, dy)))
    return g.convert("RGB")


# ---------------------------------------------------------------- 验收
def _validate(world, expect_layer10):
    import preview_full_apply as V
    import tempfile

    tag = "verify" if expect_layer10 else "dry"
    base9 = _chain9(world)
    cur = D.load_ground((0, 0, WORLD_W, WORLD_H))
    d9 = D._nz(D._pix_changed(base9, cur))
    print("[%s] 第 9 层链重算 vs 当前地面: %d px 差异" % (tag, d9))
    if not expect_layer10 and d9:
        raise SystemExit("[dry] 当前地面不是第 9 层链产物，基准漂移")

    candidate, st = apply(base9, 0, 0, world)
    check(st)
    ref = candidate if expect_layer10 else base9
    dchain = D._nz(D._pix_changed(ref, cur))
    print("[%s] %s vs 当前地面: %d px 差异（应为 0）" %
          (tag, "第 10 层链重算" if expect_layer10 else "第 9 层链重算", dchain))
    if dchain:
        raise SystemExit("[%s] 当前地面与幂等链不一致" % tag)

    again, _ = apply(base9, 0, 0, world)
    ok = candidate.tobytes() == again.tobytes()
    print("[%s] 二次 apply 一致: %s" % (tag, ok))
    if not ok:
        raise SystemExit("[%s] apply 不是确定性的" % tag)
    twice, _ = apply(candidate, 0, 0, world)
    idem = D._nz(D._pix_changed(candidate, twice))
    print("[%s] apply² 幂等差异: %d px" % (tag, idem))
    if idem:
        raise SystemExit("[%s] apply² 不是幂等的" % tag)

    nd = D._nz(D._pix_changed(base9, candidate))
    print("[%s] 第 10 层新增差异 %d px（墙脚绿化）" % (tag, nd))

    for name, fn in (("road", D.road_mask), ("water", D.water_mask)):
        d = D._nz(D._diff_mask(fn(base9), fn(candidate)))
        print("[%s] %s 掩码 diff: %d px" % (tag, name, d))
        if d:
            raise SystemExit("[%s] %s 掩码变了" % (tag, name))
    gm = D.grass_mask(base9, D.road_mask(base9), D.water_mask(base9))
    gc = D.grass_mask(candidate, D.road_mask(candidate), D.water_mask(candidate))
    d = D._nz(D._diff_mask(gm, gc))
    print("[%s] grass 掩码 diff: %d px" % (tag, d))
    if d:
        raise SystemExit("[%s] grass 掩码变了" % tag)

    with tempfile.TemporaryDirectory(prefix="xgd_layer10_" + tag + "_") as td:
        rb, gb = V.prop_grids(base9, td, "before")
        ra, ga = V.prop_grids(candidate, td, "after")
        dr = sum(1 for a, b in zip(rb, ra) if a != b)
        dg = sum(1 for a, b in zip(gb, ga) if a != b)
    print("[%s] road 道具网格 diff: %d 格" % (tag, dr))
    print("[%s] grass 道具网格 diff: %d 格" % (tag, dg))
    if dr or dg:
        raise SystemExit("[%s] 道具候选网格变了" % tag)

    print("[%s] ALL PASS" % tag)
    return candidate


def _apply_full(world):
    base9 = _chain9(world)
    out, st = apply(base9, 0, 0, world)
    check(st)
    E.save(out)
    print("[layer10] 已全图写回 assets/ground/：墙脚绿化 %d px" % st["apron_px"])
    print("[layer10] 记得升 Arena.gd 的 MINIMAP_CACHE 并跑 godot --headless --path . --import")


def main():
    args = sys.argv[1:]
    world = load_world()

    if "--apply" in args:
        if "--force" not in args:
            raise SystemExit("[layer10] 全图铺开会覆盖 28 张地面贴图，请显式加 --force")
        _apply_full(world)
        return
    if "--dry" in args or "--verify" in args:
        _validate(world, "--verify" in args)
        return

    for box, path, scale, title, note in (
        (CAMPUS_BOX, OUT_CAMPUS, 1, "Campus core - layer 10 (SAMPLE ONLY)",
         "A hedge strip now follows each building's actual footing line."),
        (CLOSE_BOX, OUT_CLOSE, 5, "Building footing - closeup (5x)",
         "Check the strip follows the slanted base, no floating, no eating the wall."),
    ):
        before = D.load_ground(box)
        after, st = apply(before, box[0], box[1], world)
        check(st)
        _compare(before, after, path, scale, title, note)
        print("      apron %d px" % st["apron_px"])

    before = D.load_ground(CAMPUS_BOX)
    after, _ = apply(before, CAMPUS_BOX[0], CAMPUS_BOX[1], world)
    _compare(_local_scene(before, world, CAMPUS_BOX),
             _local_scene(after, world, CAMPUS_BOX),
             OUT_SCENE, 1, "Campus core with building sprites",
             "The strip must read as planting at the wall, not a stray green line.")


if __name__ == "__main__":
    main()
