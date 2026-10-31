#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 tools/pitches_props.json 合并进 assets/world.json 的 props。

幂等：重复跑不会叠加（按 name 去重）。保持 world.json 的紧凑单行格式。
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
WORLD = os.path.join(HERE, "..", "assets", "world.json")
ADD = os.path.join(HERE, "pitches_props.json")


def main():
    world = json.load(open(WORLD, encoding="utf-8"))
    add = json.load(open(ADD, encoding="utf-8"))
    names = {p["name"] for p in add}

    before = len(world["props"])
    world["props"] = [p for p in world["props"] if p.get("name") not in names]
    removed = before - len(world["props"])
    world["props"].extend(add)

    with open(WORLD, "w", encoding="utf-8") as f:
        json.dump(world, f, ensure_ascii=False, separators=(",", ":"))
    print("props: %d → %d（替换 %d 条，新增 %d 条）" % (
        before, len(world["props"]), removed, len(add)))


if __name__ == "__main__":
    main()
