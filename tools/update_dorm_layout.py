#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""重排宿舍（dorm_space.json）：

1. 北墙分节：每间北屋的北墙开一段玻璃（glass:true，不画墙），窗 prop
   伸到房间矩形上沿之外（y=-9..0）—— 玻璃是透明的，透出房间背后那层天
   （RoomSky），和图书馆北墙落地窗同一套做法。有窗之后 Arena 的
   view_top_px() 会自动放宽相机上边界、镜头上抬，背景才看得见。
2. 每间屋的家具从「床+箱+桌+植物 全部一样」换成四种款式轮换
   （学习 / 储物 / 书桌 / 电竞），家具用 OGA 切片图集的新 kind
   （见 room_prop.gd 的 _DORM_KIND_CELL），尺寸 = cell × DORM_SCALE。
3. beds 数组同步搬到新床的 rect（ beds 驱动躺下交互与房间门牌，
   rect 必须和画的床一致，否则躺姿位置对不上）。
4. 走廊补两台自动售货机之间的陈设：售货机、长椅（程序画的沙发）、
   沿途盆栽 —— 只占走廊南北两条边，中间留足走道。

幂等：每次运行都从固定模板重建 walls / props / beds，跑多少遍结果一致。
seats / room_doors / pod_floors / rugs / spawn / exit / elevator 不动。
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PATH = os.path.join(ROOT, "assets", "rooms", "dorm_space.json")

# 北屋 / 南屋的 pod 左上角（格）。pod 内部 12×8。
NORTH_X = [2, 15, 28, 41, 54, 67, 80]
NORTH_Y = 2
SOUTH_Y = 20

# 窗：每间北屋一扇，跨在北墙开口上、向上伸出房间矩形（局部格）
WIN_W = 5.4
WIN_X_OFF = 3.3     # 开口左缘相对 pod 左缘
WIN_Y = -9.0
WIN_H = 9.0

# 家具尺寸（格）= 图集 cell 像素 × DORM_SCALE(1.5) ÷ 8px/格
BED = (4.6875, 2.625)
WARDROBE = (2.8125, 3.75)
SHELF = (2.0625, 3.75)          # dbshelf / dshelf 共用
DESK = (3.75, 2.625)            # ddesk（桌面堆了东西的俯视书桌，无椅）
TABLE = (3.75, 2.25)
PCDESK = (3.75, 2.8125)         # pcdesk（带显示器和塞进去的椅子，装饰用）
STOOL = (1.5, 1.6875)
BOX = (1.3125, 1.875)

# 固定书桌位：右上方，正对座位（seat 朝上，坐下来面向桌面）
DESK_POS = (7.5, 0.4)

# 四种款式。坐标是 pod 内偏移（格）。床的位置变体会同步进 beds 数组。
# A 学习舱：床左上 + 书桌 + 衣柜 + 盆栽
# B 储物舱：书桌 + 床右下 + 矮书架 + 纸箱 + 圆凳
# C 书桌舱：空桌当书桌 + 床左上 + 高书柜 + 盆栽
# D 电竞舱：书桌 + 床左上 + 第二张电脑桌（南墙边，自带椅子）+ 衣柜
VARIANTS = [
    {
        "bed": (0.7, 0.9),
        "props": [
            ("ddesk", DESK_POS, DESK),
            ("dormbed", (0.7, 0.9), BED),
            ("wardrobe", (0.7, 4.0), WARDROBE),
            ("plant", (10.5, 6.7), (1.2, 1.0)),
        ],
    },
    {
        "bed": (6.9, 4.3),
        "props": [
            ("ddesk", DESK_POS, DESK),
            ("dormbed", (6.9, 4.3), BED),
            ("dshelf", (0.7, 4.0), SHELF),
            ("dbox", (3.0, 5.9), BOX),
            ("dstool", (9.9, 3.3), STOOL),
        ],
    },
    {
        "bed": (0.7, 0.9),
        "props": [
            ("dtable", DESK_POS, TABLE),
            ("dormbed", (0.7, 0.9), BED),
            ("dbshelf", (0.7, 4.0), SHELF),
            ("plant", (10.5, 6.7), (1.2, 1.0)),
        ],
    },
    {
        "bed": (0.7, 0.9),
        "props": [
            ("ddesk", DESK_POS, DESK),
            ("dormbed", (0.7, 0.9), BED),
            ("pcdesk", (0.7, 6.6), PCDESK),
            ("wardrobe", (9.0, 4.2), WARDROBE),
        ],
    },
]

# 走廊陈设（全局格坐标）：走廊 y=12..18，只占南北两条边
CORRIDOR_PROPS = [
    {"k": "vending", "x": 87.2, "y": 12.4, "w": 1.8, "h": 2.6, "solid": True},
    {"k": "sofa", "x": 2.6, "y": 15.3, "w": 4.5, "h": 2.2, "solid": True, "v": 0},
    {"k": "plant", "x": 13.2, "y": 12.2, "w": 1.2, "h": 1.0, "solid": True},
    {"k": "plant", "x": 26.2, "y": 16.6, "w": 1.2, "h": 1.0, "solid": True},
    {"k": "plant", "x": 39.2, "y": 12.2, "w": 1.2, "h": 1.0, "solid": True},
    {"k": "plant", "x": 52.2, "y": 16.6, "w": 1.2, "h": 1.0, "solid": True},
    {"k": "plant", "x": 65.2, "y": 12.2, "w": 1.2, "h": 1.0, "solid": True},
    {"k": "plant", "x": 78.2, "y": 16.6, "w": 1.2, "h": 1.0, "solid": True},
]


def split_north_wall(walls):
    """北墙 (0,0,94,2) 按窗开口切段：开口处 glass:true（不画墙、保留碰撞）。"""
    openings = sorted((px + WIN_X_OFF, px + WIN_X_OFF + WIN_W) for px in NORTH_X)
    x = 0.0
    for a, b in openings:
        if b <= a:
            continue
        if a > x:
            walls.append({"x": x, "y": 0, "w": a - x, "h": 2})
        walls.append({"x": a, "y": 0, "w": b - a, "h": 2, "glass": True})
        x = b
    if x < 94.0:
        walls.append({"x": x, "y": 0, "w": 94.0 - x, "h": 2})


def main():
    with open(PATH, encoding="utf-8") as f:
        data = json.load(f)

    walls = []
    for w in data["walls"]:
        if w["y"] == 0:
            continue    # 北墙那一条（含旧整条 / 已切好的段），每次从整条重切
        walls.append(w)
    split_north_wall(walls)
    # 幂等：split 输入是干净的整条，输出段数固定；防手滑再保险一层
    assert len([w for w in walls if w["y"] == 0]) == 15, walls
    data["walls"] = walls

    # 窗 prop（无碰撞，玻璃透明）
    windows = [{"k": "window", "x": px + WIN_X_OFF, "y": WIN_Y,
                "w": WIN_W, "h": WIN_H} for px in NORTH_X]

    # 保留：门、电梯；其余 pod 内家具全部重建
    keep = [p for p in data["props"] if p.get("k") in ("door", "elevator")]
    props = list(windows) + keep + list(CORRIDOR_PROPS)

    beds = []
    idx = 0
    for px, py in [(x, NORTH_Y) for x in NORTH_X] + \
                  [(x, SOUTH_Y) for x in NORTH_X]:
        v = VARIANTS[idx % 4 if py == NORTH_Y else (idx + 1) % 4]
        for kind, (ox, oy), (w, h) in v["props"]:
            solid = kind != "plant"
            props.append({"k": kind, "x": px + ox, "y": py + oy,
                          "w": w, "h": h, "solid": solid})
        bx, by = v["bed"]
        beds.append({"index": idx, "x": px + bx, "y": py + by,
                     "w": BED[0], "h": BED[1]})
        idx += 1

    data["props"] = props
    data["beds"] = beds

    with open(PATH, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    print("walls=%d props=%d beds=%d windows=%d" % (
        len(walls), len(props), len(beds), len(windows)))


if __name__ == "__main__":
    main()
