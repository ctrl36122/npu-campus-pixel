#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成图书馆内景数据 assets/rooms/study_space.json。

这一版按「正方形套中间正方形镂空」重做：

   整层 120×120 格（原来 96×38，面积约 4 倍），外墙一圈正方形
   正中 60×60 格是**镂空的中庭**，四边用亮色矮护栏围住、走不进去
   环带里摆 34 张双人自习桌：北 12 / 南 6 / 西 8 / 东 8
   **一张桌的两把椅并排在桌子同一侧**（都朝桌面），不再是南北面对面
   南侧留一整条入口大厅：沙发讨论角、白板、书架、贩卖机、门前地垫
   北墙 8 扇落地窗首尾相接；Room.gd 的 bright 主题保持浅木地板

中庭不是「摆一块地毯」：地板烘焙时在 void 矩形里换成天光色 + 内阴影井壁，
看起来是往中间挖空了一块，而不是又铺了一块地板。

用法：python tools/build_study_room.py
"""

from __future__ import annotations

import io
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "assets", "rooms", "study_space.json")
SKY_MAP = os.path.join(
    os.path.dirname(ROOT), "references", "SkyOffice", "client", "public",
    "assets", "map", "map.tmx",
)

# ── 整层尺度（格）：正方形，面积 120×120 ≈ 原 96×38 的 3.95 倍 ──────────
W, H = 120.0, 120.0
WALL_T = 1.6
ZOOM = 1.2          # 房间太大，镜头不再强行 fit 全屋，保持人物可读

# ── 中间的镂空正方形 ───────────────────────────────────────────────────
VOID_X, VOID_Y, VOID_W = 30.0, 30.0, 60.0
RAIL_T = 1.0

# ── 双人桌（格）：两把椅并排在同侧 ──────────────────────────────────────
TABLE_W, TABLE_H = 9.0, 2.6
SEAT_W, SEAT_H = 2.4, 1.6
SEAT_GAP = 0.4             # 椅子离桌沿的缝
SEAT_PAIR_GAP = 1.2        # 并排两把椅之间的缝
NORTH_COLS = [5.0, 23.0, 41.0, 59.0, 77.0, 95.0]
NORTH_ROWS = [6.0, 17.0]
SOUTH_ROWS = [98.0]
SIDE_W_COLS = [4.0, 16.0]
SIDE_E_COLS = [95.0, 107.0]
SIDE_ROWS = [36.0, 49.0, 62.0, 75.0]

# ── 南墙门洞 ───────────────────────────────────────────────────────────
DOOR_X, DOOR_W = 56.0, 8.0

# ── 南侧入口大厅 / 讨论角 ──────────────────────────────────────────────
LOUNGE_L_X, LOUNGE_R_X = 6.0, 86.0
LOUNGE_Y, LOUNGE_W, LOUNGE_H = 103.0, 28.0, 13.0


def skyoffice_pattern() -> dict:
    """把 SkyOffice 的椅子拓扑记进 source。tmx 在就用真数据，缺了也不拦生成。"""
    if not os.path.isfile(SKY_MAP):
        return {
            "project": "SkyOffice (MIT)", "layer": "Chair",
            "note": "成排开放座位；本机未找到 map.tmx，按文档记录",
        }
    with io.open(SKY_MAP, encoding="utf-8") as f:
        text = f.read()
    block = re.search(r'<objectgroup[^>]*name="Chair"[^>]*>(.*?)</objectgroup>', text, re.S)
    dirs = {"down": 0, "up": 0, "left": 0, "right": 0}
    n = 0
    if block:
        for m in re.finditer(r'name="direction"\s+value="(\w+)"', block.group(1)):
            if m.group(1) in dirs:
                dirs[m.group(1)] += 1
        n = len(re.findall(r"<object\b", block.group(1)))
    return {
        "project": "SkyOffice (MIT)",
        "layer": "Chair",
        "tile_px": 32,
        "objects": n,
        "directions": dirs,
        "note": "取「成排开放座位」的拓扑；本项目改成回字中庭环带 + 一张桌两把椅并排",
    }


def rect(x, y, w, h, **extra):
    d = {"x": round(float(x), 3), "y": round(float(y), 3),
         "w": round(float(w), 3), "h": round(float(h), 3)}
    d.update(extra)
    return d


def overlap(a: dict, b: dict) -> bool:
    return (a["x"] < b["x"] + b["w"] - 1e-6 and b["x"] < a["x"] + a["w"] - 1e-6
            and a["y"] < b["y"] + b["h"] - 1e-6 and b["y"] < a["y"] + a["h"] - 1e-6)


def void_rect() -> dict:
    return rect(VOID_X, VOID_Y, VOID_W, VOID_W)


def table_specs() -> list[tuple[float, float, str]]:
    """(x, y, 组名)。四段环带围着中庭，桌一律横放。"""
    out: list[tuple[float, float, str]] = []
    for ty in NORTH_ROWS:
        for tx in NORTH_COLS:
            out.append((tx, ty, "n"))
    for ty in SOUTH_ROWS:
        for tx in NORTH_COLS:
            out.append((tx, ty, "s"))
    for ty in SIDE_ROWS:
        for tx in SIDE_W_COLS:
            out.append((tx, ty, "w"))
        for tx in SIDE_E_COLS:
            out.append((tx, ty, "e"))
    return out


def build() -> dict:
    src = skyoffice_pattern()
    hole = void_rect()

    # ── 外墙：正方形四边，南墙按门洞切成两段 ────────────────────────────
    walls = [
        rect(0, 0, W, WALL_T),                                   # 北
        rect(0, H - WALL_T, DOOR_X, WALL_T),                     # 南 · 门左
        rect(DOOR_X + DOOR_W, H - WALL_T, W - DOOR_X - DOOR_W, WALL_T),  # 南 · 门右
        rect(0, WALL_T, WALL_T, H - WALL_T * 2),                # 西
        rect(W - WALL_T, WALL_T, WALL_T, H - WALL_T * 2),       # 东
    ]

    props: list[dict] = []
    seats: list[dict] = []
    rugs: list[dict] = []

    # ── 北墙整排落地窗：贴墙内侧、不 solid。只放北墙 —— 南墙在 y-sort 里
    # 比窗更靠下，会把窗整片盖掉。8 扇 15 格首尾相接，不留灰色断口
    for i in range(8):
        props.append(rect(i * 15.0, WALL_T, 15.0, 1.0, k="window"))

    # ── 中庭四边的矮护栏：solid，人走不进镂空区。四段首尾不重叠 ──────────
    vx, vy, vw = VOID_X, VOID_Y, VOID_W
    props += [
        rect(vx, vy, vw, RAIL_T, k="rail", solid=True),                       # 北
        rect(vx, vy + vw - RAIL_T, vw, RAIL_T, k="rail", solid=True),         # 南
        rect(vx, vy + RAIL_T, RAIL_T, vw - RAIL_T * 2, k="rail", solid=True),  # 西
        rect(vx + vw - RAIL_T, vy + RAIL_T, RAIL_T, vw - RAIL_T * 2,
             k="rail", solid=True),                                           # 东
    ]

    # ── 双人自习桌：一桌两椅**并排**在桌子北侧，都面朝桌面（face=down）──
    specs = table_specs()
    for i, (tx, ty, group) in enumerate(specs):
        props.append(rect(tx, ty, TABLE_W, TABLE_H, k="table", solid=True))
        pair_w = SEAT_W * 2.0 + SEAT_PAIR_GAP
        sx0 = tx + (TABLE_W - pair_w) * 0.5
        sy = ty - SEAT_H - SEAT_GAP
        for j in range(2):
            seats.append(rect(sx0 + j * (SEAT_W + SEAT_PAIR_GAP), sy,
                              SEAT_W, SEAT_H,
                              id="study_%s_%02d_%d" % (group, i, j), face="down"))
        # 桌角一小盆绿植，隔一张放一盆，纯装饰不挡路
        if i % 2 == 0:
            props.append(rect(tx + TABLE_W - 1.5, ty + 0.5, 1.2, 1.2, k="plant"))

    # ── 回字四个转角各一株绿植，压住环带的空角 ──────────────────────────
    for cx, cy in ((25.0, 25.0), (92.0, 25.0), (25.0, 92.0), (92.0, 92.0)):
        props.append(rect(cx, cy, 2.0, 2.0, k="plant"))

    # ── 南侧入口大厅：左右两块浅色地毯，中间给门留通道 ───────────────────
    for lx in (LOUNGE_L_X, LOUNGE_R_X):
        rugs.append(rect(lx, LOUNGE_Y, LOUNGE_W, LOUNGE_H))
    # 左侧讨论角
    props += [
        rect(8.0, 105.0, 8.0, 2.6, k="sofa", solid=True),
        rect(10.6, 110.0, 5.0, 2.2, k="table", solid=True),
        rect(8.6, 113.4, 2.0, 1.6, k="cushion"),
        rect(14.0, 113.4, 2.0, 1.6, k="cushion"),
        rect(20.0, 104.0, 7.0, 1.2, k="board"),
        rect(20.0, 108.0, 7.0, 2.2, k="block", solid=True),
        rect(27.0, 108.0, 3.0, 3.4, k="vending", solid=True),
        rect(31.0, 104.0, 1.6, 1.6, k="plant"),
        rect(31.0, 113.0, 1.6, 1.6, k="plant"),
    ]
    # 右侧讨论角（镜像，用书架代替贩卖机，两边不完全一样）
    props += [
        rect(98.0, 105.0, 8.0, 2.6, k="sofa", solid=True),
        rect(100.6, 110.0, 5.0, 2.2, k="table", solid=True),
        rect(98.6, 113.4, 2.0, 1.6, k="cushion"),
        rect(104.0, 113.4, 2.0, 1.6, k="cushion"),
        rect(90.0, 104.0, 7.0, 1.2, k="board"),
        rect(90.0, 108.0, 7.0, 2.2, k="block", solid=True),
        rect(87.0, 104.0, 1.6, 1.6, k="plant"),
        rect(112.0, 113.0, 1.6, 1.6, k="plant"),
    ]
    for i, cx in enumerate((8.6, 14.0, 98.6, 104.0)):
        seats.append(rect(cx, 113.4, 2.0, 1.6,
                          id="study_lounge_%d" % i, face="down"))

    # ── 门前：两排矮书架 + 地垫 + 出口玻璃门 ─────────────────────────────
    props += [
        rect(38.0, 112.0, 12.0, 2.0, k="block", solid=True),
        rect(70.0, 112.0, 12.0, 2.0, k="block", solid=True),
        rect(35.0, 115.0, 1.6, 1.6, k="plant"),
        rect(83.4, 115.0, 1.6, 1.6, k="plant"),
    ]
    rugs.append(rect(DOOR_X - 1.0, H - WALL_T - 2.6, DOOR_W + 2.0, 2.6))
    props.append(rect(DOOR_X, H - WALL_T, DOOR_W, WALL_T, k="door"))

    return {
        "id": "study_space",
        "name": "图书馆",
        "desc": "回字形的明亮自习大厅，中间是镂空的中庭，环带里全是并排的双人桌。",
        "bright": True,
        "W": W, "H": H,
        "zoom": ZOOM,
        "spawn": {"x": DOOR_X + DOOR_W * 0.5, "y": H - WALL_T - 4.0},
        "exit": rect(DOOR_X, H - WALL_T, DOOR_W, WALL_T),
        # 不给 elevator：自习空间不是宿舍楼，没有换层这回事
        "walls": walls,
        "voids": [hole],    # 中间镂空：地板换成天光色，四边护栏挡住
        "pod_floors": [],       # 不要深色地胶，整间保持浅木地板
        "rugs": rugs,
        "props": props,
        "seats": seats,
        "room_doors": [],       # 公共空间，没有会锁的单间
        "team_boards": [],
        "beds": [],
        "source": src,
    }


def validate(d: dict) -> list[str]:
    """几何自检：四倍面积 / 回字中庭 / 并排座位 / 桌椅零重叠 / 门洞对齐。"""
    problems: list[str] = []
    hole = d["voids"][0]
    old_area = 96.0 * 38.0
    new_area = float(d["W"]) * float(d["H"])
    if abs(float(d["W"]) - float(d["H"])) > 0.01:
        problems.append("外框不是正方形")
    if not (3.7 <= new_area / old_area <= 4.3):
        problems.append("面积不是原来的约 4 倍（%.2f 倍）" % (new_area / old_area))
    if abs(hole["w"] - hole["h"]) > 0.01:
        problems.append("中庭镂空不是正方形")
    if abs(hole["x"] + hole["w"] * 0.5 - float(d["W"]) * 0.5) > 0.01 \
            or abs(hole["y"] + hole["h"] * 0.5 - float(d["H"]) * 0.5) > 0.01:
        problems.append("中庭没居中")
    rails = [p for p in d["props"] if p.get("k") == "rail"]
    if len(rails) != 4 or not all(p.get("solid", False) for p in rails):
        problems.append("中庭四边护栏不齐（%d 段）" % len(rails))

    tables = [p for p in d["props"] if p.get("k") == "table"
              and float(p["w"]) == TABLE_W and float(p["h"]) == TABLE_H]
    want_tables = len(table_specs())
    if len(tables) != want_tables:
        problems.append("双人桌数量 %d 不对（应为 %d）" % (len(tables), want_tables))
    desk_seats = [s for s in d["seats"] if "study_lounge" not in str(s.get("id", ""))]
    if len(desk_seats) != len(tables) * 2:
        problems.append("桌边座位 %d 与桌数×2 不符" % len(desk_seats))

    for s in d["seats"]:
        for p in d["props"]:
            if p.get("k") in ("table", "sofa", "block", "vending") and overlap(s, p):
                problems.append("座位压家具：%s" % s.get("id"))
                break
        for w in d["walls"]:
            if overlap(s, w):
                problems.append("座位压墙：%s" % s.get("id"))
                break
        if overlap(s, hole):
            problems.append("座位落进镂空中庭：%s" % s.get("id"))
        if not (0 <= s["x"] and s["x"] + s["w"] <= d["W"]
                and 0 <= s["y"] and s["y"] + s["h"] <= d["H"]):
            problems.append("座位越界：%s" % s.get("id"))

    for p in d["props"]:
        if p.get("k") in ("window", "rail", "plant", "cushion", "board", "door"):
            continue
        if overlap(p, hole):
            problems.append("%s 落进镂空中庭 @%s" % (p.get("k"), (p["x"], p["y"])))
        if not p.get("solid", False):
            continue
        for w in d["walls"]:
            if overlap(p, w):
                problems.append("%s 压墙 @%s" % (p.get("k"), (p["x"], p["y"])))
                break
        for q in d["props"]:
            if q is p or not q.get("solid", False):
                continue
            if overlap(p, q) and id(p) < id(q):
                problems.append("%s/%s 互相重叠 @%s"
                                % (p.get("k"), q.get("k"), (p["x"], p["y"])))

    # 每桌两把椅：同一侧（同 y）、并排（x 不同）、朝向相同
    for t in tables:
        pair = [s for s in desk_seats
                if t["x"] <= s["x"] and s["x"] + s["w"] <= t["x"] + t["w"]
                and abs(s["y"] - (t["y"] - SEAT_H - SEAT_GAP)) < 0.01]
        if len(pair) != 2:
            problems.append("双人桌 @%s 没配齐两把椅（%d 把）"
                            % ((t["x"], t["y"]), len(pair)))
            continue
        pair.sort(key=lambda s: s["x"])
        if abs(pair[0]["y"] - pair[1]["y"]) > 0.01:
            problems.append("双人桌 @%s 的两把椅不是并排（南北错开）" % ((t["x"], t["y"]),))
        if {s.get("face") for s in pair} != {"down"}:
            problems.append("双人桌 @%s 的两把椅朝向不一致" % ((t["x"], t["y"]),))
        if pair[1]["x"] - (pair[0]["x"] + pair[0]["w"]) < 0.5:
            problems.append("双人桌 @%s 的两把椅黏在一起" % ((t["x"], t["y"]),))
        mid = ((pair[0]["x"] + pair[0]["w"] * 0.5)
               + (pair[1]["x"] + pair[1]["w"] * 0.5)) * 0.5
        if abs(mid - (t["x"] + t["w"] * 0.5)) > 0.01:
            problems.append("双人桌 @%s 的并排椅没居中" % ((t["x"], t["y"]),))

    # 门洞：南墙两段之间正好是 exit
    gap = d["exit"]
    south = [w for w in d["walls"] if abs(w["y"] - (H - WALL_T)) < 0.01]
    if len(south) != 2 or abs(south[0]["x"] + south[0]["w"] - gap["x"]) > 0.01 \
            or abs(south[1]["x"] - (gap["x"] + gap["w"])) > 0.01:
        problems.append("南墙门洞与 exit 没对齐")
    return problems


def main() -> None:
    d = build()
    problems = validate(d)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with io.open(OUT, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False, indent=1)
    print("已生成 %s" % OUT)
    print("整层 %g×%g 格（%.2f 倍于旧版），中庭 %g×%g 格镂空，%d 张双人桌（并排座），%d 个座位，%d 扇窗"
          % (d["W"], d["H"], d["W"] * d["H"] / (96.0 * 38.0),
             d["voids"][0]["w"], d["voids"][0]["h"],
             len([p for p in d["props"] if p.get("k") == "table"
                  and float(p["w"]) == TABLE_W]),
             len(d["seats"]),
             len([p for p in d["props"] if p.get("k") == "window"])))
    print("参考：%s" % d["source"])
    if problems:
        print("!! 几何自检发现 %d 处问题：" % len(problems))
        for p in problems[:12]:
            print("   -", p)
        raise SystemExit(1)
    print("几何自检通过：四倍正方形、中庭居中镂空、每桌两把并排椅、门洞对齐")


if __name__ == "__main__":
    main()
