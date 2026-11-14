#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在五处玩家常走的十字路口布置斑马线与路牌（地图整体优化 · 路网节点）。

选址流程：
  1) 像素扫全图，按四臂连续度找出 40 处交叉口。
  2) 再筛「四个进口都是 3~7 格窄路」的规整十字（宽广场、斜向双幅路都排除），
     得到 12 处候选；这一步推翻了最初靠缩略图选的 (128,390)/(128,226)——
     前者是斜向双幅路，后者横截面连续 24 格全是灰铺装，根本不是窄路口。
  3) 十二处游戏内截图复核，留下五处视野开阔、不被 2.5D 建筑立面盖住的：
       (106, 638) 南部开阔十字，四周全是草地
       (266, 556) 中央院落东南十字
       (256, 190) 教学东楼西侧十字
       (340, 186) 东部教学楼间十字
       (110,  74) 北门内侧十字
     淘汰 (122,310) 体育馆遮挡、(124,182) 数字化大楼夹住、(176,238) 被楼挡一半、
       (66,178) 两个进口压足球场地贴、(216,394) 本身是圆形喷泉广场。

对齐：路面只有 3 格宽、中心线会左右偏 1 格，而且个别进口在 9 格外已经
离开路面。所以每个进口都在 6~12 格里自动找一个「3x3 白条区全在路面、
不压建筑/地贴」的偏移，并按横截面求路面中心，而不是硬套路口中心坐标。
路牌同样从一组对角候选里挑第一个不与已有道具/树/建筑冲突的位置。

为什么走 Ground 层 sprite：
  * 不改任何地面 PNG -> road/grass/water 掩码与道具候选网格零差异，
    不用升 MINIMAP_CACHE、不用重算地面烘焙链、不用重导 EXE/APK。
  * 不碰 instances -> 树影随机种子按数组下标算，删/加树会重排全图树影。
  * 不动 RPC。
幂等：写入前按 MARK 前缀清掉上一次写进去的条目。

用法：
    python tools/place_road_nodes.py --verify
    python tools/place_road_nodes.py --apply --verify
"""
import json
import os
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORLD = os.path.join(ROOT, "assets", "world.json")
CELL = 8
MARK = "路口_"

NODES = [
    ("south", 106.0, 638.0),
    ("courtyard", 266.0, 556.0),
    ("east_mid", 256.0, 190.0),
    ("east", 340.0, 186.0),
    ("north_gate", 110.0, 74.0),
]
OFFS = (9, 8, 7, 6, 10, 11, 12)   # 斑马线中心离路口中心的候选距离（格）
ZEBRA = 3.0                       # 地贴 24x24 = 3x3 格

# 路牌候选：先对角，再更远 / 另一个对角
SIGN_CANDIDATES = [
    (-9.0, -9.0, "props_sign_blue.png"),
    (9.0, 9.0, "props_sign_yellow.png"),
    (-11.0, -11.0, "props_sign_blue.png"),
    (11.0, 11.0, "props_sign_yellow.png"),
    (-9.0, 9.0, "props_sign_blue.png"),
    (9.0, -9.0, "props_sign_yellow.png"),
    (-12.0, -6.0, "props_sign_blue.png"),
    (12.0, 6.0, "props_sign_yellow.png"),
]


def load():
    with open(WORLD, encoding="utf-8") as f:
        return json.load(f)


def ground_image(world):
    W, H = world["map"]["W"], world["map"]["H"]
    big = Image.new("RGB", (W * CELL, H * CELL), (0, 0, 0))
    for c in range(4):
        for r in range(7):
            p = os.path.join(ROOT, "assets", "ground", "g%d_%d.png" % (c, r))
            if os.path.exists(p):
                big.paste(Image.open(p).convert("RGB"), (c * 1024, r * 1024))
    return big


def sprite_cells(sprite):
    p = os.path.join(ROOT, sprite.replace("res://", ""))
    with Image.open(p) as im:
        return im.width / CELL, im.height / CELL


def is_grass(rgb):
    r, g, b = rgb[:3]
    return g - r > 14 and g - b > 28 and g > 100


def is_water(rgb):
    r, g, b = rgb[:3]
    return b > g and b >= r and (b - r) > 18


def is_beige(rgb):
    r, g, b = rgb[:3]
    return r > g > b and r - g >= 7 and g - b >= 18 and r >= 160


def _is_road(px, x, y):
    r, g, b = px[x * CELL + 4, y * CELL + 4][:3]
    return 70 <= r <= 190 and max(r, g, b) - min(r, g, b) <= 16


def context(world):
    W, H = world["map"]["W"], world["map"]["H"]
    water = set()
    for w in world.get("water", []):
        for yy in range(int(w["y"]), int(w["y"]) + int(w["h"])):
            for xx in range(int(w["x"]), int(w["x"]) + int(w["w"])):
                water.add((xx, yy))
    gboxes, existing = [], []
    for p in world["props"]:
        name = str(p.get("name", ""))
        x, y = float(p.get("x", 0)), float(p.get("baseY", 0))
        if name.startswith(MARK):
            continue
        existing.append((name, x, y))
        if str(p.get("layer")) == "ground":
            try:
                w, h = sprite_cells(str(p.get("sprite", "")))
            except Exception:
                continue
            gboxes.append((x, y - h, x + w, y, name))
    return {
        "W": W, "H": H, "water": water, "gboxes": gboxes,
        "existing": existing,
        "boxes": [b["box"] for b in world["buildings"] if b.get("box")],
        "trees": [(float(i["x"]), float(i["y"])) for i in world["instances"]
                  if str(i.get("k")) == "tree" and not i.get("hide", False)],
    }


def in_building(ctx, x, y):
    return any(b["minx"] <= x <= b["maxx"] and
               b["miny"] <= y <= b["maxy"] for b in ctx["boxes"])


def _align(px, cx, cy, kind, off):
    """按进口横截面求路面中心；找不到 3~7 格窄路就退回路口中心坐标。"""
    if kind in ("n", "s"):
        fixed = int(cy - off if kind == "n" else cy + off)
        rng = list(range(int(cx) - 12, int(cx) + 13))
        vals = [_is_road(px, v, fixed) for v in rng]
        base = cx
    else:
        fixed = int(cx - off if kind == "w" else cx + off)
        rng = list(range(int(cy) - 12, int(cy) + 13))
        vals = [_is_road(px, fixed, v) for v in rng]
        base = cy
    runs, cur = [], 0
    for i, v in enumerate(vals + [False]):
        if v:
            cur += 1
        else:
            if cur:
                runs.append((rng[i - cur], rng[i - 1]))
            cur = 0
    ok = [(a + b) / 2 for a, b in runs
          if 3 <= b - a + 1 <= 7 and abs((a + b) / 2 - base) <= 3]
    return min(ok, key=lambda v: abs(v - base)) if ok else base


def _white_ok(px, ctx, ccx, ccy):
    """3x3 白条区必须全在路面，且不能压建筑 / 已有 Ground 地贴。"""
    W, H = ctx["W"], ctx["H"]
    for dy in range(-1, 2):
        for dx in range(-1, 2):
            gx, gy = int(ccx + dx), int(ccy + dy)
            if not (0 <= gx < W and 0 <= gy < H):
                return False
            rgb = px[gx * CELL + 4, gy * CELL + 4]
            if (gx, gy) in ctx["water"] or is_water(rgb) or is_grass(rgb) or is_beige(rgb):
                return False
            if in_building(ctx, gx, gy):
                return False
    x0, y0 = ccx - ZEBRA / 2, ccy - ZEBRA / 2
    for a, b, c, e, _ in ctx["gboxes"]:
        if x0 < c and x0 + ZEBRA > a and y0 < e and y0 + ZEBRA > b:
            return False
    return True


def _sign_ok(px, ctx, x, y, sprite, placed):
    W, H = ctx["W"], ctx["H"]
    w, _ = sprite_cells("res://assets/" + sprite)
    for xx in (x + 0.5, x + w / 2, x + w - 0.5):
        gx, gy = int(xx), int(y - 0.5)
        if not (0 <= gx < W and 0 <= gy < H):
            return False
        rgb = px[gx * CELL + 4, gy * CELL + 4]
        if (gx, gy) in ctx["water"] or is_water(rgb) or is_beige(rgb):
            return False
        if in_building(ctx, gx, gy):
            return False
    for ename, ex, ey in ctx["existing"]:
        if abs(ex - x) < 3.0 and abs(ey - y) < 3.0:
            return False
    for tx, ty in ctx["trees"]:
        if abs(tx - x) < 3.0 and abs(ty - y) < 3.0:
            return False
    for px_, py_ in placed:
        if abs(px_ - x) < 5.0 and abs(py_ - y) < 5.0:
            return False
    return True


def items(px, ctx):
    """产出 (name, sprite, x, baseY, layer, tag, ccx, ccy)。"""
    out, placed = [], []
    for tag, cx, cy in NODES:
        for side, kind, sign, sprite in (
                ("n", "n", -1, "props_zebra_ns.png"),
                ("s", "s", 1, "props_zebra_ns.png"),
                ("w", "w", -1, "props_zebra_ew.png"),
                ("e", "e", 1, "props_zebra_ew.png")):
            pos = None
            for off in OFFS:
                a = _align(px, cx, cy, kind, off)
                ccx, ccy = ((a, cy + sign * off) if kind in ("n", "s")
                            else (cx + sign * off, a))
                if _white_ok(px, ctx, ccx, ccy):
                    pos = (ccx, ccy)
                    break
            if pos is None:
                continue                     # 该进口放不下就跳过，不硬塞
            ccx, ccy = pos
            out.append((MARK + "%s_zebra_%s" % (tag, side), sprite,
                        ccx - ZEBRA / 2, ccy + ZEBRA / 2,
                        "ground", tag, ccx, ccy))
        # 每个路口最多两块路牌，从对角候选里挑可用的
        got = 0
        for dx, dy, sp in SIGN_CANDIDATES:
            x, y = cx + dx, cy + dy
            if not _sign_ok(px, ctx, x, y, sp, placed):
                continue
            out.append((MARK + "%s_sign_%d" % (tag, got), sp,
                        x, y, None, tag, x, y))
            placed.append((x, y))
            got += 1
            if got >= 2:
                break
    return out


def verify(world, verbose=True):
    px = ground_image(world).load()
    ctx = context(world)
    all_items = items(px, ctx)
    bad = []
    for name, sprite, x, y, layer, tag, ccx, ccy in all_items:
        if not os.path.exists(os.path.join(ROOT, "assets", sprite)):
            bad.append((name, "精灵不存在", sprite))
            continue
        if layer == "ground" and not _white_ok(px, ctx, ccx, ccy):
            bad.append((name, "白条区不在路面 / 压建筑 / 压已有地贴", ccx, ccy))
    # 每处路口至少 3 条斑马线，否则不成组
    for tag, _, _ in NODES:
        n = sum(1 for it in all_items if it[5] == tag and it[4] == "ground")
        if n < 3:
            bad.append((tag, "斑马线不足 3 条", n))
    if verbose:
        ze = sum(1 for it in all_items if it[4] == "ground")
        print("[road_nodes] 待放 %d 件（斑马线 %d / 路牌 %d，%d 处路口），违规 %d 处"
              % (len(all_items), ze, len(all_items) - ze, len(NODES), len(bad)))
        for b in bad[:60]:
            print("  ", b)
    return bad, all_items


def apply(world):
    px = ground_image(world).load()
    ctx = context(world)
    all_items = items(px, ctx)
    before = len(world["props"])
    world["props"] = [p for p in world["props"]
                      if not str(p.get("name", "")).startswith(MARK)]
    for name, sprite, x, y, layer, *_ in all_items:
        item = {"name": name, "sprite": "res://assets/" + sprite,
                "x": x, "baseY": y, "bottom": 0}
        if layer:
            item["layer"] = layer
        world["props"].append(item)
    print("[road_nodes] props %d -> %d" % (before, len(world["props"])))
    return world


def main():
    args = sys.argv[1:]
    world = load()
    if "--verify" in args and "--apply" not in args:
        bad, _ = verify(world)
        sys.exit(1 if bad else 0)
    if "--apply" in args:
        world = apply(world)
        with open(WORLD, "w", encoding="utf-8") as f:
            json.dump(world, f, ensure_ascii=False, separators=(",", ":"))
        if "--verify" in args:
            bad, _ = verify(world)
            sys.exit(1 if bad else 0)
    else:
        print(__doc__)


if __name__ == "__main__":
    main()
