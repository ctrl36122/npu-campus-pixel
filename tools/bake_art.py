#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
一次性美术烘焙（零依赖，纯 Python 自带 zlib）：
  1) 砖路：把地面分块 assets/ground/g{cx}_{cy}.png 里「道路」像素（暖灰、低饱和、中亮度）
     重绘成红砖人字砌法（running bond），砖缝用深灰勾出。用「全局像素坐标」算砖位，
     保证 28 块分块之间砖缝连续不断。
  2) 窗光：逐栋楼扫描 assets/buildings/b{i}.png 的立面窗格（窗洞比墙暗），
     把每个窗格中心转成「校园局部像素」写进 assets/window_glows.json，
     Arena 夜间据此给「每一扇窗」打暖光。

用法（项目根目录）：
  python3 tools/bake_art.py
原图已备份在 assets/ground_bak/，可随时还原。
"""
import os, zlib, struct, json, array

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CELL = 8.0

# ----------------------------------------------------------------- 极小 PNG 编解码
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
        raw.append(0)  # filter type 0 (none)
        raw += px[y * stride:(y + 1) * stride]
    comp = zlib.compress(bytes(raw), 9)
    colt = 2 if ch == 3 else 6
    out = bytearray(b"\x89PNG\r\n\x1a\n")
    def chunk(typ, body):
        out.extend(struct.pack(">I", len(body)))
        out.extend(typ)
        out.extend(body)
        crc = zlib.crc32(typ + body) & 0xFFFFFFFF
        out.extend(struct.pack(">I", crc))
    chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, colt, 0, 0, 0))
    chunk(b"IDAT", comp)
    chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(out)


# ----------------------------------------------------------------- 砖路
def is_road(r, g, b):
    # 道路 = 暖灰、低饱和、中亮度（与草地的绿、水体的蓝、广场的暖米色区分）
    mx = max(r, g, b); mn = min(r, g, b)
    return (mx - mn) < 0.13 * 255 and mn > 0.42 * 255 and mx < 0.78 * 255


def brick_color(gx, gy):
    course_h = 5.0
    brick_w = 10.0
    mortar = 1.0
    row = int(gy // course_h)
    off = (row % 2) * (brick_w / 2.0)
    bx = gx + off
    col = int(bx // brick_w)
    lx = bx - col * brick_w
    ly = gy - row * course_h
    if lx < mortar or ly < mortar:
        return (0.34 * 255, 0.30 * 255, 0.27 * 255)  # 砖缝
    # 砖面：基础红砖 + 按 (行,列) 哈希做轻微明度起伏（确定性，避免噪点闪烁）
    v = ((row * 31 + col * 17) % 7) / 7.0 * 0.10 - 0.05
    top = 0.06 if ly < mortar + 1.0 else 0.0           # 砖顶高光
    edge = 0.05 if lx < mortar + 1.2 else 0.0          # 砖左侧高光
    return ((0.62 + v + top + edge) * 255,
            (0.40 + v + top * 0.8 + edge) * 255,
            (0.32 + v + top * 0.6 + edge) * 255)


def bake_bricks():
    painted = 0
    chunk = 1024
    for cy in range(7):
        for cx in range(4):
            path = os.path.join(ROOT, "assets/ground/g%d_%d.png" % (cx, cy))
            if not os.path.exists(path):
                continue
            w, h, ch, px = decode_png(path)
            buf = bytearray(px)
            for ly in range(h):
                gy = cy * chunk + ly
                base = ly * w * ch
                for lx in range(w):
                    i = base + lx * ch
                    r, g, b = px[i], px[i + 1], px[i + 2]
                    if is_road(r, g, b):
                        br, bg, bb = brick_color(cx * chunk + lx, gy)
                        buf[i] = min(255, int(br))
                        buf[i + 1] = min(255, int(bg))
                        buf[i + 2] = min(255, int(bb))
                        painted += 1
            encode_png(path, w, h, ch, bytes(buf))
    print("[bake_art] 砖路重绘完成，道路像素约 %d 个" % painted)


# ----------------------------------------------------------------- 窗光
def getp(px, w, ch, x, y):
    i = (y * w + x) * ch
    return px[i], px[i + 1], px[i + 2], (px[i + 3] if ch == 4 else 255)


def detect_windows(w, h, ch, px):
    # 不透明包围盒（建筑贴图有透明边距）
    minx = miny = 10 ** 9; maxx = maxy = -1
    for y in range(h):
        for x in range(w):
            _, _, _, a = getp(px, w, ch, x, y)
            if a > 12:
                if x < minx: minx = x
                if x > maxx: maxx = x
                if y < miny: miny = y
                if y > maxy: maxy = y
    if maxx < 0 or (maxy - miny) < 8:
        return []
    # 立面区：跳过顶部屋顶 (~18%) 与底部贴地 (~6%)
    y0 = miny + int((maxy - miny) * 0.18)
    y1 = maxy - int((maxy - miny) * 0.06)
    x0, x1 = minx, maxx
    fac_h = max(1, y1 - y0)
    # 每行平均亮度（仅立面、不透明列）
    rowmean = [0.0] * h
    for y in range(y0, y1):
        s = n = 0
        for x in range(x0, x1):
            r, g, b, a = getp(px, w, ch, x, y)
            if a > 12:
                s += (r + g + b) / 3.0; n += 1
        rowmean[y] = (s / n) / 255.0 if n else 1.0
    # 暗格（窗洞）= 比本行均值明显更暗
    win = [[False] * w for _ in range(h)]
    colcnt = [0] * w
    rowcnt = [0] * h
    for y in range(y0, y1):
        for x in range(x0, x1):
            r, g, b, a = getp(px, w, ch, x, y)
            if a <= 12:
                continue
            L = (r + g + b) / 3.0 / 255.0
            if L < rowmean[y] - 0.08 and L < 0.62:
                win[y][x] = True
                colcnt[x] += 1
                rowcnt[y] += 1
    # 窗列中心：暗像素多的列聚成一段，取段中点
    cols = []
    x = x0
    while x <= x1:
        if colcnt[x] > 0.18 * fac_h:
            s = x
            while x <= x1 and colcnt[x] > 0.18 * fac_h:
                x += 1
            cols.append((s + x - 1) // 2)
        else:
            x += 1
    # 窗排中心
    rows = []
    y = y0
    while y <= y1:
        if rowcnt[y] > 0.10 * (x1 - x0):
            s = y
            while y <= y1 and rowcnt[y] > 0.10 * (x1 - x0):
                y += 1
            rows.append((s + y - 1) // 2)
        else:
            y += 1
    if not cols or not rows:
        return []
    # 笛卡尔网格取交点，去重最小间距
    centers = []
    for cyc in rows:
        for cxc in cols:
            # 该交点附近确实偏暗才算真窗，避免砖墙错点亮
            near = 0; tot = 0
            for yy in range(max(y0, cyc - 2), min(y1, cyc + 3)):
                for xx in range(max(x0, cxc - 2), min(x1, cxc + 3)):
                    tot += 1
                    if win[yy][xx]:
                        near += 1
            if tot and near / tot > 0.30:
                centers.append((cxc, cyc))
    # 间距去重（<4px 合并）
    out = []
    for c in sorted(centers):
        if all(abs(c[0] - o[0]) > 4 or abs(c[1] - o[1]) > 4 for o in out):
            out.append(c)
    return out


def bake_window_glows():
    wj = os.path.join(ROOT, "assets/world.json")
    with open(wj, encoding="utf-8") as f:
        d = json.load(f)
    glows = []
    total = 0
    for i, b in enumerate(d["buildings"]):
        path = os.path.join(ROOT, "assets/buildings/b%d.png" % i)
        if not os.path.exists(path):
            continue
        w, h, ch, px = decode_png(path)
        cents = detect_windows(w, h, ch, px)
        if not cents:
            continue
        bx = float(b["x"]) * CELL
        by = float(b["y"]) * CELL
        for (tx, ty) in cents:
            glows.append([round(bx + tx, 1), round(by + ty, 1)])
        total += len(cents)
    outp = os.path.join(ROOT, "assets/window_glows.json")
    with open(outp, "w", encoding="utf-8") as f:
        json.dump({"glows": glows}, f, ensure_ascii=False)
    print("[bake_art] 窗光点 %d 个（%d 栋楼），写入 %s" % (total, len(d["buildings"]), outp))


# ----------------------------------------------------------------- 窗光：蓝色玻璃透光（逐栋楼）
def is_window_pane(r, g, b) -> bool:
    """只认「明显偏蓝」的窗玻璃：b 比 g 大很多（b>g+15）且比 r 大（b>r+8）、够亮。
    墙是浅灰/暖色（b≈g 或 b<g），灰色玻璃幕墙（b≈g）也不算——避免整栋墙发光；
    窗棂是暗线更暗。这样只有真正偏蓝的窗玻璃会亮，其余保持夜里暗。"""
    L = (r + g + b) / 3.0
    return b > r + 8 and b > g + 15 and L > 120.0 and b > 110.0


# ---- 窗光质感参数 ----
LIT_RATE: float = 0.74      # 夜里有灯的比例（其余为暗窗，只留一点冷色反光）
BIG_DOMAIN: int = 320       # 连通域超过这个像素数就按网格切成一格格窗（玻璃幕墙\)
CELL_W: int = 13            # 切分后「一格窗」的宽/高（贴图像素）
CELL_H: int = 16
# 典型室内灯光色温（add 混合叠在暗墙上）：暖白钨丝 / 暖黄 / 中性暖白 / 冷白荧光 / 淡青
LIGHT_COLORS = (
    (255, 214, 150), (255, 196, 118), (255, 232, 196),
    (226, 238, 245), (190, 224, 240),
)
LIGHT_WEIGHTS = (40, 25, 25, 8, 2)          # 默认（暖为主，少量冷白）
W_WARM = (56, 30, 11, 2, 1)                 # 宿舍/公寓：几乎全是暖黄钨丝灯
W_COOL = (16, 9, 28, 34, 13)                # 教学/实验/办公/图书馆：荧光冷白为主
LIT_WARM: float = 0.80                      # 宿舍夜里亮灯率高
LIT_COOL: float = 0.54                      # 教学/办公楼夜里很多教室是空的
LIT_DEFAULT: float = 0.70
DARK_COLOR = (150, 172, 196)     # 暗窗：夜空/路微弱反光，冷色
BLOOM_COLOR = (255, 226, 180)    # 窗光外溢的柔晕（统一暖白）


def light_profile(name: str):
    """按建筑用途给出「灯光色温权重 + 亮灯率」：宿舍一片暖黄、教学楼一片冷白荧光，
    夜里一眼就能分辨出生活区和教学区。"""
    n = name or ""
    if any(k in n for k in ("宿舍", "公寓", "家园", "餐厅", "食堂")):
        return W_WARM, LIT_WARM
    if any(k in n for k in ("教学", "实验", "图书", "学院", "办公", "科技", "中心")):
        return W_COOL, LIT_COOL
    return LIGHT_WEIGHTS, LIT_DEFAULT


def h32(a: int, b: int, c: int, salt: int) -> int:
    """确定性整数哈希（可复现），替代 random —— 保证每次烘焙结果一致。"""
    x = (a * 73856093) ^ (b * 19349663) ^ (c * 83492791) ^ (salt * 2654435761)
    x &= 0xFFFFFFFF
    x ^= x >> 13
    x = (x * 1274126177) & 0xFFFFFFFF
    x ^= x >> 16
    return x


def pick_color(u: float, weights=LIGHT_WEIGHTS):
    """按权重挑一种灯光色温。"""
    acc = 0
    for k, wt in enumerate(weights):
        acc += wt
        if u * 100 < acc:
            return LIGHT_COLORS[k]
    return LIGHT_COLORS[0]


def bake_window_overlays():
    """逐栋楼：把贴图里「窗玻璃」的像素烘成一张同尺寸发光叠加层
    （assets/glow_winb_{i}.png）。运行时 Arena 把该层精确叠在楼体上，夜里玻璃自己发光。

    质感处理（这一版新增）：
      1) 连通域把玻璃聚成「一扇窗」；过大的域（玻璃幕墙）按网格再切成一格格窗，
         避免出现「整面墙一起亮」的塑料感。
      2) 每格独立随机：约 LIT_RATE 的窗亮着（暖黄/暖白/冷白色温各异、亮度不同），
         其余是暗窗，只留一点冷色反光 —— 真实夜里不可能每扇窗都亮。
      3) 窗内上下渐变 + 轻微噪声，玻璃透光不均。
      4) 窗光外溢柔晕（bloom）：向窗外 2px 扩散一层低 alpha 暖光，只落在楼体上。"""
    wj = os.path.join(ROOT, "assets/world.json")
    with open(wj, encoding="utf-8") as f:
        d = json.load(f)
    n = 0
    for i, b in enumerate(d["buildings"]):
        path = os.path.join(ROOT, "assets/buildings/b%d.png" % i)
        if not os.path.exists(path):
            continue
        w, h, ch, px = decode_png(path)

        # --- 1) 玻璃 mask + 楼体不透明 mask ---
        glass = bytearray(w * h)
        opaque = bytearray(w * h)
        for y in range(h):
            row = y * w
            for x in range(w):
                o = row + x
                r, g, b2, a = getp(px, w, ch, x, y)
                if a <= 12:
                    continue
                opaque[o] = 1
                if is_window_pane(r, g, b2):
                    glass[o] = 1
        if not any(glass):
            encode_png(os.path.join(ROOT, "assets/glow_winb_%d.png" % i), w, h, 4,
                       bytes(w * h * 4))
            n += 1
            continue

        # --- 2) 连通域（4 邻域）把玻璃聚成「一扇窗」 ---
        gid = [-1] * (w * h)
        groups = []          # 每组: [像素索引列表, minx, maxx, miny, maxy]
        stack = []
        for start in range(w * h):
            if glass[start] == 0 or gid[start] >= 0:
                continue
            gi = len(groups)
            pixs = []
            stack.append(start)
            gid[start] = gi
            minx = maxx = start % w
            miny = maxy = start // w
            while stack:
                p = stack.pop()
                pixs.append(p)
                px0 = p % w
                py0 = p // w
                if px0 < minx: minx = px0
                if px0 > maxx: maxx = px0
                if py0 < miny: miny = py0
                if py0 > maxy: maxy = py0
                if px0 > 0 and glass[p - 1] and gid[p - 1] < 0:
                    gid[p - 1] = gi; stack.append(p - 1)
                if px0 + 1 < w and glass[p + 1] and gid[p + 1] < 0:
                    gid[p + 1] = gi; stack.append(p + 1)
                if py0 > 0 and glass[p - w] and gid[p - w] < 0:
                    gid[p - w] = gi; stack.append(p - w)
                if py0 + 1 < h and glass[p + w] and gid[p + w] < 0:
                    gid[p + w] = gi; stack.append(p + w)
            groups.append([pixs, minx, maxx, miny, maxy])

        # --- 3) 过大连通域（玻璃幕墙）按网格再切成一格格窗 ---
        phase_x = i * 5 % CELL_W
        phase_y = i * 3 % CELL_H
        cell_of = [-1] * (w * h)
        cells = {}           # key -> 像素索引列表
        for gi, (pixs, minx, maxx, miny, maxy) in enumerate(groups):
            if len(pixs) <= BIG_DOMAIN:
                key = ("g", gi)
                cells.setdefault(key, []).extend(pixs)
                continue
            for p in pixs:
                x = p % w
                y = p // w
                cxk = (x - minx + phase_x) // CELL_W
                cyk = (y - miny + phase_y) // CELL_H
                k = ("c", gi, cxk, cyk)
                cells.setdefault(k, []).append(p)
        # 把 cell 编号写回，便于后面按格取「该格 bbox」做窗内渐变
        for k, pixs in cells.items():
            for p in pixs:
                cell_of[p] = 1

        # --- 4) 逐「窗格」随机：亮/暗、色温、亮度 ---
        weights, lit_base = light_profile(b.get("name", ""))
        base_a = bytearray(w * h)
        base_r = bytearray(w * h)
        base_g = bytearray(w * h)
        base_b = bytearray(w * h)
        for k, pixs in cells.items():
            # 格的键用于确定性随机；用该格第一个像素坐标做 seed
            p0 = pixs[0]
            sx = p0 % w
            sy = p0 // w
            u1 = (h32(i, sx, sy, 11) % 10000) / 10000.0
            u2 = (h32(i, sx, sy, 23) % 10000) / 10000.0
            u3 = (h32(i, sx, sy, 37) % 10000) / 10000.0
            # 窗内上下渐变（下亮上暗）+ 像素噪声，避免每格一块死板的纯色
            ys = [p // w for p in pixs]
            y0 = min(ys)
            y1 = max(ys)
            span = max(1, y1 - y0)
            # 高层亮灯更稀疏（低层人多）：亮灯率随高度递减
            t_h = (y0 + span * 0.5) / max(1.0, float(h))
            lit_rate = lit_base + 0.16 * (1.0 - t_h)
            if lit_rate > 0.92:
                lit_rate = 0.92
            if u1 < lit_rate:
                col = pick_color(u3, weights)
                if u2 < 0.14:
                    amp = 55 + int(u2 * 200)        # 微亮（台灯/半拉窗帘）
                else:
                    amp = 110 + int(u2 * 95)        # 正常亮灯
            else:
                col = DARK_COLOR
                amp = 12 + int(u2 * 18)             # 暗窗：只留一点冷色反光
            for p in pixs:
                y = p // w
                t = (y - y0) / span
                grad = 0.84 + 0.16 * t
                noise = 0.94 + ((h32(i, p % w, y, 53) % 100) / 100.0) * 0.12
                av = int(amp * grad * noise)
                if av < 1:
                    av = 1
                if av > 255:
                    av = 255
                base_a[p] = av
                base_r[p] = col[0]
                base_g[p] = col[1]
                base_b[p] = col[2]

        # --- 5) 窗光外溢柔晕（bloom）：向邻域扩散，只落在楼体上 ---
        bloom = array.array("f", bytes(4 * w * h))
        K1 = 0.38   # 4 邻域
        K2 = 0.22   # 对角
        K3 = 0.12   # 距离 2
        for p in range(w * h):
            av = base_a[p]
            if av < 40:
                continue
            x = p % w
            y = p // w
            v = float(av)
            if x > 0: bloom[p - 1] += v * K1
            if x + 1 < w: bloom[p + 1] += v * K1
            if y > 0: bloom[p - w] += v * K1
            if y + 1 < h: bloom[p + w] += v * K1
            if x > 0 and y > 0: bloom[p - w - 1] += v * K2
            if x + 1 < w and y > 0: bloom[p - w + 1] += v * K2
            if x > 0 and y + 1 < h: bloom[p + w - 1] += v * K2
            if x + 1 < w and y + 1 < h: bloom[p + w + 1] += v * K2
            if x > 1: bloom[p - 2] += v * K3
            if x + 2 < w: bloom[p + 2] += v * K3
            if y > 1: bloom[p - 2 * w] += v * K3
            if y + 2 < h: bloom[p + 2 * w] += v * K3

        # --- 6) 合成输出 RGBA ---
        out = bytearray(w * h * 4)
        for p in range(w * h):
            a0 = base_a[p]
            bl = bloom[p]
            if a0 > 0:
                av = a0 + int(bl * 0.42)
                if av > 255:
                    av = 255
                o = p * 4
                out[o] = base_r[p]; out[o + 1] = base_g[p]; out[o + 2] = base_b[p]
                out[o + 3] = av
            elif bl > 10.0 and opaque[p]:
                av = int(bl * 0.34)
                if av > 112:
                    av = 112
                o = p * 4
                out[o] = BLOOM_COLOR[0]; out[o + 1] = BLOOM_COLOR[1]
                out[o + 2] = BLOOM_COLOR[2]; out[o + 3] = av
        encode_png(os.path.join(ROOT, "assets/glow_winb_%d.png" % i), w, h, 4, bytes(out))
        n += 1
    print("[bake_art] 窗光叠加层 %d 张（逐窗随机点亮 + 色温 + 柔晕）→ assets/glow_winb_*.png" % n)


if __name__ == "__main__":
    # 砖路已在上一轮烘进地面分块，这里只（重）烘「蓝色玻璃透光叠加层」。
    # 旧的分块暖光球方案（bake_window_glows / glow_win_*.png）已弃用，不再生成。
    bake_window_overlays()
    print("[bake_art] done")

