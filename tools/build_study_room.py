#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成图书馆「自习空间」内景数据 assets/rooms/study_space.json。

参考 SkyOffice 的 Chair 图层：开放式办公区是「成排桌椅」、会议区是
「一张桌两侧面对面坐」（map.tmx 的 (14,8)(14,10)/(17,8)(17,10) 那一组）。
这里把两者合成一句：**两个人一桌，一整个大间**，不再切小隔间。

   整层 96×38 格，一整间不隔墙
   12 张双人自习桌（4 列 × 3 排），每张桌南北各一把椅子 = 24 席
   桌间横向净空 11 格、纵向过道 3.4 格，镜头拉远也不会挤成一坨
   北墙 4 扇落地窗 + 南墙 3 扇，配合 Room.gd 的 bright 主题做浅木地板
   右侧讨论角：沙发 / 茶几 / 两个可坐坐垫 / 白板 / 书架 / 绿植
   南墙正中开 8 格门洞，站在门口按 E 回到图书馆广场

bright=true 让 Room.gd 换一套浅色调色板（地板、墙、地毯、小地图底色），
现有宿舍和活动室不受影响。美术全部程序化绘制，不引入任何第三方图集。

用法：python tools/build_study_room.py
"""

from __future__ import annotations

import io
import itertools
import json
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "assets", "rooms", "study_space.json")
SKY_MAP = os.path.join(
    os.path.dirname(ROOT), "references", "SkyOffice", "client", "public",
    "assets", "map", "map.tmx",
)

# ── 整层尺度（格）──────────────────────────────────────────────────────
W, H = 96.0, 38.0
WALL_T = 1.6

# ── 双人桌（格）────────────────────────────────────────────────────────
TABLE_W, TABLE_H = 9.0, 2.6
SEAT_W, SEAT_H = 2.4, 1.6
SEAT_GAP = 0.4                  # 椅子离桌沿的缝
TABLE_COLS = [5.0, 25.0, 45.0, 65.0]
TABLE_ROWS = [5.0, 15.0, 25.0]

# ── 南墙门洞 ───────────────────────────────────────────────────────────
DOOR_X, DOOR_W = 44.0, 8.0

# ── 讨论角（右侧 76~92）───────────────────────────────────────────────
LOUNGE_X = 76.0


def skyoffice_pattern() -> dict:
    """把 SkyOffice 的椅子拓扑记进 source。tmx 在就用真数据，缺了也不拦生成。"""
    if not os.path.isfile(SKY_MAP):
        return {
            "project": "SkyOffice (MIT)", "layer": "Chair",
            "note": "成排开放座位 + 会议桌两侧面对面；本机未找到 map.tmx，按文档记录",
        }
    with io.open(SKY_MAP, encoding="utf-8") as f:
        text = f.read()
    import re
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
        "note": "取「会议桌两侧面对面 + 成排开放座位」的拓扑；本项目改成一整间、两人一桌，尺寸按 8px/格 重定",
    }


def rect(x, y, w, h, **extra):
    d = {"x": round(float(x), 3), "y": round(float(y), 3),
         "w": round(float(w), 3), "h": round(float(h), 3)}
    d.update(extra)
    return d


def overlap(a: dict, b: dict) -> bool:
    return (a["x"] < b["x"] + b["w"] - 1e-6 and b["x"] < a["x"] + a["w"] - 1e-6
            and a["y"] < b["y"] + b["h"] - 1e-6 and b["y"] < a["y"] + a["h"] - 1e-6)


def build() -> dict:
    src = skyoffice_pattern()

    # ── 外墙：南墙按门洞切成两段，其余四面整条 ──────────────────────────
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
    # 比窗更靠下，会把窗整片盖掉（窗必须画在墙之后才像「墙上开了洞」）。
    # 每扇 15 格、首尾相接，北墙不留露出灰色墙顶的断口
    for wx in (3.0, 18.0, 33.0, 48.0, 63.0, 78.0):
        props.append(rect(wx, WALL_T, 15.0, 1.0, k="window"))

    # ── 双人自习桌：一桌两椅，南北对着坐 ─────────────────────────────────
    for ri, ty in enumerate(TABLE_ROWS):
        for ci, tx in enumerate(TABLE_COLS):
            table = rect(tx, ty, TABLE_W, TABLE_H, k="table", solid=True)
            props.append(table)
            sx = tx + (TABLE_W - SEAT_W) * 0.5
            # 北侧椅：面朝镜头（down），正对南边的同桌
            seats.append(rect(sx, ty - SEAT_H - SEAT_GAP, SEAT_W, SEAT_H,
                              id="study_%d_%d_n" % (ri, ci), face="down"))
            # 南侧椅：背对镜头（up），正对北边的同桌
            seats.append(rect(sx, ty + TABLE_H + SEAT_GAP, SEAT_W, SEAT_H,
                              id="study_%d_%d_s" % (ri, ci), face="up"))
            # 桌角一小盆绿植，纯装饰、不挡路（每张桌都有会太花，隔一张放一盆）
            if (ri + ci) % 2 == 0:
                props.append(rect(tx + TABLE_W - 1.5, ty + 0.5, 1.2, 1.2, k="plant"))

    # ── 右侧讨论角：一块浅色地毯把「休息」和「自习」分开 ──────────────────
    # 整体下压到 y13~28：右上角固定挂着小地图面板，讨论角若贴北墙会被整块盖住。
    rugs.append(rect(LOUNGE_X, 13.0, 17.0, 15.0))
    props += [
        rect(LOUNGE_X + 1.0, 14.2, 7.6, 2.6, k="sofa", solid=True),
        rect(LOUNGE_X + 2.6, 19.0, 4.6, 2.2, k="table", solid=True),
        rect(LOUNGE_X + 1.4, 22.6, 2.0, 1.6, k="cushion"),
        rect(LOUNGE_X + 5.0, 22.6, 2.0, 1.6, k="cushion"),
        rect(LOUNGE_X + 9.0, 13.4, 6.0, 1.2, k="board"),
        rect(LOUNGE_X + 9.0, 18.4, 6.0, 2.2, k="block", solid=True),
        rect(LOUNGE_X + 9.0, 23.0, 3.0, 3.4, k="vending", solid=True),
        rect(LOUNGE_X + 15.0, 14.0, 1.6, 1.6, k="plant"),
        rect(LOUNGE_X + 15.0, 25.0, 1.6, 1.6, k="plant"),
    ]
    # 上一轮提的「休息角看起来能坐却不能坐」：这里的坐垫真的能坐
    for i, cx in enumerate((LOUNGE_X + 1.4, LOUNGE_X + 5.0)):
        seats.append(rect(cx, 22.6, 2.0, 1.6,
                          id="study_lounge_%d" % i, face="down"))

    # ── 门前：一排矮书架 + 地垫 + 出口玻璃门 ─────────────────────────────
    props.append(rect(4.0, 32.0, 14.0, 2.0, k="block", solid=True))
    props.append(rect(78.0, 32.0, 14.0, 2.0, k="block", solid=True))
    props.append(rect(20.0, 33.0, 1.6, 1.6, k="plant"))
    props.append(rect(74.0, 33.0, 1.6, 1.6, k="plant"))
    rugs.append(rect(DOOR_X - 1.0, H - WALL_T - 2.6, DOOR_W + 2.0, 2.6))
    props.append(rect(DOOR_X, H - WALL_T, DOOR_W, WALL_T, k="door"))

    return {
        "id": "study_space",
        "name": "图书馆 · 自习空间",
        "desc": "一整间明亮的大自习室，12 张双人桌，靠窗还有沙发讨论角。",
        "bright": True,
        "W": W, "H": H,
        "spawn": {"x": DOOR_X + DOOR_W * 0.5, "y": H - WALL_T - 4.0},
        "exit": rect(DOOR_X, H - WALL_T, DOOR_W, WALL_T),
        # 不给 elevator：自习空间不是宿舍楼，没有换层这回事
        "walls": walls,
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
    """几何自检：桌椅零重叠、座位不出墙、每桌正好两把对面椅、门洞对得齐。"""
    problems: list[str] = []
    tables = [p for p in d["props"] if p.get("k") == "table"
              and float(p["w"]) == TABLE_W]
    if len(tables) != len(TABLE_COLS) * len(TABLE_ROWS):
        problems.append("双人桌数量 %d 不对（应为 %d）"
                        % (len(tables), len(TABLE_COLS) * len(TABLE_ROWS)))
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
        if not (0 <= s["x"] and s["x"] + s["w"] <= d["W"]
                and 0 <= s["y"] and s["y"] + s["h"] <= d["H"]):
            problems.append("座位越界：%s" % s.get("id"))

    for p in d["props"]:
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

    # 每桌南北各一把椅子，且 x 中心对齐
    for t in tables:
        pair = [s for s in desk_seats
                if abs((s["x"] + s["w"] * 0.5) - (t["x"] + t["w"] * 0.5)) < 0.01
                and (abs(s["y"] + s["h"] - t["y"]) < 1.0
                     or abs(s["y"] - (t["y"] + t["h"])) < 1.0)]
        if len(pair) != 2:
            problems.append("双人桌 @%s 没配齐两把对面椅（%d 把）"
                            % ((t["x"], t["y"]), len(pair)))
        elif {p.get("face") for p in pair} != {"up", "down"}:
            problems.append("双人桌 @%s 的两把椅不是面对面" % ((t["x"], t["y"]),))

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
    print("整层 %g×%g 格（一整间不隔墙），%d 张双人桌，%d 个座位，%d 扇窗"
          % (d["W"], d["H"],
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
    print("几何自检通过：桌椅零重叠、不压墙、每桌两把对面椅、门洞对齐")


if __name__ == "__main__":
    main()
