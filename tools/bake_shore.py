#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
为水缘生成「绿化带 + 水面凹陷」透明叠加层（28 张 1024 分块，对齐地面图网格）。

每个水矩形（抠掉桥面足迹）周围：
  - 外侧 BANK_PX 像素：草地绿带 + 灌木斑点（绿化带）
  - 最外缘 LIP_PX 像素：提亮（岸边被光照到，显得高）
  - 内侧 SHADOW_PX 像素：深蓝半透明（水面比岸低，边缘变暗=凹陷感）

零依赖纯 Python。输出 assets/shore/g{cx}_{cy}.png（全透明分块不写文件）。
build_world_scene.gd 会在 Ground 层把这些叠到地面图之上。

用法：python3 tools/bake_shore.py
"""
import os, zlib, struct, json, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORLD = os.path.join(ROOT, "assets", "world.json")
OUTDIR = os.path.join(ROOT, "assets", "shore")
CELL = 8.0
COLS, ROWS, CHUNK = 4, 7, 1024
PXW, PXH = COLS * CHUNK, ROWS * CHUNK  # 3392 x 6400

BANK_PX = 10     # 外侧绿化带宽度（像素，≈1.25 格）
SHADOW_PX = 3    # 内侧水面阴影宽度
LIP_PX = 2       # 最外缘提亮宽度


def encode_png(path, w, h, ch, px):
    raw = bytearray()
    stride = w * ch
    for y in range(h):
        raw.append(0)
        raw += px[y * stride:(y + 1) * stride]
    comp = zlib.compress(bytes(raw), 9)
    colt = 2 if ch == 3 else 6
    out = bytearray(b"\x89PNG\r\n\x1a\n")
    def chunk(typ, body):
        out.extend(struct.pack(">I", len(body)))
        out.extend(typ); out.extend(body)
        out.extend(struct.pack(">I", zlib.crc32(typ + body) & 0xFFFFFFFF))
    chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, colt, 0, 0, 0))
    chunk(b"IDAT", comp)
    chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(out)


def cut_rects(x, y, w, h, holes):
    """把矩形扣掉若干轴对齐洞，返回 [(x,y,w,h)] 列表（逐行扫描，相邻同宽行合并）。"""
    hit = any(x < ox + ow and ox < x + w and y < oy + oh and oy < y + h
              for (ox, oy, ow, oh) in holes)
    if not hit:
        return [(x, y, w, h)]
    out = []
    row = 0
    while row < h:
        ry = y + row
        spans = [(x, x + w)]
        for (ox, oy, ow, oh) in holes:
            if ry < oy or ry >= oy + oh:
                continue
            nxt = []
            for (a, b) in spans:
                if ox >= b or ox + ow <= a:
                    nxt.append((a, b)); continue
                if ox > a:
                    nxt.append((a, min(ox, b)))
                if ox + ow < b:
                    nxt.append((max(ox + ow, a), b))
            spans = nxt
        for (a, b) in spans:
            if b - a <= 0:
                continue
            out.append((a, ry, b - a, 1))
        row += 1
    merged = []
    for (rx, ry, rw, rh) in out:
        if merged and merged[-1][0] == rx and merged[-1][1] + merged[-1][3] == ry and merged[-1][2] == rw:
            merged[-1][3] += 1
        else:
            merged.append([rx, ry, rw, rh])
    return [(rx, ry, rw, rh) for (rx, ry, rw, rh) in merged]


# ---------------------------------------------------------------- 主流程
wj = json.load(open(WORLD))
water = wj.get("water", [])
decks = [(float(b.get("x", 0)), float(b.get("y", 0)), float(b.get("w", 0)), float(b.get("h", 0)))
         for b in wj.get("bridges", [])]

# 水掩码（像素级，1=水）
mask = bytearray(PXW * PXH)
pieces = []  # (x0,y0,x1,y1) 像素闭区间
for r in water:
    wx, wy, ww, wh = float(r["x"]), float(r["y"]), float(r["w"]), float(r["h"])
    if ww < 2 or wh < 2:
        continue
    for (cx, cy, cw, chh) in cut_rects(wx, wy, ww, wh, decks):
        x0 = int(round(cx * CELL)); y0 = int(round(cy * CELL))
        x1 = int(round((cx + cw) * CELL)); y1 = int(round((cy + chh) * CELL))
        pieces.append((x0, y0, x1, y1))
        for yy in range(y0, y1):
            base = yy * PXW
            for xx in range(x0, x1):
                mask[base + xx] = 1

# 分块缓冲
chunks = {}
def put(gx, gy, rgba):
    if gx < 0 or gy < 0 or gx >= PXW or gy >= PXH:
        return
    cx, cy = gx // CHUNK, gy // CHUNK
    if cx >= COLS or cy >= ROWS:
        return
    buf = chunks.get((cx, cy))
    if buf is None:
        buf = bytearray(CHUNK * CHUNK * 4)
        chunks[(cx, cy)] = buf
    i = ((gy % CHUNK) * CHUNK + (gx % CHUNK)) * 4
    buf[i] = rgba[0]; buf[i + 1] = rgba[1]; buf[i + 2] = rgba[2]; buf[i + 3] = rgba[3]

def noise(x, y):
    return (x * 131 + y * 57) % 100

BANK = BANK_PX
SH = SHADOW_PX
LIP = LIP_PX
drawn = 0
for (x0, y0, x1, y1) in pieces:
    w = x1 - x0; h = y1 - y0
    for gy in range(y0 - BANK, y1 + BANK):
        if gy < 0 or gy >= PXH:
            continue
        for gx in range(x0 - BANK, x1 + BANK):
            if gx < 0 or gx >= PXW:
                continue
            inside = mask[gy * PXW + gx] == 1
            if inside:
                # 距最近水边的内距
                d = min(gx - x0, x1 - 1 - gx, gy - y0, y1 - 1 - gy)
                if d < SH:
                    a = int(190 * (1.0 - d / SH)) + 40
                    put(gx, gy, (12, 28, 44, max(40, min(190, a))))
            else:
                # 外侧距水边的外距
                dout = max(0, x0 - gx, gx - (x1 - 1), y0 - gy, gy - (y1 - 1))
                if dout <= BANK:
                    n = noise(gx, gy)
                    if dout >= BANK - LIP:
                        put(gx, gy, (150, 198, 112, 255))      # 外缘提亮（高岸）
                    elif n < 14:
                        put(gx, gy, (64, 118, 48, 255))        # 灌木暗点
                    elif n > 88:
                        put(gx, gy, (122, 186, 98, 255))       # 灌木亮点
                    else:
                        put(gx, gy, (92, 156, 70, 255))        # 草地绿带
                    drawn += 1

# 写出非空分块
os.makedirs(OUTDIR, exist_ok=True)
cnt = 0
for (cx, cy), buf in chunks.items():
    if any(v != 0 for v in buf):
        encode_png(os.path.join(OUTDIR, "g%d_%d.png" % (cx, cy)), CHUNK, CHUNK, 4, buf)
        cnt += 1
print("水缘叠加层已生成：%d 张分块（BANK=%d SHADOW=%d LIP=%d），绿化带像素≈%d" % (cnt, BANK, SH, LIP, drawn))
