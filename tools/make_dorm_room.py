#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成「宿舍空间」内景（assets/rooms/dorm_space.json）。

布局：中间一条长横向走廊贯通东西，走廊两侧各 7 间、共 14 间带门的宿舍。
走廊西端是出入口（回校园），东端是电梯（换楼层）。
每间配床 + 书桌 + 椅子 + 衣柜 + 绿植；房间铺深色地胶，和走廊的木地板分开。

俯视（格）：
    ┌──────────────────────────────────────────────────────┐  ← 北外墙
    │ 房0 │ 房1 │ … │ 房6 │                                   ← 北排 7 间（门朝南、开向走廊）
    ├──门─┼──门─┼ … ┼──门─┤                                   ← 墙 A（2 格厚，每间一个 3 格门洞）
    ╞═════ 走廊（贯通东西；西端出入口，东端电梯）══════════════╡
    ├──门─┼──门─┼ … ┼──门─┤                                   ← 墙 B
    │ 房7 │ 房8 │ … │ 房13│                                   ← 南排 7 间（门朝北、开向走廊）
    └──────────────────────────────────────────────────────┘  ← 南外墙

尺度（别随手改，改了所有家具都会失调）：
  人物约 18px 高（2.25 格）、11px 宽（1.4 格），是唯一的标尺。
  房间净宽 12 格、净深 8 格，够摆下一张床 + 一张桌 + 衣柜。
  门洞 3 格宽、正对房间中线；家具都摆在左右两侧，中央进门通道保持空着。

用法：
  python tools/make_dorm_room.py --ascii      # 打印俯视草图 + 写盘
"""

import argparse
import io
import json
import os

# ── 整体 ────────────────────────────────────────────────────────────────
T = 2                    # 外墙厚
PART = 1                 # 房间之间竖向隔墙厚
BAND = 2                 # 房间 ↔ 走廊之间那堵墙的厚度（2 格才放得下一个门）
N = 7                    # 每侧房间数（共 14 间）
ROOM_W = 12              # 房间净宽
ROOM_D = 8               # 房间净深
CR_H = 6                 # 走廊净高
DW = 3                   # 房间门洞宽

X0 = T                   # 最西一间房间内部起点
ENTR_Y0 = 13             # 西端出入口门洞起点（走廊正中）
ENTR_H = 3               # 西端出入口门洞高

# ── 竖向（y）版式 ──────────────────────────────────────────────────────
N_Y0 = T                 # 北排房间内部起点（2）
N_Y1 = N_Y0 + ROOM_D     # 10
A_Y0 = N_Y1              # 墙 A 起点（10，占 10..11）
CR_Y0 = A_Y0 + BAND      # 走廊起点（12）
CR_Y1 = CR_Y0 + CR_H     # 走廊终点（18）
B_Y0 = CR_Y1             # 墙 B 起点（18，占 18..19）
S_Y0 = B_Y0 + BAND       # 南排房间内部起点（20）
S_Y1 = S_Y0 + ROOM_D     # 28

# ── 横向（x）版式 ──────────────────────────────────────────────────────
ROOM_X = [X0 + i * (ROOM_W + PART) for i in range(N)]
ROOM_END = ROOM_X[-1] + ROOM_W           # 最后一间房间右沿

W = ROOM_END + T                         # 94
H = S_Y1 + T                             # 30

# 电梯：走廊东端、嵌进东墙里的一樘门（门洞开在东墙上，门与按钮画在墙里/门边）
ELEV_X0 = ROOM_END - 6.0                 # 电梯前室起点
ELEV_W = 6.0
ELEV_Y0 = CR_Y0                          # 12
ELEV_H = CR_H                            # 6
ELEV_DOOR_Y0 = 13.2                      # 门洞起点（走廊竖向居中）
ELEV_DOOR_H = 3.6                        # 门洞高（人 2.25 格，够宽）
ELEV_DOOR_Y1 = ELEV_DOOR_Y0 + ELEV_DOOR_H


def r2(v):
    return round(float(v) + 0.0, 3)


def room_cx(i):
    return ROOM_X[i] + ROOM_W * 0.5


def build():
    walls, props, seats, pod_floors, rugs, room_doors, beds = [], [], [], [], [], [], []

    # ── 外墙（西墙留出入口门洞） ────────────────────────────────────────
    walls.append({"x": 0, "y": 0, "w": W, "h": T})                       # 北
    walls.append({"x": 0, "y": H - T, "w": W, "h": T})                   # 南
    walls.append({"x": 0, "y": T, "w": T, "h": ENTR_Y0 - T})             # 西（出入口上方）
    walls.append({"x": 0, "y": ENTR_Y0 + ENTR_H, "w": T,
                  "h": (H - T) - (ENTR_Y0 + ENTR_H)})                    # 西（出入口下方）
    # 东墙：中间留出电梯门洞 —— 门就嵌在这面墙里（不再是一个浮在走廊上的盒子）
    walls.append({"x": W - T, "y": T, "w": T, "h": ELEV_DOOR_Y0 - T})     # 东（门洞北）
    walls.append({"x": W - T, "y": ELEV_DOOR_Y1, "w": T,
                  "h": (H - T) - ELEV_DOOR_Y1})                           # 东（门洞南）

    # 西端出入口的门
    props.append({"k": "door", "x": 0.1, "y": ENTR_Y0, "w": T - 0.2, "h": ENTR_H})

    # ── 房间与走廊之间的两堵横墙（每间留一个门洞） ──────────────────────
    for band_y in (A_Y0, B_Y0):
        cursor = X0
        for i in range(N):
            gap0 = room_cx(i) - DW * 0.5
            gap1 = gap0 + DW
            if gap0 - cursor > 0.01:
                walls.append({"x": r2(cursor), "y": band_y,
                              "w": r2(gap0 - cursor), "h": BAND})
            cursor = gap1
        if ROOM_END - cursor > 0.01:
            walls.append({"x": r2(cursor), "y": band_y,
                          "w": r2(ROOM_END - cursor), "h": BAND})

    # 每个门洞上的门 + 记录门的位置（给门牌/认领判定用）
    for i in range(N):
        dx = room_cx(i) - DW * 0.5
        props.append({"k": "door", "x": r2(dx), "y": A_Y0, "w": DW, "h": BAND})
        props.append({"k": "door", "x": r2(dx), "y": B_Y0, "w": DW, "h": BAND})
        room_doors.append({"index": i, "side": "n", "x": r2(dx), "y": A_Y0,
                           "w": DW, "h": BAND})
        room_doors.append({"index": N + i, "side": "s", "x": r2(dx), "y": B_Y0,
                           "w": DW, "h": BAND})

    # ── 房间之间的竖向隔墙 ──────────────────────────────────────────────
    for i in range(N - 1):
        px = ROOM_X[i] + ROOM_W
        walls.append({"x": px, "y": N_Y0, "w": PART, "h": (A_Y0 + BAND) - N_Y0})
        walls.append({"x": px, "y": B_Y0, "w": PART, "h": S_Y1 - B_Y0})

    # ── 每间宿舍：地胶 + 家具 ──────────────────────────────────────────
    bed_w, bed_h = 2.2, 3.6
    for i in range(N):
        rx = ROOM_X[i]
        for ry in (N_Y0, S_Y0):
            pod_floors.append({"x": rx, "y": ry, "w": ROOM_W, "h": ROOM_D})
            bx, by = r2(rx + 0.4), r2(ry + 0.6)
            props.append({"k": "bed", "x": bx, "y": by,
                          "w": bed_w, "h": bed_h, "solid": True})
            # 床位：认领了宿舍的人就是从这间房的这张床上出生的
            beds.append({"index": i if ry == N_Y0 else N + i,
                         "x": bx, "y": by, "w": bed_w, "h": bed_h})
            props.append({"k": "block", "x": r2(rx + 0.5), "y": r2(ry + 5.0),
                          "w": 1.6, "h": 2.4, "solid": True})
            props.append({"k": "desk", "x": r2(rx + 7.6), "y": r2(ry + 0.6),
                          "w": 3.4, "h": 2.0, "solid": True})
            seats.append({"id": "room%d_%s" % (i, "n" if ry == N_Y0 else "s"),
                          "x": r2(rx + 8.3), "y": r2(ry + 2.7),
                          "w": 2.0, "h": 1.5, "face": "up"})
            props.append({"k": "plant", "x": r2(rx + 10.1), "y": r2(ry + 5.6),
                          "w": 1.2, "h": 1.0, "solid": True})

    # ── 走廊：一条贯通东西的地毯（到电梯前室为止） ────────────────────
    rugs.append({"x": r2(X0 + 1), "y": r2(CR_Y0 + 1.5),
                 "w": r2(ELEV_X0 - 1 - X0 - 1), "h": r2(CR_H - 3.0)})

    # ── 电梯：嵌进东墙的门（门洞位置就是墙上的缺口） ──────────────────
    # 门本体同时当碰撞体用：东墙被切开一段，没有它人能顺着门洞走进墙外的虚空。
    props.append({"k": "elevator", "x": r2(W - T), "y": r2(ELEV_DOOR_Y0),
                  "w": r2(T), "h": r2(ELEV_DOOR_H), "solid": True})
    # 电梯前室的地面与标识（用一块地胶区分）
    pod_floors.append({"x": r2(ELEV_X0), "y": r2(ELEV_Y0),
                       "w": r2(ELEV_W), "h": r2(ELEV_H)})

    return {
        "id": "dorm_space",
        "name": "宿舍空间",
        "W": W, "H": H,
        # 出生点放在走廊西端（进楼的位置附近）
        "spawn": {"x": 6.0, "y": CR_Y0 + CR_H * 0.5},
        "exit": {"x": 0.5, "y": ENTR_Y0, "w": 1.5, "h": ENTR_H},
        # 电梯交互区：站在门前这一小块，按 E 弹楼层（不是整间前室）
        "elevator": {"x": r2(W - T - 2.2), "y": r2(ELEV_DOOR_Y0),
                     "w": 2.2, "h": r2(ELEV_DOOR_H)},
        "room_doors": room_doors,
        # 每间房的床（index 与 room_doors 一致）：认领后从这张床出生 / 躺着
        "beds": beds,
        "pod_floors": pod_floors,
        "rugs": rugs,
        "walls": walls,
        "props": props,
        "seats": seats,
    }


def ascii_plan(d):
    W, H = d["W"], d["H"]
    grid = [["." for _ in range(W)] for _ in range(H)]

    def fill(x, y, w, h, ch):
        for yy in range(int(y), int(round(y + h))):
            for xx in range(int(x), int(round(x + w))):
                if 0 <= yy < H and 0 <= xx < W:
                    grid[yy][xx] = ch

    for r in d["pod_floors"]:
        fill(r["x"], r["y"], r["w"], r["h"], ",")
    for r in d["rugs"]:
        fill(r["x"], r["y"], r["w"], r["h"], ":")
    for w in d["walls"]:
        fill(w["x"], w["y"], w["w"], w["h"], "#")
    for p in d["props"]:
        fill(p["x"], p["y"], p["w"], p["h"], {
            "desk": "D", "table": "t", "sofa": "S", "vending": "V",
            "plant": "*", "block": "+", "cushion": "o", "bed": "B",
            "door": "d", "elevator": "E", "board": "W",
        }.get(p["k"], "?"))
    for s in d["seats"]:
        fill(s["x"], s["y"], s["w"], s["h"], "C")
    sp = d["spawn"]
    grid[int(sp["y"])][int(sp["x"])] = "@"
    e = d["exit"]
    fill(e["x"], e["y"], e["w"], e["h"], "=")

    print("   " + "".join(str(i // 10 % 10) for i in range(W)))
    print("   " + "".join(str(i % 10) for i in range(W)))
    for y in range(H):
        print("%2d " % y + "".join(grid[y]))
    print("\n图例  # 墙/隔板   , 房间地胶   : 走廊地毯   B 床   D 桌   C 椅子   + 衣柜   "
          "* 绿植   d 门   E 电梯   = 出入口   @ 出生点")
    print("\n尺寸 %d × %d 格 = %d × %d px；房间 %d 间，座位 %d 个"
          % (W, H, W * 8, H * 8, N * 2, len(d["seats"])))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ascii", action="store_true", help="打印俯视草图")
    ap.add_argument("-o", "--out", default="assets/rooms/dorm_space.json")
    args = ap.parse_args()

    d = build()
    if args.ascii:
        ascii_plan(d)

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = os.path.join(root, args.out)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with io.open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(d, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print("\n已写入 %s（%d 字节）" % (args.out, os.path.getsize(path)))


if __name__ == "__main__":
    main()
