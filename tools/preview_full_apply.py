#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""大地图静态质感「全图铺开」零写回预演。

第 2 步（地面）和第 3 步（建筑立面）此前只出过图书馆周边小样。本脚本把
两条链真的在全图规模上跑一遍，用来回答「铺开会不会踩到没预料到的楼 / 块」，
但**绝不写回任何 assets**：所有候选图都在内存或临时目录里，唯一落盘的是
根目录两张 shot_full_apply_*.png 对比图。

覆盖校验：
  * 地面：_ground_src -> bake_roads.build() -> detail.apply() 全图重算，
    与当前 28 张 ground 逐像素比对底图；road / grass / water 掩码不变；
    place_life_props 的 road_grid / grass_grid 不变（401 个道具候选点）；
    全图结果裁图书馆区域 == 之前的小样结果。
  * 建筑：58 张逐张 apply() + 玻璃/alpha/bbox 自检；把 before / after
    分别喂给真实 bake_art.bake_window_overlays()，58 张夜间窗光逐字节复验。
  * 资源：174 个源文件前后 sha256 总哈希不变。

用法：
    python tools/preview_full_apply.py            # 默认全量预演（不写回）
    python tools/preview_full_apply.py --quick    # 跳过道具网格与窗光全量复验
"""
import glob
import hashlib
import json
import os
import shutil
import sys
import tempfile

from PIL import Image, ImageChops, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

WORLD_JSON = os.path.join(ROOT, "assets", "world.json")
WORLD_W, WORLD_H = 3392, 6400
CHUNK = 1024
COLS, ROWS = 4, 7
CELL = 8
LIB_BOX = (1560, 2360, 2380, 3180)
CANVAS = (24, 26, 30)

OUT_OVERVIEW = os.path.join(ROOT, "shot_full_apply_overview.png")
OUT_SCENE = os.path.join(ROOT, "shot_full_apply_scene.png")

ASSET_PATS = [
    "assets/world.json",
    "assets/osm_tags.json",
    "assets/ground/g*_*.png",
    "assets/_ground_src/g*_*.png",
    "assets/buildings/b*.png",
    "assets/glow_winb_*.png",
]


# ---------------------------------------------------------------- 通用工具
def snap():
    files = []
    for pat in ASSET_PATS:
        files += sorted(glob.glob(os.path.join(ROOT, pat)))
    h = hashlib.sha256()
    for p in files:
        h.update(os.path.relpath(p, ROOT).encode("utf-8"))
        with open(p, "rb") as f:
            h.update(f.read())
    return len(files), h.hexdigest()


def _font(size):
    try:
        return ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", size)
    except Exception:
        return ImageFont.load_default(size=size)


def _label(d, xy, text, size, fill, anchor=None):
    d.text(xy, text, font=_font(size), fill=fill, anchor=anchor)


def _max_channel_diff(a, b):
    d = ImageChops.difference(a.convert("RGB"), b.convert("RGB"))
    return ImageChops.lighter(ImageChops.lighter(d.getchannel("R"),
                                                 d.getchannel("G")),
                              d.getchannel("B"))


def diff_pixels(a, b):
    """两张同尺寸 RGB 图里，任一通道有差异的像素数。"""
    return _max_channel_diff(a, b).point(lambda v: 255 if v else 0).histogram()[255]


def strong_diff_pixels(a, b, threshold=2):
    """内容级差异：任一通道差超过 threshold 级。

    PIL 在局部图里用负坐标/边界裁剪画斜线时，Bresenham 取整会与全图
    相差 1px；滤波器边缘 clamp 也会留下 1~2 级明度差。这些都不是
    「小样所见与铺开所得不一致」，真正的分叉（修复前 7944 px / delta
    最大 78）幅度都在 24 级以上，必须被抓到。
    """
    h = _max_channel_diff(a, b).histogram()
    return sum(h[threshold + 1:]), max((i for i, v in enumerate(h) if v), default=0)


def current_mosaic():
    canvas = Image.new("RGB", (COLS * CHUNK, ROWS * CHUNK), (0, 0, 0))
    for cy in range(ROWS):
        for cx in range(COLS):
            p = os.path.join(ROOT, "assets", "ground", "g%d_%d.png" % (cx, cy))
            canvas.paste(Image.open(p).convert("RGB"), (cx * CHUNK, cy * CHUNK))
    return canvas.crop((0, 0, WORLD_W, WORLD_H))


def chunks_from_mosaic(mosaic, ground_dir):
    """与 bake_road_edge.save() 相同：按 _ground_src 里每张源图**各自的尺寸**
    切块（最后一列 320 宽、最后一行 256 高），统一切 1024² 会让引擎摆歪。"""
    os.makedirs(ground_dir, exist_ok=True)
    full = Image.new("RGB", (COLS * CHUNK, ROWS * CHUNK), (0, 0, 0))
    full.paste(mosaic.convert("RGB"), (0, 0))
    srcdir = os.path.join(ROOT, "assets", "_ground_src")
    for cy in range(ROWS):
        for cx in range(COLS):
            name = "g%d_%d.png" % (cx, cy)
            sw, sh = Image.open(os.path.join(srcdir, name)).size
            x0, y0 = cx * CHUNK, cy * CHUNK
            full.crop((x0, y0, x0 + sw, y0 + sh)).save(
                os.path.join(ground_dir, name))


def grid_diff(a, b):
    return sum(1 for ra, rb in zip(a, b) for va, vb in zip(ra, rb) if va != vb)


# ---------------------------------------------------------------- 校验链
def prop_grids(mosaic, td, tag):
    """把候选地面写到隔离目录，让真实的 place_life_props 去认路/认草。"""
    import place_life_props as P
    odir = os.path.join(td, "props_" + tag)
    gdir = os.path.join(odir, "assets", "ground")
    chunks_from_mosaic(mosaic, gdir)
    old = P.ROOT
    P.ROOT = odir
    try:
        road = P.road_mask()
        grass = P.grass_mask()
    finally:
        P.ROOT = old
    return road, grass


def bake_glows(world, td, img_of):
    """在临时目录里跑一次真实窗光烘焙，返回 58 张 glow 的字节。"""
    import bake_art
    adir = os.path.join(td, "assets")
    bdir = os.path.join(adir, "buildings")
    os.makedirs(bdir, exist_ok=True)
    for p in glob.glob(os.path.join(adir, "glow_winb_*.png")):
        os.remove(p)
    for i in range(len(world["buildings"])):
        img_of(i).convert("RGBA").save(os.path.join(bdir, "b%d.png" % i))
    with open(os.path.join(adir, "world.json"), "w", encoding="utf-8") as f:
        json.dump(world, f, ensure_ascii=False)
    old = bake_art.ROOT
    bake_art.ROOT = td
    try:
        bake_art.bake_window_overlays()
    finally:
        bake_art.ROOT = old
    out = []
    for i in range(len(world["buildings"])):
        p = os.path.join(adir, "glow_winb_%d.png" % i)
        with open(p, "rb") as f:
            out.append(f.read())
    return out


# ---------------------------------------------------------------- 对比图
def overview(before, after, stats, path, base_diff, ground_changed):
    W, H = 424, 800
    ims = [im.resize((W, H), Image.LANCZOS) for im in (before, after)]
    top, gap, side, foot = 88, 18, 16, 96
    cw, ch = W * 2 + gap + side * 2, H + top + foot
    canvas = Image.new("RGB", (cw, ch), CANVAS)
    d = ImageDraw.Draw(canvas)
    _label(d, (side, 10), "Full-map dry run - ground + facade detail", 24,
           (238, 240, 244))
    _label(d, (side, 42), "LEFT: CURRENT    RIGHT: CANDIDATE    (1/8 scale, "
           "no asset written)", 15, (150, 160, 172))
    _label(d, (side, 68), "Buildings shown as footprints only at this zoom; "
           "see scene comparison for the real composite.", 14, (126, 136, 148))
    for c, im in enumerate(ims):
        x = side + c * (W + gap)
        canvas.paste(im, (x, top))
        d.rectangle([x, top, x + W - 1, top + H - 1],
                    outline=(70, 76, 84), width=1)
    lines = [
        "Ground: %d shadow px / %d detail marks / %d changed px / %d restored px" %
        (stats["shadow_px"], stats["detail_marks"], ground_changed,
         stats["restored_px"]),
        "Masks: road %d / grass %d / water %d diff px (all must be 0)" %
        (stats["road_diff"], stats["grass_diff"], stats["water_diff"]),
        "Base re-bake vs current ground: %d changed px (0 = idempotent chain)" %
        base_diff,
        "DRY RUN ONLY - all 28 ground + 58 building + 58 glow PNGs untouched.",
    ]
    for i, t in enumerate(lines):
        _label(d, (side, top + H + 12 + i * 19), t, 14, (176, 186, 198))
    canvas.save(path)
    print("[dry] overview -> %s (%d x %d, %d B)" %
          (os.path.basename(path), cw, ch, os.path.getsize(path)))


def night_sprite(im, idx):
    """近似 building_xray.gdshader，但保留 alpha 以便正确贴回地面。"""
    dark = Image.blend(im.convert("RGB"),
                       Image.new("RGB", im.size, (8, 12, 30)), 0.72)
    p = os.path.join(ROOT, "assets", "glow_winb_%d.png" % idx)
    if os.path.exists(p):
        gl = Image.open(p).convert("RGBA")
        if gl.size == im.size:
            scaled = ImageChops.multiply(
                gl.convert("RGB"),
                Image.merge("RGB", (gl.getchannel("A"),) * 3))
            dark = ImageChops.add(dark, scaled)
    out = dark.convert("RGBA")
    out.putalpha(im.getchannel("A"))
    return out


def scene(mosaic, after_map, world, box, use_after, night):
    """把地面裁切与建筑 sprite 按游戏里的 (x*CELL, y*CELL) + y-sort 合成。"""
    x0, y0, x1, y1 = box
    g = mosaic.crop(box).convert("RGBA")
    g.putalpha(255)
    if night:
        g = Image.blend(g.convert("RGB"),
                        Image.new("RGB", g.size, (8, 12, 30)), 0.72).convert("RGBA")
        g.putalpha(255)
    bl = []
    for i, b in enumerate(world["buildings"]):
        x = float(b.get("x", 0.0)) * CELL
        y = float(b.get("y", 0.0)) * CELL
        if use_after and i in after_map:
            im = after_map[i]
        else:
            p = os.path.join(ROOT, "assets", "buildings", "b%d.png" % i)
            if not os.path.exists(p):
                continue
            im = Image.open(p).convert("RGBA")
        if x >= x1 or x + im.width <= x0 or y >= y1 or y + im.height <= y0:
            continue
        bl.append((float(b.get("baseY", y / CELL)), i, x, y, im))
    bl.sort(key=lambda t: t[0])
    for _, i, x, y, im in bl:
        if night:
            im = night_sprite(im, i)
        dx, dy = int(x - x0), int(y - y0)
        sx0, sy0 = max(0, -dx), max(0, -dy)
        sx1, sy1 = min(im.width, g.width - dx), min(im.height, g.height - dy)
        if sx1 <= sx0 or sy1 <= sy0:
            continue
        g.alpha_composite(im.crop((sx0, sy0, sx1, sy1)),
                          (max(0, dx), max(0, dy)))
    return g.convert("RGB")


def scene_compare(before, after, after_map, world, path):
    W, H = LIB_BOX[2] - LIB_BOX[0], LIB_BOX[3] - LIB_BOX[1]
    imgs = [
        scene(before, after_map, world, LIB_BOX, False, False),
        scene(after, after_map, world, LIB_BOX, True, False),
        scene(before, after_map, world, LIB_BOX, False, True),
        scene(after, after_map, world, LIB_BOX, True, True),
    ]
    top, gap, side, foot, rowh = 96, 16, 112, 64, H + 30
    cw, ch = W * 2 + gap + side * 2, top + 2 * rowh + gap + foot
    canvas = Image.new("RGB", (cw, ch), CANVAS)
    d = ImageDraw.Draw(canvas)
    _label(d, (side, 10), "In-game view - library area (ground + building sprites)",
           23, (238, 240, 244))
    _label(d, (side, 42), "LEFT: CURRENT    RIGHT: CANDIDATE    "
           "TOP: DAY    BOTTOM: NIGHT", 16, (150, 160, 172))
    _label(d, (side, 70), "1:1 pixels, nearest-neighbour. Trees / decor / "
           "characters omitted; both columns use the same camera box.", 14,
           (126, 136, 148))
    for r, tag in enumerate(("DAY", "NIGHT")):
        y = top + r * (rowh + gap)
        _label(d, (12, y + H // 2), tag, 18, (188, 196, 206), anchor="lm")
        for c in range(2):
            x = side + c * (W + gap)
            canvas.paste(imgs[r * 2 + c], (x, y))
            d.rectangle([x, y, x + W - 1, y + H - 1],
                        outline=(70, 76, 84), width=1)
    _label(d, (side, ch - foot + 10),
           "Shadows / grass / road wear on the ground + wall grain / windows / "
           "AC units / nameplates on the buildings. Dry run only.", 14,
           (176, 186, 198))
    canvas.save(path)
    print("[dry] scene -> %s (%d x %d, %d B)" %
          (os.path.basename(path), cw, ch, os.path.getsize(path)))


# ---------------------------------------------------------------- 主流程
def main():
    quick = "--quick" in sys.argv[1:]
    with open(WORLD_JSON, encoding="utf-8") as f:
        world = json.load(f)
    blds = world["buildings"]
    fails = []
    s0 = snap()
    print("[dry] baseline: %d asset files, sha256 %s" % (s0[0], s0[1][:24]))

    # ---- 地面：完整重算链 ----
    import bake_road_edge as E
    import bake_roads as B
    import bake_ground_detail as D
    E.ensure_src()
    src = E.load_mosaic()
    base, _ = B.build(src)
    cur = current_mosaic()
    base_diff = diff_pixels(base, cur)
    print("[dry] ground chain: re-baked base vs current ground = %d changed px"
          % base_diff)

    after, stats = D.apply(base, 0, 0, world)
    try:
        D.check(stats)
    except SystemExit as e:
        fails.append("ground: %s" % e)
    ground_changed = diff_pixels(cur, after)
    print("[dry] ground: %d changed px / %d shadow px / %d detail marks / "
          "road %d grass %d water %d diff" %
          (ground_changed, stats["shadow_px"], stats["detail_marks"],
           stats["road_diff"], stats["grass_diff"], stats["water_diff"]))

    # 全图裁图书馆区域 == 之前的小样结果（证明「所见即铺开所得」）。
    # 内缩 12px 排除 _shadow_layer 的 MaxFilter(7) + GaussianBlur(1.8)
    # 边缘 clamp；剩下 1~2 级的取整差也不算内容差异。
    x0, y0, x1, y1 = LIB_BOX
    sample_in = D.load_ground(LIB_BOX)
    sample, _ = D.apply(sample_in, x0, y0, world)
    fc = after.crop(LIB_BOX)
    sd_all = diff_pixels(sample, fc)
    ins = 12
    inner = (ins, ins, x1 - x0 - ins, y1 - y0 - ins)
    sd, sd_max = strong_diff_pixels(sample.crop(inner), fc.crop(inner))
    print("[dry] sample-vs-full crop: %d changed px overall / %d content px "
          ">2 levels inside 12px inset (max %d)" % (sd_all, sd, sd_max))
    if sd:
        fails.append("全图裁图书馆区与既有小样不一致：内缩后仍有 "
                     "%d 个内容级差异像素" % sd)

    if not quick:
        td = tempfile.mkdtemp(prefix="xgd_dry_props_")
        try:
            rb, gb = prop_grids(cur, td, "before")
            ra, ga = prop_grids(after, td, "after")
            dr, dg = grid_diff(rb, ra), grid_diff(gb, ga)
            print("[dry] place_life_props grids: road %d / grass %d "
                  "changed cells" % (dr, dg))
            if dr or dg:
                fails.append("道具候选网格变化：road %d / grass %d" % (dr, dg))
        finally:
            shutil.rmtree(td, ignore_errors=True)

    # ---- 建筑：58 张逐张预演 ----
    import bake_facade as F
    after_map = {}
    totals = {"ac": 0, "vent": 0, "pipe": 0, "plate": 0, "cells": 0}
    no_plate = []
    changed_px = 0
    for i, b in enumerate(blds):
        p = os.path.join(ROOT, "assets", "buildings", "b%d.png" % i)
        before = Image.open(p).convert("RGBA")
        try:
            a, st = F.apply(before, i, b)
            st["idx"] = i
            F.check(st)
        except SystemExit as e:
            fails.append("b%d %s: %s" % (i, b.get("name", ""), e))
            continue
        except Exception as e:
            fails.append("b%d %s: 异常 %r" % (i, b.get("name", ""), e))
            continue
        after_map[i] = a
        changed_px += diff_pixels(before, a)
        for k in totals:
            totals[k] += st.get(k, 0)
        if not st.get("plate", 0):
            no_plate.append("b%d %s" % (i, b.get("name", "")))
    print("[dry] facades: %d/%d built, %d changed px | AC %d / vent %d / "
          "pipe %d / plate %d / window cells %d" %
          (len(after_map), len(blds), changed_px, totals["ac"],
           totals["vent"], totals["pipe"], totals["plate"], totals["cells"]))
    print("[dry] no nameplate (%d): %s" %
          (len(no_plate), ", ".join(no_plate[:18]) + (" ..." if len(no_plate) > 18 else "")))

    if not quick and len(after_map) == len(blds):
        td2 = tempfile.mkdtemp(prefix="xgd_dry_glow_")
        try:
            def orig(i):
                return Image.open(os.path.join(ROOT, "assets", "buildings",
                                              "b%d.png" % i)).convert("RGBA")
            g0 = bake_glows(world, td2, orig)
            g1 = bake_glows(world, td2, lambda i: after_map[i])
            bad = [i for i in range(len(blds)) if g0[i] != g1[i]]
            print("[dry] night glow: %d/%d byte-identical (total %d B)"
                  % (len(blds) - len(bad), len(blds), sum(len(x) for x in g1)))
            if bad:
                fails.append("窗光贴图变化：%s" % bad[:10])
        finally:
            shutil.rmtree(td2, ignore_errors=True)

    # ---- 出图 + 资源零写回复验 ----
    overview(cur, after, stats, OUT_OVERVIEW, base_diff, ground_changed)
    scene_compare(cur, after, after_map, world, OUT_SCENE)
    s1 = snap()
    ok = (s0 == s1)
    print("[dry] assets after: %d files, sha256 %s | unchanged = %s"
          % (s1[0], s1[1][:24], ok))
    if not ok:
        fails.append("资源文件哈希变化（预演写回了 assets！）")

    if fails:
        print("[dry] FAILED (%d):" % len(fails))
        for f in fails:
            print("   -", f)
        sys.exit(1)
    print("[dry] ALL PASS - 全图重算无掩码/窗光/道具/资源回归；"
          "本脚本从不写回 assets（--apply 入口另需显式 --force）。")


if __name__ == "__main__":
    main()
