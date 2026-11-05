#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成宿舍楼 B1「活动室」内景数据 assets/rooms/activity_room.json。

抄的是 SkyOffice 的**布局骨架**，不是它的图集：
  references/SkyOffice/.../map/map.json 的 Computer 图层里，电脑是
  「3 台一排、上下两组」(x=960/1056/1152 间距 96px；y=544 与 800 两组)，
  正面各配一把椅子。这里把它放大成每间大单间 6 套「电脑桌 + 座椅」，
  两排三列、正面朝屏幕，中间留走道 —— 就是网吧/电竞房的排布。

尺寸沿用现有 dorm_space.json 的规格（本项目 8px/格，人物 26px）：
  desk 3.4×2 格、seat 2×1.5 格、房间 94×30 格、电梯在东端。
  绝对尺寸不按 SkyOffice 的 32px 格等比放大 —— 那会让桌子宽到 10 格，
  和校园里「视觉压缩」的楼/人比例打架。

美术仍由 net/scripts/room_prop.gd 程序化绘制（含屏幕/键盘/鼠标/发光），
不引入任何第三方图集。

用法：python tools/build_activity_room.py
"""

from __future__ import annotations

import io
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "assets", "rooms", "activity_room.json")
SKY_MAP = os.path.join(
    os.path.dirname(ROOT), "references", "SkyOffice", "client", "public",
    "assets", "map", "map.json",
)

# ── 房间尺度（格）──────────────────────────────────────────────────────
W, H = 94.0, 30.0
CORRIDOR_Y0, CORRIDOR_Y1 = 13.4, 16.6
NORTH_Y0, NORTH_Y1 = 2.0, 12.2          # 北侧大单间
SOUTH_Y0, SOUTH_Y1 = 17.8, 28.0         # 南侧大单间
WALL_T = 1.2

DESK_W, DESK_H = 3.4, 2.0
SEAT_W, SEAT_H = 2.0, 1.5
SEAT_GAP = 0.1                          # 座位贴着桌子前沿

DOOR_W = 3.0


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
        "note": "取 3 台成排 × 上下两组 的布局骨架；本项目每间补足为 2 排 × 3 列 = 6 套机位",
    }


def rect(x, y, w, h, **extra):
    d = {"x": round(float(x), 3), "y": round(float(y), 3),
         "w": round(float(w), 3), "h": round(float(h), 3)}
    d.update(extra)
    return d


def build() -> dict:
    src = skyoffice_pattern()

    # ── 4 间大单间：北西 / 北东 / 南西 / 南东 ──────────────────────────
    rooms = [
        # name 要短：门牌是屏幕空间 Label，太长会和隔壁板子的牌子横向叠在一起
        {"index": 0, "name": "A 区", "x": 2.0, "y": NORTH_Y0,
         "w": 44.0, "h": NORTH_Y1 - NORTH_Y0, "side": "n", "door_x": 22.0},
        {"index": 1, "name": "B 区", "x": 48.0, "y": NORTH_Y0,
         "w": 42.0, "h": NORTH_Y1 - NORTH_Y0, "side": "n", "door_x": 68.0},
        {"index": 2, "name": "C 区", "x": 2.0, "y": SOUTH_Y0,
         "w": 44.0, "h": SOUTH_Y1 - SOUTH_Y0, "side": "s", "door_x": 22.0},
        {"index": 3, "name": "D 区", "x": 48.0, "y": SOUTH_Y0,
         "w": 42.0, "h": SOUTH_Y1 - SOUTH_Y0, "side": "s", "door_x": 68.0},
    ]

    # ── 墙：外墙 + 中间竖隔墙 + 走廊隔墙（在门洞处断开）────────────────
    walls = [
        rect(0, 0, W, 2),                       # 北外墙
        rect(0, 28, W, 2),                     # 南外墙
        rect(0, 2, 2, 11),                     # 西墙北段（出口洞 y=13..16）
        rect(0, 16, 2, 12),                    # 西墙南段
        rect(92, 2, 2, 11.2),                  # 东墙北段（电梯洞 y=13.2..16.8）
        rect(92, 16.8, 2, 11.2),               # 东墙南段
        rect(46, NORTH_Y0, 2, NORTH_Y1 - NORTH_Y0),   # 北两间之间的隔墙
        rect(46, SOUTH_Y0, 2, SOUTH_Y1 - SOUTH_Y0),   # 南两间之间的隔墙
    ]
    # 走廊两侧隔墙，按门洞切成段
    for y, spans in (
        (12.2, [(2, 22), (25, 46), (48, 68), (71, 90)]),
        (16.6, [(2, 22), (25, 46), (48, 68), (71, 90)]),
    ):
        for x0, x1 in spans:
            walls.append(rect(x0, y, x1 - x0, WALL_T))

    props: list[dict] = []
    seats: list[dict] = []
    pod_floors: list[dict] = []
    team_boards: list[dict] = []

    # 每间：6 套电脑桌（2 排 × 3 列）+ 休息角 + 门口组队板
    for r in rooms:
        idx = r["index"]
        rx, ry = r["x"], r["y"]
        pod_floors.append(rect(rx, ry, r["w"], r["h"]))

        # 3 列：相对房间左边界 +6 / +17 / +28（列间留 7.6 格走道）
        col_x = [rx + 6.0, rx + 17.0, rx + 28.0]
        # 2 排：北侧房间从 +1.5 起，南侧房间从 +1.5 起（各自房间内相对坐标）
        row_y = [ry + 1.5, ry + 6.0]

        for ri, dy in enumerate(row_y):
            for ci, dx in enumerate(col_x):
                props.append(rect(dx, dy, DESK_W, DESK_H, k="desk", solid=True,
                                  room=idx))
                seats.append(rect(dx + (DESK_W - SEAT_W) * 0.5,
                                  dy + DESK_H + SEAT_GAP,
                                  SEAT_W, SEAT_H,
                                  id="b1_%d_%d_%d" % (idx, ri, ci),
                                  room=idx, face="up"))

        # 右侧休息角：沙发 / 白板 / 绿植 / 贩卖机
        gx = rx + r["w"] - 10.0
        props.append(rect(gx, ry + 1.6, 6.0, 2.4, k="sofa", solid=True, room=idx))
        props.append(rect(gx, ry + 5.2, 6.0, 1.2, k="board", room=idx))
        props.append(rect(gx + 6.4, ry + 1.6, 2.4, 3.2, k="vending",
                          solid=True, room=idx))
        props.append(rect(gx + 6.4, ry + 5.4, 1.4, 1.2, k="plant",
                          solid=True, room=idx))

        # 门口组队板：挂在走廊墙上（不 solid，不挡路），同时也是交互热点。
        # 南北两块必须水平错开 >= 8 格：走廊只有 3.2 格宽，交互半径 3.2 格，
        # 若 x 相同，站走廊中间会永远命中北侧那块，南侧板按不到。
        board_y = 13.5 if r["side"] == "n" else 15.5
        bx = r["door_x"] - 4.0 if r["side"] == "n" else r["door_x"] + 4.0
        props.append(rect(bx, board_y, 2.8, 1.0, k="board", room=idx))
        team_boards.append(rect(bx, board_y, 2.8, 1.0,
                                index=idx, name=r["name"], side=r["side"],
                                room_rect=[rx, ry, r["w"], r["h"]]))

    # ── 公共区 ─────────────────────────────────────────────────────────
    props.append(rect(0.1, 13.0, 1.8, 3.0, k="door"))           # 西端出口玻璃门
    props.append(rect(92.0, 13.2, 2.0, 3.6, k="elevator", solid=True))
    props.append(rect(85.0, 13.8, 2.4, 2.6, k="vending", solid=True))
    props.append(rect(42.0, 14.0, 1.4, 1.2, k="plant", solid=True))
    props.append(rect(42.0, 15.4, 1.4, 1.2, k="plant", solid=True))

    return {
        "id": "activity_room",
        "name": "B1 · 游戏活动室",
        "desc": "四个大单间，每间六台机位。门口组队板可以开队、看谁在找搭子。",
        "W": W, "H": H,
        "spawn": {"x": 6.0, "y": 15.0},
        "exit": {"x": 0.5, "y": 13.0, "w": 1.5, "h": 3.0},
        "elevator": {"x": 89.8, "y": 13.2, "w": 2.2, "h": 3.6},
        "walls": walls,
        "pod_floors": pod_floors,
        "rugs": [rect(3.0, 13.5, 82.0, 3.0)],
        "props": props,
        "seats": seats,
        "team_boards": team_boards,
        "room_doors": [],       # 公共空间，不要会锁的门
        "beds": [],
        "source": src,
    }


def main() -> None:
    d = build()
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with io.open(OUT, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False, indent=1)
    print("已生成 %s" % OUT)
    print("房间 %g×%g 格，%d 间大单间，%d 张电脑桌，%d 个座位，%d 块组队板"
          % (d["W"], d["H"], len(d["team_boards"]),
             sum(1 for p in d["props"] if p["k"] == "desk"),
             len(d["seats"]), len(d["team_boards"])))
    print("SkyOffice 布局骨架：%d 列 × %d 排（Computer 图层 %d 个对象）"
          % (d["source"]["columns"], d["source"]["rows"],
             d["source"]["objects"]))


if __name__ == "__main__":
    main()
