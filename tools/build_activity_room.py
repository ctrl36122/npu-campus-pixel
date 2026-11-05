#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成宿舍楼 B1「活动室」内景数据 assets/rooms/activity_room.json。

布局骨架参考 SkyOffice 的 Computer 图层（3 台成排 × 上下两组），
但**不按它的 32px 格等比放大** —— 那会让桌子宽到 10 格，和校园里
「视觉压缩」的楼/人比例打架。本项目统一 8px/格，人物约 26px。

2026-11-05 第二版：整体放大重排。上一版 94×30、单间 44×10.2，
两排桌子之间只剩 1 格走道，坐下来像被夹在缝里。这一版：

  整层 132×42 格、走廊 4.6 格宽（原 3.2）
  单间 63×15.5 格（原 44×10.2，面积 2.2 倍）
  桌 4.0×2.2、椅 2.2×1.6（原 3.4×2 / 2×1.5）
  两排之间留 3 格走道（原 1 格），桌列之间留 8 格
  每间右侧另设休息角：沙发 + 茶几 + 坐垫 + 绿植 + 贩卖机 + 白板
  每间仍是 6 套「电脑桌 + 座椅」，共 4 间 24 席

美术全部由 net/scripts/room_prop.gd 程序化绘制（含屏幕/键盘/鼠标/发光），
不引入任何第三方图集。

用法：python tools/build_activity_room.py
"""

from __future__ import annotations

import io
import itertools
import json
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "assets", "rooms", "activity_room.json")
SKY_MAP = os.path.join(
    os.path.dirname(ROOT), "references", "SkyOffice", "client", "public",
    "assets", "map", "map.json",
)

# ── 整层尺度（格）──────────────────────────────────────────────────────
W, H = 132.0, 42.0
N_Y0, N_Y1 = 2.0, 17.5                  # 北侧大单间
S_Y0, S_Y1 = 24.5, 40.0                 # 南侧大单间
CORR_Y0, CORR_Y1 = 18.7, 23.3           # 走廊可行走区（墙内沿）
WALL_T = 1.2
OUTER_T = 2.0

# ── 家具尺度（格）──────────────────────────────────────────────────────
DESK_W, DESK_H = 4.0, 2.2
SEAT_W, SEAT_H = 2.2, 1.6
SEAT_GAP = 0.15                         # 座位贴着桌子前沿（南侧）
DOOR_W = 3.4

# ── 单间内布局（房间局部坐标，房间 63×15.5）────────────────────────────
DESK_COLS = [5.0, 17.0, 29.0]           # 3 列，列间 12 格（桌间净空 8 格）
DESK_ROWS = [3.0, 9.4]                  # 2 排，排间 6.4 格（走道 3 格）
ROOM_W = 63.0
ROOM_H = N_Y1 - N_Y0                    # 15.5


def skyoffice_pattern() -> dict:
    """读 SkyOffice 的 Computer 图层，把「3 台一排 / 上下两组」的拓扑记进 source。"""
    if not os.path.isfile(SKY_MAP):
        raise SystemExit("找不到 SkyOffice 地图：%s" % SKY_MAP)
    with io.open(SKY_MAP, encoding="utf-8") as f:
        doc = json.load(f)
    objs = []
    for layer in doc.get("layers", []):
        if layer.get("type") == "objectgroup" and layer.get("name") == "Computer":
            objs = layer.get("objects", [])
            break
    if not objs:
        raise SystemExit("SkyOffice 地图里没有 Computer 图层对象")
    xs = sorted({round(float(o["x"]) / 32.0, 2) for o in objs})
    ys = sorted({round(float(o["y"]) / 32.0, 2) for o in objs})
    return {
        "project": "SkyOffice (MIT)",
        "layer": "Computer",
        "tile_px": doc.get("tilewidth", 32),
        "objects": len(objs),
        "columns": len(xs),
        "rows": len(ys),
        "column_tiles": xs,
        "row_tiles": ys,
        "note": "只取「3 台成排 × 上下两组」的布局骨架；尺寸按本项目 8px/格重定",
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

    # ── 4 间大单间：北西 / 北东 / 南西 / 南东 ──────────────────────────
    # name 要短：门牌是屏幕空间 Label，太长会和隔壁板子的牌子横向叠住。
    rooms = [
        {"index": 0, "name": "A 区", "x": 2.0, "y": N_Y0,
         "w": ROOM_W, "h": ROOM_H, "side": "n", "door_x": 23.0},
        {"index": 1, "name": "B 区", "x": 67.0, "y": N_Y0,
         "w": ROOM_W, "h": ROOM_H, "side": "n", "door_x": 88.0},
        {"index": 2, "name": "C 区", "x": 2.0, "y": S_Y0,
         "w": ROOM_W, "h": ROOM_H, "side": "s", "door_x": 23.0},
        {"index": 3, "name": "D 区", "x": 67.0, "y": S_Y0,
         "w": ROOM_W, "h": ROOM_H, "side": "s", "door_x": 88.0},
    ]

    # ── 墙：外墙 + 中间竖隔墙 + 走廊隔墙（门洞处断开）──────────────────
    walls = [
        rect(0, 0, W, OUTER_T),                             # 北外墙
        rect(0, H - OUTER_T, W, OUTER_T),                   # 南外墙
        rect(0, OUTER_T, OUTER_T, CORR_Y0 - OUTER_T),       # 西墙北段（出口洞在走廊）
        rect(0, CORR_Y1, OUTER_T, H - OUTER_T - CORR_Y1),   # 西墙南段
        rect(W - OUTER_T, OUTER_T, OUTER_T, CORR_Y0 - OUTER_T),      # 东墙北段
        rect(W - OUTER_T, CORR_Y1, OUTER_T, H - OUTER_T - CORR_Y1),  # 东墙南段
        rect(65, N_Y0, 2, ROOM_H),                          # 北两间之间的隔墙
        rect(65, S_Y0, 2, ROOM_H),                          # 南两间之间的隔墙
    ]
    # 走廊两侧隔墙，按门洞切成段（门洞 = door_x ± DOOR_W/2）
    gaps = []
    for r in rooms:
        gaps.append((r["door_x"] - DOOR_W * 0.5, r["door_x"] + DOOR_W * 0.5))
    gaps.sort()
    for wall_y in (N_Y1, CORR_Y1):         # 北侧墙 17.5、南侧墙 23.3
        cur = OUTER_T
        for g0, g1 in gaps:
            if g0 > cur:
                walls.append(rect(cur, wall_y, g0 - cur, WALL_T))
            cur = max(cur, g1)
        if W - OUTER_T > cur:
            walls.append(rect(cur, wall_y, W - OUTER_T - cur, WALL_T))

    props: list[dict] = []
    seats: list[dict] = []
    pod_floors: list[dict] = []
    rugs: list[dict] = []
    team_boards: list[dict] = []

    # 每间：6 套电脑桌（2 排 × 3 列）+ 右侧休息角 + 门口组队板
    for r in rooms:
        idx = r["index"]
        rx, ry = r["x"], r["y"]
        # 深色地胶只铺「机位区」（局部 0~36），休息角留给木地板 + 地毯。
        # 整间铺满会把房间读成一块黑底，越大越像空地。
        pod_floors.append(rect(rx, ry, 36.0, r["h"]))
        # 休息角地毯：冷色压在暖木地板上，跟机位区的黑地胶再分开一层。
        # 只铺沙发+茶几+坐垫这一块（约 13×10 格），四周留木地板。
        # 早先铺到 27×12 时整块地毯被读成「一个蓝色高台」—— 地毯越大、硬边越显眼。
        rugs.append(rect(rx + 34.8, ry + 2.4, 13.4, 10.4))
        # 过门垫：门洞那一段是墙带（不含在地胶和走廊地毯里），不补会被木地板
        # 顶出一条棕色台阶。补一块地毯色当门槛。
        thr_y = N_Y1 if r["side"] == "n" else CORR_Y1
        rugs.append(rect(r["door_x"] - DOOR_W * 0.5, thr_y, DOOR_W, WALL_T))

        for ri, dy in enumerate(DESK_ROWS):
            for ci, dx in enumerate(DESK_COLS):
                props.append(rect(rx + dx, ry + dy, DESK_W, DESK_H,
                                  k="desk", solid=True, room=idx))
                seats.append(rect(rx + dx + (DESK_W - SEAT_W) * 0.5,
                                  ry + dy + DESK_H + SEAT_GAP,
                                  SEAT_W, SEAT_H,
                                  id="b1_%d_%d_%d" % (idx, ri, ci),
                                  room=idx, face="up"))

        # 右侧休息角（局部 x 35~56）：沙发组 + 绿植 + 贩卖机 + 一张高桌配坐垫。
        # 房间里不再摆立式白板 —— room_prop 的白板是纯白色板面，摆在房间中央
        # 特别抢眼、远看像一块白木板；走廊那 4 块组队板已经承担了「板子」的语义。
        props.append(rect(rx + 36.0, ry + 3.2, 7.6, 2.8, k="sofa", solid=True, room=idx))
        props.append(rect(rx + 37.0, ry + 8.0, 4.6, 2.4, k="table", solid=True, room=idx))
        props.append(rect(rx + 35.9, ry + 11.0, 1.8, 1.6, k="cushion", room=idx))
        props.append(rect(rx + 38.7, ry + 11.0, 1.8, 1.6, k="cushion", room=idx))
        props.append(rect(rx + 44.8, ry + 3.2, 1.6, 1.6, k="plant", solid=True, room=idx))
        props.append(rect(rx + 44.8, ry + 11.0, 1.6, 1.6, k="plant", solid=True, room=idx))
        props.append(rect(rx + 48.6, ry + 3.2, 2.8, 3.6, k="vending", solid=True, room=idx))
        props.append(rect(rx + 48.6, ry + 8.4, 4.6, 2.4, k="table", solid=True, room=idx))
        props.append(rect(rx + 48.8, ry + 11.4, 1.8, 1.6, k="cushion", room=idx))
        props.append(rect(rx + 51.6, ry + 11.4, 1.8, 1.6, k="cushion", room=idx))
        props.append(rect(rx + 54.6, ry + 3.2, 1.6, 1.6, k="plant", solid=True, room=idx))

        # 门口组队板：贴在走廊墙上（不 solid，不挡路），同时是交互热点。
        # 南北两块必须水平错开足够远：走廊只有 4.6 格宽、交互半径 3.2 格，
        # 而且门牌是**屏幕空间** Label（13px 字号，一块约 120px 宽 ≈ 15 格），
        # 只错开 8 格时两块牌子会横向叠住、字被后画的那块盖掉。
        # 这里北侧挂在门左侧 -9 格、南侧挂在门右侧 +9 格，中心距 18 格。
        if r["side"] == "n":
            bx, by = r["door_x"] - 9.0, CORR_Y0 + 0.1
        else:
            bx, by = r["door_x"] + 9.0, CORR_Y1 - 1.1
        board = rect(bx, by, 2.8, 1.0, k="board", room=idx)
        props.append(board)
        team_boards.append(rect(bx, by, 2.8, 1.0,
                                index=idx, name=r["name"], side=r["side"],
                                room_rect=[rx, ry, r["w"], r["h"]]))

    # ── 公共走廊 ───────────────────────────────────────────────────────
    props.append(rect(0.6, CORR_Y0, 1.6, CORR_Y1 - CORR_Y0, k="door"))       # 西端出口玻璃门
    props.append(rect(W - 2.8, CORR_Y0, 2.4, CORR_Y1 - CORR_Y0,
                      k="elevator", solid=True))                            # 东端电梯
    # 走廊贩卖机 / 绿植（贴墙摆，不挡中间通道）。
    # 贩卖机高只取 2.2 格：走廊净宽 4.6，留 2.2 格给人过，太深会把通道堵成单行。
    props.append(rect(118.0, CORR_Y0 + 0.2, 2.6, 2.2, k="vending", solid=True))
    for i, px in enumerate((14.0, 34.0, 54.0, 74.0, 94.0)):
        if i % 2 == 0:
            props.append(rect(px, CORR_Y0 + 0.2, 1.6, 1.3, k="plant", solid=True))
        else:
            props.append(rect(px, CORR_Y1 - 1.5, 1.6, 1.3, k="plant", solid=True))

    data = {
        "id": "activity_room",
        "name": "B1 · 游戏活动室",
        "desc": "四个宽敞大单间，每间六台机位带休息角。门口组队板可以开队。",
        "W": W, "H": H,
        "spawn": {"x": 6.0, "y": (CORR_Y0 + CORR_Y1) * 0.5},
        "exit": {"x": 0.6, "y": CORR_Y0, "w": 1.6, "h": CORR_Y1 - CORR_Y0},
        "elevator": {"x": W - 2.8, "y": CORR_Y0, "w": 2.4, "h": CORR_Y1 - CORR_Y0},
        "walls": walls,
        "pod_floors": pod_floors,
        "rugs": [rect(2.4, CORR_Y0, W - 5.6, CORR_Y1 - CORR_Y0)] + rugs,
        "props": props,
        "seats": seats,
        "team_boards": team_boards,
        "room_doors": [],       # 公共空间，不要会锁的门
        "beds": [],
        "source": src,
    }
    return data


def validate(d: dict) -> list[str]:
    """几何自检：桌椅不互相压、不压墙、座位不出房间、组队板分得开。"""
    problems: list[str] = []
    desks = [p for p in d["props"] if p.get("k") == "desk"]
    if len(desks) != len(d["team_boards"]) * 6:
        problems.append("桌数 %d 与单间数×6 不符" % len(desks))
    if len(d["seats"]) != len(desks):
        problems.append("座位数 %d 与桌数 %d 不符" % (len(d["seats"]), len(desks)))

    for s in d["seats"]:
        for p in desks:
            if overlap(s, p):
                problems.append("座位压桌：%s" % s.get("id"))
        for w in d["walls"]:
            if overlap(s, w):
                problems.append("座位压墙：%s" % s.get("id"))
        if not (0 <= s["x"] and s["x"] + s["w"] <= d["W"]
                and 0 <= s["y"] and s["y"] + s["h"] <= d["H"]):
            problems.append("座位越界：%s" % s.get("id"))

    for p in d["props"]:
        if p.get("k") in ("desk", "sofa", "table", "vending"):
            for w in d["walls"]:
                if overlap(p, w):
                    problems.append("%s 压墙 @%s" % (p.get("k"), (p["x"], p["y"])))
                    break
            for q in d["props"]:
                if q is p or q.get("k") not in ("desk", "sofa", "table", "vending"):
                    continue
                if overlap(p, q) and id(p) < id(q):
                    problems.append("%s/%s 互相重叠 @%s"
                                    % (p.get("k"), q.get("k"), (p["x"], p["y"])))

    boards = d["team_boards"]
    for a, b in itertools.combinations(boards, 2):
        ca = (a["x"] + a["w"] * 0.5, a["y"] + a["h"] * 0.5)
        cb = (b["x"] + b["w"] * 0.5, b["y"] + b["h"] * 0.5)
        if math.hypot(ca[0] - cb[0], ca[1] - cb[1]) <= 6.4:
            problems.append("组队板 %d/%d 离得太近" % (a["index"], b["index"]))
    return problems


def main() -> None:
    d = build()
    problems = validate(d)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with io.open(OUT, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False, indent=1)
    print("已生成 %s" % OUT)
    print("整层 %g×%g 格，单间 %g×%g 格 ×%d 间，%d 张电脑桌，%d 个座位，%d 块组队板"
          % (d["W"], d["H"], ROOM_W, ROOM_H, len(d["team_boards"]),
             len([p for p in d["props"] if p.get("k") == "desk"]),
             len(d["seats"]), len(d["team_boards"])))
    print("每间桌/座：%s" % {r["index"]: (
        sum(1 for p in d["props"] if p.get("k") == "desk" and p.get("room") == r["index"]),
        sum(1 for s in d["seats"] if s.get("room") == r["index"]),
    ) for r in d["team_boards"]})
    print("走廊净宽 %.1f 格，桌排间走道 %.1f 格"
          % (CORR_Y1 - CORR_Y0, DESK_ROWS[1] - (DESK_ROWS[0] + DESK_H + SEAT_GAP + SEAT_H)))
    if problems:
        print("!! 几何自检发现 %d 处问题：" % len(problems))
        for p in problems[:12]:
            print("   -", p)
        raise SystemExit(1)
    print("几何自检通过：桌椅零重叠、不压墙、组队板互相分得开")


if __name__ == "__main__":
    main()
