#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成「宿舍空间」的房间数据（assets/rooms/dorm_space.json）。

一排小隔间 + 中间的休息区，全部按本项目的 8px/格 尺度排的。
加 --ascii 打印俯视草图，方便核对隔间、桌椅、门的位置。

尺度怎么定的（别随手改，改了所有家具都会失调）：
  人物约 18px 高（2.25 格）、11px 宽（1.4 格），这是唯一的标尺。
  - 隔间内净宽 5 格 = 40px ≈ 3.6 个人宽，桌宽 4 格（32px）刚好塞满，
    两侧各留半格 —— 像网吧的独立包厢，不是空房间。
  - 桌深 1.75 格（14px），椅子 2×1.5 格，人坐进去贴着桌沿。
  - 房高 34 格（272px）在室内视距 2.7 下正好一屏，进门一眼看全。
"""

import argparse
import io
import json
import os

# ── 房间整体 ────────────────────────────────────────────────────────────
W, H = 59, 22
T = 2                       # 外墙厚度

# ── 隔间 ────────────────────────────────────────────────────────────────
POD_N = 8                   # 隔间数
POD_W = 6                   # 每个隔间占地（净宽 5 + 右隔板 1）
POD_X0 = 2
POD_Y0 = 2
POD_H = 7                   # 隔间深度（2 .. 9）
PART_W = 1                  # 隔板厚度

DESK_W, DESK_D = 4, 2.25    # 桌宽 / 桌深（格）
CHAIR_W, CHAIR_H = 2.0, 1.5

DOOR_X0, DOOR_W = 26, 6     # 南墙的门洞


def r2(v):
    return round(float(v) + 0.0, 3)


def build():
    walls, props, seats, pod_floors, rugs = [], [], [], [], []

    # ── 外墙（南墙留门洞） ──────────────────────────────────────────────
    walls.append({"x": 0, "y": 0, "w": W, "h": T})                       # 北
    walls.append({"x": 0, "y": T, "w": T, "h": H - T * 2})               # 西
    walls.append({"x": W - T, "y": T, "w": T, "h": H - T * 2})           # 东
    walls.append({"x": 0, "y": H - T, "w": DOOR_X0, "h": T})             # 南（左段）
    walls.append({"x": DOOR_X0 + DOOR_W, "y": H - T,
                  "w": W - DOOR_X0 - DOOR_W, "h": T})                    # 南（右段）
    # 门垛：让门像是「开在墙上」，而不是墙断了一截
    walls.append({"x": DOOR_X0 - 1, "y": H - T - 1.5, "w": 1, "h": 1.5})
    walls.append({"x": DOOR_X0 + DOOR_W, "y": H - T - 1.5, "w": 1, "h": 1.5})

    # ── 隔间 ────────────────────────────────────────────────────────────
    for k in range(POD_N):
        px = POD_X0 + k * POD_W
        inner = POD_W - PART_W                      # 净宽
        pod_floors.append({"x": px, "y": POD_Y0, "w": inner, "h": POD_H})

        # 隔板（最后一间靠着东侧区域，不用再立）
        if k < POD_N - 1:
            walls.append({"x": px + inner, "y": POD_Y0, "w": PART_W, "h": POD_H})

        # 桌子：贴北墙，居中
        props.append({
            "k": "desk",
            "x": r2(px + (inner - DESK_W) * 0.5), "y": r2(POD_Y0 + 0.3),
            "w": DESK_W, "h": DESK_D, "solid": True,
        })

        # 椅子：桌子正前方，跟桌沿留半格
        seats.append({
            "id": "pod%d" % k,
            "x": r2(px + (inner - CHAIR_W) * 0.5), "y": r2(POD_Y0 + 3.1),
            "w": CHAIR_W, "h": CHAIR_H, "face": "up",
        })

        # 隔间角落一件小物：交替放收纳箱 / 绿植，地板别空着
        props.append({
            "k": "block" if k % 2 == 0 else "plant",
            "x": r2(px + 0.4), "y": r2(POD_Y0 + 4.6),
            "w": 1.3, "h": 1.2, "solid": True,
        })

    # 门：把南墙的门洞填上（洞外是虚空，不加门就是一块纯黑）
    props.append({"k": "door", "x": DOOR_X0, "y": H - T - 0.8,
                  "w": DOOR_W, "h": T + 0.8})

    # ── 休息区 ──────────────────────────────────────────────────────────
    rugs.append({"x": 23, "y": 12.6, "w": 12.5, "h": 6.2})

    # 沙发：摆在休息区北侧、面朝镜头（也就是面朝门口）
    props.append({"k": "sofa", "x": 27.4, "y": 10.8, "w": 3.8, "h": 1.5, "solid": True})
    # 茶几
    props.append({"k": "table", "x": 28.4, "y": 14.2, "w": 2.4, "h": 1.2, "solid": True})
    # 地毯上的坐垫
    props.append({"k": "cushion", "x": 24.2, "y": 17.2, "w": 1.3, "h": 1.0})
    props.append({"k": "cushion", "x": 33.4, "y": 17.2, "w": 1.3, "h": 1.0})

    # 西侧聊天角：一张矮桌 + 两个坐垫，把左半边填起来
    props.append({"k": "table", "x": 9.2, "y": 14.4, "w": 2.6, "h": 1.2, "solid": True})
    props.append({"k": "cushion", "x": 8.0, "y": 16.6, "w": 1.3, "h": 1.0})
    props.append({"k": "cushion", "x": 11.4, "y": 16.6, "w": 1.3, "h": 1.0})
    props.append({"k": "cushion", "x": 10.0, "y": 12.0, "w": 1.3, "h": 1.0})
    # 西墙的书架（用柜子代替，跨两格高）
    props.append({"k": "block", "x": 2.4, "y": 12.4, "w": 1.4, "h": 2.2, "solid": True})
    props.append({"k": "block", "x": 2.4, "y": 15.0, "w": 1.4, "h": 2.2, "solid": True})

    # 贩卖机：东侧空档、贴东墙
    props.append({"k": "vending", "x": 55.0, "y": 10.2, "w": 1.7, "h": 1.4, "solid": True})
    # 收纳柜
    props.append({"k": "block", "x": 52.0, "y": 12.0, "w": 1.4, "h": 1.9, "solid": True})
    props.append({"k": "block", "x": 52.0, "y": 14.4, "w": 1.4, "h": 1.9, "solid": True})
    # 绿植：墙角 / 过道边
    for (gx, gy) in [(2.4, 10.2), (43.5, 17.8), (48.5, 10.4), (55.4, 17.2), (40, 17.8)]:
        props.append({"k": "plant", "x": r2(gx), "y": r2(gy), "w": 1.2, "h": 1.0, "solid": True})

    return {
        "id": "dorm_space",
        "name": "宿舍空间",
        "W": W, "H": H,
        "spawn": {"x": DOOR_X0 + DOOR_W * 0.5, "y": H - T - 2.5},
        "exit": {"x": DOOR_X0 + 0.5, "y": H - T - 1.5, "w": DOOR_W - 1, "h": 1.5},
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
        fill(p["x"], p["y"], p["w"], p["h"], {"desk": "D", "table": "t", "sofa": "S",
                                              "vending": "V", "plant": "*", "block": "+",
                                              "cushion": "o"}.get(p["k"], "?"))
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
    print("\n图例  # 墙/隔板   , 隔间地面   : 地毯   D 工位桌   C 椅子   S 沙发   "
          "t 茶几   V 贩卖机   * 绿植   + 柜子   o 坐垫   = 门垫   @ 出生点")
    print("\n尺寸 %d × %d 格 = %d × %d px；隔间 %d 个，座位 %d 个"
          % (W, H, W * 8, H * 8, POD_N, len(d["seats"])))


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
