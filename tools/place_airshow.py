# -*- coding: utf-8 -*-
"""第 11 层：校园最南端「航空展示区」摆位。

上一轮把 ARJ21 从中央广场挪到了最南端，但那里只是一片空草地，
另外三架小飞机还跨在南部两条路上。这一层把三架小飞机也理到干净
草地，并用现成的护栏 / 路灯 / 长椅 / 垃圾桶 / 花坛 / 指示牌把这一角
做成一个能停留的展示区。

只动 assets/world.json 的实例坐标与 props 数组，不碰任何地面贴图、
不碰 RPC、不动 world.tscn 的手工内容（场景由 build_world_scene.gd 重建）。

⚠️ 展区里的树只能打 hide 标记、绝不能删：bake_ground_detail 用
instances 的数组下标做树影随机种子，删一条会让全图树影重排。

用法：
  python tools/place_airshow.py --verify   # 只体检，不写文件
  python tools/place_airshow.py --apply    # 写入（幂等，先清掉旧的 设施_air_ 条目）
"""
import argparse
import json
import os
import sys
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORLD = os.path.join(ROOT, "assets", "world.json")
MARK = "设施_air_"
CELL = 8

# 三架小飞机（decor sp=5/6/7，切片 320x160，锚点 ax=20 / ay=10 格）
PLANES = {
    "transport": (264, 748),
    "bomber": (292, 750),
    "fighter": (320, 748),
}
ARJ = (349, 775)          # 上一轮已就位，这一层不动

# (名字, 精灵, x, baseY, layer)
PROPS = []


def _add(name, sprite, x, y, layer=None):
    PROPS.append((MARK + name, "res://assets/" + sprite,
                  float(x), float(y), layer))


# 两块停机坪：地贴是 Ground 层精灵，不改地面贴图，掩码 0 差异
# 960x224 -> 覆盖 x240~360 / y735~763；480x224 -> x320~380 / y762~790
_add("pad3", "props_airpad3.png", 240, 763, "ground")
_add("pad1", "props_airpad1.png", 320, 790, "ground")

# 北侧一排护栏，中间 276~292 留作入口（fence_h 宽 64px = 8 格）
for i, fx in enumerate([244, 252, 260, 268, 292, 300, 308, 316, 324, 332]):
    _add("fence_%02d" % i, "props_fence_h.png", fx, 734)
# 路灯压在护栏后侧，略微向北错开
for i, lx in enumerate([240, 268, 300, 344]):
    _add("lamp_%02d" % i, "props_lamp.png", lx, 730)
# 南侧休息位：三张长椅、两个垃圾桶、两个花坛、一块指示牌
for i, bx in enumerate([252, 276, 300]):
    _add("bench_%02d" % i, "props_bench.png", bx, 766)
for i, gx in enumerate([264, 288]):
    _add("bin_%02d" % i, "props_bin.png", gx, 766)
for i, px in enumerate([238, 310]):
    _add("planter_%02d" % i, "props_planter.png", px, 766)
_add("sign", "props_sign_blue.png", 242, 752)
# 阿娇机位南侧（y=794，仍在地图内 H=800）
for i, bx in enumerate([330, 358]):
    _add("arj_bench_%02d" % i, "props_bench.png", bx, 794)
_add("arj_bin", "props_bin.png", 344, 794)
for i, lx in enumerate([318, 382]):
    _add("arj_lamp_%02d" % i, "props_lamp.png", lx, 790)


def ground_image(world):
    W, H = world["map"]["W"], world["map"]["H"]
    big = Image.new("RGBA", (W * CELL, H * CELL), (0, 0, 0, 0))
    for c in range(4):
        for r in range(7):
            path = os.path.join(ROOT, "assets", "ground", "g%d_%d.png" % (c, r))
            big.paste(Image.open(path).convert("RGBA"), (c * 1024, r * 1024))
    return big


def water_cells(world):
    out = set()
    for w in world["water"]:
        for y in range(int(w["y"]), int(w["y"]) + int(w["h"])):
            for x in range(int(w["x"]), int(w["x"]) + int(w["w"])):
                out.add((x, y))
    return out


def is_blue(rgb):
    r, g, b = rgb[:3]
    return b > g and b > r - 2 and b - r > 12


def is_grass(rgb):
    r, g, b = rgb[:3]
    return (g - r > 14) and (g - b > 28) and g > 100


def in_show_area(x, y):
    """展示区范围：树会因为 y-sort 盖住飞机和设施，这一圈必须清空。"""
    return 230 <= x <= 390 and 725 <= y <= 800


def verify(world):
    px = ground_image(world).load()
    W, H = world["map"]["W"], world["map"]["H"]
    boxes = [b["box"] for b in world["buildings"] if b.get("box")]
    water = water_cells(world)
    trees = [(float(i["x"]), float(i["y"]))
             for i in world["instances"]
             if str(i.get("k")) == "tree" and not i.get("hide", False)]
    shown_in_area = [(float(i["x"]), float(i["y"]))
                     for i in world["instances"]
                     if str(i.get("k")) == "tree" and in_show_area(
                         float(i["x"]), float(i["y"])) and not i.get("hide", False)]
    existing = [(str(p.get("name", "")), float(p.get("x", 0)), float(p.get("baseY", 0)))
                for p in world["props"] if not str(p.get("name", "")).startswith(MARK)]
    bad = []

    def check(label, x, y):
        ix, iy = int(x), int(y)
        if not (0 <= ix < W and 0 <= iy < H):
            bad.append((label, "越界", x, y)); return
        rgb = px[ix * CELL + 4, iy * CELL + 4]
        if is_blue(rgb):
            bad.append((label, "落在水面", x, y))
        if any(b["minx"] <= x <= b["maxx"] and b["miny"] <= y <= b["maxy"] for b in boxes):
            bad.append((label, "落在楼体", x, y))
        for nm, ex, ey in existing:
            if abs(ex - x) < 1 and abs(ey - y) < 1:
                bad.append((label, "与已有道具重叠:" + nm, x, y)); break
        for tx, ty in trees:
            if abs(tx - x) < 2 and abs(ty - y) < 2:
                bad.append((label, "压在树上", x, y)); break

    # 飞机整块包围盒逐格必须是草：不压水、不压路、不压楼
    for model, (x, y) in list(PLANES.items()) + [("arj", ARJ)]:
        half_w, half_h = (25, 13) if model == "arj" else (20, 10)
        check("plane:" + model, x, y)
        non_grass = 0
        for yy in range(int(y) - half_h, int(y) + half_h + 1):
            for xx in range(int(x) - half_w, int(x) + half_w + 1):
                if not is_grass(px[xx * CELL + 4, yy * CELL + 4]):
                    non_grass += 1
        if non_grass:
            bad.append(("plane:" + model, "包围盒非草 %d 格" % non_grass, x, y))
    # 展示区内的树会被 y-sort 画到飞机/设施前面：只能 hide，不能删
    for tx, ty in shown_in_area:
        bad.append(("tree", "展示区残留未隐藏的树", round(tx, 2), round(ty, 2)))
    for name, sprite, x, y, layer in PROPS:
        if not os.path.exists(os.path.join(ROOT, sprite.replace("res://", ""))):
            bad.append((name, "精灵不存在", sprite))
        if layer == "ground":
            continue
        check(name, x, y)
        # 道具底边落进阿娇机身投影（y 762.5~787.5）才会被 y-sort 画到机身上
        if 762.5 <= y <= 787.5 and 324 <= x <= 374:
            bad.append((name, "落在阿娇机身投影内", x, y))
    return bad


def apply(world):
    # 飞机坐标
    for it in world["instances"]:
        if str(it.get("k")) == "plane" and str(it.get("model")) in PLANES:
            x, y = PLANES[str(it["model"])]
            it["x"], it["y"] = float(x), float(y)
    # 展区里的树会盖住机身，但绝不能从 instances 里删：
    # bake_ground_detail._shadow_layer 用「数组下标」做树影随机种子，
    # 删一条会让后面所有树的树影重排，整条地面烘焙链就对不上了。
    # 只打 hide 标记，build_world_scene.gd 渲染时跳过，链仍读到原数组。
    hidden = 0
    for it in world["instances"]:
        if str(it.get("k")) == "tree" and in_show_area(
                float(it["x"]), float(it["y"])) and not it.get("hide", False):
            it["hide"] = True
            hidden += 1
    print("[airshow] 隐藏展区内的树 %d 棵（实例保留，地面链不变）" % hidden)
    # 幂等：先清掉上一次写进去的条目
    world["props"] = [p for p in world["props"]
                      if not str(p.get("name", "")).startswith(MARK)]
    for name, sprite, x, y, layer in PROPS:
        item = {"name": name, "sprite": sprite, "x": x, "baseY": y, "bottom": 0}
        if layer:
            item["layer"] = layer
        world["props"].append(item)
    return world


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--verify", action="store_true")
    args = ap.parse_args()
    world = json.load(open(WORLD, encoding="utf-8"))
    if args.apply:
        world = apply(world)
        with open(WORLD, "w", encoding="utf-8") as f:
            json.dump(world, f, ensure_ascii=False, separators=(",", ":"))
        print("[airshow] 已写入 %d 个道具，三架小飞机已重排" % len(PROPS))
    bad = verify(world)
    if bad:
        print("[airshow] 违规 %d 处：" % len(bad))
        for b in bad[:40]:
            print("   ", b)
        sys.exit(1)
    print("[airshow] ALL PASS：飞机 %d 架、道具 %d 个，0 处压水/压楼/重叠"
          % (len(PLANES) + 1, len(PROPS)))


if __name__ == "__main__":
    main()
