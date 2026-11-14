#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把外部「俯视像素车」素材包导入成游戏内可用的图集，并替换 world.json / world.tscn 里的 112 台车。

用法:
    python tools/import_car_pack.py --src "C:/Users/xxx/Downloads/77080c6b571d2c60"
    python tools/import_car_pack.py --src <目录> --dry      # 只生成图集与预览，不改数据

做什么:
    1. 把素材包里每台车降采样到 CELL_W x CELL_H（保留比例、底部对齐、alpha 二值化）
    2. 打成一张图集 assets/props_cars_sheet.png（16 列 x 7 行，每格 12x22）
    3. 每台车随机（固定种子）分配一台不重复素材；_vd 朝向 = 上下翻转
    4. 改写 world.json 的 props（sprite + region）
    5. 改写 scenes/world.tscn 里对应节点的 texture / region_rect / offset / polygon
    6. 输出预览图 build/_car_pack_preview.png（放大 8 倍的对照）

注意:
    车辆节点在场景里是 StaticBody2D + Sprite2D + CollisionPolygon2D 三段，
    脚本按「节点名 -> props 里同名车」配对，只改这三处，其余原样保留。
"""
from __future__ import annotations

import argparse
import json
import random
import re
import sys
from pathlib import Path

from PIL import Image

CELL_W, CELL_H = 12, 22          # 单台车在游戏里的最终像素尺寸（原 9x16）
COLS = 16
SHEET_REL = "res://assets/props_cars_sheet.png"
SHEET_ID = "900_carsheet"
SEED = 20261114
ALPHA_CUT = 96                   # alpha 二值化阈值
ZOOM = 8                         # 预览放大倍数

# 素材包里混进来的非「整台轿车」图，人工剔除：
#   car_072  一张图塞了 4 台小摩托（会被当成一坨 X）
#   car_089  科幻飞行器（不是校园车）
BLACKLIST = {"car_072", "car_089"}

GAME = Path(__file__).resolve().parent.parent      # sxgd-game/
ROOT = GAME.parent                                  # 项目根


# --------------------------------------------------------------- 素材筛选
def is_single_vehicle(im: Image.Image) -> bool:
    """alpha 连通块只有一块（多台车挤在一张图里的会被拆成几块，直接排除）。"""
    a = im.convert("RGBA").split()[3]
    w, h = a.size
    px = a.load()
    seen = [[False] * w for _ in range(h)]
    total = 0
    best = 0
    for y0 in range(h):
        for x0 in range(w):
            if px[x0, y0] <= ALPHA_CUT or seen[y0][x0]:
                continue
            stack = [(x0, y0)]
            seen[y0][x0] = True
            n = 0
            while stack:
                x, y = stack.pop()
                n += 1
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < w and 0 <= ny < h and not seen[ny][nx] and px[nx, ny] > ALPHA_CUT:
                        seen[ny][nx] = True
                        stack.append((nx, ny))
            total += n
            best = max(best, n)
    return total > 0 and best / total >= 0.85


# --------------------------------------------------------------- 降采样
def fit_car(src: Image.Image, flip_v: bool) -> Image.Image:
    """等比缩放到底部对齐的 CELL 画布，alpha 硬二值（像素风不能有半透明毛边）。"""
    src = src.convert("RGBA")
    bbox = src.getbbox()
    if bbox:
        src = src.crop(bbox)
    if flip_v:
        src = src.transpose(Image.FLIP_TOP_BOTTOM)

    w, h = src.size
    scale = min(CELL_W / w, CELL_H / h)
    nw, nh = max(1, round(w * scale)), max(1, round(h * scale))

    # 预乘 alpha 后再缩，避免透明边缘把颜色拉黑
    px = src.load()
    pre = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    pp = pre.load()
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a:
                pp[x, y] = (r * a // 255, g * a // 255, b * a // 255, a)
    small = pre.resize((nw, nh), Image.LANCZOS)

    out = Image.new("RGBA", (CELL_W, CELL_H), (0, 0, 0, 0))
    sp = small.load()
    op = out.load()
    ox = (CELL_W - nw) // 2
    oy = CELL_H - nh
    for y in range(nh):
        for x in range(nw):
            pr, pg, pb, pa = sp[x, y]
            if pa < ALPHA_CUT:
                continue
            op[ox + x, oy + y] = (
                min(255, pr * 255 // pa),
                min(255, pg * 255 // pa),
                min(255, pb * 255 // pa),
                255,
            )
    return out


# --------------------------------------------------------------- tscn
def parse_cars(tscn: str):
    """返回 [(节点名, 块起始, 块结束)]。

    场景里每个物件是 StaticBody2D(父节点) + 若干子节点(Sprite/Collision)，
    块 = 从自己的 [node] 头一直到「下一个一级节点」（parent 不含 '/'）之前。
    """
    heads = []   # (start, name, type, parent)
    for m in re.finditer(r'\[node name="([^"]*)" type="([^"]*)"(?: parent="([^"]*)")?', tscn):
        heads.append((m.start(), m.group(1), m.group(2), m.group(3) or ""))
    out = []
    for i, (start, name, ntype, parent) in enumerate(heads):
        if ntype != "StaticBody2D" or parent != "Objects":
            continue
        end = len(tscn)
        for j in range(i + 1, len(heads)):
            if "/" not in heads[j][3]:
                end = heads[j][0]
                break
        out.append((name, start, end))
    return out


def patch_tscn(path: Path, rects: dict[str, tuple[int, int]], dry: bool) -> int:
    tscn = path.read_text(encoding="utf-8")
    if SHEET_ID not in tscn:
        # 在最后一处 ext_resource 之后插入图集
        last = None
        for m in re.finditer(r'\[ext_resource type="[^"]+" path="[^"]+" id="[^"]+"\]\n', tscn):
            last = m
        if last is None:
            sys.exit("找不到 ext_resource 段")
        ins = f'[ext_resource type="Texture2D" path="{SHEET_REL}" id="{SHEET_ID}"]\n'
        tscn = tscn[: last.end()] + ins + tscn[last.end():]

    spans = {name: (a, b) for name, a, b in parse_cars(tscn)}
    patched = 0
    # 从后往前替换，避免偏移错乱
    for name in sorted(spans, key=lambda n: spans[n][0], reverse=True):
        if name not in rects:
            continue
        a, b = spans[name]
        blk = tscn[a:b]
        cx, cy = rects[name]
        nb = blk
        nb = re.sub(r'texture = ExtResource\("[^"]+"\)',
                    f'texture = ExtResource("{SHEET_ID}")', nb, count=1)
        nb = re.sub(r'\noffset = Vector2\([^)]*\)\n',
                    f'\noffset = Vector2(-{(CELL_W - 9) / 2:g}, -{CELL_H})\n', nb, count=1)
        nb = re.sub(r'region_enabled = (?:true|false)\n', '', nb)
        nb = re.sub(r'region_rect = Rect2\([^)]*\)\n', '', nb)
        nb = nb.replace(f'texture = ExtResource("{SHEET_ID}")\n',
                        f'texture = ExtResource("{SHEET_ID}")\n'
                        f'region_enabled = true\n'
                        f'region_rect = Rect2({cx}, {cy}, {CELL_W}, {CELL_H})\n', 1)
        nb = re.sub(r'polygon = PackedVector2Array\([^)]*\)',
                    'polygon = PackedVector2Array('
                    f'-{(CELL_W - 9) / 2:g}, -{round(CELL_H * 0.95, 1)}, '
                    f'{CELL_W - (CELL_W - 9) / 2:g}, -{round(CELL_H * 0.95, 1)}, '
                    f'{CELL_W - (CELL_W - 9) / 2:g}, 0, '
                    f'-{(CELL_W - 9) / 2:g}, 0)', nb, count=1)
        if nb != blk:
            tscn = tscn[:a] + nb + tscn[b:]
            patched += 1

    if not dry:
        path.write_text(tscn, encoding="utf-8")
    return patched


# --------------------------------------------------------------- main
def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="素材包目录（car_001.png … 的父目录）")
    ap.add_argument("--dry", action="store_true", help="只出图集和预览，不改 world.json / world.tscn")
    args = ap.parse_args()

    src_dir = Path(args.src)
    pool = []
    for f in sorted(src_dir.glob("car_*.png")):
        if f.stem in BLACKLIST:
            continue
        if not is_single_vehicle(Image.open(f)):
            print(f"跳过 {f.name}（不是单台车）")
            continue
        pool.append(f)
    if not pool:
        sys.exit(f"{src_dir} 里没有可用的 car_*.png")

    world_json = GAME / "assets" / "world.json"
    data = json.loads(world_json.read_text(encoding="utf-8"))
    cars = [p for p in data["props"]
            if "props_car" in p.get("sprite", "") or "props_cars_sheet" in p.get("sprite", "")]
    if not cars:
        sys.exit("world.json 里没找到车")
    print(f"素材 {len(pool)} 台 / 场上车辆 {len(cars)} 台")

    rng = random.Random(SEED)
    picks = pool[:]
    rng.shuffle(picks)
    if len(picks) < len(cars):
        picks = (picks * (len(cars) // len(picks) + 1))[: len(cars)]

    rows = (len(cars) + COLS - 1) // COLS
    sheet = Image.new("RGBA", (COLS * CELL_W, rows * CELL_H), (0, 0, 0, 0))

    rects: dict[str, tuple[int, int]] = {}
    for i, prop in enumerate(cars):
        name = prop["name"]
        flip = "_vd" in prop["sprite"]
        cell = fit_car(Image.open(picks[i]), flip)
        cx, cy = (i % COLS) * CELL_W, (i // COLS) * CELL_H
        sheet.alpha_composite(cell, (cx, cy))
        rects[name] = (cx, cy)

    sheet_path = GAME / "assets" / "props_cars_sheet.png"
    sheet.save(sheet_path)
    print(f"图集 -> {sheet_path.relative_to(ROOT)}  {sheet.width}x{sheet.height}  {len(cars)} 格")

    if not args.dry:
        dx = -(CELL_W - 9) / 2          # 变宽后向左让 1.5px，保持原中心
        for prop in cars:
            cx, cy = rects[prop["name"]]
            by = float(prop["baseY"])
            prop["sprite"] = SHEET_REL
            prop["region"] = [cx, cy, CELL_W, CELL_H]
            prop["offs"] = [round(dx, 3), -CELL_H]
            # 碰撞按新占地重算，中心不变（宽 12px=1.5 格，高 20.9px）
            if prop.get("collide"):
                xs = [pt[0] for poly in prop["collide"] for pt in poly]
                cxc = (min(xs) + max(xs)) / 2
                x0, x1 = round(cxc - 0.75, 4), round(cxc + 0.75, 4)
                y0, y1 = round(by - 2.6125, 4), round(by, 4)
                prop["collide"] = [[[x0, y0], [x1, y0], [x1, y1], [x0, y1]]]
        world_json.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")),
                              encoding="utf-8")
        n = patch_tscn(GAME / "scenes" / "world.tscn", rects, dry=False)
        print(f"world.json 已更新；world.tscn 改了 {n} 个车辆节点")

    # 预览：图集整体放大 + 随机 6 格
    Z = ZOOM
    prev = sheet.resize((sheet.width * Z, sheet.height * Z), Image.NEAREST)
    bg = Image.new("RGBA", prev.size, (222, 222, 222, 255))
    bg.alpha_composite(prev)
    out_dir = GAME / "build"
    out_dir.mkdir(exist_ok=True)
    bg.save(out_dir / "_car_pack_preview.png")
    print(f"预览 -> build/_car_pack_preview.png  ({bg.width}x{bg.height})")


if __name__ == "__main__":
    main()
