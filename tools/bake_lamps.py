#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""重新烘焙路灯位置 assets/lamps.json。

旧版 559 盏里有 1/3 散落在离任何道路 >8 格的空地/草坪中央（看似随机撒点），
用户要求「优先分布在道路两边」。这里改为从 OSM 路网中心线沿**两侧**成对布置：

  · 主干道 / 次干道 / 步道分别按 26 / 34 / 50 格一个「站距」，
    每站向路中心线左右法线各偏 (半宽 + 1.3 格) —— 正好落在路缘外的草沿/人行带上，
    成对出现，视觉上是「道路两边各一排灯」。
  · 每个候选点先过禁放掩码：建筑轮廓(poly) / 水面 / 运动场(pitches) 一律跳过；
    该侧被挡就跳过该侧（不硬塞）。
  · 全局最小间距 7 格去重，路口不会堆一坨。
  · 「其他地方」：POI 广场各撒一圈、每栋楼南侧入口前放一盏，让广场/楼门口也亮起来。

输出 {"lamps": [[px, py], ...]}，px = 格 × 8（杆底地面锚点，Lamp.gd origin=杆底）。

改完必须把 Arena.gd 的 LM_CACHE 版本号 +1（lightmap_vN），否则旧光照图缓存不会重烘。
用法：python tools/bake_lamps.py [--dry]
"""
import json
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))

import road_net                 # 路网折线 + 分级定宽
import place_life_props as plp  # road_mask / pitch_mask / poly_fill（复用同一套识别）

W, H, CELL = 424, 800, 8

# 每类道路的「站距」（格）：两站之间左右各来一盏，所以同侧间距 = 站距。
# 光照图有效照明半径≈10 格（LM_FALLOFF=2 / LAMP_LEVEL≈15，7 单元=14 格，亮部≈10 格），
# 站距必须明显小于 2×半径 才能首尾相接不出现暗段；之前 36 格的步道中间大片黑就是这原因。
STEP = {2: 14, 1: 16, 0: 18}      # 2=主干 1=次干 0=步道（同侧间距 = 站距）
OFF_EXTRA = 0.6                   # 在路面半宽之外再外扩多少格（贴着路缘，别骑到路面上）
MIN_SEP = 5.0                     # 灯与灯最小间距（格）
LAMP_PX_OFF = 4                   # 杆底取格中心（+4px）


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
            if grid[y][x]:
                for dy in range(-pad, pad + 1):
                    for dx in range(-pad, pad + 1):
                        nx, ny = x + dx, y + dy
                        if 0 <= nx < W and 0 <= ny < H:
                            out[ny][nx] = 1
    return out


def _walk_stations(road):
    """沿折线按 STEP 等弧长返回 (x, y, tangent) 站点（格坐标）。"""
    step = STEP[road["cls"]]
    pts = road["pts"]
    out = []
    if len(pts) < 2:
        return out
    acc = step * 0.5     # 首站不贴路口
    for k in range(len(pts) - 1):
        (x0, y0), (x1, y1) = pts[k], pts[k + 1]
        seg = math.dist((x0, y0), (x1, y1))
        if seg < 1e-6:
            continue
        tx, ty = (x1 - x0) / seg, (y1 - y0) / seg
        t = 0.0
        while acc <= seg:
            t = acc / seg if seg else 0.0
            out.append((x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, tx, ty))
            acc += step
        acc -= seg
    return out


def _avg_normal(pts):
    """折线整体走向的单位法线（用于短路中点补灯）。"""
    sx = sy = 0.0
    n = 0
    for k in range(len(pts) - 1):
        (x0, y0), (x1, y1) = pts[k], pts[k + 1]
        seg = math.dist((x0, y0), (x1, y1))
        if seg < 1e-6:
            continue
        tx, ty = (x1 - x0) / seg, (y1 - y0) / seg
        sx += -ty
        sy += tx
        n += 1
    if n == 0:
        return 1.0, 0.0
    L = math.hypot(sx, sy) or 1.0
    return sx / L, sy / L


def main():
    dry = "--dry" in sys.argv
    world = json.load(open(os.path.join(ROOT, "assets/world.json"), encoding="utf-8"))

    # ---- 禁放掩码 ----
    bld = plp.poly_fill([b.get("poly", []) for b in world.get("buildings", [])])
    water = _dilate(_water_grid(world), 1)   # 水面外扩 1 格，灯别贴水边
    pitch = plp.pitch_mask(world)

    def blocked(cx, cy):
        x, y = int(round(cx)), int(round(cy))
        if not (0 <= x < W and 0 <= y < H):
            return True
        if bld[x, y]:
            return True
        if water[y][x] or pitch[y][x]:
            return True
        return False

    placed = []          # [(cx, cy)]
    cells = []           # 去重用的整数格

    def too_close(cx, cy):
        for (px, py) in placed:
            if (px - cx) ** 2 + (py - cy) ** 2 < MIN_SEP * MIN_SEP:
                return True
        return False

    def add(cx, cy):
        if blocked(cx, cy):
            return False
        if too_close(cx, cy):
            return False
        placed.append((cx, cy))
        return True

    # ---- 1) 道路两侧成对布灯 ----
    roads = road_net.load()
    for road in roads:
        half = road["w"] / 16.0 + OFF_EXTRA          # 路面半宽(格) + 外扩
        stations = _walk_stations(road)
        for (x, y, tx, ty) in stations:
            nx, ny = -ty, tx                          # 法线
            for side in (1.0, -1.0):
                add(x + nx * side * half, y + ny * side * half)
        # 短路（整条不够放一个站距）：在中点两侧各补一盏，避免整条黑
        if len(stations) == 0 and road["len"] >= 6.0:
            pts = road["pts"]
            mx = sum(p[0] for p in pts) / len(pts)
            my = sum(p[1] for p in pts) / len(pts)
            nx, ny = _avg_normal(pts)
            for side in (1.0, -1.0):
                add(mx + nx * side * half, my + ny * side * half)

    n_road = len(placed)

    # ---- 2) POI 广场各撒一圈（其他地方也亮起来）----
    for poi in world.get("poi", []):
        px = float(poi.get("x", 0))
        py = float(poi.get("y", 0))
        for a in range(6):
            ang = a * math.pi / 3.0
            add(px + math.cos(ang) * 5.0, py + math.sin(ang) * 5.0)

    n_poi = len(placed) - n_road

    # ---- 3) 每栋楼南侧入口前放一盏（只在附近无道路灯时才补，避免沿路楼重复堆灯）----
    def covered(cx, cy, r):
        for (px, py) in placed:
            if (px - cx) ** 2 + (py - cy) ** 2 < r * r:
                return True
        return False

    for b in world.get("buildings", []):
        cx = float(b.get("cx", b.get("x", 0)))
        by = float(b.get("baseY", b.get("y", 0)))
        ex, ey = cx, by + 2.4
        if covered(ex, ey, 9.0):     # 9 格内已有灯（多半是路缘灯）→ 不重复
            continue
        add(ex, ey)

    n_bld = len(placed) - n_road - n_poi

    # ---- 排序 + 输出 ----
    placed.sort(key=lambda p: (round(p[1], 1), round(p[0], 1)))
    lamps = [[round(cx * CELL + LAMP_PX_OFF, 1), round(cy * CELL + LAMP_PX_OFF, 1)]
             for (cx, cy) in placed]

    print("[lamps] 道路两侧 %d  |  POI %d  |  楼门口 %d  |  合计 %d"
          % (n_road, n_poi, n_bld, len(lamps)))
    if dry:
        print("[lamps] --dry，不写文件")
        return
    out = os.path.join(ROOT, "assets", "lamps.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump({"lamps": lamps}, f, ensure_ascii=False)
    print("[lamps] 已写 %s（%d 盏）" % (os.path.relpath(out, ROOT), len(lamps)))


if __name__ == "__main__":
    main()
