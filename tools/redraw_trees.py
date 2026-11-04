#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
重绘 decor_0.png 里的树（defs 0-4），并新增三种变体（松树/秋色/深绿），
让「水边绿化带 + 树」有好看的树可用。零依赖纯 Python 改 PNG。

- 保留 defs 5-10（plane/bridge 等）像素原样不动。
- defs 0-4 在原 (rx,ry,w,h) 内重画，沿用原 ax/ay 锚点（保证实例位置不变）。
- 新增 defs 11/12/13：松树 / 秋色树 / 深绿树，放在图集下方空位（ry=320）。

用法（项目根目录）：
  python3 tools/redraw_trees.py            # 直接改 assets/decor_0.png + world.json
  python3 tools/redraw_trees.py --dry      # 只打印计划，不改文件
"""
import os, zlib, struct, json, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ATLAS = os.path.join(ROOT, "assets", "decor_0.png")
WORLD = os.path.join(ROOT, "assets", "world.json")
CELL = 8.0


# ---------------------------------------------------------------- PNG 编解码（仿 bake_art）
def decode_png(path):
    with open(path, "rb") as f:
        data = f.read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not png"
    pos = 8
    w = h = bitd = colt = None
    idat = b""
    while pos < len(data):
        ln = struct.unpack(">I", data[pos:pos + 4])[0]
        typ = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + ln]
        if typ == b"IHDR":
            w, h, bitd, colt = struct.unpack(">IIBB", chunk[:10])
        elif typ == b"IDAT":
            idat += chunk
        elif typ == b"IEND":
            break
        pos += 12 + ln
    raw = zlib.decompress(idat)
    ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colt]
    stride = w * ch
    out = bytearray()
    prev = bytearray(stride)
    p = 0
    for _ in range(h):
        f = raw[p]; p += 1
        line = bytearray(raw[p:p + stride]); p += stride
        for i in range(stride):
            a = line[i - ch] if i >= ch else 0
            b = prev[i]
            c = prev[i - ch] if i >= ch else 0
            if f == 1:
                line[i] = (line[i] + a) & 255
            elif f == 2:
                line[i] = (line[i] + b) & 255
            elif f == 3:
                line[i] = (line[i] + ((a + b) >> 1)) & 255
            elif f == 4:
                pp = a + b - c
                pa = abs(pp - a); pb = abs(pp - b); pc = abs(pp - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        out += line
        prev = line
    return w, h, ch, bytes(out)


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
        out.extend(typ)
        out.extend(body)
        out.extend(struct.pack(">I", zlib.crc32(typ + body) & 0xFFFFFFFF))
    chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, colt, 0, 0, 0))
    chunk(b"IDAT", comp)
    chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(out)


# ---------------------------------------------------------------- 画布
w, h, ch, src = decode_png(ATLAS)
assert ch == 4, "atlas 需为 RGBA，实际 ch=%d" % ch
OLD_H = h
NW = w
NH = 512
buf = bytearray(NW * NH * 4)  # 全透明
# 复制原图顶部 OLD_H 行（defs 5-10 都在 ry<302 区域，完整保留）
for y in range(OLD_H):
    s0 = y * w * 4
    d0 = y * NW * 4
    buf[d0:d0 + w * 4] = src[s0:s0 + w * 4]


def setpx(x, y, rgba):
    if 0 <= x < NW and 0 <= y < NH:
        i = (y * NW + x) * 4
        buf[i] = rgba[0]; buf[i + 1] = rgba[1]; buf[i + 2] = rgba[2]; buf[i + 3] = rgba[3]


def geta(x, y):
    if 0 <= x < NW and 0 <= y < NH:
        return buf[(y * NW + x) * 4 + 3]
    return 0


def clear(rx, ry, rw, rh):
    for y in range(ry, ry + rh):
        for x in range(rx, rx + rw):
            i = (y * NW + x) * 4
            buf[i] = buf[i + 1] = buf[i + 2] = buf[i + 3] = 0


def ellipse(x0, y0, rx_, ry_, rgba, a=255):
    for y in range(int(y0 - ry_ - 1), int(y0 + ry_ + 2)):
        for x in range(int(x0 - rx_ - 1), int(x0 + rx_ + 2)):
            dx = (x - x0) / rx_; dy = (y - y0) / ry_
            if dx * dx + dy * dy <= 1.0:
                setpx(x, y, (rgba[0], rgba[1], rgba[2], a))


# ---------------------------------------------------------------- 调色板
GREEN = dict(outline=(28, 58, 30, 255), shadow=(46, 92, 38, 255), mid=(74, 139, 58, 255),
             light=(126, 186, 98, 255), trunk=(96, 66, 42, 255), trunk_d=(74, 50, 32, 255))
AUTUMN = dict(outline=(92, 40, 20, 255), shadow=(150, 70, 26, 255), mid=(214, 120, 42, 255),
              light=(242, 178, 72, 255), trunk=(96, 66, 42, 255), trunk_d=(74, 50, 32, 255))
PINE = dict(outline=(18, 42, 28, 255), shadow=(30, 72, 44, 255), mid=(46, 102, 64, 255),
            light=(82, 144, 96, 255), trunk=(84, 58, 38, 255), trunk_d=(64, 44, 30, 255))
DARK = dict(outline=(22, 50, 34, 255), shadow=(34, 82, 52, 255), mid=(52, 112, 70, 255),
            light=(96, 160, 110, 255), trunk=(90, 62, 40, 255), trunk_d=(70, 48, 31, 255))


def draw_round(buf_DUMMY, base_x, base_y, tw, th, pal, speckle=0):
    """圆形树冠 + 锥形树干。base 为树干落地像素点（图集绝对坐标）。"""
    trunk_h = int(th * 0.30)
    tw_b = max(3, int(tw * 0.10))
    tw_t = max(2, int(tw_b * 0.55))
    # 接触阴影
    ellipse(base_x, base_y + 1, tw_b * 1.4, 3.0, (20, 30, 16), a=90)
    # 树干
    for y in range(base_y - trunk_h, base_y + 1):
        t = (base_y - y) / max(1, trunk_h)
        hw = int(round(tw_b + (tw_t - tw_b) * t))
        if t < 0.14:
            hw += 1
        for x in range(base_x - hw, base_x + hw + 1):
            setpx(x, y, pal['trunk_d'] if x > base_x else pal['trunk'])
    # 树冠
    cx = base_x
    cy = base_y - trunk_h - int(th * 0.20)
    R = int(tw * 0.42)
    blobs = [(cx, cy, R),
             (cx - R * 0.55, cy - R * 0.35, R * 0.72),
             (cx + R * 0.55, cy - R * 0.30, R * 0.66),
             (cx, cy - R * 0.55, R * 0.60)]
    mask = set()
    for (bx, by, r) in blobs:
        for y in range(int(by - r - 1), int(by + r + 2)):
            for x in range(int(bx - r - 1), int(bx + r + 2)):
                dx = x - bx; dy = y - by
                if dx * dx + dy * dy <= r * r:
                    lit = ((-(x - cx)) + (-(y - cy))) / (2.0 * R)
                    lit = max(0.0, min(1.0, 0.5 + lit * 0.6))
                    if lit > 0.72:
                        col = pal['light']
                    elif lit < 0.32:
                        col = pal['shadow']
                    else:
                        col = pal['mid']
                    setpx(x, y, col)
                    mask.add((x, y))
    # 叶簇斑点（增加质感）
    import random
    rnd = random.Random(1234 + int(tw))
    for _ in range(speckle):
        sx = cx + rnd.randint(-R, R)
        sy = cy + rnd.randint(-R, R)
        if (sx, sy) in mask:
            setpx(sx, sy, pal['shadow'] if rnd.random() < 0.5 else pal['light'])
    # 描边
    for (x, y) in list(mask):
        if geta(x + 1, y) == 0 or geta(x - 1, y) == 0 or geta(x, y + 1) == 0 or geta(x, y - 1) == 0:
            setpx(x, y, pal['outline'])


def draw_pine(base_x, base_y, tw, th, pal):
    trunk_h = int(th * 0.16)
    twk = max(2, int(tw * 0.07))
    for y in range(base_y - trunk_h, base_y + 1):
        for x in range(base_x - twk, base_x + twk + 1):
            setpx(x, y, pal['trunk'])
    ellipse(base_x, base_y + 1, twk * 2.0, 3.0, (20, 30, 16), a=90)
    tiers = 3
    total_h = int(th * 0.82)
    th0 = base_y - trunk_h
    mask = set()
    for i in range(tiers):
        yy0 = th0 - int((i + 0.7) * total_h / tiers)
        yyb = th0 - int(i * total_h / tiers) + 2
        maxw = int(tw * 0.5 * (1 - i * 0.20))
        for y in range(yy0, yyb + 1):
            t = (y - yy0) / max(1, yyb - yy0)
            hw = int(maxw * t)
            for x in range(base_x - hw, base_x + hw + 1):
                col = pal['light'] if x < base_x - 1 else (pal['shadow'] if x > base_x + 1 else pal['mid'])
                setpx(x, y, col)
                mask.add((x, y))
    for (x, y) in list(mask):
        if geta(x + 1, y) == 0 or geta(x - 1, y) == 0 or geta(x, y + 1) == 0 or geta(x, y - 1) == 0:
            setpx(x, y, pal['outline'])


# ---------------------------------------------------------------- 执行
wj = json.load(open(WORLD))
decor = wj["decor"]

# 1) 重画 defs 0-4
for idx in (0, 1, 2, 3, 4):
    dd = decor[idx]
    rx = int(dd["rx"]); ry = int(dd["ry"]); tw = int(dd["w"]); th = int(dd["h"])
    axc = int(round(float(dd["ax"]) * CELL)); ayc = int(round(float(dd["ay"]) * CELL))
    clear(rx, ry, tw, th)
    draw_round(None, rx + axc, ry + ayc, tw, th, GREEN, speckle=int(tw * 0.5))

# 2) 新增变体（图集空位 ry=320）
NEW = [
    # (name, w, h, rx, pal, kind)
    ("pine",   56, 140, 0,   PINE,   "pine"),
    ("autumn", 86, 132, 64,  AUTUMN, "round"),
    ("dark",   80, 124, 160, DARK,   "round"),
]
new_decor = []
for i, (name, tw, th, rx, pal, kind) in enumerate(NEW):
    ry = 320
    axc = tw // 2
    ayc = th - 8
    clear(rx, ry, tw, th)
    if kind == "pine":
        draw_pine(rx + axc, ry + ayc, tw, th, pal)
    else:
        draw_round(None, rx + axc, ry + ayc, tw, th, pal, speckle=int(tw * 0.5))
    new_decor.append({
        "i": 11 + i, "page": 0, "rx": rx, "ry": ry, "w": tw, "h": th,
        "x": 0, "y": 0, "ax": axc / CELL, "ay": ayc / CELL,
    })
    print("新增装饰 %d: %s %dx%d @(%d,%d) ax=%.2f ay=%.2f" % (11 + i, name, tw, th, rx, ry, axc / CELL, ayc / CELL))

if "--dry" in sys.argv:
    print("[dry] 不动文件。新 decor 条目：", new_decor)
    raise SystemExit(0)

# 3) 写回
encode_png(ATLAS, NW, NH, 4, buf)
wj["decor"] = decor + new_decor
with open(WORLD, "w", encoding="utf-8") as f:
    json.dump(wj, f, ensure_ascii=False, separators=(",", ":"))
print("已写回", ATLAS, "(%dx%d)" % (NW, NH))
print("已更新", WORLD, "decor 条目数:", len(wj["decor"]))
