#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""全图铺开后的验收脚本（只读，不写回任何 assets）。

在 `bake_ground_detail.py --apply --force` / `bake_facade.py --apply --force`
之后运行，逐项确认：
  1. 备份清单里只有 28 张 ground + 58 张 buildings 变化，58 张 glow 不变；
  2. 从真源幂等重算的结果与当前 86 张 PNG 逐字节一致；
  3. 当前地面与铺开前的 road / grass / water 掩码逐像素一致；
  4. place_life_props 的道路 / 草地候选网格不变（401 个道具）；
  5. 建筑真源与当前贴图的玻璃分类 / alpha / 不透明包围盒一致；
  6. 用真实 bake_art 重烘 58 张窗光，与当前 glow 逐字节一致。

用法：
    python tools/verify_full_apply.py
    python tools/verify_full_apply.py --quick     # 跳过道具网格与窗光全量复验
"""
import glob
import hashlib
import json
import os
import shutil
import sys
import tempfile

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

BACKUP = r"D:/像素工大/backup/before-full-apply-20261111"
WORLD_JSON = os.path.join(ROOT, "assets", "world.json")
CHUNK = 1024
COLS, ROWS = 4, 7
WORLD_W, WORLD_H = 3392, 6400


def sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def mosaic_from(ground_dir):
    canvas = Image.new("RGB", (COLS * CHUNK, ROWS * CHUNK), (0, 0, 0))
    for cy in range(ROWS):
        for cx in range(COLS):
            p = os.path.join(ground_dir, "g%d_%d.png" % (cx, cy))
            canvas.paste(Image.open(p).convert("RGB"), (cx * CHUNK, cy * CHUNK))
    return canvas.crop((0, 0, WORLD_W, WORLD_H))


def main():
    quick = "--quick" in sys.argv[1:]
    with open(WORLD_JSON, encoding="utf-8") as f:
        world = json.load(f)
    blds = world["buildings"]
    fails = []

    if not os.path.isdir(BACKUP):
        raise SystemExit("[verify] 找不到铺开前备份：%s" % BACKUP)
    with open(os.path.join(BACKUP, "manifest.json"), encoding="utf-8") as f:
        manifest = json.load(f)

    # 1) 变化清单
    changed = {"ground": 0, "buildings": 0, "glow": 0}
    unchanged = {"ground": 0, "buildings": 0, "glow": 0}
    live_dir = {"ground": os.path.join("assets", "ground"),
                "buildings": os.path.join("assets", "buildings"),
                "glow": "assets"}
    for key, h in manifest.items():
        sub, name = key.split("/")
        live = os.path.join(ROOT, live_dir[sub], name)
        if not os.path.exists(live):
            fails.append("资源缺失：%s" % key)
            continue
        if sha(live) == h:
            unchanged[sub] += 1
        else:
            changed[sub] += 1
    print("[verify] manifest: ground %d/%d changed, buildings %d/%d changed, "
          "glow %d/%d changed" %
          (changed["ground"], changed["ground"] + unchanged["ground"],
           changed["buildings"], changed["buildings"] + unchanged["buildings"],
           changed["glow"], changed["glow"] + unchanged["glow"]))
    if changed["ground"] != 28 or changed["buildings"] != 58 or changed["glow"] != 0:
        fails.append("写回范围异常：期望 ground 28 / buildings 58 / glow 0 变化")

    import bake_ground_detail as D
    import bake_facade as F
    import preview_full_apply as P

    cur_ground_dir = os.path.join(ROOT, "assets", "ground")
    live = mosaic_from(cur_ground_dir)
    old = mosaic_from(os.path.join(BACKUP, "ground"))

    # 2) 幂等：从真源重算，切块后与当前 28 张逐字节比对
    import bake_road_edge as E
    import bake_roads as B
    src = E.load_mosaic()
    base, _ = B.build(src)
    again, st = D.apply(base, 0, 0, world)
    D.check(st)
    td = tempfile.mkdtemp(prefix="xgd_verify_")
    try:
        tmpg = os.path.join(td, "ground")
        os.makedirs(tmpg, exist_ok=True)
        # 直接复用真实写回函数（按源图各自尺寸切块），只把输出目录改到临时目录
        old_out = E.OUT
        E.OUT = tmpg
        try:
            E.save(again)
        finally:
            E.OUT = old_out
        dground = sum(1 for cy in range(ROWS) for cx in range(COLS)
                      if sha(os.path.join(tmpg, "g%d_%d.png" % (cx, cy))) !=
                      sha(os.path.join(cur_ground_dir, "g%d_%d.png" % (cx, cy))))
        print("[verify] ground re-bake vs live: %d/28 tiles differ" % dground)
        if dground:
            fails.append("地面幂等重算与写回结果不一致：%d 块" % dground)

        # 3) 掩码：铺开前后分类逐像素一致
        for label, a, b in (("road", D.road_mask(old), D.road_mask(live)),
                            ("water", D.water_mask(old), D.water_mask(live)),
                            ("grass", D.grass_mask(old, D.road_mask(old),
                                                   D.water_mask(old)),
                             D.grass_mask(live, D.road_mask(live),
                                          D.water_mask(live)))):
            n = P.diff_pixels(a, b)
            print("[verify] %s mask diff: %d px" % (label, n))
            if n:
                fails.append("%s 掩码变化 %d px" % (label, n))

        if not quick:
            rb, gb = P.prop_grids(old, td, "old")
            ra, ga = P.prop_grids(live, td, "live")
            dr, dg = P.grid_diff(rb, ra), P.grid_diff(gb, ga)
            print("[verify] place_life_props grids: road %d / grass %d changed cells"
                  % (dr, dg))
            if dr or dg:
                fails.append("道具候选网格变化：road %d / grass %d" % (dr, dg))

        # 4) 建筑：真源 -> 当前，逐张结构 + 幂等
        srcdir = os.path.join(ROOT, "assets", "_buildings_src")
        ndiff = nstruct = 0
        for i, b in enumerate(blds):
            s = os.path.join(srcdir, "b%d.png" % i)
            if not os.path.exists(s):
                fails.append("建筑真源缺失 b%d" % i)
                continue
            before = Image.open(s).convert("RGBA")
            after, fs = F.apply(before, i, b)
            fs["idx"] = i
            try:
                F.check(fs)
            except SystemExit as e:
                fails.append("b%d %s" % (i, e))
                continue
            cur = Image.open(os.path.join(ROOT, "assets", "buildings",
                                         "b%d.png" % i)).convert("RGBA")
            if after.tobytes() != cur.tobytes():
                ndiff += 1
            # 结构：玻璃分类 / alpha / 不透明包围盒（用 bytearray 比较，避免
            # 26M 次 Python 逐像素循环）
            m0, m1 = F._masks(before), F._masks(cur)
            if (m0[2][3::4] != m1[2][3::4] or m0[3] != m1[3]
                    or m0[5] != m1[5] or m0[6] != m1[6]):
                nstruct += 1
        print("[verify] facades: %d/58 differ from idempotent re-bake, "
              "%d/58 glass/alpha structure changed" % (ndiff, nstruct))
        if ndiff or nstruct:
            fails.append("立面幂等/结构复验失败：%d + %d 张" % (ndiff, nstruct))

        # 5) 窗光：真实 bake_art 重烘，与当前 glow 逐字节比对
        if not quick:
            g = P.bake_glows(world, td, lambda i: Image.open(
                os.path.join(ROOT, "assets", "buildings",
                             "b%d.png" % i)).convert("RGBA"))
            bad = [i for i in range(len(blds))
                   if g[i] != open(os.path.join(ROOT, "assets",
                                               "glow_winb_%d.png" % i), "rb").read()]
            print("[verify] night glow: %d/58 byte-identical" %
                  (len(blds) - len(bad)))
            if bad:
                fails.append("窗光贴图与重烘结果不一致：%s" % bad[:10])
    finally:
        shutil.rmtree(td, ignore_errors=True)

    if fails:
        print("[verify] FAILED (%d):" % len(fails))
        for f in fails:
            print("   -", f)
        sys.exit(1)
    print("[verify] ALL PASS - 铺开后地面/立面/窗光/道具/掩码全部符合预期。")


if __name__ == "__main__":
    main()
