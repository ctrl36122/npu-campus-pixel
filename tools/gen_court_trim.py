#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""给运动场地加围网与高杆灯。

输入 tools/pitches_raw.json（格坐标轮廓），输出 tools/court_trim_props.json，
再由 merge_court_trim.py 合并进 assets/world.json。

摆放约定（按场地贴图的轴对齐 bbox，和 gen_pitches.py 一致）：
- 围网只做南北两条长边。东西两端在俯视 2.5D 下只是一条竖线，成本高收益低，
  而且留出东西向出入口，玩家不会被围死。
- 每段围网固定 8 格宽（64px），两端对齐、中间均分，重叠最多几像素。
- 高杆灯放在南北长边外侧 1.5 格，大场地四根、小场地两根。

体育馆 / 游泳馆是有实体楼的建筑，不处理。
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, "pitches_raw.json")
OUT = os.path.join(HERE, "court_trim_props.json")

SEG = 8.0                      # 一段围网 8 格
SKIP = ("翱翔体育馆", "翱翔游泳馆")


def fence_row(minx, maxx, y, tag):
    """沿东西向铺一排围网，返回 props。"""
    span = maxx - minx
    if span < 4:
        return []
    n = max(1, int(round(span / SEG)))
    step = (span - SEG) / (n - 1) if n > 1 else 0.0
    out = []
    for i in range(n):
        x = minx + (step * i if n > 1 else span / 2 - SEG / 2)
        out.append({
            "name": "%s围网%d" % (tag, i + 1),
            "sprite": "res://assets/props_fence_h.png",
            "x": round(x, 1),
            "baseY": round(y, 1),
            "bottom": 0,
        })
    return out


def towers(minx, maxx, miny, maxy, tag):
    long_side = (maxx - minx) >= 26
    ins = 2.0
    spots = []
    if long_side:
        spots = [(minx + ins, miny - 1.6), (maxx - ins - 2.5, miny - 1.6),
                 (minx + ins, maxy + 1.2), (maxx - ins - 2.5, maxy + 1.2)]
    else:
        mid = (minx + maxx) / 2 - 1.25
        spots = [(mid, miny - 1.6), (mid, maxy + 1.2)]
    return [{
        "name": "%s灯%d" % (tag, i + 1),
        "sprite": "res://assets/props_light_tower.png",
        "x": round(x, 1),
        "baseY": round(y, 1),
        "bottom": 0,
        "collide": [[[round(x, 1), round(y - 1, 1)],
                     [round(x + 1.6, 1), round(y - 1, 1)],
                     [round(x + 1.6, 1), round(y, 1)],
                     [round(x, 1), round(y, 1)]]],
    } for i, (x, y) in enumerate(spots)]


def main():
    raw = json.load(open(RAW, encoding="utf-8"))
    props = []
    for p in raw["pitches"]:
        name = p["name"]
        if name in SKIP or not name.startswith("星天苑") and not name.startswith("云天苑"):
            continue
        xs = [q[0] for q in p["pts"]]
        ys = [q[1] for q in p["pts"]]
        minx, maxx, miny, maxy = min(xs), max(xs), min(ys), max(ys)
        tag = name
        north = fence_row(minx, maxx, miny - 0.35, tag + "北")
        south = fence_row(minx, maxx, maxy + 0.6, tag + "南")
        tow = towers(minx, maxx, miny, maxy, tag)
        print("  %-12s bbox %.0fx%.0f 格   围网 %d+%d 段   灯 %d 根" % (
            name, maxx - minx, maxy - miny, len(north), len(south), len(tow)))
        props.extend(north + south + tow)

    json.dump(props, open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("\n共 %d 条 props" % len(props))


if __name__ == "__main__":
    main()
