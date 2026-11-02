#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 tools/street_props.json 合并进 assets/world.json 的 props。

幂等：先删掉本脚本产出的五类名字，再按位置插入。
插入前会和「已有的立体道具」比脚底占位，重叠的跳过并报出来
（广场铺装是 layer=ground，不算，设施立在上面是正常的）。
"""
import json
import os
import re

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
WORLD = os.path.join(ROOT, "assets", "world.json")
ADD = os.path.join(HERE, "street_props.json")

MINE = re.compile(r"^(快递柜|店招|售货机|自行车|垃圾桶)·")
TS = 8.0
FOOT_DEPTH = 0.5


def tex_w(sprite_path):
    """按贴图宽度算脚底占位（格）。"""
    rel = sprite_path.replace("res://", "").replace("/", os.sep)
    p = os.path.join(ROOT, rel)
    try:
        with Image.open(p) as im:
            return im.width / TS
    except Exception:
        return 2.0


def footprint(p):
    w = tex_w(str(p.get("sprite", "")))
    x0 = float(p.get("x", 0.0))
    ay = float(p.get("baseY", 0.0))
    return (x0, ay - FOOT_DEPTH, x0 + w, ay)


def main():
    world = json.load(open(WORLD, encoding="utf-8"))
    add = json.load(open(ADD, encoding="utf-8"))

    before = len(world["props"])
    kept = [p for p in world["props"] if not MINE.match(p.get("name", ""))]
    removed = before - len(kept)

    # 已有立体道具的脚底占位（ground 层是铺装，不参与）
    existing = [footprint(p) for p in kept
                if str(p.get("layer", "objects")) != "ground"]

    inserted, skipped = [], []
    for p in add:
        x0, y0, x1, y1 = footprint(p)
        hit = None
        for (a0, b0, a1, b1) in existing:
            if not (x1 < a0 + 0.1 or x0 > a1 - 0.1 or y1 < b0 + 0.1 or y0 > b1 - 0.1):
                hit = (a0, b0, a1, b1)
                break
        if hit:
            skipped.append((p["name"], hit))
            continue
        inserted.append(p)
        existing.append((x0, y0, x1, y1))

    world["props"] = kept + inserted

    with open(WORLD, "w", encoding="utf-8") as f:
        json.dump(world, f, ensure_ascii=False, separators=(",", ":"))
    print("props: %d → %d（替换旧 %d 条，插入 %d 条，跳过 %d 条）" % (
        before, len(world["props"]), removed, len(inserted), len(skipped)))
    for nm, hit in skipped:
        print("   跳过 %-24s 与已有占位 (%.1f,%.1f)-(%.1f,%.1f) 重叠" % (nm, *hit))


if __name__ == "__main__":
    main()
