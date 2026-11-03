#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""往校园里摆「生活小物件」：停车场 + 车、垃圾桶、路牌。

照片里最像真实校园的东西之一就是**成排停的车** —— 现在的校园一辆车都没有。
这里自动找「挨着路边、不压楼不压水不压树」的空地，铺一块沥青停车场并停满车，
再沿主干道撒几个垃圾桶、在楼门口立两块路牌。

原则：只在 world.json 里追加 props，不改任何几何；摆完跑
    godot --headless --path . --script res://tools/build_world_scene.gd -- --force
然后是 --import。

用法：python tools/place_life_props.py [--dry]
"""
import json
import math
import os
import random
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
W, H, CELL = 424, 800, 8
RNG = random.Random(20261102)

LOT_W, LOT_H = 16, 9          # 格（= 停车场贴图 128×72 px）
CAR_COLORS = ["white", "silver", "blue", "red"]
CAR_W, CAR_H = 9, 16          # px


def load_world():
    with open(os.path.join(ROOT, "assets/world.json"), encoding="utf-8") as f:
        return json.load(f)


def road_mask():
    """从地面图里认出「路面」：中性灰（石材铺装 / 沥青）。返回 W×H 的 0/1 网格。"""
    grid = [[0] * W for _ in range(H)]
    chunks = {}
    for cy in range(7):
        for cx in range(4):
            p = os.path.join(ROOT, "assets/ground/g%d_%d.png" % (cx, cy))
            if os.path.exists(p):
                chunks[(cx, cy)] = Image.open(p).convert("RGB").load()

    def is_road(px):
        r, g, b = px
        return max(r, g, b) - min(r, g, b) <= 12 and 92 <= r <= 182

    for gy in range(H):
        for gx in range(W):
            cx, cy = gx // 128, gy // 128
            im = chunks.get((cx, cy))
            if im is None:
                continue
            ox, oy = (gx % 128) * CELL, (gy % 128) * CELL
            n = 0
            for yy in range(0, CELL, 2):
                for xx in range(0, CELL, 2):
                    if is_road(im[ox + xx, oy + yy]):
                        n += 1
            if n >= 6:
                grid[gy][gx] = 1
    return grid


def grass_mask():
    """草地网格：只有真草才允许铺停车场（防止铺到塑胶跑道、广场铺装、沙地上）。"""
    grid = [[0] * W for _ in range(H)]
    chunks = {}
    for cy in range(7):
        for cx in range(4):
            p = os.path.join(ROOT, "assets/ground/g%d_%d.png" % (cx, cy))
            if os.path.exists(p):
                chunks[(cx, cy)] = Image.open(p).convert("RGB").load()
    for gy in range(H):
        for gx in range(W):
            im = chunks.get((gx // 128, gy // 128))
            if im is None:
                continue
            ox, oy = (gx % 128) * CELL, (gy % 128) * CELL
            n = 0
            for yy in range(0, CELL, 2):
                for xx in range(0, CELL, 2):
                    r, g, b = im[ox + xx, oy + yy]
                    if g > r + 14 and g > b + 28 and g > 100:
                        n += 1
            if n >= 12:
                grid[gy][gx] = 1
    return grid


def pitch_mask(world):
    """运动场禁停掩码：足球/篮球/排球/网球/操场等球场地面 sprite。

    这些场地在 world.json 里是 Ground 层 props（sprite 在 assets/pitches/ 下），
    **不是建筑多边形** —— grass_mask 会把它当普通草地放行，near_building 又满足
    （挨着宿舍），于是停车场被铺到球场正中央（用户原话「星天苑操场怎么有个停车场纯胡扯」）。
    这里单独建一张禁停掩码，选址时直接跳过。"""
    grid = [[0] * W for _ in range(H)]
    for p in world.get("props", []):
        sp = str(p.get("sprite", ""))
        if "pitches/" not in sp:
            continue
        x = int(round(float(p["x"])))
        by = float(p.get("baseY", 0))
        ww = hh = 1
        try:
            im = Image.open(os.path.join(ROOT, sp.replace("res://", "")))
            ww = max(1, int(round(im.width / CELL)))
            hh = max(1, int(round(im.height / CELL)))
        except Exception:
            pass
        y0 = int(round(by - hh))
        for yy in range(y0, int(round(by))):
            for xx in range(x, x + ww):
                if 0 <= xx < W and 0 <= yy < H:
                    grid[yy][xx] = 1
    return grid


def _dilate(grid, pad):
    if pad <= 0:
        return grid
    out = [[0] * W for _ in range(H)]
    for y in range(H):
        for x in range(W):
            if grid[y][x]:
                for dy in range(-pad, pad + 1):
                    for dx in range(-pad, pad + 1):
                        nx, ny = x + dx, y + dy
                        if 0 <= nx < W and 0 <= ny < H:
                            out[ny][nx] = 1
    return out


def poly_fill(polys):
    from PIL import ImageDraw
    m = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(m)
    for poly in polys:
        if len(poly) >= 3:
            d.polygon([(float(p[0]), float(p[1])) for p in poly], fill=1)
    return m.load()


def main():
    dry = "--dry" in sys.argv
    w = load_world()

    # 可重复运行：先把上次摆的撤掉，否则每跑一次就多一层。
    # 必须在建占用图之前做，不然上一轮的车会把地面全占住。
    w["props"] = [p for p in w.get("props", [])
                  if not (str(p.get("name", "")).startswith("停车场")
                          or str(p.get("name", "")).startswith("停车牌")
                          or str(p.get("name", "")).startswith("车")
                          or str(p.get("name", "")).startswith("垃圾桶"))]

    # 上次为停车场清掉的树先放回去再重算，否则每跑一次都会多砍一圈树（幂等）
    restored = w.pop("cleared_trees", None)
    if restored:
        w.setdefault("instances", []).extend(restored)
        print("[place] 已恢复上次清掉的 %d 棵树，重新计算" % len(restored))

    roads = road_mask()
    grass = grass_mask()
    # 运动场（pitches/ sprite）一律禁停，外扩 2 格避免紧贴球场边线
    pitch = _dilate(pitch_mask(w), 2)
    bpoly = poly_fill([b.get("poly", []) for b in w.get("buildings", [])])

    water = [[0] * W for _ in range(H)]
    for r in w.get("water", []):
        x0, y0 = int(r["x"]), int(r["y"])
        for yy in range(max(0, y0), min(H, y0 + int(r["h"]) + 1)):
            for xx in range(max(0, x0), min(W, x0 + int(r["w"]) + 1)):
                water[yy][xx] = 1

    # 占用图：楼 / 水 / 已有的树和摆件（各留 pad 格）
    busy = [[0] * W for _ in range(H)]
    for y in range(H):
        for x in range(W):
            if bpoly[x, y] or water[y][x]:
                busy[y][x] = 1

    # 桥面：那是跨水的通道，车不能停在上面
    for br in w.get("bridges", []):
        bx, by = int(br.get("x", 0)), int(br.get("y", 0))
        bw, bh = int(br.get("w", 0)), int(br.get("h", 0))
        for y in range(max(0, by), min(H, by + bh + 1)):
            for x in range(max(0, bx), min(W, bx + bw + 1)):
                busy[y][x] = 1

    def stamp(grid, cx, cy, pad):
        for y in range(max(0, cy - pad), min(H, cy + pad + 1)):
            for x in range(max(0, cx - pad), min(W, cx + pad + 1)):
                grid[y][x] = 1

    for it in w.get("instances", []):
        if str(it.get("k")) == "tree":
            stamp(busy, int(float(it["x"])), int(float(it["y"])), 3)

    # 摆件按**精灵真实包围盒**占位，不能只按底座那一格：
    # 旗杆/路灯/长椅的底座在停车场外，但精灵是从底座往上长的，会压到车位上。
    for p in w.get("props", []):
        if p.get("layer") == "ground":
            continue
        px = float(p["x"])
        py = float(p.get("baseY", 0))
        ww = hh = 1
        sp = str(p.get("sprite", "")).replace("res://", "")
        if sp:
            try:
                im = Image.open(os.path.join(ROOT, sp))
                ww = max(1, int(math.ceil(im.width / float(CELL))))
                hh = max(1, int(math.ceil(im.height / float(CELL))))
            except Exception:
                pass
        for y in range(int(py) - hh, int(py) + 1):
            for x in range(int(px), int(px) + ww + 1):
                if 0 <= x < W and 0 <= y < H:
                    busy[y][x] = 1

    def free_rect(x0, y0, ww, hh):
        if x0 < 4 or y0 < 4 or x0 + ww > W - 4 or y0 + hh > H - 4:
            return False
        for y in range(y0, y0 + hh):
            for x in range(x0, x0 + ww):
                if busy[y][x] or roads[y][x] or pitch[y][x] or not grass[y][x]:
                    return False
        return True

    def near_road(x0, y0, ww, hh, dist=2):
        for y in range(y0 - dist, y0 + hh + dist):
            for x in range(x0 - dist, x0 + ww + dist):
                if 0 <= x < W and 0 <= y < H and roads[y][x]:
                    return True
        return False

    def in_shade(x0, y0, ww, hh):
        """楼是 2.5D 往上挤出的：footprint 北侧 hp 格都被屋顶盖住。
        停车场铺进那片区域就等于"藏在楼背后"，从画面上看只剩一道缝。"""
        for b in w.get("buildings", []):
            box = b.get("box", {})
            minx = float(box.get("minx", 0)) - 3
            maxx = float(box.get("maxx", 0)) + 3
            miny = float(box.get("miny", 0)) - float(b.get("hp", 20)) - 3
            maxy = float(box.get("maxy", 0))
            if x0 + ww > minx and x0 < maxx and y0 + hh > miny and y0 < maxy:
                return True
        return False

    def near_building(x0, y0, ww, hh, dist=16):
        """停车场要挨着楼（不然车停在一片空草地中间很怪）。
        按矩形边距算，不要用楼的中心点——大院子的中心离路边几十格，永远够不着。"""
        for b in w.get("buildings", []):
            box = b.get("box", {})
            minx = float(box.get("minx", 0))
            maxx = float(box.get("maxx", 0))
            miny = float(box.get("miny", 0))
            maxy = float(box.get("maxy", 0))
            dx = max(minx - (x0 + ww), x0 - maxx)
            dy = max(miny - (y0 + hh), y0 - maxy)
            if dx <= dist and dy <= dist:
                return True
        return False

    props = []
    lots = 0
    tried = 0
    lot_at = []
    n_free = n_road = n_shade = n_bld = 0
    cand_lots = []
    for y0 in range(6, H - LOT_H - 6, 3):
        for x0 in range(6, W - LOT_W - 6, 3):
            tried += 1
            if not free_rect(x0, y0, LOT_W, LOT_H):
                continue
            n_free += 1
            if not near_road(x0, y0, LOT_W, LOT_H):
                continue
            n_road += 1
            if in_shade(x0, y0, LOT_W, LOT_H):
                continue
            n_shade += 1
            if not near_building(x0, y0, LOT_W, LOT_H):
                continue
            n_bld += 1
            cand_lots.append((x0, y0))

    # 从候选里挑：随机顺序 + 最小间距，避免全挤在同一个片区（顺序扫描会一路扎堆往北）
    RNG.shuffle(cand_lots)
    picked = []
    for x0, y0 in cand_lots:
        if len(picked) >= 9:
            break
        if any(abs(x0 - px) < 48 and abs(y0 - py) < 48 for px, py in picked):
            continue
        picked.append((x0, y0))
    picked.sort(key=lambda t: t[1])

    # ---- 给停车场清场：删掉树冠压在这块地上的树 ----
    # 停车场在 Ground 层，永远画在 Objects 层的树下面。一棵 12×20 格的树精灵能把
    # 大半个停车场盖住，所以直接把相交的树删掉——真实校园里停车场本来也不长树。
    def tree_box(it):
        si = int(it.get("sp", -1))
        decs = w.get("decor", [])
        if si < 0 or si >= len(decs):
            return None
        d = decs[si]
        ax, ay = float(d.get("ax", 0)), float(d.get("ay", 0))
        tw, th = float(d.get("w", 8)) / CELL, float(d.get("h", 8)) / CELL
        x, y = float(it.get("x", 0)), float(it.get("y", 0))
        return (x - ax, y - ay, x - ax + tw, y - ay + th)

    cleared = 0
    keep_inst = []
    gone = []
    for it in w.get("instances", []):
        if str(it.get("k")) != "tree":
            keep_inst.append(it)
            continue
        bb = tree_box(it)
        hit = False
        if bb is not None:
            for x0, y0 in picked:
                if (bb[2] > x0 - 1 and bb[0] < x0 + LOT_W + 1
                        and bb[3] > y0 - 1 and bb[1] < y0 + LOT_H + 1):
                    hit = True
                    break
        if hit:
            cleared += 1
            gone.append(it)
        else:
            keep_inst.append(it)
    w["instances"] = keep_inst
    print("[place] 为停车场清掉 %d 棵树" % cleared)

    for x0, y0 in picked:
        # 入口停车牌：立在停车场**北侧**的路沿上（不能放进车位里，会把第一台车挡没）
        props.append({
            "name": "停车牌%d" % (lots + 1),
            "sprite": "res://assets/props_sign_blue.png",
            "x": round(x0 + 1.0, 2), "baseY": round(y0 - 0.6, 2), "bottom": 0,
        })
        # 铺地面
        props.append({
            "name": "停车场%d" % (lots + 1),
            "sprite": "res://assets/props_parking_lot.png",
            "x": x0, "baseY": y0 + LOT_H, "bottom": 0, "layer": "ground",
        })
        # 停车：上下两排，每排 8 个车位
        stall_w, pad_x, pad_y, stall_d, aisle = 15, 4, 4, 19, 26
        for row in range(2):
            cy_px = (y0 * CELL) + pad_y + row * (stall_d + aisle)
            for i in range(8):
                if RNG.random() < 0.28:      # 留些空位，别像停车场广告图
                    continue
                col = RNG.choice(CAR_COLORS)
                face = "v" if row == 0 else "vd"
                px = x0 * CELL + pad_x + i * stall_w + 3
                py = cy_px + 1
                props.append({
                    "name": "车%d_%d" % (lots + 1, row * 8 + i),
                    "sprite": "res://assets/props_car_%s_%s.png" % (col, face),
                    "x": round(px / CELL, 3),
                    "baseY": round((py + CAR_H) / CELL, 3),
                    "bottom": 0,
                    "collide": [[
                        [px / CELL, (py + CAR_H) / CELL - 1.9],
                        [px / CELL + CAR_W / CELL, (py + CAR_H) / CELL - 1.9],
                        [px / CELL + CAR_W / CELL, (py + CAR_H) / CELL],
                        [px / CELL, (py + CAR_H) / CELL],
                    ]],
                })
        lot_at.append((x0, y0))
        # 这块地以后不能再放垃圾桶
        for y in range(y0 - 1, y0 + LOT_H + 1):
            for x in range(x0 - 1, x0 + LOT_W + 1):
                if 0 <= x < W and 0 <= y < H:
                    busy[y][x] = 1
        lots += 1

    # ---- 垃圾桶：贴着路沿的草地/人行道边，按间距挑，别扎堆 ----
    # 注意：不能按固定步进采样再要求「这一格没被树占用」——行道树沿路种成一排，
    # 正好把路边那圈格子全占了，结果一个都选不出来。改成先收集全部候选再按间距挑。
    bins = 0
    cand = []
    for y in range(6, H - 6):
        for x in range(6, W - 6):
            if roads[y][x] or busy[y][x]:
                continue
            if not grass[y][x]:
                continue
            if not any(roads[y + dy][x + dx]
                       for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
                continue
            # 别塞进楼的遮挡带里（L 形楼的凹口看着是草地，其实被南翼盖着）
            if in_shade(x, y, 1, 1):
                continue
            cand.append((x, y))
    RNG.shuffle(cand)
    placed = []
    for x, y in cand:
        if bins >= 24:
            break
        if any(abs(x - px) < 22 and abs(y - py) < 22 for px, py in placed):
            continue
        props.append({
            "name": "垃圾桶%d" % (bins + 1),
            "sprite": "res://assets/props_bin_street.png",
            "x": x + RNG.uniform(-0.3, 0.3), "baseY": y + 0.9, "bottom": 0,
        })
        placed.append((x, y))
        bins += 1
    print("[place] 垃圾桶候选 %d 个" % len(cand))

    print("[place] 网格 %d 个 → 空地 %d → 临路 %d → 不在楼影 %d → 靠楼 %d"
          % (tried, n_free, n_road, n_shade, n_bld))
    print("[place] 停车场位置(格):", lot_at)
    print("[place] 停车场 %d 个、车 %d 辆、垃圾桶 %d 个、合计新增 %d 个 props"
          % (lots, sum(1 for p in props if str(p["name"]).startswith("车")), bins, len(props)))
    if dry:
        return
    w.setdefault("props", []).extend(props)
    w["cleared_trees"] = gone
    path = os.path.join(ROOT, "assets/world.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(w, f, ensure_ascii=False, separators=(",", ":"))
    print("[place] 已写回 world.json（记得重跑 build_world_scene + --import）")


if __name__ == "__main__":
    main()
