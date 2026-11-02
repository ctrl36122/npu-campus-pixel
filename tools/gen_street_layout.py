#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给校园摆一批生活设施（快递柜 / 自行车 / 垃圾桶 / 售货机 / 店招）。

坐标依据：
- 建筑的 box/poly 来自 world.json（OSM 拟合，1 格 ≈ 2.5 m）
- 店招位置来自 OSM 的 shop/amenity 节点（学府快餐、宝来惠超市），
  用 tools/pitches_raw.json 里的同一套 s/ox/oy 变换换到格坐标

每一步都会校验「不压建筑、不落水面、不和已有道具重叠」，不合法就跳过并报出来，
所以这个脚本可以反复跑（配合 merge_street_props.py 是幂等的）。

用法：python tools/gen_street_layout.py [--dry]
输出：tools/street_props.json
"""
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
WORLD = os.path.join(HERE, "..", "assets", "world.json")
OUT = os.path.join(HERE, "street_props.json")

# 贴图尺寸（px）→ 格（TS=8）
ART = {
    "bin":     ("res://assets/props_bin.png",     14, 20),
    "locker":  ("res://assets/props_locker.png",  46, 42),
    "bike":    ("res://assets/props_bike.png",    24, 20),
    "vending": ("res://assets/props_vending.png", 20, 32),
    "sign_r":  ("res://assets/props_sign_red.png",    36, 30),
    "sign_y":  ("res://assets/props_sign_yellow.png", 36, 30),
}
TS = 8.0


def point_in_poly(px, py, poly):
    inside = False
    n = len(poly)
    j = n - 1
    for i in range(n):
        xi, yi = poly[i][0], poly[i][1]
        xj, yj = poly[j][0], poly[j][1]
        if (yi > py) != (yj > py):
            xint = (xj - xi) * (py - yi) / (yj - yi) + xi
            if px < xint:
                inside = not inside
        j = i
    return inside


class Board:
    def __init__(self, world):
        self.polys = [(b.get("name", "?"), b["poly"]) for b in world["buildings"] if b.get("poly")]
        self.water = world["water"]
        self.placed = []          # (x0, y0, x1, y1)

    def in_building(self, x, y, pad=0.0):
        for name, poly in self.polys:
            if point_in_poly(x, y, poly):
                return name
        if pad > 0:
            # 贴边也算压楼：往外扩一点点再测一圈
            for dx, dy in ((pad, 0), (-pad, 0), (0, pad), (0, -pad)):
                for name, poly in self.polys:
                    if point_in_poly(x + dx, y + dy, poly):
                        return name
        return None

    def in_water(self, x, y):
        for r in self.water:
            if r["x"] <= x < r["x"] + r["w"] and r["y"] <= y < r["y"] + r["h"]:
                return True
        return False

    def rect_free(self, x0, y0, x1, y1, pad=0.2, samples=5):
        """包围盒（格）内取样点都要空；再和一个已经摆好的道具比一下矩形。"""
        for i in range(samples):
            for j in range(samples):
                x = x0 + (x1 - x0) * i / (samples - 1)
                y = y0 + (y1 - y0) * j / (samples - 1)
                if self.in_building(x, y, pad):
                    return False, "压到建筑 %s @(%.1f,%.1f)" % (self.in_building(x, y), x, y)
                if self.in_water(x, y):
                    return False, "落在水面 @(%.1f,%.1f)" % (x, y)
        for (a0, b0, a1, b1) in self.placed:
            if not (x1 < a0 - 0.05 or x0 > a1 + 0.05 or y1 < b0 - 0.05 or y0 > b1 + 0.05):
                return False, "和已摆道具重叠"
        return True, ""

    def footprint_free(self, x0, x1, ay, depth=0.5, allow_overlap=False, pad=0.15, samples=4):
        """只判「脚底占位」：贴图是竖直立起来的，上方立面盖住楼体是正常的
        （路灯、树都这样），拿整个包围盒去判空会把所有靠墙的摆件都毙掉。"""
        y0, y1 = ay - depth, ay
        for i in range(samples):
            for j in range(samples):
                x = x0 + (x1 - x0) * i / (samples - 1)
                y = y0 + (y1 - y0) * j / (samples - 1)
                hit = self.in_building(x, y, pad)
                if hit:
                    return False, "压到建筑 %s @(%.1f,%.1f)" % (hit, x, y)
                if self.in_water(x, y):
                    return False, "落在水面 @(%.1f,%.1f)" % (x, y)
        if not allow_overlap:
            for (a0, b0, a1, b1) in self.placed:
                if not (x1 < a0 - 0.05 or x0 > a1 + 0.05 or y1 < b0 - 0.05 or y0 > b1 + 0.05):
                    return False, "和已摆道具重叠"
        return True, ""

    def put(self, kind, name, ax, ay, layer=None, allow_overlap=False, depth=0.5):
        """ax=中心 x（格），ay=底边 y（格）。返回是否成功。"""
        sprite, wpx, hpx = ART[kind]
        w = wpx / TS
        x0 = ax - w / 2.0
        x1 = x0 + w
        ok, why = self.footprint_free(x0, x1, ay, depth, allow_overlap)
        if not ok:
            print("  ✗ %-22s (%.1f,%.1f) %s" % (name, ax, ay, why))
            return False
        self.placed.append((x0, ay - depth, x1, ay))
        p = {"name": name, "sprite": sprite,
             "x": round(x0, 2), "baseY": round(ay, 2), "bottom": 0}
        if layer:
            p["layer"] = layer
        self.out.append(p)
        print("  ✓ %-22s x=%.2f baseY=%.2f" % (name, x0, ay))
        return True

    def row(self, kind, name_fmt, ax, ay, n, gap, allow_overlap=True):
        """同一排摆 n 个，横向间隔 gap 格，居中排布。
        自行车并排停放本来就挤，允许互相压一点点（allow_overlap）。"""
        for i in range(n):
            off = (i - (n - 1) / 2.0) * gap
            self.put(kind, name_fmt % (i + 1), ax + off, ay, allow_overlap=allow_overlap)


def bbox(world, name):
    for b in world["buildings"]:
        if b.get("name") == name:
            return b["box"]
    raise KeyError(name)


def main():
    dry = "--dry" in sys.argv
    world = json.load(open(WORLD, encoding="utf-8"))
    bd = Board(world)
    bd.out = []

    print("== 快递柜（宿舍楼下，南侧）==")
    for nm, dx in (("星天苑B座", 0.0), ("云天苑B座", 0.0), ("海天苑学生宿舍1号楼", 0.0),
                   ("南山苑", -8.0)):
        box = bbox(world, nm)
        cx = (box["minx"] + box["maxx"]) / 2 + dx
        bd.put("locker", "快递柜·%s" % nm, cx, box["maxy"] + 1.4)

    print("== 店招（OSM 节点：学府快餐 / 宝来惠超市）==")
    bd.put("sign_y", "店招·学府快餐", 148.8, 176.4)
    bd.put("sign_r", "店招·宝来惠超市", 98.1, 68.4)

    print("== 自动售货机 ==")
    for nm, dx in (("翱翔体育馆", 6.0), ("星天苑D座", 0.0), ("教学东楼A座", 0.0)):
        box = bbox(world, nm)
        cx = (box["minx"] + box["maxx"]) / 2 + dx
        bd.put("vending", "售货机·%s" % nm, cx, box["maxy"] + 1.5)

    print("== 自行车停放区 ==")
    for nm, ay_off, n in (("星天苑A座", 1.3, 5), ("云天苑餐厅", 1.3, 5),
                          ("教学西楼A座", 1.3, 4), ("海天苑学生食堂", 1.3, 4),
                          ("留学生公寓", 1.3, 3)):
        box = bbox(world, nm)
        cx = (box["minx"] + box["maxx"]) / 2
        bd.row("bike", "自行车·%s-%%d" % nm, cx, box["maxy"] + ay_off, n, 3.05)

    print("== 垃圾桶 ==")
    for nm, dx in (("星天苑南餐厅", -9.0), ("星天苑北餐厅", 9.0), ("云天苑餐厅", -10.0),
                   ("海天苑学生宿舍2号楼", 8.0), ("亚洲最大水上图书馆", -18.0),
                   ("翱翔学生中心", 0.0), ("启翔楼", 0.0)):
        box = bbox(world, nm)
        cx = (box["minx"] + box["maxx"]) / 2 + dx
        bd.put("bin", "垃圾桶·%s" % nm, cx, box["maxy"] + 1.2)

    print("\n合计 %d 件" % len(bd.out))
    if dry:
        print("(--dry，不写文件)")
        return
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(bd.out, f, ensure_ascii=False, indent=1)
    print("已写 %s" % OUT)


if __name__ == "__main__":
    main()
