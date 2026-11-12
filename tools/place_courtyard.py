"""中央海天苑回字形院落的庭院设施摆位。

背景：这片区域是全校唯一成片的米色硬质铺装（约 x180~280 / y440~560 格），
第 7 层石板柔化之后整片显得很空。用一组喷泉 / 花坛 / 长椅 / 路灯给院落
一个中心，避免「一大块沙漠」。

只写 assets/world.json 的 props 数组，不改地面 PNG、不碰 instances（树影链用
数组下标做随机种子，删/加树会重排全图树影）、不动 RPC。
幂等：写入前先按 MARK 前缀清掉上一次的条目。

用法：
    python tools/place_courtyard.py --verify          # 只体检，不写文件
    python tools/place_courtyard.py --apply --verify  # 写入并复验
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORLD = os.path.join(ROOT, "assets", "world.json")
CELL = 8
MARK = "庭院_"

# (名字后缀, 精灵, 左边 x(格), 底边 baseY(格))
# 楼群 box（格）：北 183~263/455~471，西 183~199/471~529，东 247~263/471~529，
# 南 183~263/529~545，中楼 207~239/482~512。
PROPS = [
    # 中庭南带（y512~529）：喷泉做视觉焦点，两侧各一张长椅
    ("fountain",      "props_fountain.png",  215.0, 526.0),
    ("bench_mid_w",   "props_bench.png",    202.0, 526.0),
    ("bench_mid_e",   "props_bench.png",    240.0, 526.0),
    ("bin_mid",       "props_bin.png",      244.0, 526.0),
    # 中庭北带（y471~482，中楼之前）
    ("bed_n1",        "props_flowerbed.png", 201.0, 478.0),
    ("bed_n2",        "props_flowerbed.png", 212.0, 478.0),
    ("bed_n3",        "props_flowerbed.png", 229.0, 478.0),
    ("bed_n4",        "props_flowerbed.png", 241.0, 478.0),
    ("bench_n",       "props_bench.png",    220.0, 478.0),
    # 中庭西 / 东两条侧带（中楼 x207~239 两侧）
    ("bed_w1",        "props_flowerbed.png", 200.0, 495.0),
    ("bed_w2",        "props_flowerbed.png", 200.0, 508.0),
    ("bed_e1",        "props_flowerbed.png", 241.0, 495.0),
    ("bed_e2",        "props_flowerbed.png", 241.0, 508.0),
    # 楼群北带（y450~454）
    ("lamp_nw",       "props_lamp.png",     187.0, 452.0),
    ("lamp_ne",       "props_lamp.png",     250.0, 452.0),
    ("bed_ext_n1",    "props_flowerbed.png", 195.0, 452.0),
    ("bed_ext_n2",    "props_flowerbed.png", 230.0, 452.0),
    # 楼群南带（y545~549）
    ("lamp_sw",       "props_lamp.png",     187.0, 547.0),
    ("lamp_se",       "props_lamp.png",     250.0, 547.0),
    ("bed_ext_s1",    "props_flowerbed.png", 195.0, 547.0),
    ("bed_ext_s2",    "props_flowerbed.png", 230.0, 547.0),
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
            path = os.path.join(ROOT, "assets", "ground", "g%d_%d.png" % (c, r))
            big.paste(Image.open(path).convert("RGB"), (c * 1024, r * 1024))
    return big


def is_paving(rgb):
    """米色硬质铺装（含砖缝 / 阴影渐变），排除草 / 灰路 / 水。"""
    r, g, b = rgb[:3]
    return r > g > b and (r - g) >= 7 and (g - b) >= 18 and r >= 160


def sprite_cells(path):
    from PIL import Image
    im = Image.open(os.path.join(ROOT, "assets", os.path.basename(path)))
    return im.width / CELL, im.height / CELL


def verify(world, verbose=True):
    px = ground_image(world).load()
    W, H = world["map"]["W"], world["map"]["H"]
    boxes = [b["box"] for b in world["buildings"] if b.get("box")]
    WATER = set()
    for w in world.get("water", []):
        for yy in range(int(w["y"]), int(w["y"]) + int(w["h"])):
            for xx in range(int(w["x"]), int(w["x"]) + int(w["w"])):
                WATER.add((xx, yy))
    existing = [(str(p.get("name", "")), float(p.get("x", 0)), float(p.get("baseY", 0)))
                for p in world["props"]
                if not str(p.get("name", "")).startswith(MARK)]

    bad = []

    def in_building(x, y):
        # 只按底边格判：2.5D 精灵的上半身是立面，不参与地面占位 / 碰撞
        return any(b["minx"] <= x <= b["maxx"] and
                   b["miny"] <= y <= b["maxy"] for b in boxes)

    for suffix, sprite, x, y in PROPS:
        w, _ = sprite_cells(sprite)
        # 只验底边一行（左 / 中 / 右三点）：y-sort、碰撞、脚下地面都看这里
        for xx in (x + 0.5, x + w / 2, x + w - 0.5):
            gx, gy = int(xx), int(y - 0.5)
            if not (0 <= gx < W and 0 <= gy < H):
                bad.append((suffix, "越界", gx, gy))
                continue
            if (gx, gy) in WATER:
                bad.append((suffix, "压水", gx, gy))
            if in_building(gx, gy):
                bad.append((suffix, "压建筑", gx, gy))
            if not is_paving(px[gx * CELL + 4, gy * CELL + 4]):
                bad.append((suffix, "不在米色铺装上", gx, gy))
        for name, ex, ey in existing:
            if abs(ex - x) < 3.0 and abs(ey - y) < 3.0:
                bad.append((suffix, "与已有道具 %s 重叠" % name, ex, ey))
                break
        # 庭院自身也别互压
        for s2, sp2, x2, y2 in PROPS:
            if s2 <= suffix:
                continue
            if abs(x2 - x) < (w + sprite_cells(sp2)[0]) / 2 and abs(y2 - y) < 3.0:
                bad.append((suffix, "与 %s 重叠" % s2, x2, y2))

    if verbose:
        print("[courtyard] 待放 %d 件，违规 %d 处" % (len(PROPS), len(bad)))
        for b in bad[:40]:
            print("  ", b)
    return bad


def apply(world):
    before = len(world["props"])
    world["props"] = [p for p in world["props"]
                      if not str(p.get("name", "")).startswith(MARK)]
    for suffix, sprite, x, y in PROPS:
        world["props"].append({
            "name": MARK + suffix,
            "sprite": "res://assets/" + sprite,
            "x": x, "baseY": y, "bottom": 0,
        })
    print("[courtyard] props %d -> %d（新增 %d 件）"
          % (before, len(world["props"]), len(PROPS)))
    return world


def main():
    args = sys.argv[1:]
    world = load()
    if "--apply" in args:
        bad = verify(world, verbose=False)
        if bad:
            print("[courtyard] 摆位体检未过，拒绝写入：")
            for b in bad[:40]:
                print("  ", b)
            raise SystemExit(1)
        world = apply(world)
        with open(WORLD, "w", encoding="utf-8") as f:
            json.dump(world, f, ensure_ascii=False, separators=(",", ":"))
        world = load()
    bad = verify(world)
    print("[courtyard] %s" % ("ALL PASS" if not bad else "FAILED"))
    if bad:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
