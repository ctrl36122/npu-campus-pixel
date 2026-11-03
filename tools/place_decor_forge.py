#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""往校园里再撒一批「装饰」：长椅 / 花坛 / 自行车 / 自动售货机 / 储物柜 / 路牌 / 旗杆，
以及从 PixelSRPG 资源库（MIT）里挑出来的、像校园后勤杂物（木箱 / 油桶 / 梯子 / 设备箱）。

原则（沿用 place_life_props）：
  - 只在 world.json 里追加 props，不改任何几何；幂等（重跑先撤掉上次装饰_ 前缀的）。
  - 占用图 = 楼 / 水 / 桥 / 树 / 已有摆件 / 运动场；装饰只落在「草地 + 不压路不压楼」的空地。
  - 临路类（花坛/路牌/长椅）贴路边；楼前类（自行车/售货机/储物柜）挨建筑；
    后勤类（木箱/油桶/梯子/设备箱）只放四周边角空地，别挤进教学楼区。

用法：python tools/place_decor_forge.py [--dry]
"""
import json
import math
import os
import random
import sys

import place_life_props as lp
from PIL import Image

ROOT = lp.ROOT
W, H, CELL = lp.W, lp.H, lp.CELL
RNG = random.Random(20261103)

# 装饰目录：sprite 路径（res:// 相对项目根），数量，落点上下文，是否阻挡玩家
# ctx: road=贴路边草地 / front=挨建筑楼前 / util=四周边角后勤区
CATALOG = [
    # —— 已有校园素材（风格一致）多撒一些 ——
    ("res://assets/props_planter.png",      12, "road",  False),
    ("res://assets/props_bench.png",         8, "front", True),
    ("res://assets/props_bike.png",          8, "front", True),
    ("res://assets/props_vending.png",       3, "front", True),
    ("res://assets/props_locker.png",        4, "front", True),
    ("res://assets/props_sign_blue.png",     4, "road",  False),
    ("res://assets/props_sign_red.png",      2, "road",  False),
    ("res://assets/props_flag.png",          4, "front", False),
    # —— PixelSRPG-Forge（MIT）里挑出来的、不像地牢的杂物 ——
    ("res://assets/props_forge/decor_85.png", 3, "util",  True),   # 木箱堆
    ("res://assets/props_forge/decor_86.png", 3, "util",  True),   # 油桶堆
    ("res://assets/props_forge/decor_68.png", 2, "util",  False),  # 梯子
    ("res://assets/props_forge/decor_77.png", 2, "util",  True),   # 设备箱
    ("res://assets/props_forge/decor_78.png", 2, "util",  True),   # 设备箱
]


def footprint(sprite):
    p = os.path.join(ROOT, sprite.replace("res://", ""))
    im = Image.open(p)
    return max(1, math.ceil(im.width / CELL)), max(1, math.ceil(im.height / CELL))


def load_world():
    with open(os.path.join(ROOT, "assets/world.json"), encoding="utf-8") as f:
        return json.load(f)


def main():
    dry = "--dry" in sys.argv
    w = load_world()
    # 幂等：撤掉上次的装饰
    w["props"] = [p for p in w.get("props", [])
                  if not str(p.get("name", "")).startswith("装饰_")]

    roads = lp.road_mask()
    grass = lp.grass_mask()
    pitch = lp._dilate(lp.pitch_mask(w), 2)
    bpoly = lp.poly_fill([b.get("poly", []) for b in w.get("buildings", [])])
    water = [[0] * W for _ in range(H)]
    for r in w.get("water", []):
        x0, y0 = int(r["x"]), int(r["y"])
        for yy in range(max(0, y0), min(H, y0 + int(r["h"]) + 1)):
            for xx in range(max(0, x0), min(W, x0 + int(r["w"]) + 1)):
                water[yy][xx] = 1

    busy = [[0] * W for _ in range(H)]
    for y in range(H):
        for x in range(W):
            if bpoly[x, y] or water[y][x]:
                busy[y][x] = 1
    for br in w.get("bridges", []):
        bx, by = int(br.get("x", 0)), int(br.get("y", 0))
        bw, bh = int(br.get("w", 0)), int(br.get("h", 0))
        for y in range(max(0, by), min(H, by + bh + 1)):
            for x in range(max(0, bx), min(W, bx + bw + 1)):
                busy[y][x] = 1
    for it in w.get("instances", []):
        if str(it.get("k")) == "tree":
            gx, gy = int(float(it["x"])), int(float(it["y"]))
            for y in range(max(0, gy - 3), min(H, gy + 4)):
                for x in range(max(0, gx - 3), min(W, gx + 4)):
                    busy[y][x] = 1
    for p in w.get("props", []):
        if p.get("layer") == "ground":
            continue
        px = float(p["x"]); py = float(p.get("baseY", 0))
        try:
            im = Image.open(os.path.join(ROOT, str(p.get("sprite", "")).replace("res://", "")))
            ww = max(1, math.ceil(im.width / CELL)); hh = max(1, math.ceil(im.height / CELL))
        except Exception:
            ww = hh = 1
        for y in range(int(py) - hh, int(py) + 1):
            for x in range(int(px), int(px) + ww + 1):
                if 0 <= x < W and 0 <= y < H:
                    busy[y][x] = 1

    def near_road(x0, y0, ww, hh, dist=2):
        for y in range(y0 - dist, y0 + hh + dist):
            for x in range(x0 - dist, x0 + ww + dist):
                if 0 <= x < W and 0 <= y < H and roads[y][x]:
                    return True
        return False

    def near_building(x0, y0, ww, hh, dist=10):
        for b in w.get("buildings", []):
            box = b.get("box", {})
            minx, maxx = float(box.get("minx", 0)), float(box.get("maxx", 0))
            miny, maxy = float(box.get("miny", 0)), float(box.get("maxy", 0))
            dx = max(minx - (x0 + ww), x0 - maxx)
            dy = max(miny - (y0 + hh), y0 - maxy)
            if dx <= dist and dy <= dist:
                return True
        return False

    def in_shade(x0, y0, ww, hh):
        for b in w.get("buildings", []):
            box = b.get("box", {})
            minx = float(box.get("minx", 0)) - 3
            maxx = float(box.get("maxx", 0)) + 3
            miny = float(box.get("miny", 0)) - float(b.get("hp", 20)) - 3
            maxy = float(box.get("maxy", 0))
            if x0 + ww > minx and x0 < maxx and y0 + hh > miny and y0 < maxy:
                return True
        return False

    def free(x0, y0, ww, hh):
        if x0 < 4 or y0 < 4 or x0 + ww > W - 4 or y0 + hh > H - 4:
            return False
        for y in range(y0, y0 + hh):
            for x in range(x0, x0 + ww):
                if busy[y][x] or roads[y][x] or pitch[y][x] or not grass[y][x]:
                    return False
        return True

    # 预计算三张布尔网格，把 O(网格×楼数) 的逐格判定降成 O(1) 查表
    near_road_g = [[0] * W for _ in range(H)]
    for y in range(H):
        for x in range(W):
            if near_road(x, y, 1, 1):
                near_road_g[y][x] = 1
    near_bld_g = [[0] * W for _ in range(H)]
    for y in range(H):
        for x in range(W):
            if near_building(x, y, 1, 1):
                near_bld_g[y][x] = 1
    shade_g = [[0] * W for _ in range(H)]
    for y in range(H):
        for x in range(W):
            if in_shade(x, y, 1, 1):
                shade_g[y][x] = 1

    def candidates(ctx, fw, fh):
        out = []
        for y0 in range(5, H - fh - 5):
            for x0 in range(5, W - fw - 5):
                if not free(x0, y0, fw, fh):
                    continue
                if shade_g[y0 + fh - 1][x0]:
                    continue
                if ctx == "road":
                    if not near_road_g[y0][x0]:
                        continue
                elif ctx == "front":
                    if not near_bld_g[y0][x0]:
                        continue
                elif ctx == "util":
                    edge = (x0 < 34 or x0 > W - 34 or y0 < 34 or y0 > H - 34)
                    if not edge:
                        continue
                    if near_road_g[y0][x0]:
                        continue
                out.append((x0, y0))
        return out

    placed = []  # 全局防重叠
    props = []
    seq = {}
    for sprite, n, ctx, collide in CATALOG:
        fw, fh = footprint(sprite)
        cands = candidates(ctx, fw, fh)
        RNG.shuffle(cands)
        cnt = 0
        for x0, y0 in cands:
            if cnt >= n:
                break
            if any(abs(x0 - px) < 10 and abs(y0 - py) < 10 for px, py in placed):
                continue
            placed.append((x0, y0))
            seq[sprite] = seq.get(sprite, 0) + 1
            entry = {
                "name": "装饰_%d" % len(props),
                "sprite": sprite,
                "x": round(x0 + RNG.uniform(0, 0.4), 2),
                "baseY": round(y0 + fh, 2),
                "bottom": 0,
            }
            if collide:
                entry["collide"] = [[
                    [x0, y0 + fh - 0.4],
                    [x0 + fw, y0 + fh - 0.4],
                    [x0 + fw, y0 + fh],
                    [x0, y0 + fh],
                ]]
            props.append(entry)
            # 这块地占住，避免不同装饰叠在一起
            for y in range(y0 - 1, y0 + fh + 1):
                for x in range(x0 - 1, x0 + fw + 1):
                    if 0 <= x < W and 0 <= y < H:
                        busy[y][x] = 1
            cnt += 1
        print("[decor] %s x%d (候选 %d)" % (sprite.replace("res://assets/", ""), cnt, len(cands)))

    print("[decor] 共新增 %d 个装饰 props" % len(props))
    if dry:
        return
    w.setdefault("props", []).extend(props)
    with open(os.path.join(ROOT, "assets/world.json"), "w", encoding="utf-8") as f:
        json.dump(w, f, ensure_ascii=False, separators=(",", ":"))
    print("[decor] 已写回 world.json（记得 build_world_scene --force + --import）")


if __name__ == "__main__":
    main()
