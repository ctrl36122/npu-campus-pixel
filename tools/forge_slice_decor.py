#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 PixelSRPG-Forge 的装饰道具表里切出单个 sprite，存到 assets/props_forge/。

来源（MIT，需保留署名）：
    references/PixelSRPG-Forge-main/.../Buildings_建筑场景/Tiles-SandstoneDungeons.zip
        -> Tiles-Props-pack.png / Tiles-Items-pack.png
切割方式：按 alpha 连通域分块，每块裁成独立 PNG（透明背景，偶数尺寸方便像素对齐）。
只保留「不大不小」的块（过滤噪音点和整张表边框），太大的单独提示。

用法：
    python tools/forge_slice_decor.py            # 切到 assets/props_forge/
    python tools/forge_slice_decor.py --show    # 只打印每块尺寸，不写盘
"""
import os
import sys
import zipfile

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ZIP = os.path.join(ROOT, "..", "references", "PixelSRPG-Forge-main",
                   "PixelSRPG-Forge-main", "Buildings_建筑场景", "Tiles-SandstoneDungeons.zip")
SHEETS = ["Tiles-Props-pack.png", "Tiles-Items-pack.png"]
OUT = os.path.join(ROOT, "assets", "props_forge")


def _entry(zf, base):
    for n in zf.namelist():
        if n.endswith(base):
            return n
    raise SystemExit("[forge] %s 不在压缩包里" % base)
# 块像素面积过滤：太小是噪音/像素点，太大是整张边框或半张表
MIN_AREA = 60
MAX_AREA = 90 * 90


def components(mask):
    """4 连通域，返回 [(x0,y0,x1,y1,set_of_pixels)...]（坐标列表省内存用 bbox 即可）。"""
    H, W = len(mask), len(mask[0])
    seen = [[False] * W for _ in range(H)]
    comps = []
    for y in range(H):
        for x in range(W):
            if mask[y][x] and not seen[y][x]:
                stack = [(x, y)]
                seen[y][x] = True
                minx = maxx = x
                miny = maxy = y
                while stack:
                    cx, cy = stack.pop()
                    if cx < minx:
                        minx = cx
                    if cx > maxx:
                        maxx = cx
                    if cy < miny:
                        miny = cy
                    if cy > maxy:
                        maxy = cy
                    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                        nx, ny = cx + dx, cy + dy
                        if 0 <= nx < W and 0 <= ny < H and mask[ny][nx] and not seen[ny][nx]:
                            seen[ny][nx] = True
                            stack.append((nx, ny))
                comps.append((minx, miny, maxx, maxy))
    return comps


def main():
    if not os.path.exists(ZIP):
        raise SystemExit("[forge] 找不到 %s" % ZIP)
    zf = zipfile.ZipFile(ZIP)
    show = "--show" in sys.argv
    if not show:
        os.makedirs(OUT, exist_ok=True)
    count = 0
    manifest = []
    for sheet in SHEETS:
        data = zf.read(_entry(zf, sheet))
        im = Image.open(__import__("io").BytesIO(data)).convert("RGBA")
        W, H = im.size
        px = im.load()
        mask = [[px[x, y][3] > 16 for x in range(W)] for y in range(H)]
        for (x0, y0, x1, y1) in components(mask):
            w = x1 - x0 + 1
            h = y1 - y0 + 1
            area = w * h
            if area < MIN_AREA or area > MAX_AREA:
                continue
            # 偶数尺寸，像素对齐
            ow, oh = (w + 1) & ~1, (h + 1) & ~1
            cell = Image.new("RGBA", (ow, oh), (0, 0, 0, 0))
            cell.paste(im.crop((x0, y0, x1 + 1, y1 + 1)), (0, 0))
            count += 1
            name = "decor_%02d.png" % count
            manifest.append((name, w, h))
            if show:
                print("  %s %dx%d (area=%d)" % (name, w, h, area))
            else:
                cell.save(os.path.join(OUT, name))
    if not show:
        print("[forge] 切出 %d 个装饰 sprite -> %s" % (count, OUT))


if __name__ == "__main__":
    main()
