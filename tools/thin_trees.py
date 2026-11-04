#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把世界里过密的树木稀疏化（用户反馈「树太多了」）。

原 world.json 有 1460 棵 tree 实例，铺满草坪显得拥挤。这里按空间网格分桶，
每桶确定性随机保留 1 棵，整体降到 ~260 棵，保留 sp（树种）多样性与成片草坪的疏朗感。

用法：python tools/thin_trees.py [--dry]
"""
import json
import os
import random
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
P = os.path.join(ROOT, "assets/world.json")

GRID = 37          # 每 37×37 格(≈296px) 区域最多留 1 棵
SEED = 20261104    # 固定种子 → 可重复


def main():
    dry = "--dry" in sys.argv
    d = json.load(open(P, encoding="utf-8"))
    inst = d.get("instances", [])
    trees = [i for i in inst if i.get("k") == "tree"]
    others = [i for i in inst if i.get("k") != "tree"]

    buckets = {}
    for t in trees:
        bx = int(float(t["x"]) // GRID)
        by = int(float(t["y"]) // GRID)
        buckets.setdefault((bx, by), []).append(t)

    rng = random.Random(SEED)
    kept = []
    for _k, lst in buckets.items():
        rng.shuffle(lst)
        kept.append(lst[0])
    kept.sort(key=lambda t: (t["y"], t["x"]))

    print("原树数: %d   网格桶数: %d   保留: %d" % (len(trees), len(buckets), len(kept)))
    if dry:
        return

    d["instances"] = others + kept
    with open(P, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False, separators=(",", ":"))
    print("已写回 world.json（紧凑单行，保持原格式）")


if __name__ == "__main__":
    main()
