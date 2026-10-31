#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 OSM 原始数据提取运动场地轮廓，换算成 world.json 的格坐标。

坐标换算不去复刻 parse_osm.py 的 scope 逻辑（那个依赖中间数据），
而是用「同名建筑的 bbox 中心」做最小二乘拟合，误差可控、可验证。
"""
import json
import math
import os
import sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
OSM = os.path.join(HERE, "..", "..", "sxgd-tiled-vertion", "data", "map.osm")
WORLD = os.path.join(HERE, "..", "assets", "world.json")


def load_osm(path):
    root = ET.parse(path).getroot()
    b = root.find("bounds")
    clat = (float(b.get("minlat")) + float(b.get("maxlat"))) / 2
    clon = (float(b.get("minlon")) + float(b.get("maxlon"))) / 2
    mperlat = 110540.0
    mperlon = 111320.0 * math.cos(math.radians(clat))

    nodes = {}
    for n in root.findall("node"):
        nodes[n.get("id")] = (
            (float(n.get("lon")) - clon) * mperlon,
            -(float(n.get("lat")) - clat) * mperlat,
        )

    ways = []
    for w in root.findall("way"):
        tags = {t.get("k"): t.get("v") for t in w.findall("tag")}
        pts = [nodes[nd.get("ref")] for nd in w.findall("nd") if nd.get("ref") in nodes]
        if len(pts) >= 3:
            ways.append({"tags": tags, "pts": pts})
    return ways


def centroid(pts):
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2


def main():
    ways = load_osm(OSM)
    world = json.load(open(WORLD, encoding="utf-8"))

    osm_by_name = {}
    for w in ways:
        nm = w["tags"].get("name")
        if nm and (w["tags"].get("building") or w["tags"].get("leisure")):
            osm_by_name.setdefault(nm, w)

    pairs = []
    for b in world["buildings"]:
        nm = b.get("name", "")
        w = osm_by_name.get(nm)
        if not w:
            continue
        box = b["box"]
        gx = (box["minx"] + box["maxx"]) / 2
        gy = (box["miny"] + box["maxy"]) / 2
        mx, my = centroid(w["pts"])
        pairs.append((nm, mx, my, gx, gy))

    print("匹配到 %d 栋（共 %d）" % (len(pairs), len(world["buildings"])))
    if len(pairs) < 4:
        raise SystemExit("同名建筑太少，拟合不可靠")

    # 最小二乘：g = s*m + o（x、y 共用同一个 s，各自独立求 o）
    n = len(pairs)
    mx_ = sum(p[1] for p in pairs) / n
    my_ = sum(p[2] for p in pairs) / n
    gx_ = sum(p[3] for p in pairs) / n
    gy_ = sum(p[4] for p in pairs) / n

    num = sum((p[1] - mx_) * (p[3] - gx_) + (p[2] - my_) * (p[4] - gy_) for p in pairs)
    den = sum((p[1] - mx_) ** 2 + (p[2] - my_) ** 2 for p in pairs)
    s = num / den
    ox = gx_ - s * mx_
    oy = gy_ - s * my_

    errs = [math.hypot(s * p[1] + ox - p[3], s * p[2] + oy - p[4]) for p in pairs]
    print("s=%.6f  ox=%.2f  oy=%.2f" % (s, ox, oy))
    print("残差 平均 %.3f 格，最大 %.3f 格" % (sum(errs) / n, max(errs)))
    for (nm, _, _, _, _), e in sorted(zip(pairs, errs), key=lambda t: -t[1])[:5]:
        print("   %-24s %.3f" % (nm[:22], e))

    # ---- 提取球场 ----
    pitches = [w for w in ways if w["tags"].get("leisure") in ("pitch", "stadium", "sports_centre")]
    print("\n球场/场地 %d 处：" % len(pitches))
    out = []
    for w in pitches:
        nm = w["tags"].get("name") or "(无名)"
        kind = w["tags"].get("leisure")
        sport = w["tags"].get("sport", "")
        pts = [(s * x + ox, s * y + oy) for x, y in w["pts"]]
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        wd, ht = max(xs) - min(xs), max(ys) - min(ys)
        print("   %-14s %-8s %-10s bbox=(%.0f,%.0f) %.0fx%.0f 格" % (
            nm, kind, sport, min(xs), min(ys), wd, ht))
        out.append({"name": nm, "kind": kind, "sport": sport,
                    "pts": [(round(x, 1), round(y, 1)) for x, y in pts]})

    dst = os.path.join(HERE, "pitches_raw.json")
    json.dump({"transform": {"s": s, "ox": ox, "oy": oy}, "pitches": out},
              open(dst, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("\n已写 %s" % dst)


if __name__ == "__main__":
    main()
