#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把烘焙好的地面贴图分类成「地面材质图」，给脚步声用（也方便以后做别的按地表的判定）。

产出（每格 1 像素，整张 424x800，和 world.json 的 map.W/H 对齐）：
    assets/ground_kind.png         R 通道 = 材质编号（0..4），G/B=0
    build/_ground_kind_preview.png 上色的预览图（肉眼校对用，不进 git）

材质编号：
    0 grass    草地（含草径）
    1 stone    石板 / 广场铺装（米色系）
    2 asphalt  沥青路面 / 水泥地
    3 water    水面（**以 world.json 的 water 矩形为准**，不看颜色，颜色只做兜底）
    4 other    认不出来的（树影、道具压住的边角），按硬地处理

用法:
    python tools/bake_ground_kind.py
    python tools/bake_ground_kind.py --verify     # 只统计，不写文件

为什么要单独烘一张：
    运行时按像素去读 28 张地面分块（3392x6400）要 80MB 内存，
    缩到 1 格 1 像素只有 424x800，加载进来几毫秒、300KB。
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from PIL import Image

GAME = Path(__file__).resolve().parent.parent
ROOT = GAME.parent

CELL = 8
CHUNK = 1024
KINDS = ["grass", "stone", "asphalt", "water", "other"]
PALETTE = {
    "grass": (74, 150, 70),
    "stone": (206, 190, 158),
    "asphalt": (96, 98, 104),
    "water": (48, 96, 190),
    "other": (168, 120, 78),
}

## Ground 层的「地贴」道具是画在地面之上的，烘焙好的地面贴图底下还是草地，
## 所以停车场 / 广场 / 停机坪 / 斑马线要单独盖一层，否则站上去还是草的声音。
## 值为 None 的保持原样（草坪圆地贴本来就是草）。
GROUND_PROP_KIND = {
    "props_plaza_lib": "stone",
    "props_plaza_north": "stone",
    "props_plaza_east": "stone",
    "props_parking_lot": "asphalt",
    "props_airpad1": "asphalt",
    "props_airpad3": "asphalt",
    "props_zebra_ns": "asphalt",
    "props_zebra_ew": "asphalt",
    "pitch_": "asphalt",           # 球场 / 跑道：硬地跑道 + 人造草，统一按硬地
    "props_lawn_disc": None,
}


def classify(r: int, g: int, b: int) -> int:
    """按颜色判材质。顺序有讲究：水 -> 草 -> 石板 -> 沥青 -> 其它。"""
    hi, lo = max(r, g, b), min(r, g, b)
    # 水：蓝压过红，且不比绿低太多（青色的浅水边也算）
    if b > r + 18 and b >= g - 12:
        return 3
    # 草：绿明显占优（草地贴图从暗到亮 G 都比 R/B 高一截）
    if g > r + 6 and g > b + 12:
        return 0
    # 石板/广场：米色系 r>g>b，离灰不远又不算纯灰
    if r >= g >= b and 6 <= r - g <= 30 and 14 <= g - b <= 50 and 150 <= r <= 235:
        return 1
    # 沥青/水泥：低饱和灰
    if hi - lo <= 20 and 45 <= hi <= 185:
        return 2
    return 4


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--verify", action="store_true", help="只统计分布")
    args = ap.parse_args()

    data = json.loads((GAME / "assets" / "world.json").read_text(encoding="utf-8"))
    w = int(data["map"]["W"])
    h = int(data["map"]["H"])

    # 水面用 world.json 的矩形（权威），颜色分类只当兜底
    water = set()
    for r in data.get("water", []):
        x, y = int(r["x"]), int(r["y"])
        rw, rh = int(r["w"]), int(r["h"])
        for ty in range(max(0, y), min(h, y + rh)):
            for tx in range(max(0, x), min(w, x + rw)):
                water.add((tx, ty))
    print(f"水面矩形 {len(data.get('water', []))} 个 -> {len(water)} 格")

    chunks: dict[tuple[int, int], Image.Image] = {}

    def chunk(cx: int, cy: int):
        if (cx, cy) not in chunks:
            # 文件名是 g{列}_{行}（末列 320 宽、末行 256 高）
            p = GAME / "assets" / "ground" / f"g{cx}_{cy}.png"
            chunks[(cx, cy)] = Image.open(p).convert("RGB") if p.exists() else None
        return chunks[(cx, cy)]

    out = Image.new("RGB", (w, h))
    px = out.load()
    count = {k: 0 for k in KINDS}
    misses = 0

    for ty in range(h):
        for tx in range(w):
            idx = None
            if (tx, ty) in water:
                idx = 3
            else:
                # 取格心的 4 个点投票，避开格线上的接缝
                votes: dict[int, int] = {}
                for ox, oy in ((3, 3), (4, 4), (3, 5), (5, 3)):
                    gx, gy = tx * CELL + ox, ty * CELL + oy
                    im = chunk(gx // CHUNK, gy // CHUNK)
                    if im is None:
                        continue
                    lx, ly = gx % CHUNK, gy % CHUNK
                    if lx >= im.width or ly >= im.height:
                        continue
                    c = classify(*im.getpixel((lx, ly)))
                    votes[c] = votes.get(c, 0) + 1
                if votes:
                    idx = max(votes.items(), key=lambda kv: kv[1])[0]
                else:
                    misses += 1
                    idx = 4
            px[tx, ty] = (idx, 0, 0)
            count[KINDS[idx]] += 1

    total = w * h
    for k in KINDS:
        print(f"  {k:8s} {count[k]:8d}  {count[k] * 100 / total:5.1f}%")
    if misses:
        print(f"  （{misses} 格没取到地面像素，按 other 处理）")

    # 1) Ground 层地贴（停车场/广场/停机坪/斑马线）盖上去
    overlay = 0
    for prop in data.get("props", []):
        if prop.get("layer") != "ground":
            continue
        sprite = str(prop.get("sprite", ""))
        stem = Path(sprite).stem
        kind = None
        for key, val in GROUND_PROP_KIND.items():
            if stem.startswith(key):
                kind = val
                break
        if kind is None:
            continue
        idx = KINDS.index(kind)
        path = GAME / sprite.replace("res://", "")
        if not path.exists():
            continue
        tex = Image.open(path)
        x0 = int(round(float(prop["x"])))
        y0 = int(round(float(prop["baseY"]) - tex.height / CELL))
        tw, th = tex.width // CELL, tex.height // CELL
        for ty in range(y0, y0 + th):
            if not (0 <= ty < h):
                continue
            for tx in range(x0, x0 + tw):
                if 0 <= tx < w:
                    px[tx, ty] = (idx, 0, 0)
                    count[KINDS[idx]] += 1
                    overlay += 1
    print(f"  地贴覆盖 {overlay} 格")

    # 2) 「认不出来」的格子向四周看齐（树影、草丛上的杂色），别留成孤岛
    for _ in range(2):
        fixes = []
        for ty in range(1, h - 1):
            for tx in range(1, w - 1):
                if px[tx, ty][0] != 4:
                    continue
                votes: dict[int, int] = {}
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1),
                               (1, 1), (-1, -1), (1, -1), (-1, 1)):
                    k = px[tx + dx, ty + dy][0]
                    if k != 4:
                        votes[k] = votes.get(k, 0) + 1
                if votes:
                    fixes.append((tx, ty, max(votes.items(), key=lambda kv: kv[1])[0]))
        if not fixes:
            break
        for tx, ty, k in fixes:
            px[tx, ty] = (k, 0, 0)
        print(f"  抹平孤立点 {len(fixes)} 个")

    if args.verify:
        return

    out.save(GAME / "assets" / "ground_kind.png")
    prev = Image.new("RGB", (w, h))
    pp = prev.load()
    for y in range(h):
        for x in range(w):
            pp[x, y] = PALETTE[KINDS[out.getpixel((x, y))[0]]]
    prev.resize((w * 2, h * 2), Image.NEAREST).save(GAME / "build" / "_ground_kind_preview.png")
    print(f"\n已写 assets/ground_kind.png（{w}x{h}）")
    print("预览 -> build/_ground_kind_preview.png")


if __name__ == "__main__":
    main()
