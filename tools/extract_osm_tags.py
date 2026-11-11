#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从原始 OSM 补回被 parse_osm.py 压掉的标签，产出独立的 assets/osm_tags.json。

为什么需要这个文件
------------------
`sxgd-tiled-vertion/tools/parse_osm.py` 生成的 `src/data.js` 只保留了：
  · r:[ 73 条道路折线（第 2 项虽是 highway 值，但 road_net.py 视而不见）
  · l:[ 加工后的 landuse/leisure 分类
  · b:/w:/p: 建筑、水域、POI
丢失的：OSM id、relation 的 outer/inner 角色、oneway / lanes / bridge / layer、
landuse 与 natural 的**原始**值、building:levels，以及被 `:250` 长路过滤丢掉的
9 条真实干道（含全部 trunk/secondary/tertiary/path 和仅有的 2 条 lanes）。

本脚本直读 `data/map.osm`，用 `tools/pitches_raw.json` 已拟合好的变换把经纬度
换算成 424×800 格坐标，产出**独立**的 `assets/osm_tags.json`。

铁律（改动前先读）
------------------
  · 四个输入全部只读；**绝不写** world.json / roads_src.json / data.js / map.osm /
    assets/ground/* / _ground_src/*。本脚本不产出任何贴图、不改任何 .gd。
  · 绝不重跑 parse_osm.py（会覆盖 data.js，丢掉手工补的教学东楼镜像、
    图书馆/海天苑 multipolygon 等数据）。
  · kept/dropped 以 `data.js r:[` 的实际 73 条产物（等价 roads_src.json）为准，
    通过「名字 + 几何」反推，不复刻 `:250` 的 diag 阈值（那个 diag 依赖过滤后的
    命名建筑 + 水域 + 球场 scope，硬复刻易偏，且没有必要）。
  · 只有 status=matched && confidence=high && in_bounds 的条目才允许被下游
    road_net.py 用来覆盖分级；其余一律回退。

用法
----
    python tools/extract_osm_tags.py --check      # 只解析+自检+打印报告，绝不写文件
    python tools/extract_osm_tags.py              # 生成 assets/osm_tags.json
    python tools/extract_osm_tags.py              # 再跑一次 → unchanged（幂等）
    python tools/extract_osm_tags.py --force      # 内容变化时允许覆盖
"""
import argparse
import hashlib
import json
import math
import os
import sys
import unicodedata
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

DEFAULT_OSM = os.path.normpath(os.path.join(
    ROOT, "..", "sxgd-tiled-vertion", "data", "map.osm"))
DEFAULT_TRANSFORM = os.path.join(HERE, "pitches_raw.json")
DEFAULT_ROADS = os.path.join(ROOT, "assets", "roads_src.json")
DEFAULT_WORLD = os.path.join(ROOT, "assets", "world.json")
DEFAULT_OUT = os.path.join(ROOT, "assets", "osm_tags.json")
DEFAULT_DATA_JS = os.path.normpath(os.path.join(
    ROOT, "..", "sxgd-tiled-vertion", "src", "data.js"))

W, H = 424, 800
SEED = 20261110
MATCH_T, AMBIG_T = 1.0, 3.0
ZONE_KEYS = ("landuse", "natural", "amenity", "leisure", "water")
ABSENT_KEYS = ("surface", "maxspeed", "width", "height",
               "waterway", "sport", "access")

# 真源基线：任一不符即说明源文件被换过，停止生成而不是默默产出错误数据。
BASELINE_MD5 = {
    "world.json": "2219c0365ce46119e60d17d6bf986a37",
    "roads_src.json": "23bd27c28cf6253ffe5cb192ce0144b7",
    "map.osm": "9bc5c4a0cc9b72f33969cebabae38bc4",
    "data.js": "12d9c378ec41fbb8a4bff89e81d1f62d",
}
EXPECTED_HW = {
    "secondary": 2, "trunk": 2, "residential": 67,
    "unclassified": 5, "tertiary": 1, "service": 4, "path": 1,
}
EXPECTED_UNMATCHED_BUILDINGS = [
    "为国铸剑", "无名建筑",
    "海天苑大楼·东楼", "海天苑大楼·中楼", "海天苑大楼·北楼",
    "海天苑大楼·南楼", "海天苑大楼·西楼",
    "翱翔学生中心", "翱翔游泳馆",
]


# ------------------------------------------------------------------ 基础工具
def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def norm(s):
    """名字归一化：NFKC + 去所有空白。中文路名重名靠几何再分。"""
    s = unicodedata.normalize("NFKC", s or "").strip()
    return "".join(c for c in s if not c.isspace())


def tags_of(el):
    return {t.get("k"): t.get("v") for t in el.findall("tag")}


def rlen(pts):
    return sum(math.dist(pts[k], pts[k + 1]) for k in range(len(pts) - 1))


def bbox(pts):
    if not pts:
        return [0.0, 0.0, 0.0, 0.0]
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return [round(min(xs), 1), round(min(ys), 1),
            round(max(xs), 1), round(max(ys), 1)]


def in_bounds(pts):
    return bool(pts) and all(0.0 <= x <= W and 0.0 <= y <= H for x, y in pts)


def pt_seg(p, a, b):
    """点到线段距离。与 road_net.py:133-139 的 _pt_seg 同义。"""
    dx, dy = b[0] - a[0], b[1] - a[1]
    L2 = dx * dx + dy * dy
    t = 0.0 if L2 == 0 else max(0.0, min(1.0, (
        (p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / L2))
    return math.hypot(p[0] - (a[0] + dx * t), p[1] - (a[1] + dy * t))


def polyline_dist(P, Q):
    """对称平均点-线距离：对两条折线点数不同、端点不齐不敏感。"""
    def one(A, B):
        if not A or not B:
            return 1e9
        if len(B) == 1:
            return sum(math.dist(p, B[0]) for p in A) / len(A)
        ds = [min(pt_seg(p, B[k], B[k + 1]) for k in range(len(B) - 1))
              for p in A]
        return sum(ds) / len(ds)
    if not P or not Q:
        return 1e9
    return (one(P, Q) + one(Q, P)) / 2.0


def center(bb):
    return ((bb[0] + bb[2]) / 2.0, (bb[1] + bb[3]) / 2.0)


def blank_match(reason=""):
    return {"status": "unmatched", "roads_src_index": None, "method": "none",
            "dist_grid": None, "confidence": "none", "reason": reason}


# ------------------------------------------------------------------ OSM 解析
def parse_osm(path, transform_path):
    root = ET.parse(path).getroot()
    b = root.find("bounds")
    clat = (float(b.get("minlat")) + float(b.get("maxlat"))) / 2.0
    clon = (float(b.get("minlon")) + float(b.get("maxlon"))) / 2.0
    mperlat = 110540.0
    mperlon = 111320.0 * math.cos(math.radians(clat))

    nodes = {}
    for n in root.findall("node"):
        nodes[n.get("id")] = (
            (float(n.get("lon")) - clon) * mperlon,
            -(float(n.get("lat")) - clat) * mperlat,
        )

    with open(transform_path, encoding="utf-8") as f:
        tr = json.load(f)["transform"]
    s, ox, oy = float(tr["s"]), float(tr["ox"]), float(tr["oy"])

    def to_grid(m):
        return (round(s * m[0] + ox, 1), round(s * m[1] + oy, 1))

    ways = []
    for w in root.findall("way"):
        tags = tags_of(w)
        pts_m = [nodes[nd.get("ref")] for nd in w.findall("nd")
                 if nd.get("ref") in nodes]
        ways.append({
            "id": w.get("id"), "tags": tags, "pts_m": pts_m,
            "pts_grid": [to_grid(p) for p in pts_m],
        })

    relations = []
    for rel in root.findall("relation"):
        members = [(m.get("type"), m.get("ref"), m.get("role") or "outer")
                   for m in rel.findall("member")]
        relations.append({
            "id": rel.get("id"), "tags": tags_of(rel), "members": members,
        })

    counts = {
        "node": len(root.findall("node")),
        "way": len(ways),
        "relation": len(relations),
        "tag_keys": len({k for el in root.iter()
                         if el.tag in ("node", "way", "relation")
                         for k in tags_of(el)}),
    }
    return {"ways": ways, "relations": relations, "counts": counts,
            "transform": {"s": s, "ox": ox, "oy": oy}}


# ------------------------------------------------------------------ 匹配
def match_roads(roads, src):
    """L1 有名分组贪心 → L2 无名几何最近 → 剩余标 unmatched。"""
    claimed_src = set()
    for r in roads:
        r["match"] = blank_match()

    # L1：同名组内按最小几何距离一对一配对
    src_named = {}
    osm_named = {}
    for i, s in enumerate(src):
        if norm(s.get("name")):
            src_named.setdefault(norm(s["name"]), []).append(i)
    for i, r in enumerate(roads):
        if norm(r["name"]):
            osm_named.setdefault(norm(r["name"]), []).append(i)

    for key in sorted(set(src_named) & set(osm_named)):
        oi, si = osm_named[key], src_named[key]
        if len(oi) != len(si):
            for i in oi:
                roads[i]["match"]["reason"] = "同名组数量不等，避免误配"
                roads[i]["match"]["status"] = "ambiguous"
            continue
        pairs = sorted(
            ((polyline_dist(roads[i]["grid_polyline"], src[j]["pts"]), i, j)
             for i in oi for j in si), key=lambda t: (t[0], t[1], t[2]))
        used_o, used_s = set(), set()
        for d, i, j in pairs:
            if i in used_o or j in used_s:
                continue
            if d >= MATCH_T:
                continue
            used_o.add(i)
            used_s.add(j)
            claimed_src.add(j)
            roads[i]["match"] = {
                "status": "matched", "roads_src_index": j,
                "method": "name+geometry", "dist_grid": round(d, 3),
                "confidence": "high", "reason": "",
            }
        for i in oi:
            if i not in used_o:
                roads[i]["match"]["status"] = "ambiguous"
                roads[i]["match"]["reason"] = "同名组内几何距离过大"
        for j in si:
            if j not in used_s:
                claimed_src.add(j)     # 占住，避免 L2 再抢

    # L2：剩余全量按几何距离贪心（含无名 + L1 未认领）
    cand = []
    for i, r in enumerate(roads):
        if r["match"]["status"] == "matched":
            continue
        for j, s in enumerate(src):
            if j in claimed_src:
                continue
            d = polyline_dist(r["grid_polyline"], s["pts"])
            if d < AMBIG_T:
                cand.append((d, i, j))
    cand.sort(key=lambda t: (t[0], t[1], t[2]))
    used_o = {i for i, r in enumerate(roads) if r["match"]["status"] == "matched"}
    for d, i, j in cand:
        if i in used_o or j in claimed_src:
            continue
        if roads[i]["match"]["status"] == "matched":
            continue
        used_o.add(i)
        claimed_src.add(j)
        roads[i]["match"] = {
            "status": "matched", "roads_src_index": j, "method": "geometry",
            "dist_grid": round(d, 3),
            "confidence": "high" if d < MATCH_T else "medium",
            "reason": "" if d < MATCH_T else "距离 1~3 格，仅记录不用于覆盖分级",
        }

    unclaimed_src = [j for j in range(len(src)) if j not in claimed_src]
    return unclaimed_src


def match_buildings(osm_buildings, world_buildings):
    """OSM 建筑（way + MP relation）按名字精确匹配 world.json 的 58 栋。

    名字是唯一可靠键：world.json 是 data.js 之后又手工调整过的产物，
    其中海天苑学生宿舍 1/2 号楼、留学生公寓的 box 与 OSM multipolygon
    轮廓中心有 3~13 格偏移。这类仍按名字认领，但 confidence 降为 medium
    并在 reason 写明，后续视觉阶段应回退 world.json 自带 poly/box。
    """
    matched_world = set()
    for b in osm_buildings:
        b["match"] = {"status": "unmatched", "world_building": None,
                      "dist_grid": None, "confidence": "none", "reason": ""}
        key = norm(b["name"])
        if not key:
            b["match"]["reason"] = "OSM 无名字"
            continue
        hit = None
        for wi, wb in enumerate(world_buildings):
            if norm(wb.get("name")) == key:
                hit = (wi, wb)
                break
        if hit is None:
            b["match"]["reason"] = "world.json 无同名建筑"
            continue
        wi, wb = hit
        if wi in matched_world:
            b["match"]["status"] = "ambiguous"
            b["match"]["reason"] = "同名 world 建筑已被另一 OSM 实体认领"
            continue
        d = math.dist(center(b["bbox_grid"]), center([
            wb["box"]["minx"], wb["box"]["miny"],
            wb["box"]["maxx"], wb["box"]["maxy"]]))
        matched_world.add(wi)
        if d < 1.0:
            conf, reason = "high", ""
        elif d < 20.0:
            conf = "medium"
            reason = ("world.json box 与 OSM 轮廓中心偏 %.1f 格（历史手工调整）；"
                      "按名字认领，视觉阶段回退 world.json poly/box" % d)
        else:
            conf = "low"
            reason = ("几何偏移 %.1f 格过大，仅按名字认领，不用于几何用途" % d)
        b["match"] = {"status": "matched", "world_building": wb.get("name"),
                      "dist_grid": round(d, 3), "confidence": conf,
                      "reason": reason}
    unmatched_world = [
        {"index": i, "name": wb.get("name", "")}
        for i, wb in enumerate(world_buildings) if i not in matched_world
    ]
    return unmatched_world


# ------------------------------------------------------------------ 组装
def build_document(args):
    osm = parse_osm(args.osm, args.transform)
    src = json.load(open(args.roads, encoding="utf-8"))
    world = json.load(open(args.world, encoding="utf-8"))
    ways = osm["ways"]
    relations = osm["relations"]
    ways_by_id = {w["id"]: w for w in ways}

    all_tags = {}
    for el_tags in [w["tags"] for w in ways] + [r["tags"] for r in relations]:
        for k, v in el_tags.items():
            all_tags.setdefault(k, []).append(v)

    # ---- roads：82 条 highway
    roads = []
    for w in ways:
        t = w["tags"]
        if "highway" not in t:
            continue
        g = [list(p) for p in w["pts_grid"]]
        roads.append({
            "osm_way_id": w["id"],
            "name": t.get("name") or "",
            "name_norm": norm(t.get("name")),
            "highway": t["highway"],
            "oneway": t.get("oneway"),
            "lanes": t.get("lanes"),
            "bridge": t.get("bridge"),
            "layer": t.get("layer"),
            "extra_tags": {k: t[k] for k in sorted(t)},
            "length_m": round(rlen(w["pts_m"]), 1),
            "grid_polyline": g,
            "bbox_grid": bbox(g),
            "in_bounds": in_bounds(g),
            "parse_osm_dropped": False,   # 由下面的匹配结果反推
        })
    roads.sort(key=lambda r: int(r["osm_way_id"]))
    unclaimed_src = match_roads(roads, src)

    dropped_ids = []
    for r in roads:
        m = r["match"]
        if m["status"] != "matched" or m["roads_src_index"] is None:
            r["parse_osm_dropped"] = True
            dropped_ids.append(r["osm_way_id"])
            if not m["reason"]:
                m["reason"] = "不在 data.js r:[ 的 73 条内（parse_osm.py 长路过滤）"

    # ---- zones：分区原始标签（稀疏；boundary 成员 way 排除）
    boundary_member_ids = set()
    for rel in relations:
        if rel["tags"].get("type") == "boundary":
            for typ, ref, _ in rel["members"]:
                if typ == "way":
                    boundary_member_ids.add(ref)

    zones = []
    for w in ways:
        if w["id"] in boundary_member_ids:
            continue
        t = w["tags"]
        hits = [k for k in ZONE_KEYS if k in t]
        if not hits:
            continue
        g = [list(p) for p in w["pts_grid"]]
        if len(g) < 3:
            continue
        for k in hits:
            zones.append({
                "osm_ref": "way/%s" % w["id"], "element": "way",
                "tag_key": k, "tag_value": t[k],
                "name": t.get("name") or "",
                "zone_tags": {kk: t[kk] for kk in sorted(t) if kk in ZONE_KEYS},
                "grid_polyline": g,
                "bbox_grid": bbox(g), "in_bounds": in_bounds(g),
            })
    zones.sort(key=lambda z: (int(z["osm_ref"].split("/")[1]), z["tag_key"]))

    # ---- relations：MP 存完整环；boundary 只存成员 id（51/40/20 条，避免 inflate）
    rel_out = []
    inner_refs = []
    for rel in relations:
        t = rel["tags"]
        typ = t.get("type", "")
        is_boundary = typ == "boundary"
        outer, inner = [], []
        for mtyp, ref, role in rel["members"]:
            if mtyp != "way" or ref not in ways_by_id:
                continue
            w = ways_by_id[ref]
            item_ref = {"osm_way_id": ref, "role": role}
            if is_boundary:
                item_ref["grid_polyline"] = None    # 行政边界不进分区/不做几何
            else:
                item_ref["grid_polyline"] = [list(p) for p in w["pts_grid"]]
            (inner if role == "inner" else outer).append(item_ref)
            if role == "inner":
                inner_refs.append("%s:inner" % rel["id"])
        all_g = [p for m in outer + inner if m["grid_polyline"]
                 for p in m["grid_polyline"]]
        rel_out.append({
            "osm_relation_id": rel["id"], "type": typ,
            "name": t.get("name") or "",
            "tags": {k: t[k] for k in sorted(t)},
            "outer": outer, "inner": inner,
            "bbox_grid": bbox(all_g), "in_bounds": in_bounds(all_g),
            "match": {"status": "unmatched", "world_building": None,
                      "confidence": "none",
                      "reason": "行政边界，非校园几何" if is_boundary else ""},
        })
    rel_out.sort(key=lambda r: int(r["osm_relation_id"]))

    # ---- buildings：OSM building way + MP relation（outer 拼环）→ world.json 58 栋
    osm_buildings = []
    for w in ways:
        t = w["tags"]
        if "building" not in t or len(w["pts_grid"]) < 3:
            continue
        g = [list(p) for p in w["pts_grid"]]
        osm_buildings.append({
            "osm_ref": "way/%s" % w["id"], "name": t.get("name") or "",
            "grid_polyline": g, "bbox_grid": bbox(g),
        })
    for rel in rel_out:
        t = rel["tags"]
        if rel["type"] != "multipolygon":
            continue
        if not (t.get("building") or t.get("amenity") in
                ("library", "school", "university", "college")):
            continue
        g = [p for m in rel["outer"] if m["grid_polyline"]
             for p in m["grid_polyline"]]
        if len(g) < 3:
            continue
        osm_buildings.append({
            "osm_ref": "relation/%s" % rel["osm_relation_id"],
            "name": rel["name"], "grid_polyline": g,
            "bbox_grid": bbox(g),
            "relation_outer_count": len(rel["outer"]),
        })
    osm_buildings.sort(key=lambda b: (b["osm_ref"].split("/")[0],
                                      int(b["osm_ref"].split("/")[1])))
    unmatched_world = match_buildings(osm_buildings, world["buildings"])

    # relation 级的建筑名匹配（用于 relations[].match）
    world_names = {norm(b.get("name")): b.get("name")
                   for b in world["buildings"]}
    for rel in rel_out:
        if rel["type"] != "multipolygon":
            continue
        key = norm(rel["name"])
        if key and key in world_names:
            rel["match"] = {"status": "matched",
                            "world_building": world_names[key],
                            "confidence": "high", "reason": ""}

    # ---- unmatched 汇总
    unmatched = {
        "roads_src_indices": unclaimed_src,
        "osm_way_ids": sorted(dropped_ids, key=int),
        "world_building_names": [x["name"] for x in unmatched_world],
        "world_building_indices": [x["index"] for x in unmatched_world],
        "relation_ids": sorted(
            [r["osm_relation_id"] for r in rel_out if r["type"] == "boundary"]
            + inner_refs),
        "notes": [
            "9 条 dropped 长路被 parse_osm.py:250 的 rlen>diag*0.55 过滤，"
            "含全部 trunk/secondary/tertiary/path 与仅有的 2 条 lanes；"
            "仅作参考层，绝不写进 roads_src.json / world.json。",
            "3 个 boundary relation 是行政边界，member way 不进 zones。",
            "军工素质教育实践中心的 inner 成员单独存 relations[].inner，"
            "不参与轮廓拼接。",
            "9 栋 world.json 建筑在 OSM 无同名实体（手工补建或改名拆分），"
            "后续视觉阶段回退 world.json 自带 poly/box，不猜测。",
        ],
    }

    hw = {}
    for r in roads:
        hw[r["highway"]] = hw.get(r["highway"], 0) + 1
    counts = dict(osm["counts"])
    counts.update({
        "highway_ways": len(roads),
        "highway_kept": len(roads) - len(dropped_ids),
        "highway_dropped": len(dropped_ids),
        "lanes": len(all_tags.get("lanes", [])),
        "building_levels": len(all_tags.get("building:levels", [])),
        "oneway": len(all_tags.get("oneway", [])),
        "landuse": len(all_tags.get("landuse", [])),
        "natural": len(all_tags.get("natural", [])),
        "amenity": len(all_tags.get("amenity", [])),
        "leisure": len(all_tags.get("leisure", [])),
        "water": len(all_tags.get("water", [])),
        "bridge": len(all_tags.get("bridge", [])),
        "layer": len(all_tags.get("layer", [])),
        "highway_by_value": {k: hw.get(k, 0) for k in sorted(hw)},
    })
    for k in ABSENT_KEYS:
        counts[k] = len(all_tags.get(k, []))

    doc = {
        "meta": {
            "schema": "osm_tags/v1",
            "source_osm": "../sxgd-tiled-vertion/data/map.osm",
            "source_md5": md5(args.osm),
            "transform": osm["transform"],
            "transform_source": "tools/pitches_raw.json",
            "generated_by": "tools/extract_osm_tags.py",
            "seed": SEED,
            "world": {"W": W, "H": H, "TS": 8},
            "filter_rule": (
                "parse_osm.py:250 丢弃 rlen(pts)>diag*0.55 的 highway；"
                "本文件以 data.js r:[ 的实际 73 条产物（roads_src.json）为准，"
                "用名字+几何反推 kept/dropped，不复刻 diag 阈值。"),
            "counts": counts,
        },
        "roads": roads,
        "zones": zones,
        "relations": rel_out,
        "buildings": osm_buildings,
        "unmatched": unmatched,
    }
    return doc, src, world, all_tags


# ------------------------------------------------------------------ 自检
def self_check(doc, src, world, all_tags, args):
    errs = []

    def need(cond, msg):
        if not cond:
            errs.append(msg)

    c = doc["meta"]["counts"]
    need((c["node"], c["way"], c["relation"], c["tag_keys"]) ==
         (2405, 182, 9, 56), "OSM 元素数/标签种类基线不符：%s" %
         str((c["node"], c["way"], c["relation"], c["tag_keys"])))
    need(c["highway_ways"] == 82, "highway 应为 82 条，实为 %d" % c["highway_ways"])
    need(c["highway_by_value"] == EXPECTED_HW,
         "highway 值分布不符：%s" % c["highway_by_value"])
    need(c["highway_kept"] == 73 and c["highway_dropped"] == 9,
         "kept/dropped 应为 73/9，实为 %d/%d" %
         (c["highway_kept"], c["highway_dropped"]))
    need(len(src) == 73, "roads_src.json 应为 73 条，实为 %d" % len(src))
    need(len(world["buildings"]) == 58, "world.json 楼数应为 58")

    need(c["lanes"] == 2, "lanes 应为 2，实为 %d" % c["lanes"])
    lanes_roads = [r for r in doc["roads"] if r["lanes"] is not None]
    need(len(lanes_roads) == 2 and all(
        r["highway"] == "trunk" and r["parse_osm_dropped"] for r in lanes_roads),
        "2 条 lanes 应全部属于被过滤的 trunk")
    need(c["building_levels"] == 1, "building:levels 应为 1，实为 %d" %
         c["building_levels"])
    lv = [w for w in all_tags.get("building:levels", [])]
    need(lv == ["6"], "building:levels 值应为 6，实为 %s" % lv)
    for k in ABSENT_KEYS:
        need(c[k] == 0, "标签 %s 本应不存在，实为 %d 条" % (k, c[k]))

    need(doc["unmatched"]["roads_src_indices"] == [],
         "roads_src 有未认领条目：%s" % doc["unmatched"]["roads_src_indices"])
    need(len(doc["unmatched"]["osm_way_ids"]) == 9,
         "dropped 应为 9 条，实为 %d" % len(doc["unmatched"]["osm_way_ids"]))
    need(sorted(doc["unmatched"]["world_building_names"]) ==
         sorted(EXPECTED_UNMATCHED_BUILDINGS),
         "9 栋手工楼名单不符：%s" % doc["unmatched"]["world_building_names"])
    need(len(doc["unmatched"]["relation_ids"]) == 4,
         "unmatched relation 应为 3 个 boundary + 1 个 inner，实为 %s" %
         doc["unmatched"]["relation_ids"])

    dropped_types = {r["highway"] for r in doc["roads"] if r["parse_osm_dropped"]}
    need({"trunk", "secondary", "tertiary", "path"} <= dropped_types,
         "被过滤的 9 条应含全部 trunk/secondary/tertiary/path，实为 %s" %
         dropped_types)

    matched = [r for r in doc["roads"] if r["match"]["status"] == "matched"]
    need(len(matched) == 73, "matched 应为 73 条，实为 %d" % len(matched))
    for r in matched:
        d = r["match"]["dist_grid"]
        need(d is not None and d < MATCH_T,
             "way %s 匹配残差 %.3f ≥1 格" % (r["osm_way_id"], d or 0))
    for r in doc["roads"]:
        if r["parse_osm_dropped"]:
            d = r["match"]["dist_grid"]
            need(d is None or d > 10.0,
                 "dropped way %s 距离 %.3f 异常偏小" %
                 (r["osm_way_id"], d or 0))

    seen = set()
    for r in matched:
        j = r["match"]["roads_src_index"]
        need(j not in seen, "roads_src[%d] 被重复认领" % j)
        seen.add(j)

    # 坐标：有限数 + 宽松包围盒（实测 11/73 条有界外点，不硬断言全在 424×800）
    for group in ("roads", "zones", "relations", "buildings"):
        for item in doc[group]:
            pts = item.get("grid_polyline") or [
                p for m in item.get("outer", []) + item.get("inner", [])
                if m.get("grid_polyline") for p in m["grid_polyline"]]
            for x, y in pts:
                need(math.isfinite(x) and math.isfinite(y),
                     "%s 出现非有限坐标" % group)
                need(-1000 <= x <= 1500 and -3000 <= y <= 2500,
                     "%s 坐标越出宽松盒：(%s,%s)" % (group, x, y))

    # 源文件基线（证明本脚本没写坏任何输入）
    actual = {
        "world.json": md5(args.world),
        "roads_src.json": md5(args.roads),
        "map.osm": md5(args.osm),
        "data.js": md5(args.data_js) if os.path.exists(args.data_js) else "",
    }
    for k, v in BASELINE_MD5.items():
        need(actual[k] == v, "%s 哈希变了：%s（基线 %s）" % (k, actual[k], v))

    return errs, actual


# ------------------------------------------------------------------ main
def main():
    ap = argparse.ArgumentParser(description="从原始 OSM 补回标签数据")
    ap.add_argument("--osm", default=DEFAULT_OSM)
    ap.add_argument("--transform", default=DEFAULT_TRANSFORM)
    ap.add_argument("--roads", default=DEFAULT_ROADS)
    ap.add_argument("--world", default=DEFAULT_WORLD)
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--data-js", default=DEFAULT_DATA_JS)
    ap.add_argument("--check", action="store_true",
                    help="只解析+自检+打印报告，绝不写文件")
    ap.add_argument("--force", action="store_true",
                    help="输出内容变化时允许覆盖")
    args = ap.parse_args()

    doc, src, world, all_tags = build_document(args)
    errs, actual = self_check(doc, src, world, all_tags, args)

    c = doc["meta"]["counts"]
    print("[osm_tags] highway %d 条（kept %d / dropped %d），zones %d，"
          "relations %d，buildings %d" %
          (c["highway_ways"], c["highway_kept"], c["highway_dropped"],
           len(doc["zones"]), len(doc["relations"]), len(doc["buildings"])))
    print("[osm_tags] 未认领 roads_src %d 条，9 栋手工楼 %s" %
          (len(doc["unmatched"]["roads_src_indices"]),
           len(doc["unmatched"]["world_building_names"])))
    print("[osm_tags] 输入哈希：world=%s roads_src=%s osm=%s data.js=%s" %
          (actual["world.json"][:8], actual["roads_src.json"][:8],
           actual["map.osm"][:8], actual["data.js"][:8]))

    if errs:
        print("[osm_tags] 自检失败 %d 项：" % len(errs), file=sys.stderr)
        for e in errs:
            print("  - " + e, file=sys.stderr)
        raise SystemExit(1)
    print("[osm_tags] 自检通过")

    if args.check:
        print("[osm_tags] --check 模式，未写任何文件")
        return

    if os.path.exists(args.out):
        with open(args.out, encoding="utf-8") as f:
            try:
                old = json.load(f)
            except ValueError:
                old = None
        if old == doc:
            print("[osm_tags] unchanged，%s 未改动" % os.path.basename(args.out))
            return
        if not args.force:
            print("[osm_tags] %s 已存在且内容不同；需 --force 才覆盖"
                  % args.out, file=sys.stderr)
            raise SystemExit(2)
        print("[osm_tags] --force 覆盖已有文件")

    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print("[osm_tags] 已写出 %s（%d B）" %
          (args.out, os.path.getsize(args.out)))


if __name__ == "__main__":
    main()
