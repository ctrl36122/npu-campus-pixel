#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 tools/court_trim_props.json 合并进 assets/world.json 的 props。

幂等：按名字模式（…围网N / …灯N）先删旧条目再插入。
"""
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
WORLD = os.path.join(HERE, "..", "assets", "world.json")
ADD = os.path.join(HERE, "court_trim_props.json")

# 只认本脚本产的两种名字：……北围网1 / ……场灯1
# 不能写成「灯\d+」—— 会把「图书馆路灯1」这类原有路灯一起删掉
MINE = re.compile(r"(围网\d+|场灯\d+)$")


def main():
    world = json.load(open(WORLD, encoding="utf-8"))
    add = json.load(open(ADD, encoding="utf-8"))
    names = {p["name"] for p in add}

    before = len(world["props"])
    world["props"] = [p for p in world["props"]
                      if p.get("name") not in names and not MINE.search(p.get("name", ""))]
    removed = before - len(world["props"])
    world["props"].extend(add)

    with open(WORLD, "w", encoding="utf-8") as f:
        json.dump(world, f, ensure_ascii=False, separators=(",", ":"))
    print("props: %d → %d（替换 %d 条，新增 %d 条）" % (
        before, len(world["props"]), removed, len(add)))


if __name__ == "__main__":
    main()
