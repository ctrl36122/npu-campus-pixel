#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""OSM 路网：读折线 → 定级定宽 → 描边成掩码。

为什么要回到矢量数据：地面图里的路是**烘死**的像素（基本都是 1 格宽、边缘毛糙），
想加宽只能按像素腐蚀/膨胀，宽窄全凭猜，边缘还越弄越糙。
`../sxgd-tiled-vertion/data/map.osm` 经 `parse_osm.py` 生成的
`../sxgd-tiled-vertion/src/data.js` 里保留了 73 条道路折线（含路名），
实测按 `px = 格 × 8` 画回去有 99.7% 的点落在现有路面内 —— 当年地面图就是拿
这批折线烘的，坐标系完全一致。

有了中心线就能：
  · 按长度分级定宽（主干道 / 次干道 / 步道），同一条路从头到尾一样宽，
    不会像腐蚀法那样在路口鼓包；
  · 用矢量线画边，边缘是干净的斜线，而不是像素级的锯齿；
  · 主干道能在正中画虚线中线（有中心线才谈得上「车道」）。

折线单位是**格**（W=424, H=800），乘 CELL 得像素。
"""
import json
import math
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA_JS = os.path.abspath(os.path.join(ROOT, "..", "sxgd-tiled-vertion", "src", "data.js"))
CACHE = os.path.join(ROOT, "assets", "roads_src.json")

CELL = 8
WORLD_W, WORLD_H = 3392, 6400

# ---- 分级：按道路长度（格）。73 条全是 residential / service，没有
#      highway=primary 这类标签可用，只能拿长度当重要性代理。
MAIN_LEN = 300          # ≥300 格（≈840 m）→ 主干道
SEC_LEN = 120           # ≥120 格 → 次干道，其余步道
W_MAIN, W_SEC, W_PATH = 40, 22, 16     # 铺装宽度（px），8 px = 1 格；主干道 5 格 ≈ 14 m

# ---- 真实 OSM highway 分级（可选模式，默认不启用）----------------------
# 见 assets/osm_tags.json：脚本 tools/extract_osm_tags.py 从原始 map.osm 补回了
# OSM id / oneway / lanes / 分区原始标签 / 9 条被过滤的长路。
# 注意：data.js 的 r:[ 第 2 项本来就是 highway 值，只是上面的长度分级忽略了它。
# 73 条里真实 highway 只有 residential(66) / unclassified(3) / service(4)，
# 按真实分级会得到 cls 0/69/4，而长度分级是 7/29/37 —— 会让主干道变窄、
# dash_segments() 不再画任何白虚线中线。所以**默认仍是长度分级**，
# 只有显式 mode='osm' / ROAD_NET_MODE=osm 才切换，仅供对比与后续数据消费。
OSM_TAGS = os.path.join(ROOT, "assets", "osm_tags.json")
HIGHWAY_TO_CLS = {
    "trunk": 2, "primary": 2, "secondary": 2,
    "tertiary": 1, "residential": 1, "unclassified": 1,
    "service": 0, "path": 0, "footway": 0, "pedestrian": 0,
}
HIGHWAY_TO_W = {2: W_MAIN, 1: W_SEC, 0: W_PATH}


def _parse_js(path):
    """从 data.js 里抠出 r:[ ["名字","类型",[x,y,x,y,...]], ... ]。"""
    s = open(path, encoding="utf-8").read()
    i = s.index(",r:[") + 4
    j = s.index("],w:[", i)
    out = []
    for name, typ, pts in re.findall(r'\["([^"]*)","([^"]*)",\[([^\]]*)\]\]', s[i:j]):
        v = [float(t) for t in pts.split(",")]
        out.append({
            "name": name,
            "type": typ,
            "pts": [[v[k], v[k + 1]] for k in range(0, len(v) - 1, 2)],
        })
    return out


def load(mode=None, osm_tags_path=OSM_TAGS):
    """折线 + 长度 + 宽度等级。优先读缓存 assets/roads_src.json。

    mode 缺省读环境变量 ROAD_NET_MODE，**默认 'length'**：与改动前逐字节等价，
    不读 osm_tags.json、不 import 新模块、不增删字段。
    mode='osm' 时叠加按真实 highway 的分级（见 load_from_osm 的说明）。
    bake_roads.py / bake_lamps.py 都不传参，行为完全不变。
    """
    if os.path.exists(CACHE):
        raw = json.load(open(CACHE, encoding="utf-8"))
    else:
        if not os.path.exists(DATA_JS):
            raise SystemExit("[road_net] 找不到 %s" % DATA_JS)
        raw = _parse_js(DATA_JS)
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        with open(CACHE, "w", encoding="utf-8") as f:
            json.dump(raw, f, ensure_ascii=False, indent=0)

    roads = []
    for r in raw:
        pts = [(float(p[0]), float(p[1])) for p in r["pts"]]
        L = sum(math.dist(pts[k], pts[k + 1]) for k in range(len(pts) - 1))
        if L >= MAIN_LEN:
            w, cls = W_MAIN, 2
        elif L >= SEC_LEN:
            w, cls = W_SEC, 1
        else:
            w, cls = W_PATH, 0
        roads.append({"name": r.get("name") or "", "type": r.get("type") or "",
                      "pts": pts, "len": L, "w": w, "cls": cls})

    mode = (mode or os.environ.get("ROAD_NET_MODE", "length")).lower()
    if mode == "osm":
        load_from_osm(roads, osm_tags_path, fallback=True)
    elif mode != "length":
        raise SystemExit("[road_net] 未知 mode=%s（可用 length / osm）" % mode)
    return roads


def load_from_osm(roads, path=OSM_TAGS, fallback=True, min_confidence="high"):
    """按真实 highway 覆盖 w/cls。**只追加字段**，不改 name/type/pts/len、不增减条目。

    数据来源优先级：
      1. osm_tags.json 里 status=matched && confidence>=min_confidence &&
         parse_osm_dropped=false && in_bounds=true 的条目（带 OSM id，可追溯）；
      2. roads_src.json 自带的 type（本来就是 highway 值，只是无 id）；
      3. 都不认识 → 保留 :70-78 的长度分级（fallback）。

    9 条被 parse_osm.py 过滤掉的真实干道只作参考层，**绝不插入新折线**，
    所以本函数返回后道路条数永远等于输入的 73 条。
    """
    if not os.path.exists(path):
        if fallback:
            return roads
        raise SystemExit("[road_net] 找不到 %s，先跑 tools/extract_osm_tags.py" % path)
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError) as e:
        if fallback:
            return roads
        raise SystemExit("[road_net] 读 %s 失败：%s" % (path, e))

    allowed = {"high"} if min_confidence == "high" else {"high", "medium"}
    by_src = {}
    for r in doc.get("roads", []):
        m = r.get("match") or {}
        if (m.get("status") == "matched"
                and m.get("confidence") in allowed
                and not r.get("parse_osm_dropped")
                and r.get("in_bounds")
                and m.get("roads_src_index") is not None):
            by_src[int(m["roads_src_index"])] = r

    for i, road in enumerate(roads):
        src = by_src.get(i)
        hw = (src or {}).get("highway") or road.get("type") or ""
        cls = HIGHWAY_TO_CLS.get(hw)
        road["osm_highway"] = hw
        road["osm_way_id"] = (src or {}).get("osm_way_id")
        if cls is None:
            road["osm_cls"] = None
            road["osm_w"] = None
            road["osm_match"] = "length-fallback"
            continue
        road["osm_cls"] = cls
        road["osm_w"] = HIGHWAY_TO_W[cls]
        road["osm_match"] = "osm_tags" if src else "roads_src.type"
        road["w"] = road["osm_w"]
        road["cls"] = cls
    return roads


def strokes(roads, cls=None, size=(WORLD_W, WORLD_H)):
    """把折线描成掩码。线宽取每条路自己的 w；首尾补圆头，避免接缝处断口。"""
    from PIL import Image, ImageDraw
    m = Image.new("L", size, 0)
    d = ImageDraw.Draw(m)
    for r in roads:
        if cls is not None and r["cls"] != cls:
            continue
        w = r["w"]
        xy = [(x * CELL, y * CELL) for x, y in r["pts"]]
        if len(xy) == 1:
            x, y = xy[0]
            d.ellipse([x - w // 2, y - w // 2, x + w // 2, y + w // 2], fill=255)
            continue
        d.line(xy, fill=255, width=w, joint="curve")
        h = w / 2.0
        for x, y in (xy[0], xy[-1]):
            d.ellipse([x - h, y - h, x + h, y + h], fill=255)
    return m


def sample_grid(roads, step=1.0):
    """把每条路按 1 格步长采样进「格 → 路序号集合」，用来判路口。

    路口 = 该格附近存在**别的**路。虚线中线在路口断开靠它。
    """
    grid = {}
    for idx, r in enumerate(roads):
        pts = r["pts"]
        for k in range(len(pts) - 1):
            (x0, y0), (x1, y1) = pts[k], pts[k + 1]
            seg = math.dist((x0, y0), (x1, y1))
            n = max(1, int(seg / step))
            for q in range(n + 1):
                t = q / n
                key = (int(x0 + (x1 - x0) * t), int(y0 + (y1 - y0) * t))
                grid.setdefault(key, set()).add(idx)
    return grid


def at_junction(grid, x, y, my_idx, gap=2.4):
    r = int(math.ceil(gap))
    xi, yi = int(x), int(y)
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            s = grid.get((xi + dx, yi + dy))
            if s and (len(s) > 1 or my_idx not in s):
                return True
    return False


def _pt_seg(p, a, b):
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    L2 = dx * dx + dy * dy
    t = 0.0 if L2 == 0 else max(0.0, min(1.0, ((p[0] - ax) * dx + (p[1] - ay) * dy) / L2))
    return math.hypot(p[0] - (ax + dx * t), p[1] - (ay + dy * t))


def crowded(road, roads, near=6.0, step=2.0):
    """这条路沿线有多少比例的采样点，6 格内还有**别的**路。

    华山路在 OSM 里被拆成两条平行折线（双向车道），各自都够长、都会被判成主干道；
    两条 26px 的路并排画出来会拼成一条 60px 宽的带子，中间还各有一条白虚线 ——
    看着像高速路。所以「挤」的路不画中线，只当作一条宽路。
    """
    pts = road["pts"]
    hit = tot = 0
    for k in range(len(pts) - 1):
        (x0, y0), (x1, y1) = pts[k], pts[k + 1]
        seg = math.dist((x0, y0), (x1, y1))
        n = max(1, int(seg / step))
        for q in range(n + 1):
            t = q / n
            x, y = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
            tot += 1
            for other in roads:
                if other is road:
                    continue
                op = other["pts"]
                if any(_pt_seg((x, y), op[j], op[j + 1]) < near for j in range(len(op) - 1)):
                    hit += 1
                    break
    return hit / max(1, tot)


def dash_segments(roads, grid, on=1.6, off=2.6, gap=2.4, crowd_frac=0.22):
    """主干道中线虚线（像素坐标段列表）。路口断开，平行双线不画。"""
    segs = []
    period = on + off
    for idx, r in enumerate(roads):
        if r["cls"] != 2:
            continue
        if crowded(r, roads) > crowd_frac:
            continue
        pts = r["pts"]
        acc = 0.0
        for k in range(len(pts) - 1):
            (x0, y0), (x1, y1) = pts[k], pts[k + 1]
            seg = math.dist((x0, y0), (x1, y1))
            if seg < 1e-6:
                continue
            n = max(1, int(seg * 2))
            prev = None
            for q in range(n + 1):
                t = q / n
                x, y = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
                acc += seg / n
                on_dash = (acc % period) < on and not at_junction(grid, x, y, idx, gap)
                if on_dash and prev is not None:
                    segs.append((prev[0] * CELL, prev[1] * CELL, x * CELL, y * CELL))
                prev = (x, y) if on_dash else None
    return segs


if __name__ == "__main__":
    import collections
    import sys
    mode = os.environ.get("ROAD_NET_MODE", "length")
    argv = sys.argv[1:]
    for k, a in enumerate(argv):
        if a.startswith("--mode="):
            mode = a.split("=", 1)[1]
        elif a == "--mode" and k + 1 < len(argv):
            mode = argv[k + 1]
    label = {2: "主干道", 1: "次干道", 0: "步道"}
    rs = load(mode=mode)
    print("道路 %d 条，总长 %.0f 格（mode=%s）" %
          (len(rs), sum(r["len"] for r in rs), mode))
    print("分级", dict(collections.Counter(label[r["cls"]] for r in rs)))
    if mode == "osm":
        old = load(mode="length")
        print("对照 旧长度分级", dict(collections.Counter(label[r["cls"]] for r in old)))
        print("几何一致", len(old) == len(rs) and all(
            a["pts"] == b["pts"] and a["len"] == b["len"]
            and a["type"] == b["type"] for a, b in zip(old, rs)))
