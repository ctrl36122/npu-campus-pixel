#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
沿每个水矩形的外缘（水缘绿化带上）种一圈树，让「水边都有一圈绿化带+树」。

- 树实例写入 world.json 的 instances，k="tree"，model="shore"（重跑可幂等清除旧的水缘树）。
- sp 从 {0,1,2,3,4, 11,12,13} 随机（11=松 12=秋 13=深绿），秋/松少一些。
- 跳过：建筑轮廓内、桥面、仍落在水里、与其它树过近、或超出校园的候选点。

用法：python3 tools/place_water_trees.py [--dry]
"""
import os, json, random, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORLD = os.path.join(ROOT, "assets", "world.json")
CELL = 8.0
MARGIN = 2          # 水缘向外几格种树（落在绿化带上）
SPACING = 3         # 每隔几格放一棵
MIN_DIST = 2.5      # 与已有树最小间距（格）
SP_SET = [0, 1, 2, 3, 4, 13, 13, 0, 1, 2, 3, 4, 11, 12]  # 偏绿，松/秋点缀


def cut_rects(x, y, w, h, holes):
    hit = any(x < ox + ow and ox < x + w and y < oy + oh and oy < y + h
              for (ox, oy, ow, oh) in holes)
    if not hit:
        return [(x, y, w, h)]
    out = []
    row = 0
    while row < h:
        ry = y + row
        spans = [(x, x + w)]
        for (ox, oy, ow, oh) in holes:
            if ry < oy or ry >= oy + oh:
                continue
            nxt = []
            for (a, b) in spans:
                if ox >= b or ox + ow <= a:
                    nxt.append((a, b)); continue
                if ox > a:
                    nxt.append((a, min(ox, b)))
                if ox + ow < b:
                    nxt.append((max(ox + ow, a), b))
            spans = nxt
        for (a, b) in spans:
            if b - a <= 0:
                continue
            out.append((a, ry, b - a, 1))
        row += 1
    merged = []
    for (rx, ry, rw, rh) in out:
        if merged and merged[-1][0] == rx and merged[-1][1] + merged[-1][3] == ry and merged[-1][2] == rw:
            merged[-1][3] += 1
        else:
            merged.append([rx, ry, rw, rh])
    return [(rx, ry, rw, rh) for (rx, ry, rw, rh) in merged]


def in_poly(px, py, poly):
    inside = False
    n = len(poly)
    j = n - 1
    for i in range(n):
        xi, yi = poly[i][0], poly[i][1]
        xj, yj = poly[j][0], poly[j][1]
        if ((yi > py) != (yj > py)) and (px < (xj - xi) * (py - yi) / (yj - yi) + xi):
            inside = not inside
        j = i
    return inside


def main():
    wj = json.load(open(WORLD))
    water = wj.get("water", [])
    decks = [(float(b.get("x", 0)), float(b.get("y", 0)), float(b.get("w", 0)), float(b.get("h", 0)))
             for b in wj.get("bridges", [])]
    buildings = [b.get("poly", []) for b in wj.get("buildings", []) if len(b.get("poly", [])) >= 3]
    W = wj["map"]["W"]; H = wj["map"]["H"]

    inst = wj.get("instances", [])
    # 幂等：清掉旧的水缘树
    inst = [i for i in inst if i.get("model") != "shore"]
    existing_trees = [(float(i.get("x", 0)), float(i.get("y", 0)))
                      for i in inst if i.get("k") == "tree"]

    # 所有水片（像素无关，用格），用于「仍落在水里」判定
    pieces = []
    for r in water:
        wx, wy, ww, wh = float(r["x"]), float(r["y"]), float(r["w"]), float(r["h"])
        if ww < 2 or wh < 2:
            continue
        for (cx, cy, cw, chh) in cut_rects(wx, wy, ww, wh, decks):
            pieces.append((cx, cy, cw, chh))

    def in_water(gx, gy):
        for (px, py, pw, ph) in pieces:
            if px - 0.5 <= gx <= px + pw + 0.5 and py - 0.5 <= gy <= py + ph + 0.5:
                return True
        return False

    def in_building(gx, gy):
        for poly in buildings:
            if in_poly(gx, gy, poly):
                return True
        return False

    def in_deck(gx, gy):
        for (dx, dy, dw, dh) in decks:
            if dx <= gx <= dx + dw and dy <= gy <= dy + dh:
                return True
        return False

    rnd = random.Random(20261104)
    added = []
    for (px, py, pw, ph) in pieces:
        # 外缘矩形（水外 MARGIN 格）
        mx, my, mw, mh = px - MARGIN, py - MARGIN, pw + 2 * MARGIN, ph + 2 * MARGIN
        # 绕外缘矩形边框走一圈，按 SPACING 落点
        pts = []
        x0, y0 = int(round(mx)), int(round(my))
        x1, y1 = int(round(mx + mw)), int(round(my + mh))
        for x in range(x0, x1 + 1):
            pts.append((x, y0)); pts.append((x, y1))
        for y in range(y0 + 1, y1):
            pts.append((x0, y)); pts.append((x1, y))
        i = rnd.randint(0, SPACING - 1)
        while i < len(pts):
            gx, gy = pts[i][0] + 0.5, pts[i][1] + 0.5
            i += SPACING
            if not (1 <= gx < W - 1 and 1 <= gy < H - 1):
                continue
            if in_water(gx, gy) or in_building(gx, gy) or in_deck(gx, gy):
                continue
            if any(abs(gx - ex) < MIN_DIST and abs(gy - ey) < MIN_DIST for (ex, ey) in existing_trees):
                continue
            sp = rnd.choice(SP_SET)
            s = round(rnd.uniform(1.3, 2.0), 2)
            inst.append({"k": "tree", "x": gx, "y": gy, "s": s, "sp": sp, "model": "shore"})
            existing_trees.append((gx, gy))
            added.append((gx, gy, sp, s))

    wj["instances"] = inst
    if "--dry" in sys.argv:
        print("[dry] 拟加水缘树 %d 棵" % len(added))
        return
    with open(WORLD, "w", encoding="utf-8") as f:
        json.dump(wj, f, ensure_ascii=False, separators=(",", ":"))
    print("已加水缘树 %d 棵（总实例 %d）" % (len(added), len(inst)))


if __name__ == "__main__":
    main()
