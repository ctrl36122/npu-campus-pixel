#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 SkyOffice 的房间布局导成「像素工大」的内景数据。

只取坐标，不取美术。
  SkyOffice 的代码是 MIT，可以直接用；但它读的图集是 LimeZu「Modern Interiors」
  商业素材包，那些 PNG 不能随仓库分发。所以这里只搬物件位置，画由我们自己的
  程序化绘制负责 —— 跟校园地图一样，零外部素材。

尺度换算
  SkyOffice：人物 32 px、房间 30 格高（960 px），人／房 = 1/30。
  我们    ：人物 26 px，要维持同样观感，房间高应为 26×30 = 780 px = 97.5 格。
  ⇒ SkyOffice 的 1 格（32 px）对应 26 px，即 3.25 格（本项 8 px/格）。
     50 格宽的地图 → 130 格宽。

输出
  assets/rooms/game_lounge.json   —— 房间骨架（地板 / 墙 / 家具 / 座位 / 出口）
  assets/rooms/game_lounge.svg    —— 平面图预览（--svg），只用于目视校对

用法
  python tools/import_skyoffice_room.py
  python tools/import_skyoffice_room.py --svg
"""

from __future__ import annotations

import io
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

SRC = os.path.join(
    os.path.dirname(ROOT), "SkyOffice-master", "client", "public", "assets", "map", "map.json"
)
OUT_DIR = os.path.join(ROOT, "assets", "rooms")
OUT_JSON = os.path.join(OUT_DIR, "game_lounge.json")
OUT_SVG = os.path.join(OUT_DIR, "game_lounge.svg")

SCALE = 3.25      # SkyOffice 格 → 本项目格
TS = 8            # 本项目格边长（像素）

# 图层 → 语义类型。名字就写在 Tiled 里，照它来，不猜。
LAYER_KIND = {
    "Wall": "wall",
    "ObjectsOnCollide": "table",
    "GenericObjectsOnCollide": "block",
    "GenericObjects": "deco",
    "Computer": "desk",
    "Whiteboard": "board",
    "VendingMachine": "vending",
    "Basement": "pit",
}

# 会挡住玩家的类型（椅子不挡 —— 要能坐进去）
SOLID = {"wall", "table", "desk", "vending", "block", "pit"}


def load_src(path: str) -> dict:
    with io.open(path, encoding="utf-8") as f:
        return json.load(f)


def grid_rects(doc: dict) -> dict[str, list[tuple[float, float, float, float]]]:
    """把每个 objectgroup 图层转成「格坐标矩形」列表。

    Tiled 的对象 y 是底边，减掉 height 才得到顶边。
    """
    tw = doc["tilewidth"]
    th = doc["tileheight"]
    out: dict[str, list[tuple[float, float, float, float]]] = {}
    for layer in doc["layers"]:
        if layer.get("type") != "objectgroup":
            continue
        rs = []
        for o in layer.get("objects", []):
            w = float(o.get("width", tw)) / tw
            h = float(o.get("height", th)) / th
            x = float(o["x"]) / tw
            y = (float(o["y"]) - float(o.get("height", th))) / th
            rs.append((x, y, w, h))
        out[layer["name"]] = rs
    return out


def merge_rects(rs: list[tuple[float, float, float, float]]) -> list[tuple[float, float, float, float]]:
    """把一格一格的瓦片合成整块。

    先按行横向合并相邻瓦片，再把「同 x、同宽、上下相接」的横条纵向合并。
    一张 7×2 的长桌会从 14 个 1×1 变成 1 个 7×2。
    """
    if not rs:
        return []

    # 同一格上常常叠了好几个 sprite 层（桌体 + 桌面 + 餐盘），先按矩形去重，
    # 否则「左边缘 = 上一块右边缘」的判断会被同坐标的第二块打断，合并不起来。
    rs = sorted({(round(x, 2), round(y, 2), round(w, 2), round(h, 2)) for x, y, w, h in rs})

    rows: dict[tuple[float, float], list[tuple[float, float]]] = {}
    for x, y, w, h in rs:
        rows.setdefault((round(y, 2), round(h, 2)), []).append((x, w))

    horiz: list[tuple[float, float, float, float]] = []
    for (y, h) in sorted(rows):
        items = sorted(rows[(y, h)])
        cx, cw = items[0]
        for x, w in items[1:]:
            if abs(x - (cx + cw)) < 0.01:
                cw += w
            else:
                horiz.append((cx, y, cw, h))
                cx, cw = x, w
        horiz.append((cx, y, cw, h))

    cols: dict[tuple[float, float], list[tuple[float, float]]] = {}
    for x, y, w, h in horiz:
        cols.setdefault((round(x, 2), round(w, 2)), []).append((y, h))

    out: list[tuple[float, float, float, float]] = []
    for (x, w) in sorted(cols):
        items = sorted(cols[(x, w)])
        cy, ch = items[0]
        for y, h in items[1:]:
            if abs(y - (cy + ch)) < 0.01:
                ch += h
            else:
                out.append((x, cy, w, ch))
                cy, ch = y, h
        out.append((x, cy, w, ch))
    return out


def floor_bbox(doc: dict) -> tuple[float, float, float, float]:
    """Ground 图层里所有非零瓦片的包围盒（格）。"""
    w = doc["width"]
    for layer in doc["layers"]:
        if layer.get("type") != "tilelayer" or layer["name"] != "Ground":
            continue
        xs, ys = [], []
        for i, v in enumerate(layer["data"]):
            if v:
                xs.append(i % w)
                ys.append(i // w)
        return (min(xs), min(ys), max(xs) - min(xs) + 1, max(ys) - min(ys) + 1)
    raise SystemExit("找不到 Ground 图层")


def r2(v: float) -> float:
    return round(v, 2)


def build() -> dict:
    doc = load_src(SRC)
    tw = doc["tilewidth"]
    layers = grid_rects(doc)

    fx, fy, fw, fh = floor_bbox(doc)

    # 平移：让地板左上角成为原点，房间尺寸就等于地板尺寸，不留多余空白
    ox, oy = fx, fy
    W = fw * SCALE
    H = fh * SCALE

    def conv(x: float, y: float, w: float, h: float) -> dict:
        return {
            "x": r2((x - ox) * SCALE),
            "y": r2((y - oy) * SCALE),
            "w": r2(w * SCALE),
            "h": r2(h * SCALE),
        }

    parts: list[dict] = []

    # ── 墙 / 长桌 / 家具 ──────────────────────────────────────────
    for layer_name, kind in LAYER_KIND.items():
        rs = layers.get(layer_name, [])
        if not rs:
            continue
        # 白板/工位/贩卖机是整件家具，坐标本身就是整块，不拆也不合；其余都合并
        if kind in ("board", "desk", "vending"):
            merged = rs
        else:
            merged = merge_rects(rs)
        for i, (x, y, w, h) in enumerate(sorted(merged, key=lambda t: (t[1], t[0]))):
            p = conv(x, y, w, h)
            p["k"] = kind
            p["src"] = f"{layer_name}#{i}"
            p["solid"] = kind in SOLID
            parts.append(p)

    # ── 去掉被工位整条覆盖的桌板 ─────────────────────────────────
    # ObjectsOnCollide 里那条 9 格长桌其实和 Computer 层的三个工位是同一张桌子
    # 的两个图层（桌体 + 显示器套装），留着会和 desk 叠成双层，画面发脏。
    desks = [p for p in parts if p["k"] == "desk"]
    cleaned: list[dict] = []
    dropped = 0
    for p in parts:
        if p["k"] == "table":
            covered = 0.0
            for d in desks:
                ix = max(0.0, min(p["x"] + p["w"], d["x"] + d["w"]) - max(p["x"], d["x"]))
                iy = max(0.0, min(p["y"] + p["h"], d["y"] + d["h"]) - max(p["y"], d["y"]))
                covered += ix * iy
            if covered > p["w"] * p["h"] * 0.6:
                dropped += 1
                continue
        cleaned.append(p)
    parts = cleaned

    # ── 去掉压在门口的家具 ────────────────────────────────────────
    # SkyOffice 门口那两块 2×2 瓦片其实是地垫，因为躺在 ObjectsOnCollide 层
    # 被当成桌子导进来了 —— 留着就变成「一进门口摆着一张桌」，人直接站桌上。
    gx = (25.0 - ox) * SCALE
    gy = (26.0 - oy) * SCALE
    gw = 2.0 * SCALE
    gh = 3.0 * SCALE
    cleaned2: list[dict] = []
    for p in parts:
        if p["k"] == "table":
            ix = max(0.0, min(p["x"] + p["w"], gx + gw) - max(p["x"], gx))
            iy = max(0.0, min(p["y"] + p["h"], gy + gh) - max(p["y"], gy))
            if ix * iy > p["w"] * p["h"] * 0.5:
                dropped += 1
                continue
        cleaned2.append(p)
    parts = cleaned2

    # ── 椅子：单独一层，一个都不合并 ──────────────────────────────
    seats: list[dict] = []
    for i, (x, y, w, h) in enumerate(sorted(layers.get("Chair", []), key=lambda t: (t[1], t[0]))):
        s = conv(x, y, w, h)
        s["dir"] = "back"            # 俯视 2.5D：默认背对镜头（坐着的人）
        s["id"] = i
        seats.append(s)

    # ── 工位上的显示器：后续要做「屏幕发光 / 共享画面」的挂点 ─────
    screens = []
    for p in parts:
        if p["k"] != "desk":
            continue
        screens.append({
            "x": r2(p["x"] + p["w"] * 0.25),
            "y": r2(p["y"] - 2.5),          # 立在桌面靠后
            "w": r2(p["w"] * 0.5),
            "h": 3.0,
            "desk": p["src"],
        })

    # ── 出入口：SkyOffice 的门垫在 (25..27, 26..29) ────────────────
    gate = conv(25.0, 26.0, 2.0, 3.0)
    spawn = {
        "x": r2(gate["x"] + gate["w"] * 0.5),
        "y": r2(gate["y"] + gate["h"] - 1.0),
    }

    # 落点必须能站人：往上挪到第一处不压碰撞体的位置
    def blocked(px: float, py: float) -> bool:
        for p in parts:
            if not p["solid"]:
                continue
            if p["x"] - 1.2 <= px <= p["x"] + p["w"] + 1.2 and p["y"] - 1.0 <= py <= p["y"] + p["h"] + 1.0:
                return True
        return False

    for step in range(40):
        if not blocked(spawn["x"], spawn["y"] - step * 2.0):
            spawn["y"] = r2(spawn["y"] - step * 2.0)
            break

    room = {
        "id": "game_lounge",
        "name": "游戏搭子空间",
        "desc": "五台机位，三块白板，一台贩卖机。",
        "W": r2(W),
        "H": r2(H),
        "TS": TS,
        "floor": {"x": 0.0, "y": 0.0, "w": r2(W), "h": r2(H)},
        "bounds": {"x": 0.0, "y": 0.0, "w": r2(W), "h": r2(H)},
        "spawn": spawn,
        "exit": gate,
        "walls": [p for p in parts if p["k"] == "wall"],
        "props": [p for p in parts if p["k"] != "wall"],
        "seats": seats,
        "screens": screens,
        "source": {
            "from": "SkyOffice-master/client/public/assets/map/map.json",
            "grid": [doc["width"], doc["height"]],
            "tile_px": tw,
            "scale": SCALE,
            "offset_cells": [ox, oy],
            "note": "只取布局坐标；美术为 LimeZu Modern Interiors 商业素材，未复制",
        },
    }
    return room


def summary(room: dict) -> None:
    print(f"房间 {room['W']} × {room['H']} 格  ({room['W']*TS:.0f} × {room['H']*TS:.0f} px)")
    print(f"落点 ({room['spawn']['x']}, {room['spawn']['y']})   出口 "
          f"({room['exit']['x']}, {room['exit']['y']}, {room['exit']['w']}×{room['exit']['h']})")
    print()
    kinds: dict[str, int] = {}
    for p in room["props"]:
        kinds[p["k"]] = kinds.get(p["k"], 0) + 1
    print(f"{'墙':<8}{len(room['walls'])} 段")
    for k, n in sorted(kinds.items(), key=lambda t: -t[1]):
        print(f"{k:<8}{n} 件")
    print(f"{'椅子':<8}{len(room['seats'])} 把")
    print(f"{'显示器':<8}{len(room['screens'])} 台")
    print()
    print("── 工位 ──")
    for i, p in enumerate(room["props"]):
        if p["k"] == "desk":
            print(f"  #{i}  ({p['x']:6.2f}, {p['y']:6.2f})  {p['w']}×{p['h']}")
    print("── 白板 ──")
    for i, p in enumerate(room["props"]):
        if p["k"] == "board":
            print(f"  #{i}  ({p['x']:6.2f}, {p['y']:6.2f})  {p['w']}×{p['h']}")


def svg(room: dict, path: str) -> None:
    """画一张平面图，用来目视校对坐标有没有错位。"""
    S = 6.0
    pad = 10
    vw = room["W"] * S + pad * 2
    vh = room["H"] * S + pad * 2
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {vw:.0f} {vh:.0f}" width="{vw:.0f}" height="{vh:.0f}">']
    out.append('<rect width="100%" height="100%" fill="#0b1118"/>')

    def rect(x, y, w, h, fill, stroke="", sw=0.8, op=1.0, rx=0):
        s = f' stroke="{stroke}" stroke-width="{sw}"' if stroke else ""
        r = f' rx="{rx}"' if rx else ""
        out.append(
            f'<rect x="{pad + x*S:.1f}" y="{pad + y*S:.1f}" width="{w*S:.1f}" height="{h*S:.1f}" '
            f'fill="{fill}" opacity="{op}"{s}{r}/>'
        )

    # 地板 + 网格
    out.append(
        f'<rect x="{pad}" y="{pad}" width="{room["W"]*S:.1f}" height="{room["H"]*S:.1f}" '
        f'fill="#1a2430" stroke="#2c3a48"/>'
    )
    step = 10
    gx = 0.0
    while gx <= room["W"]:
        out.append(f'<line x1="{pad+gx*S:.1f}" y1="{pad}" x2="{pad+gx*S:.1f}" y2="{pad+room["H"]*S:.1f}" stroke="#222d38" stroke-width="0.5"/>')
        gx += step
    gy = 0.0
    while gy <= room["H"]:
        out.append(f'<line x1="{pad}" y1="{pad+gy*S:.1f}" x2="{pad+room["W"]*S:.1f}" y2="{pad+gy*S:.1f}" stroke="#222d38" stroke-width="0.5"/>')
        gy += step

    COLOR = {
        "wall": "#5d7488",
        "table": "#3f5266",
        "block": "#4a4258",
        "deco": "#2f4a3c",
        "desk": "#2b6f8f",
        "board": "#e8eef4",
        "vending": "#7a4b8c",
        "pit": "#191d24",
    }

    for p in room["walls"]:
        rect(p["x"], p["y"], p["w"], p["h"], COLOR["wall"])
    for p in room["props"]:
        rect(p["x"], p["y"], p["w"], p["h"], COLOR.get(p["k"], "#ffffff"), op=0.92)
    for s in room["seats"]:
        out.append(
            f'<rect x="{pad+s["x"]*S+1.2:.1f}" y="{pad+s["y"]*S+1.2:.1f}" '
            f'width="{s["w"]*S-2.4:.1f}" height="{s["h"]*S-2.4:.1f}" fill="#c98a4b" opacity="0.9" rx="3"/>'
        )
    for i, sc in enumerate(room["screens"]):
        rect(sc["x"], sc["y"], sc["w"], sc["h"], "#7fe6ff")
        out.append(
            f'<text x="{pad+(sc["x"]+sc["w"]/2)*S:.1f}" y="{pad+(sc["y"]+sc["h"]/2+0.6)*S:.1f}" '
            f'font-size="9" fill="#05222b" text-anchor="middle" font-family="monospace" font-weight="bold">{i+1}</text>'
        )

    sp = room["spawn"]
    out.append(f'<circle cx="{pad+sp["x"]*S:.1f}" cy="{pad+sp["y"]*S:.1f}" r="5" fill="#ffd166" stroke="#8a6d1f"/>')
    out.append(
        f'<text x="{pad+sp["x"]*S:.1f}" y="{pad+sp["y"]*S+16:.1f}" font-size="9" fill="#ffd166" '
        f'text-anchor="middle" font-family="monospace">spawn</text>'
    )
    e = room["exit"]
    rect(e["x"], e["y"], e["w"], e["h"], "#ffd166", stroke="#8a6d1f", sw=1.2, op=0.25)
    out.append("</svg>")

    with io.open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out))


def main() -> int:
    if not os.path.exists(SRC):
        print(f"找不到源文件：{SRC}")
        print("（SkyOffice 解压在项目同级目录，目录名 SkyOffice-master）")
        return 1

    room = build()
    os.makedirs(OUT_DIR, exist_ok=True)

    text = json.dumps(room, ensure_ascii=False, indent=1, separators=(",", ": "))
    with io.open(OUT_JSON, "w", encoding="utf-8", newline="\n") as f:
        f.write(text + "\n")

    summary(room)
    print()
    print(f"→ {os.path.relpath(OUT_JSON, ROOT)}  ({len(text)/1024:.1f} KB)")

    if "--svg" in sys.argv:
        svg(room, OUT_SVG)
        print(f"→ {os.path.relpath(OUT_SVG, ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
