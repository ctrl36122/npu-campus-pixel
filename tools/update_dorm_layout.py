#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""重排宿舍（dorm_space.json）：

1. 北墙按窗位置切段：窗洞那几段的墙「立面」留空（face_gap），墙顶那道挤出
   照画 —— 墙的轮廓还在，但窗后面没有任何墙面挡着。窗本身是独立 prop
   （panel:true，画框/窗棂/窗台），玻璃是**真透明**的，透出来的就是房间
   背后那片天（Room._bake_floor 还会在窗底下把地板挖个洞）。
   ⚠️ 窗**不能伸出房间矩形**（y 必须 ≥ 0）：Arena.view_top_px() 一看到窗在
   房间上沿之外就会放宽相机上边界并整体抬镜头，整间宿舍被压到屏幕下半截 ——
   11-15 做过一版 43×72 的「真·落地窗」，直接被否了。
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

# 窗：每间北屋一扇，嵌在北墙立面里（RISE_WALL=13px 高的那条立面）。
# 墙在 y=0..2 格（0..16px），立面画在 3..16px；窗就落在这个区间里：
#   y = 0.4 格 → 3.2px（窗顶贴着墙立面顶端）
#   h = 1.6 格 → 12.8px，下沿正好 16px = pod 地板线
WIN_W = 6.2
WIN_X_OFF = 2.9     # 相对 pod 左缘，pod 宽 12 格 ⇒ 窗居中
WIN_Y = 0.4
WIN_H = 1.6

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
        # 床回左上角：原来那版把床摆在右下（6.9, 4.3），正好盖住门内侧的
        # 猫窝（Arena 按「门中心 +1.5 格、y=7.4」摆 CatBed），实机是床压着窝。
        # 矮书架和纸箱挪到左下角，圆凳贴着书桌放。
        "bed": (0.6, 0.9),
        "props": [
            ("ddesk", DESK_POS, DESK),
            ("dormbed", (0.6, 0.9), BED),
            ("dshelf", (0.7, 4.4), SHELF),
            ("dbox", (3.2, 6.1), BOX),
            ("dstool", (5.5, 1.5), STOOL),
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
            ("wardrobe", (8.9, 6.2), WARDROBE),
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
    """北墙按窗位置切段：窗洞段的墙「立面」留空（face_gap），墙顶的挤出照画。

    这样窗是真的洞：墙的轮廓还在（上面那道墙顶面不断），但窗后面没有任何
    墙面挡着，玻璃透出来的就是房间背后那片天（RoomSky 的云和山）。
    窗本身是独立 prop（见下面的 windows），画框、窗棂和窗台。
    """
    openings = sorted((px + WIN_X_OFF, px + WIN_X_OFF + WIN_W) for px in NORTH_X)
    x = 0.0
    for a, b in openings:
        if b <= a:
            continue
        if a > x:
            walls.append({"x": x, "y": 0, "w": a - x, "h": 2})
        walls.append({"x": a, "y": 0, "w": b - a, "h": 2, "face_gap": True})
        x = b
    if x < 94.0:
        walls.append({"x": x, "y": 0, "w": 94.0 - x, "h": 2})


def main():
    with open(PATH, encoding="utf-8") as f:
        data = json.load(f)

    walls = []
    for w in data["walls"]:
        if w["y"] == 0:
            continue    # 北墙：整条重来（旧版切过段 / 整条都有可能）
        walls.append(w)
    split_north_wall(walls)
    # 幂等：7 扇窗 ⇒ 15 段，每段都是从整条重切出来的，跑多少遍都一样
    assert len([w for w in walls if w["y"] == 0]) == 15, walls
    data["walls"] = walls

    # 窗 prop：嵌在墙立面里，不伸出房间矩形（y>=0，相机因此保持原样）
    windows = [{"k": "window", "x": px + WIN_X_OFF, "y": WIN_Y,
                "w": WIN_W, "h": WIN_H, "panel": True} for px in NORTH_X]

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

    # 猫窝留位自检：Arena 把 CatBed 摆在各间屋门的右侧（门中心 +1.5 格，
    # 北排 y=7.4 / 南排 y=25.8），这里按 pod 内 (6..9, 4.4..6.8) 格留空。
    # 家具压上去就是实机里「床盖住猫窝」，改布局时这一步别删。
    bad = []
    for p in props:
        if p["k"] in ("door", "window"):
            continue
        for px, py in [(x, NORTH_Y) for x in NORTH_X] + [(x, SOUTH_Y) for x in NORTH_X]:
            box = (px + 6.0, py + 4.2, px + 10.0, py + 5.5)
            r = (p["x"], p["y"], p["x"] + p["w"], p["y"] + p["h"])
            if r[0] < box[2] and r[2] > box[0] and r[1] < box[3] and r[3] > box[1]:
                bad.append((p["k"], round(p["x"], 2), round(p["y"], 2)))
    assert not bad, "这些家具压到猫窝了：%s" % bad

    with open(PATH, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    print("walls=%d props=%d beds=%d windows=%d" % (
        len(walls), len(props), len(beds), len(windows)))


if __name__ == "__main__":
    main()
