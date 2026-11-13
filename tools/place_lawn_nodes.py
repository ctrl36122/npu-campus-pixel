#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在两处真正空旷的大草坪上布置「休憩节点」。

为什么选实体道具而不是继续叠地面像素层：
  草地已有 detail 层的三尺度噪声 + 短竖线草簇；试过再叠有机斑块 /
  野花点，结果是「一片片污渍」，8x8 底色方块也没被打散（和之前
  草地柔化更假是同一类坑）。玩家横屏真正看得见、又有整体感的，
  是成组的可停留设施，不是 1px 纹理。

选址（游戏内四处截图 + 全图滑窗扫描后定）：
  (92, 422) 西部大草坪，东侧紧邻南北向主路，离最近楼 32 格
  (230, 80) 北部草坪，西侧贴斜向路，离最近楼 29 格
  两处都是 48x34 格窗口内 >92% 纯草、无建筑立面遮挡。

只写 assets/world.json 的 props 数组：
  * 不改地面 PNG -> road/grass/water 掩码与道具候选网格零差异，
    不用升 MINIMAP_CACHE，也不用重算地面烘焙链。
  * 不碰 instances -> 树影随机种子按数组下标算，加/删树会重排全图树影。
  * 不动 RPC。
幂等：写入前按 MARK 前缀清掉上一次的条目。

用法：
    python tools/place_lawn_nodes.py --verify          # 只体检
    python tools/place_lawn_nodes.py --apply --verify  # 写入并复验
"""
import json
import os
import sys
from math import hypot

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORLD = os.path.join(ROOT, "assets", "world.json")
CELL = 8
MARK = "草坪_"

NODES = [("west", 92.0, 422.0), ("north", 230.0, 80.0)]
DISC = "props_lawn_disc.png"     # 192x192 = 24x24 格
DISC_R = 12.0

# (后缀, 精灵, 相对中心的 x, 相对中心的 baseY, layer)
LAYOUT = [
    ("disc",      DISC,                   -12.0,  12.0, "ground"),
    ("fountain",  "props_fountain.png",   -7.5,   5.0, None),
    ("bench_nw",  "props_bench.png",     -10.0,  -8.0, None),
    ("bench_ne",  "props_bench.png",       6.0,  -8.0, None),
    ("bench_sw",  "props_bench.png",     -10.0,  11.0, None),
    ("bench_se",  "props_bench.png",       6.0,  11.0, None),
    ("bed_w1",    "props_flowerbed.png", -14.0,  -4.0, None),
    ("bed_w2",    "props_flowerbed.png", -14.0,   4.0, None),
    ("bed_e1",    "props_flowerbed.png",   9.5,  -4.0, None),
    ("bed_e2",    "props_flowerbed.png",   9.5,   4.0, None),
    ("lamp_nw",   "props_lamp.png",      -15.0, -13.0, None),
    ("lamp_ne",   "props_lamp.png",       13.0, -13.0, None),
    ("lamp_sw",   "props_lamp.png",      -15.0,  16.0, None),
    ("lamp_se",   "props_lamp.png",       13.0,  16.0, None),
    ("bin",       "props_bin.png",       -11.0,  16.0, None),
    ("sign",      "props_sign_blue.png",   9.0,  16.0, None),
]


def load():
    with open(WORLD, encoding="utf-8") as f:
        return json.load(f)


def ground_image(world):
    from PIL import Image
    W = world["map"]["W"] * CELL
    H = world["map"]["H"] * CELL
    big = Image.new("RGB", (W, H))
    for c in range(4):
        for r in range(7):
            p = os.path.join(ROOT, "assets", "ground", "g%d_%d.png" % (c, r))
            big.paste(Image.open(p).convert("RGB"), (c * 1024, r * 1024))
    return big


def sprite_cells(sprite):
    from PIL import Image
    im = Image.open(os.path.join(ROOT, "assets", os.path.basename(sprite)))
    return im.width / CELL, im.height / CELL


def is_grass(rgb):
    r, g, b = rgb[:3]
    return g > r + 14 and g > b + 28 and g > 100


def items():
    out = []
    for tag, cx, cy in NODES:
        for suffix, sprite, dx, dy, layer in LAYOUT:
            out.append((MARK + tag + "_" + suffix, "res://assets/" + sprite,
                        cx + dx, cy + dy, layer, tag, cx, cy))
    return out


def verify(world, verbose=True):
    px = ground_image(world).load()
    W, H = world["map"]["W"], world["map"]["H"]
    boxes = [b["box"] for b in world["buildings"] if b.get("box")]
    water = set()
    for w in world.get("water", []):
        for yy in range(int(w["y"]), int(w["y"]) + int(w["h"])):
            for xx in range(int(w["x"]), int(w["x"]) + int(w["w"])):
                water.add((xx, yy))
    existing = [(str(p.get("name", "")), float(p.get("x", 0)),
                 float(p.get("baseY", 0))) for p in world["props"]
                if not str(p.get("name", "")).startswith(MARK)]
    trees = [(float(i["x"]), float(i["y"])) for i in world["instances"]
             if str(i.get("k")) == "tree" and not i.get("hide", False)]

    bad = []

    def in_building(x, y):
        return any(b["minx"] <= x <= b["maxx"] and
                   b["miny"] <= y <= b["maxy"] for b in boxes)

    # 地贴圆内必须全是草、不能有树（树画在地贴上会像长在铺装里）
    for tag, cx, cy in NODES:
        for dy in range(-12, 13):
            for dx in range(-12, 13):
                if hypot(dx, dy) > DISC_R:
                    continue
                gx, gy = int(cx + dx), int(cy + dy)
                if not (0 <= gx < W and 0 <= gy < H):
                    bad.append(("disc:" + tag, "越界", gx, gy))
                    continue
                if (gx, gy) in water:
                    bad.append(("disc:" + tag, "压水", gx, gy))
                if in_building(gx, gy):
                    bad.append(("disc:" + tag, "压建筑", gx, gy))
                if not is_grass(px[gx * CELL + 4, gy * CELL + 4]):
                    bad.append(("disc:" + tag, "圆内非草", gx, gy))
        for tx, ty in trees:
            if hypot(tx - cx, ty - cy) < DISC_R + 2:
                bad.append(("disc:" + tag, "圆内有树", round(tx, 1), round(ty, 1)))
    # 两处节点别挨太近
    (_, ax, ay), (_, bx, by) = NODES
    if hypot(ax - bx, ay - by) < 60:
        bad.append(("nodes", "两处节点过近", ax, ay))

    all_items = items()
    for name, sprite, x, y, layer, tag, cx, cy in all_items:
        path = os.path.join(ROOT, sprite.replace("res://", ""))
        if not os.path.exists(path):
            bad.append((name, "精灵不存在", sprite))
            continue
        w, _ = sprite_cells(sprite)
        if layer == "ground":
            continue
        # 只验底边一行（左/中/右）：y-sort、碰撞、脚下地面都看这里
        for xx in (x + 0.5, x + w / 2, x + w - 0.5):
            gx, gy = int(xx), int(y - 0.5)
            if not (0 <= gx < W and 0 <= gy < H):
                bad.append((name, "越界", gx, gy))
                continue
            if (gx, gy) in water:
                bad.append((name, "压水", gx, gy))
            if in_building(gx, gy):
                bad.append((name, "压建筑", gx, gy))
            if not is_grass(px[gx * CELL + 4, gy * CELL + 4]):
                bad.append((name, "底边不在草地上", gx, gy))
        for ename, ex, ey in existing:
            if abs(ex - x) < 3.0 and abs(ey - y) < 3.0:
                bad.append((name, "与已有道具 %s 重叠" % ename, ex, ey))
                break
        # 节点内部也别互压：x 是精灵左边缘，必须先换成中心再比宽度和
        cx_item = x + w / 2
        for n2, sp2, x2, y2, l2, tag2, _, _ in all_items:
            if tag2 != tag or n2 <= name or l2 == "ground":
                continue
            w2, _ = sprite_cells(sp2)
            cx2 = x2 + w2 / 2
            if abs(cx2 - cx_item) < (w + w2) / 2 and abs(y2 - y) < 3.0:
                bad.append((name, "与 %s 重叠" % n2, x2, y2))

    if verbose:
        print("[lawn_nodes] 待放 %d 件（%d 处），违规 %d 处"
              % (len(all_items), len(NODES), len(bad)))
        for b in bad[:40]:
            print("  ", b)
    return bad


def apply(world):
    before = len(world["props"])
    world["props"] = [p for p in world["props"]
                      if not str(p.get("name", "")).startswith(MARK)]
    for name, sprite, x, y, layer, _, _, _ in items():
        item = {"name": name, "sprite": sprite, "x": x, "baseY": y, "bottom": 0}
        if layer:
            item["layer"] = layer
        world["props"].append(item)
    print("[lawn_nodes] props %d -> %d（新增 %d 件）"
          % (before, len(world["props"]), len(items())))
    return world


def main():
    args = sys.argv[1:]
    world = load()
    if "--apply" in args:
        bad = verify(world, verbose=False)
        if bad:
            print("[lawn_nodes] 摆位体检未过，拒绝写入：")
            for b in bad[:40]:
                print("  ", b)
            raise SystemExit(1)
        world = apply(world)
        with open(WORLD, "w", encoding="utf-8") as f:
            json.dump(world, f, ensure_ascii=False, separators=(",", ":"))
        world = load()
    bad = verify(world)
    print("[lawn_nodes] %s" % ("ALL PASS" if not bad else "FAILED"))
    if bad:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
