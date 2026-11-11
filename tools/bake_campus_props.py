#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""往校园里补「人尺度」的公共设施：路边长椅、水岸长椅、楼前自行车、配套垃圾桶。

为什么单独一个脚本：`place_life_props.py` 只管停车场/车/垃圾桶，长椅只有 14 个、
自行车 29 个，散落在全图等于没有。真实的校园里，**长椅一定是成组出现在三种地方**：
路边（走累了能坐）、水边（看水）、广场边（等人）。这个脚本就按这三条规则批量补。

判据全部复用既有实现，不自己发明颜色阈值：
  · 路面    place_life_props.road_mask()
  · 草地    place_life_props.grass_mask()（已经是「真草」判据）
  · 建筑    place_life_props.poly_fill(buildings.poly)
  · 运动场  place_life_props.pitch_mask()
  · 水面    world.json 的 water 矩形

落笔一律在**草地格**上，且整块 sprite 包围盒不与建筑/水/路/已有道具相交 ——
所以不会挡路、不会插进楼里、不会漂在水上。

幂等：先删掉本脚本上一轮放的所有道具（名字前缀见 MARK），再重新算。
用法：
    python tools/bake_campus_props.py            # 写回 world.json
    python tools/bake_campus_props.py --dry      # 只统计不写
    python tools/bake_campus_props.py --preview  # 额外出预览合成图（不写）

写回之后必须：
    godot --headless --path . --script res://tools/build_world_scene.gd -- --force
    godot --headless --path . --import
"""
import json
import math
import os
import random
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))

import place_life_props as plp       # road_mask / grass_mask / poly_fill / pitch_mask
import road_net                      # 路网折线 + 分级定宽

W, H, CELL = 424, 800, 8
RNG = random.Random(20261111)

# 本脚本放的所有道具都用这个前缀，重跑时按它整体撤掉
MARK = "设施_"

# ---- 各件家具的精灵尺寸（px，来自 assets/props_*.png 实测）与碰撞占地（格）----
# footprint 用于「够不够放」的判定；collide 是真正挡人的那一条（贴地 1 格高）。
KIND = {
    "bench": {"sprite": "res://assets/props_bench.png",
              "w": 24, "h": 26, "cw": 2, "ch": 1},
    "bin":   {"sprite": "res://assets/props_bin_street.png",
              "w": 11, "h": 12, "cw": 1, "ch": 1},
    "bike":  {"sprite": "res://assets/props_bike.png",
              "w": 24, "h": 20, "cw": 2, "ch": 1},
    "stone": {"sprite": "res://assets/props_stonetable.png",
              "w": 34, "h": 26, "cw": 3, "ch": 1},
}

# ---- 三种落笔场景的间距 ----
BENCH_ROAD_STEP = 54      # 路侧长椅：沿同一条路每隔多少格出现一组
BENCH_WATER_STEP = 26     # 水岸长椅：沿水岸每隔多少格
BENCH_PLAZA_STEP = 11     # 广场边：沿铺装边缘每隔多少格
BIKE_PER_BLD = 4          # 每栋楼门口最多几辆自行车
GROUP_GAP = 13.0          # 任意两件家具之间的最小间距（格），避免扎堆
ROAD_EDGE = 1.45          # 家具离路面边界多远（格）


def load_world():
    with open(os.path.join(ROOT, "assets/world.json"), encoding="utf-8") as f:
        return json.load(f)


def _water_grid(world):
    g = [[0] * W for _ in range(H)]
    for r in world.get("water", []):
        x0 = int(round(float(r.get("x", 0))))
        y0 = int(round(float(r.get("y", 0))))
        ww = max(1, int(round(float(r.get("w", 1)))))
        hh = max(1, int(round(float(r.get("h", 1)))))
        for yy in range(y0, y0 + hh):
            for xx in range(x0, x0 + ww):
                if 0 <= xx < W and 0 <= yy < H:
                    g[yy][xx] = 1
    return g


def _dilate(grid, pad):
    if pad <= 0:
        return grid
    out = [[0] * W for _ in range(H)]
    for y in range(H):
        for x in range(W):
            if not grid[y][x]:
                continue
            for dy in range(-pad, pad + 1):
                for dx in range(-pad, pad + 1):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < W and 0 <= ny < H:
                        out[ny][nx] = 1
    return out


def _sprite_path(p):
    return str(p.get("sprite", "")).replace("res://", "")


class Board:
    """占用图 + 放置器。"""

    def __init__(self, world, roads, grass, bld, water, pitch):
        self.world = world
        self.roads = roads
        self.grass = grass
        self.bld = bld
        self.water = water
        self.pitch = pitch
        self.items = []
        self.busy = [[0] * W for _ in range(H)]
        self.spots = []          # 已放家具的格坐标，用于最小间距

        # 已有道具按 sprite 真实包围盒占位（和 place_life_props 同一套算法）
        for p in world.get("props", []):
            if p.get("layer") == "ground":
                continue
            self._stamp_prop(p)
        for it in world.get("instances", []):
            if str(it.get("k")) == "tree":
                self._stamp(int(float(it["x"])), int(float(it["y"])), 3, 3)
            elif str(it.get("k")) == "plane":
                self._stamp(int(float(it["x"])), int(float(it["y"])), 9, 9)

    # ---- 占位 ----
    def _stamp(self, cx, cy, ww, hh):
        for y in range(int(cy) - hh, int(cy) + 1):
            for x in range(int(cx), int(cx) + ww + 1):
                if 0 <= x < W and 0 <= y < H:
                    self.busy[y][x] = 1

    def _stamp_prop(self, p):
        px = float(p["x"])
        py = float(p.get("baseY", 0))
        try:
            im = Image.open(os.path.join(ROOT, _sprite_path(p)))
            ww = max(1, int(math.ceil(im.width / float(CELL))))
            hh = max(1, int(math.ceil(im.height / float(CELL))))
        except Exception:
            ww = hh = 1
        self._stamp(int(px), int(py), ww, hh)

    # ---- 判定 ----
    def _footprint_free(self, x0, y0, w_cells, h_cells, allow_road=False,
                        require_grass=True):
        """整块精灵包围盒（格）是否干净。y0 是底边，精灵向上长。"""
        for y in range(int(y0) - int(math.ceil(h_cells)), int(y0) + 1):
            for x in range(int(x0), int(x0) + int(math.ceil(w_cells)) + 1):
                if not (0 <= x < W and 0 <= y < H):
                    return False
                if self.busy[y][x] or self.bld[x, y] or self.water[y][x] or self.pitch[y][x]:
                    return False
                if not allow_road and self.roads[y][x]:
                    return False
                # 脚下必须踩草（精灵上半部可以是路对面，不判）
                if require_grass and y >= int(y0):
                    if not self.grass[y][x]:
                        return False
        return True

    def too_close(self, cx, cy, gap):
        if gap <= 0:
            return False
        for (px, py) in self.spots:
            if (px - cx) ** 2 + (py - cy) ** 2 < gap * gap:
                return True
        return False

    def place(self, kind, cx, cy, tag, require_grass=True, gap=None):
        k = KIND[kind]
        w_cells = k["w"] / float(CELL)
        h_cells = k["h"] / float(CELL)
        if not self._footprint_free(cx, cy, w_cells, h_cells,
                                    require_grass=require_grass):
            return False
        # 间距只约束「大件」。垃圾桶是长椅的配套件，必须允许紧挨着放，
        # 否则会被长椅自己的间距规则挡掉（实测 0 个）。
        if gap is None:
            gap = 0.0 if kind == "bin" else GROUP_GAP
        if self.too_close(cx, cy, gap):
            return False
        cw, ch = k["cw"], k["ch"]
        # 碰撞盒在大件精灵下居中（长椅 3 格宽、碰撞只占 2 格），但**不许挪精灵**：
        # 一挪 0.5 格，sprite 就溢出到判定时的包围盒外，会压到旁边的路面/楼体。
        bx0 = cx + (w_cells - cw) * 0.5
        self.items.append({
            "name": "%s%s_%d" % (MARK, tag, len(self.items)),
            "sprite": k["sprite"],
            "x": round(cx, 2),
            "baseY": round(cy, 2),
            "bottom": 0,
            "collide": [[[round(bx0, 2), round(cy - ch, 2)],
                         [round(bx0 + cw, 2), round(cy - ch, 2)],
                         [round(bx0 + cw, 2), round(cy, 2)],
                         [round(bx0, 2), round(cy, 2)]]],
        })
        self._stamp(int(cx), int(cy), int(math.ceil(w_cells)), int(math.ceil(h_cells)))
        self.spots.append((cx, cy))
        return True


# ---------------------------------------------------------------- 三种场景
def _walk_stations(road, step):
    """沿路网折线按固定弧长取点（同 bake_lamps 的做法）。"""
    pts = road["pts"]
    out = []
    if len(pts) < 2:
        return out
    acc = step * 0.5
    for k in range(len(pts) - 1):
        (x0, y0), (x1, y1) = pts[k], pts[k + 1]
        seg = math.dist((x0, y0), (x1, y1))
        if seg < 1e-6:
            continue
        tx, ty = (x1 - x0) / seg, (y1 - y0) / seg
        while acc <= seg:
            t = acc / seg
            out.append((x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, tx, ty))
            acc += step
        acc -= seg
    return out


def place_roadside(board):
    """路侧长椅：沿路网每隔 BENCH_ROAD_STEP 格，在路的任一侧草沿上放一组（椅子+垃圾桶）。

    只挑「两边都是草」的路段 —— 两侧都是楼/水的路段放椅子没人坐，也没地方站。
    """
    n_bench = n_bin = 0
    for road in road_net.load():
        half = road["w"] / 16.0 + ROAD_EDGE
        for (x, y, tx, ty) in _walk_stations(road, BENCH_ROAD_STEP):
            nx, ny = -ty, tx
            sides = [1.0, -1.0]
            RNG.shuffle(sides)
            hit = False
            for side in sides:
                bx = x + nx * side * half
                by = y + ny * side * half + 0.6     # 底座略往南，别贴在路缘线上
                if board.place("bench", bx, by, "road_bench"):
                    n_bench += 1
                    # 同组的垃圾桶沿**路的走向**偏移，不能沿法线偏 —— 朝路那一侧偏
                    # 会直接落到路面上（实测 bin 全被路面判掉）。
                    for d in (4.0, -4.0, 5.0, -5.0):
                        if board.place("bin", bx + tx * d, by + ty * d, "road_bin"):
                            n_bin += 1
                            break
                    hit = True
                    break
            if hit:
                continue
    return n_bench, n_bin


def place_waterfront(board, world):
    """水岸长椅：沿岸线每隔 BENCH_WATER_STEP 格放一张，朝向无所谓（精灵只有正面）。

    水岸比路侧更宽松：只要那一格草离水 <= 2 格就算岸边。
    """
    near_water = _dilate(board.water, 2)
    n_bench = n_bin = 0
    cand = []
    for y in range(6, H - 6):
        for x in range(6, W - 6):
            if not near_water[y][x] or board.water[y][x]:
                continue
            if not board.grass[y][x] or board.roads[y][x] or board.busy[y][x]:
                continue
            cand.append((x, y))
    RNG.shuffle(cand)
    for x, y in cand:
        if board.place("bench", x, y, "water_bench"):
            n_bench += 1
            if n_bench % 3 == 0:
                # 水岸没有明确走向，四向都试一遍，谁落在岸上就用谁
                for dx, dy in ((4, 0), (-4, 0), (0, 4), (0, -4), (3, 3), (-3, 3)):
                    if board.place("bin", x + dx, y + dy, "water_bin"):
                        n_bin += 1
                        break
    return n_bench, n_bin


def place_plaza_rim(board, world):
    """广场边缘：沿铺装 sprite 的矩形外框内缩 1.5 格摆一圈长椅（广场是等人/晒太阳的地方）。"""
    n_bench = 0
    for p in world.get("props", []):
        if p.get("layer") != "ground" or "plaza" not in _sprite_path(p):
            continue
        try:
            im = Image.open(os.path.join(ROOT, _sprite_path(p)))
        except Exception:
            continue
        pw = im.width / float(CELL)
        ph = im.height / float(CELL)
        x0 = float(p["x"])
        y0 = float(p.get("baseY", 0)) - ph
        # 四条边各走一遍，内缩 1.5 格（别压到铺装边缘的过渡带）
        for edge in range(4):
            if edge == 0:
                pts = [(x0 + 1.5 + t, y0 + 1.5) for t in range(0, int(pw - 3), BENCH_PLAZA_STEP)]
            elif edge == 1:
                pts = [(x0 + 1.5 + t, y0 + ph - 1.5) for t in range(0, int(pw - 3), BENCH_PLAZA_STEP)]
            elif edge == 2:
                pts = [(x0 + 1.5, y0 + 1.5 + t) for t in range(0, int(ph - 3), BENCH_PLAZA_STEP)]
            else:
                pts = [(x0 + pw - 1.5, y0 + 1.5 + t) for t in range(0, int(ph - 3), BENCH_PLAZA_STEP)]
            for bx, by in pts:
                # 广场是 Ground 层的整块 sprite，脚下看不出「草/铺装」，所以这里
                # 不要求草 —— 只要不是路/水/楼/已有道具就行（广场上摆椅子天经地义）。
                if board.place("bench", bx, by, "plaza_bench", require_grass=False):
                    n_bench += 1
    return n_bench


def place_bikes(board, world):
    """楼前自行车：每栋楼南侧入口（baseY 下方）沿墙摆一排，最多 BIKE_PER_BLD 辆。"""
    n = 0
    for b in world.get("buildings", []):
        box = b.get("box", {})
        if not box:
            continue
        minx = float(box.get("minx", 0))
        maxx = float(box.get("maxx", 0))
        maxy = float(box.get("maxy", 0))
        base_x = minx + 1.5
        base_y = maxy + 1.6
        placed = 0
        for i in range(BIKE_PER_BLD * 3):
            bx = base_x + i * 1.9
            if bx > maxx - 1.0:
                break
            if board.place("bike", bx, base_y, "bld_bike"):
                placed += 1
                if placed >= BIKE_PER_BLD:
                    break
        n += placed
    return n


# ---------------------------------------------------------------- 预览合成
def preview(board, boxes, out_prefix="shot_props_"):
    """把新道具按精灵真实尺寸贴到地面图上，用于快速目检（不启动 Godot）。"""
    import bake_ground_detail as D
    import bake_road_edge as E
    for k, (box, zoom, title) in enumerate(boxes):
        ox, oy, ex, ey = box
        before = D.load_ground((ox, oy, ex, ey)).convert("RGBA")
        after = before.copy()
        for p in board.items:
            sp = os.path.join(ROOT, _sprite_path(p))
            if not os.path.exists(sp):
                continue
            im = Image.open(sp).convert("RGBA")
            px = int(round(float(p["x"]) * CELL)) - ox
            py = int(round(float(p["baseY"]) * CELL)) - oy - im.height
            if px + im.width < 0 or py + im.height < 0 or px > after.width or py > after.height:
                continue
            after.alpha_composite(im, (px, py)) if px >= 0 and py >= 0 else None
            if px < 0 or py < 0:
                # 部分露头：裁一块贴上
                sx, sy = max(0, -px), max(0, -py)
                part = im.crop((sx, sy, im.width, im.height))
                after.alpha_composite(part, (max(0, px), max(0, py)))
        zw, zh = after.width * zoom, after.height * zoom
        canvas = Image.new("RGB", (zw * 2 + 16, zh + 34), (22, 24, 28))
        canvas.paste(before.convert("RGB").resize((zw, zh), Image.NEAREST), (0, 30))
        canvas.paste(after.convert("RGB").resize((zw, zh), Image.NEAREST), (zw + 16, 30))
        from PIL import ImageDraw
        dr = ImageDraw.Draw(canvas)
        dr.text((6, 8), "BEFORE", fill=(235, 235, 235))
        dr.text((zw + 22, 8), "AFTER  " + title, fill=(235, 235, 235))
        path = os.path.join(ROOT, "%s%d.png" % (out_prefix, k))
        canvas.save(path)
        print("[props] 预览 ->", os.path.basename(path), canvas.size)


def main():
    dry = "--dry" in sys.argv
    want_preview = "--preview" in sys.argv
    world = load_world()

    # 撤掉上一轮（幂等）
    before_n = len(world.get("props", []))
    world["props"] = [p for p in world.get("props", [])
                      if not str(p.get("name", "")).startswith(MARK)]
    removed = before_n - len(world["props"])
    if removed:
        print("[props] 撤掉上一轮 %d 件" % removed)

    roads = plp.road_mask()
    grass = plp.grass_mask()
    bld = plp.poly_fill([b.get("poly", []) for b in world.get("buildings", [])])
    water = _water_grid(world)
    pitch = plp.pitch_mask(world)

    board = Board(world, roads, grass, bld, water, pitch)

    nb_r, nb_b1 = place_roadside(board)
    nb_w, nb_b2 = place_waterfront(board, world)
    nb_p = place_plaza_rim(board, world)
    nb_k = place_bikes(board, world)

    kinds = {}
    for p in board.items:
        k = _sprite_path(p).split("props_")[-1].replace(".png", "")
        kinds[k] = kinds.get(k, 0) + 1
    print("[props] 路侧 %d 组 / 水岸 %d 张 / 广场边 %d 张 / 楼前自行车 %d 辆"
          % (nb_r, nb_w, nb_p, nb_k))
    print("[props] 明细:", kinds, "合计", len(board.items))

    if want_preview:
        # 取景：图书馆广场、湖岸、楼前
        preview(board, [
            ((1640, 3040, 1900, 3260), 4, "fountain plaza"),
            ((900, 4560, 1400, 4900), 3, "lake shore"),
        ])

    if dry:
        print("[props] --dry，不写 world.json")
        return

    world["props"].extend(board.items)
    path = os.path.join(ROOT, "assets/world.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(world, f, ensure_ascii=False, separators=(",", ":"))
    print("[props] 已写回 world.json（props %d -> %d）"
          % (before_n, len(world["props"])))
    print("[props] 接着跑：")
    print("  godot --headless --path . --script res://tools/build_world_scene.gd -- --force")
    print("  godot --headless --path . --import")


if __name__ == "__main__":
    main()
