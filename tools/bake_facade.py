#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""建筑立面「静态质感」二次烘焙 —— 墙面材质 / 窗格差异 / 外挂设备 / 楼名牌。

本轮只做**小样**：默认只出前后对比图，不写 assets/buildings/*.png，
不碰 world.json、不碰 glow_winb_*.png、不出包、不提交。
用户确认方向后，`--apply --force` 才是全图铺开入口。

## 幂等链（为什么不直接改 PNG）
    assets/_buildings_src/  ->  facade.apply()  ->  assets/buildings/b{i}.png
                            ->  bake_art.bake_window_overlays()  ->  glow_winb_{i}.png
首次 --apply 会把当前 58 张贴图原样备份到 `_buildings_src/`（带 .gdignore，
避免 Godot 再生成 58 个 .import），之后永远从备份重算，重复执行结果一致。

## 颜色红线（违反会连锁破坏夜间窗光）
  * `tools/bake_art.py:263 is_window_pane()` 用「b>r+8 且 b>g+15 且 L>120 且 b>110」
    认窗玻璃；`bake_window_overlays()` 只按这个 mask + 像素坐标生成夜间发光层。
    因此所有明暗调制都给 RGB 三通道加**同一个 delta** → b-r / b-g 恒定，
    再按像素把 delta 夹在「L 仍 >120、b 仍 >110」的区间内 → mask 逐像素不变。
    最后还有一层「分类回滚」兜底。
  * 贴图自带半透明阶梯投影（a=26/62/108）和透明边距（a<=12）。这些像素
    **逐字节不动**：bbox 不变 → y-sort / 窗光 UV / 楼体碰撞都不受影响。
  * 新加的配件只用中性灰（b<=g+15），永远不会变成「玻璃」。
  * `world.json` 只读楼名 / floors / roof / cat，一个字节都不写。

## 用法
    python tools/bake_facade.py                       # 小样对比图 + 自检（默认）
    python tools/bake_facade.py --ids 0,11,51,53
    python tools/bake_facade.py --no-glow-check      # 跳过夜间窗光逐字节复验
    python tools/bake_facade.py --apply --force      # 全图铺开（本轮不跑）
"""
import json
import math
import os
import shutil
import sys
import tempfile
from array import array

from PIL import Image, ImageChops, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

# 直接复用权威判定，绝不自己另写一套阈值
try:
    from bake_art import is_window_pane, BIG_DOMAIN, CELL_W, CELL_H
except Exception:  # pragma: no cover - 仅在单独拷走本文件时兜底
    BIG_DOMAIN, CELL_W, CELL_H = 320, 13, 16

    def is_window_pane(r, g, b):
        L = (r + g + b) / 3.0
        return b > r + 8 and b > g + 15 and L > 120.0 and b > 110.0

WORLD_JSON = os.path.join(ROOT, "assets", "world.json")
BUILDINGS = os.path.join(ROOT, "assets", "buildings")
SRC_DIR = os.path.join(ROOT, "assets", "_buildings_src")
NOTO = os.path.join(ROOT, "assets", "fonts", "noto_sc_game.ttf")
OUT_LIB = os.path.join(ROOT, "shot_facade_lib.png")
OUT_SET = os.path.join(ROOT, "shot_facade_set.png")

FACADE_SEED = 20261111
SAMPLE_IDS = [51, 0, 11, 53, 49, 52]  # 图书馆 / 自动化学院 / 学生中心 / 海天苑北楼 / 两栋窄楼小牌
TOL = 12                              # 平坦区连通用的色差容差
WALL_NOISE = 4                        # 墙面颗粒 ±4 级
PANEL_NOISE = 2                       # 低频分区 ±2 级
AC_MAX, VENT_MAX, NAMEPLATE_MAX = 12, 4, 1

# 全部为中性灰：b-g <= 15，绝不会被判成玻璃
C_SHELL = (166, 170, 174)
C_SHELL_EDGE = (100, 104, 108)
C_GRILLE = (116, 120, 124)
C_AC_SHADOW = (108, 112, 116)
C_VENT_TOP = (186, 190, 194)
C_PIPE = (118, 122, 126)
C_PIPE_LIT = (214, 218, 222)
C_PLATE = (48, 56, 66)
C_PLATE_EDGE = (198, 204, 210)
C_PLATE_TEXT = (238, 242, 246)
C_SILL_LIT, C_SILL_SHADOW = 12, -10   # 窗台：相对原色的 delta


# ---------------------------------------------------------------- 基础工具
def _hash8(seed, i, j, salt=0):
    x = (seed * 374761393 + i * 668265263 + j * 2147483647 + salt * 2654435761) & 0xFFFFFFFF
    x ^= x >> 13
    x = (x * 1274126177) & 0xFFFFFFFF
    x ^= x >> 16
    return x & 0xFF


def _u(seed, i, j, salt=0):
    return _hash8(seed, i, j, salt) / 255.0


def _clamp(v):
    return 0 if v < 0 else (255 if v > 255 else v)


def _smooth_noise(w, h, idx, salt, cell, amp):
    """低频平滑噪声（BICUBIC 放大的小随机图）。逐像素独立 hash 会变成椒盐噪点，
    缩到游戏比例后尤其像脏条纹；墙面要的是涂料/砖面的缓慢明暗起伏。"""
    gw, gh = w // cell + 3, h // cell + 3
    data = bytes(_hash8(FACADE_SEED + salt * 131, idx * 67 + i, j)
                 for j in range(gh) for i in range(gw))
    small = Image.frombytes("L", (gw, gh), data)
    big = small.resize((gw * cell, gh * cell), Image.BICUBIC)
    return [int((v - 128) / 128.0 * amp) for v in big.crop((0, 0, w, h)).tobytes()]


def load_world():
    with open(WORLD_JSON, encoding="utf-8") as f:
        return json.load(f)


def _font(size):
    try:
        return ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", size)
    except Exception:
        return ImageFont.load_default(size=size)


def _noto(size):
    try:
        return ImageFont.truetype(NOTO, size)
    except Exception:
        return _font(size)


def shorten(name):
    """楼名牌放不下全名，去校名/修饰前缀后截到 7 字。"""
    n = name or ""
    for p in ("西北工业大学", "亚洲最大", "西工大"):
        if n.startswith(p):
            n = n[len(p):]
            break
    n = n.replace("大楼·", "").replace("·", "")
    return n[:7] if len(n) > 7 else n


# ---------------------------------------------------------------- 掩码与分组
def _masks(im):
    im = im.convert("RGBA")
    w, h = im.size
    pix = bytearray(im.tobytes())          # 4 bytes/px: R G B A
    n = w * h
    glass = bytearray(n)
    solid = bytearray(n)                   # 可作画的实体（a>=250 且非玻璃）
    opaque = bytearray(n)
    minx, miny, maxx, maxy = w, h, -1, -1
    for p in range(n):
        o = p << 2
        a = pix[o + 3]
        if a <= 12:
            continue
        opaque[p] = 1
        x, y = p % w, p // w
        if x < minx: minx = x
        if x > maxx: maxx = x
        if y < miny: miny = y
        if y > maxy: maxy = y
        if a < 250:
            continue                       # 半透明阶梯投影：完全不碰
        r, g, b = pix[o], pix[o + 1], pix[o + 2]
        if is_window_pane(r, g, b):
            glass[p] = 1
        elif b > r + 8 and b > g + 15:
            # 「偏蓝但 L<=120」的深蓝玻璃暗纹/窗棂（图书馆穹顶有几千个）：
            # 既不是窗光 mask，也不是墙。保持逐字节不动，否则落水管/通风箱
            # 会被画到玻璃穹顶上，且正向 delta 容易把它推成「玻璃」。
            pass
        else:
            solid[p] = 1
    return w, h, pix, glass, solid, opaque, (minx, miny, maxx, maxy)


def _glass_cells(w, h, glass, idx):
    """复刻 bake_art 的分组：4 邻域连通域，过大的玻璃幕墙按 13×16 再切格。
    这样「一扇窗」就是烘焙窗光时的一格，明暗/窗帘差异不会跨窗。"""
    gid = array("i", [-1]) * (w * h)
    groups = []
    for start in range(w * h):
        if not glass[start] or gid[start] >= 0:
            continue
        gi = len(groups)
        pixs = []
        stack = [start]
        gid[start] = gi
        minx = maxx = start % w
        miny = maxy = start // w
        while stack:
            p = stack.pop()
            pixs.append(p)
            x, y = p % w, p // w
            if x < minx: minx = x
            if x > maxx: maxx = x
            if y < miny: miny = y
            if y > maxy: maxy = y
            for q in (p - 1 if x > 0 else -1,
                      p + 1 if x + 1 < w else -1,
                      p - w if y > 0 else -1,
                      p + w if y + 1 < h else -1):
                if q >= 0 and glass[q] and gid[q] < 0:
                    gid[q] = gi
                    stack.append(q)
        groups.append((pixs, minx, maxx, miny, maxy))

    phase_x = idx * 5 % CELL_W
    phase_y = idx * 3 % CELL_H
    cells = []                       # (pixs, minx, maxx, miny, maxy, 是否幕墙切格)
    for gi, (pixs, minx, maxx, miny, maxy) in enumerate(groups):
        if len(pixs) <= BIG_DOMAIN:
            cells.append((pixs, minx, maxx, miny, maxy, False))
            continue
        buckets = {}
        for p in pixs:
            x, y = p % w, p // w
            key = ((x - minx + phase_x) // CELL_W, (y - miny + phase_y) // CELL_H)
            buckets.setdefault(key, []).append(p)
        for pixs2 in buckets.values():
            xs = [p % w for p in pixs2]
            ys = [p // w for p in pixs2]
            cells.append((pixs2, min(xs), max(xs), min(ys), max(ys), True))
    return cells


def _flat_regions(w, h, pix, solid):
    """找大面积近单色的实体区（墙面 / 屋顶 / 深色条带），配件只会落在这些区里。
    不做「墙 vs 屋顶」的语义分类：58 张贴图风格差异大（海天苑是横条玻璃 + 深灰板），
    语义阈值必然误判，改为按颜色连通找平坦面。"""
    seen = bytearray(w * h)
    out = []
    for start in range(w * h):
        if seen[start] or not solid[start]:
            continue
        o = start << 2
        sr, sg, sb = pix[o], pix[o + 1], pix[o + 2]
        stack = [start]
        seen[start] = 1
        pixs = []
        minx = maxx = start % w
        miny = maxy = start // w
        while stack:
            p = stack.pop()
            pixs.append(p)
            x, y = p % w, p // w
            if x < minx: minx = x
            if x > maxx: maxx = x
            if y < miny: miny = y
            if y > maxy: maxy = y
            for q in (p - 1 if x > 0 else -1,
                      p + 1 if x + 1 < w else -1,
                      p - w if y > 0 else -1,
                      p + w if y + 1 < h else -1):
                if q < 0 or seen[q] or not solid[q]:
                    continue
                t = q << 2
                if (abs(pix[t] - sr) + abs(pix[t + 1] - sg)
                        + abs(pix[t + 2] - sb)) <= TOL * 3:
                    seen[q] = 1
                    stack.append(q)
        if len(pixs) < 400:
            continue
        # 玻璃穹顶上的浅灰网格线是 1px 连通网，bbox 覆盖整片穹顶但填充率极低。
        # 不排除的话落水管会顺着网格竖线画穿整个玻璃穹顶。
        fill = len(pixs) / float((maxx - minx + 1) * (maxy - miny + 1))
        if fill < 0.45:
            continue
        out.append({
            "n": len(pixs), "x0": minx, "y0": miny, "x1": maxx, "y1": maxy,
            "L": (sr + sg + sb) / 3.0, "seed": (sr, sg, sb), "pixs": pixs,
        })
    out.sort(key=lambda r: -r["n"])
    return out[:40]


# ---------------------------------------------------------------- 主变换
def apply(im, idx, bld):
    """给单栋建筑贴图加静态立面细节。纯函数：同一输入两次结果逐字节一致。

    保证：玻璃 mask、alpha 通道、半透明投影、不透明包围盒全部逐像素不变。
    """
    w, h, src, glass0, solid, opaque, bbox0 = _masks(im)
    out = bytearray(src)
    n = w * h
    name = bld.get("name", "")
    floors = int(bld.get("floors", 0) or 0)
    cat = bld.get("cat", "")

    def shade(p, d):
        """只给实体像素的三通道加同一个 delta（保持 b-r / b-g 恒定）。"""
        if not solid[p]:
            return
        o = p << 2
        r, g, b = out[o], out[o + 1], out[o + 2]
        # 图书馆玻璃幕墙里有大量「偏蓝但 L<=120」的深蓝窗棂/暗格，
        # 正向 delta 会把它们推过 L>120 变成「玻璃」→ 夜间 glow 多出一片亮斑。
        # 对这类临界像素禁止把亮度推过 120。
        if not is_window_pane(r, g, b) and (b > r + 8 and b > g + 15 and b > 110):
            d = min(d, int(120 - (r + g + b) / 3.0))
        lo = -min(r, g, b)
        hi = 255 - max(r, g, b)
        d = max(lo, min(hi, d))
        out[o], out[o + 1], out[o + 2] = r + d, g + d, b + d

    def put(p, rgb):
        if not solid[p]:
            return False
        o = p << 2
        out[o], out[o + 1], out[o + 2] = rgb
        return True

    # 1) 墙面两尺度平滑噪声明暗：替掉「一整块纯灰白」，但不能变成椒盐噪点
    n1 = _smooth_noise(w, h, idx, 1, 18, WALL_NOISE)
    n2 = _smooth_noise(w, h, idx, 2, 54, PANEL_NOISE)
    for p in range(n):
        if solid[p]:
            shade(p, n1[p] + n2[p])

    # 2) 逐「窗格」差异：亮玻璃 / 略暗玻璃 / 半幅浅色窗帘
    #    连续玻璃幕墙（穹顶）只做 ±2 的轻微不均，不切窗帘、不画窗台 ——
    #    否则一整片穹顶会被 13×16 网格切成棋盘格（第一版小样就踩过）。
    cells = _glass_cells(w, h, glass0, idx)
    n_curtain = n_dim = n_bright = n_mullion = 0
    for ci, (pixs, minx, maxx, miny, maxy, big) in enumerate(cells):
        u = _u(FACADE_SEED, idx, ci, 71)
        if big:
            target, kind = (2, "bright") if u < 0.5 else (-2, "dim")
            n_mullion += 1
        elif u < 0.44:
            target, kind = 7, "bright"
        elif u < 0.74:
            target, kind = -7, "dim"
        else:
            target, kind = 3, "curtain"
        if kind == "bright": n_bright += 1
        elif kind == "dim": n_dim += 1
        elif kind == "curtain": n_curtain += 1
        curtain_w = max(1, int((maxx - minx + 1) * 0.42))
        for p in pixs:
            o = p << 2
            r, g, b = out[o], out[o + 1], out[o + 2]
            # delta 下限：L 仍 >120 且 b 仍 >110；上限：不溢出 255
            lo = max(121.0 - (r + g + b) / 3.0, 111 - b, -16)
            hi = min(255 - max(r, g, b), 16)
            d = int(max(lo, min(hi, target)))
            if kind == "curtain":
                x = p % w
                if (x - minx) < curtain_w and ((x - minx) // 3) % 2 == 0:
                    d = int(min(hi, max(d, min(28, 255 - max(r, g, b)))))
            out[o], out[o + 1], out[o + 2] = r + d, g + d, b + d

        # 3) 窗台：窗洞下沿 1px 亮边 + 1px 投影，纯手绘立体感
        if not big and len(pixs) >= 20 and maxy + 2 < h:
            for x in range(minx, maxx + 1):
                shade((maxy + 1) * w + x, C_SILL_LIT)
                shade((maxy + 2) * w + x, C_SILL_SHADOW)

    # 4) 平坦面：上下边缘渐淡 AO，让墙面不像一张纸
    regions = _flat_regions(w, h, src, solid)
    for r in regions:
        for x in range(r["x0"], r["x1"] + 1):
            for dy, d in ((0, -5), (1, -3), (2, -1)):
                y = r["y0"] + dy
                if y <= h - 1:
                    shade(y * w + x, d)
            for dy, d in ((0, 2), (1, 1)):
                y = r["y1"] - dy
                if y >= 0:
                    shade(y * w + x, d)

    # 5) 外挂设备 / 落水管 / 楼名牌（都只在实体像素上落笔）
    n_ac = n_vent = n_pipe = n_plate = 0

    def draw_ac(x0, y0):
        nonlocal n_ac
        uw, uh, painted = 11, 7, 0
        for y in range(y0, y0 + uh + 1):
            for x in range(x0, x0 + uw):
                if x < 0 or x >= w or y < 0 or y >= h:
                    continue
                p = y * w + x
                if y == y0 + uh:
                    c = C_AC_SHADOW
                elif x in (x0, x0 + uw - 1) or y in (y0, y0 + uh - 1):
                    c = C_SHELL_EDGE
                elif y in (y0 + 2, y0 + 4):
                    c = C_GRILLE
                else:
                    c = C_SHELL
                if put(p, c):
                    painted += 1
        if painted > uw * uh * 0.6:
            n_ac += 1

    def draw_vent(x0, y0):
        nonlocal n_vent
        uw, uh, painted = 12, 7, 0
        for y in range(y0, y0 + uh):
            for x in range(x0, x0 + uw):
                if x < 0 or x >= w or y < 0 or y >= h:
                    continue
                p = y * w + x
                if x == x0 or y == y0 + uh - 1:
                    c = C_SHELL_EDGE
                elif y == y0:
                    c = C_VENT_TOP
                elif y in (y0 + 2, y0 + 4):
                    c = C_GRILLE
                else:
                    c = C_SHELL
                if put(p, c):
                    painted += 1
        if painted > uw * uh * 0.6:
            n_vent += 1

    # 空调优先挂在「真实窗格」正下方的墙带上，而不是在整面墙随机撒噪点
    spots = []
    for ci, (pixs, minx, maxx, miny, maxy, big) in enumerate(cells):
        if big or len(pixs) < 20:
            continue
        x0 = (minx + maxx) // 2 - 5
        y0 = maxy + 4
        if x0 < 1 or x0 + 12 >= w or y0 + 8 >= h:
            continue
        good = sum(solid[(y0 + dy) * w + x0 + dx]
                   for dy in range(8) for dx in range(11))
        if good > 88 * 0.72:
            spots.append((x0, y0, ci))
    spots.sort(key=lambda s: _u(FACADE_SEED, idx, s[2], 133))
    for x0, y0, _ci in spots[:AC_MAX]:
        draw_ac(x0, y0)

    for ri, r in enumerate(regions):
        bw, bh = r["x1"] - r["x0"] + 1, r["y1"] - r["y0"] + 1
        is_dark = r["L"] < 150

        # 落水管：沿大面积区的左右边缘
        if n_pipe < 2 and bh >= 60 and bw >= 40:
            n_pipe += 1
            px0 = r["x0"] + 2 if _u(FACADE_SEED, idx, ri, 91) < 0.5 else r["x1"] - 2
            for y in range(r["y0"] + 3, r["y1"] - 2):
                put(y * w + px0, C_PIPE)
                put(y * w + px0 + 1, C_PIPE_LIT)

        for k in range(2 if is_dark else 1):
            ux = _u(FACADE_SEED, idx, ri * 9 + k, 101)
            uy = _u(FACADE_SEED, idx, ri * 9 + k, 103)
            x0 = r["x0"] + 4 + int(ux * max(1, bw - 18))
            y0 = r["y0"] + 6 + int(uy * max(1, bh - 16))
            if is_dark and n_vent < VENT_MAX:
                draw_vent(x0, y0)
            elif not is_dark and n_ac < 4:
                # 没有玻璃窗格的楼（海天苑横条立面）退化到平坦面补几台
                draw_ac(x0, y0)

    # 楼名牌：扫「实心矩形」而不是用 flood-fill 区 —— 大白墙上的浅灰网格线
    # 会把连通区切成 13×16 的小格，导致牌被截成两字、中间还断开。
    # 网格线本身也是 solid，矩形密度检测天然把它们算进可绘制面。
    if n_plate < NAMEPLATE_MAX and "无名" not in name:
        W1 = w + 1
        integ = [0] * (W1 * (h + 1))
        for y in range(h):
            row_acc = 0
            base_i = y * w
            for x in range(w):
                row_acc += solid[base_i + x]
                integ[(y + 1) * W1 + x + 1] = integ[y * W1 + x + 1] + row_acc

        def rect_solid(x0, y0, x1, y1):
            return (integ[y1 * W1 + x1] - integ[y0 * W1 + x1]
                    - integ[y1 * W1 + x0] + integ[y0 * W1 + x0])

        # 两档：大牌优先；窄楼 / 横条立面放不下 112x22 时降级到 64x18。
        # 小档放宽到 0.95 的实心密度并细化步长，是为了找到完全干净的
        # 墙面（否则牌会被窗格挖出缺口）；全图预演中 b49 有 64x18 的
        # 1.0 密度区，b52 为 0.983。
        best = None
        for PW, PH, thr, step in ((112, 22, 0.92, 6), (64, 18, 0.95, 2)):
            for y0 in range(2, max(3, h - PH - 2), step):
                for x0 in range(2, max(3, w - min(60, PW // 2)), step):
                    x1, y1 = min(w, x0 + PW), min(h, y0 + PH)
                    if x1 - x0 < 60 or y1 - y0 < 14:
                        continue
                    if rect_solid(x0, y0, x1, y1) < thr * (x1 - x0) * (y1 - y0):
                        continue
                    c = ((y0 + y1) // 2) * w + (x0 + x1) // 2
                    o = c << 2
                    L = (src[o] + src[o + 1] + src[o + 2]) / 3.0
                    score = L - 0.002 * y0      # 浅墙优先，其次靠上
                    if best is None or score > best[0]:
                        best = (score, x0, y0, L, PW, PH)
            if best is not None:
                break
        if best is not None:
            _score, x0, y0, L, PW, PH = best
            light_wall = L >= 150
            base = C_PLATE if light_wall else (206, 210, 214)
            edge = C_PLATE_EDGE if light_wall else (90, 96, 104)
            ink = C_PLATE_TEXT if light_wall else (36, 44, 54)
            chosen = None
            for size in (14, 12, 10, 9, 8):
                f = _noto(size)
                t = shorten(name)
                while len(t) > 2 and f.getlength(t) + 10 > PW - 6:
                    t = t[:-1]
                if len(t) >= 2 and f.getlength(t) + 10 <= PW - 6:
                    chosen = (f, t, int(math.ceil(f.getlength(t))), size)
                    break
            if chosen is not None:
                f, label, tw, size = chosen
                pw, ph = tw + 10, min(20, PH)
                for y in range(y0, y0 + ph):
                    for x in range(x0, x0 + pw):
                        p = y * w + x
                        c = edge if (y in (y0, y0 + ph - 1)
                                     or x in (x0, x0 + pw - 1)) else base
                        put(p, c)
                mask = Image.new("L", (tw + 2, size + 2), 0)
                ImageDraw.Draw(mask).text((1, 0), label, font=f, fill=255)
                mp = mask.load()
                ty = y0 + (ph - size - 2) // 2
                for iy in range(size + 2):
                    for ix in range(tw + 2):
                        v = mp[ix, iy]
                        if not v:
                            continue
                        a = v / 255.0
                        c = tuple(int(base[k] * (1 - a) + ink[k] * a)
                                  for k in range(3))
                        put((ty + iy) * w + x0 + 5 + ix, c)
                n_plate += 1

    # 6) 兜底：alpha / 半透明 / 玻璃分类任何变化都逐像素回滚
    glass_diff = alpha_diff = semi_changed = 0
    for p in range(n):
        o = p << 2
        a0 = src[o + 3]
        if out[o + 3] != a0:
            alpha_diff += 1
            out[o:o + 4] = src[o:o + 4]
            continue
        changed = (out[o] != src[o] or out[o + 1] != src[o + 1]
                   or out[o + 2] != src[o + 2])
        if (a0 <= 12 or a0 < 250) and changed:
            semi_changed += 1
            out[o:o + 4] = src[o:o + 4]
            continue
        if a0 >= 250:
            was = is_window_pane(src[o], src[o + 1], src[o + 2])
            now = is_window_pane(out[o], out[o + 1], out[o + 2])
            if was != now:
                glass_diff += 1
                out[o:o + 4] = src[o:o + 4]

    result = Image.frombytes("RGBA", (w, h), bytes(out))
    minx, miny, maxx, maxy = w, h, -1, -1
    for p in range(n):
        if opaque[p]:
            x, y = p % w, p // w
            if x < minx: minx = x
            if x > maxx: maxx = x
            if y < miny: miny = y
            if y > maxy: maxy = y
    stats = {
        "size": (w, h), "name": name, "cat": cat, "floors": floors,
        "pane_px": sum(glass0), "cells": len(cells), "regions": len(regions),
        "bright": n_bright, "dim": n_dim, "curtain": n_curtain,
        "mullion": n_mullion,
        "ac": n_ac, "vent": n_vent, "pipe": n_pipe, "plate": n_plate,
        "glass_diff": glass_diff, "alpha_diff": alpha_diff,
        "semi_changed": semi_changed,
        "bbox": (minx, miny, maxx, maxy), "bbox0": bbox0,
    }
    return result, stats


# ---------------------------------------------------------------- 自检
def check(stats):
    """像素级红线自检：任何一条不满足就抛错，绝不出图。"""
    def need(cond, msg):
        if not cond:
            raise SystemExit("[facade] 自检失败 b%s：%s" % (stats.get("idx", "?"), msg))
    need(stats["glass_diff"] == 0,
         "窗玻璃分类变化 %d 像素（夜间 glow 贴图会错位）" % stats["glass_diff"])
    need(stats["alpha_diff"] == 0, "alpha 通道被改动")
    need(stats["semi_changed"] == 0, "透明边距 / 半透明阶梯投影被改动")
    need(stats["bbox"] == stats["bbox0"], "不透明包围盒变化（y-sort / UV 会漂）")


def self_test(before, after, idx, bld):
    """幂等 + 全图写回守卫。"""
    def need(cond, msg):
        if not cond:
            raise SystemExit("[facade] 结构自检失败：%s" % msg)
    again, _ = apply(before, idx, bld)
    need(again.tobytes() == after.tobytes(), "apply() 不是幂等的")
    need("--apply" not in sys.argv or "--force" in sys.argv, "全图写回需要 --force")
    print("[facade] 结构自检通过：apply 幂等 / 全图写回有 force 守卫")


def verify_glow(before, after, bld):
    """把 before / after 分别喂给真实的 bake_art.bake_window_overlays()，
    在临时目录里各生成一次窗光贴图并逐字节比对。临时目录用完即删，
    绝不触碰 assets/glow_winb_*.png。"""
    import bake_art
    import io

    def gen(im):
        td = tempfile.mkdtemp(prefix="xgd_facade_glow_")
        try:
            os.makedirs(os.path.join(td, "assets", "buildings"))
            im.save(os.path.join(td, "assets", "buildings", "b0.png"))
            with open(os.path.join(td, "assets", "world.json"), "w",
                      encoding="utf-8") as f:
                json.dump({"buildings": [{"name": bld.get("name", "")}]}, f,
                          ensure_ascii=False)
            old = bake_art.ROOT
            bake_art.ROOT = td
            try:
                bake_art.bake_window_overlays()
            finally:
                bake_art.ROOT = old
            with open(os.path.join(td, "assets", "glow_winb_0.png"), "rb") as f:
                return f.read()
        finally:
            shutil.rmtree(td, ignore_errors=True)

    a, b = gen(before), gen(after)
    if a != b:
        raise SystemExit("[facade] 夜间窗光贴图不一致！立面细节破坏了玻璃 mask")
    print("[facade] 夜间窗光复验通过：bake_art 重烘 glow 逐字节一致（%d B）" % len(a))


# ---------------------------------------------------------------- 对比图
BG = (236, 239, 243, 255)
CANVAS = (24, 26, 30)


def _flatten(im, bg=BG):
    base = Image.new("RGBA", im.size, bg)
    return Image.alpha_composite(base, im.convert("RGBA")).convert("RGB")


def _night(im, idx):
    """近似 building_xray.gdshader：夜幕压暗 + glow 加色叠加。"""
    path = os.path.join(ROOT, "assets", "glow_winb_%d.png" % idx)
    day = _flatten(im).convert("RGB")
    dark = Image.blend(day, Image.new("RGB", day.size, (8, 12, 30)), 0.72)
    if os.path.exists(path):
        gl = Image.open(path).convert("RGBA")
        if gl.size == im.size:
            scaled = ImageChops.multiply(gl.convert("RGB"),
                                         Image.merge("RGB", (gl.getchannel("A"),) * 3))
            dark = ImageChops.add(dark, scaled)
    return dark


def _label(d, xy, text, size, fill, anchor=None):
    d.text(xy, text, font=_font(size), fill=fill, anchor=anchor)


def compare_lib(rec, path):
    """图书馆：DAY / NIGHT 两行 × BEFORE / AFTER 两列。"""
    idx, bld, before, after = rec["idx"], rec["bld"], rec["before"], rec["after"]
    scale = 1.0
    W, H = before.size
    W, H = int(W * scale), int(H * scale)
    imgs = []
    for src in (before, after):
        day = _flatten(src.resize((W, H), Image.LANCZOS))
        imgs.append(day)
        imgs.append(_night(src, idx).resize((W, H), Image.LANCZOS))
    top, gap, side, foot = 76, 16, 108, 56
    cw, ch = W * 2 + gap + side, H * 2 + gap + top + foot
    canvas = Image.new("RGB", (cw, ch), CANVAS)
    d = ImageDraw.Draw(canvas)
    _label(d, (14, 10), "Facade detail sample - %s" % bld.get("name", ""), 24,
           (238, 240, 244))
    _label(d, (14, 42),
           "LEFT: BEFORE    RIGHT: AFTER (SAMPLE ONLY - building PNGs untouched)",
           16, (150, 160, 172))
    for r, tag in enumerate(("DAY", "NIGHT")):
        y = top + r * (H + gap)
        _label(d, (10, y + H // 2), tag, 19, (188, 196, 206), anchor="lm")
        for c in range(2):
            x = side + c * (W + gap)
            canvas.paste(imgs[c * 2 + r], (x, y))
            d.rectangle([x, y, x + W - 1, y + H - 1], outline=(70, 76, 84), width=1)
    _label(d, (12, ch - foot + 8),
           "Wall grain / per-window tone & curtains / sills / AC units / roof vents / "
           "downpipes / nameplate. Glass mask + alpha + night glow stay byte-identical.",
           15, (160, 170, 180))
    canvas.save(path)
    print("[facade] 对比图 -> %s (%d x %d, %d B)" %
          (os.path.basename(path), cw, ch, os.path.getsize(path)))


def compare_set(recs, path):
    """四栋不同风格的楼：每栋一行，左 BEFORE 右 AFTER。"""
    H, W = 392, 300
    top, gap, side, rowh, foot = 70, 16, 132, H + 34, 46
    cw = W * 2 + gap + side
    ch = top + rowh * len(recs) + foot
    canvas = Image.new("RGB", (cw, ch), CANVAS)
    d = ImageDraw.Draw(canvas)
    _label(d, (14, 10), "Facade detail across building styles", 24, (238, 240, 244))
    _label(d, (14, 42), "LEFT: BEFORE    RIGHT: AFTER  |  flat-colour walls get grain, "
           "sills, equipment and a nameplate", 16, (150, 160, 172))
    for r, rec in enumerate(recs):
        y = top + r * rowh
        tag = shorten(rec["bld"].get("name", "")) + "  b%d" % rec["idx"]
        _label(d, (10, y + H // 2), tag, 17, (188, 196, 206), anchor="lm")
        for c, src in enumerate((rec["before"], rec["after"])):
            ratio = min(W / src.width, H / src.height)
            sz = (max(1, int(src.width * ratio)), max(1, int(src.height * ratio)))
            pic = _flatten(src.resize(sz, Image.LANCZOS))
            x = side + c * (W + gap) + (W - sz[0]) // 2
            yy = y + (H - sz[1]) // 2
            canvas.paste(pic, (x, yy))
            d.rectangle([x, yy, x + sz[0] - 1, yy + sz[1] - 1],
                        outline=(70, 76, 84), width=1)
    _label(d, (12, ch - foot + 8),
           "SAMPLE ONLY - no assets/buildings/*.png, world.json or glow_winb_*.png written.",
           15, (160, 170, 180))
    canvas.save(path)
    print("[facade] 对比图 -> %s (%d x %d, %d B)" %
          (os.path.basename(path), cw, ch, os.path.getsize(path)))


# ---------------------------------------------------------------- 全图入口
def _apply_full(world):
    """从 _buildings_src 幂等重算并写回 58 张贴图。本轮不执行。"""
    if not os.path.isdir(SRC_DIR):
        os.makedirs(SRC_DIR)
        with open(os.path.join(SRC_DIR, ".gdignore"), "w", encoding="utf-8") as f:
            f.write("")
        for i in range(len(world["buildings"])):
            shutil.copy2(os.path.join(BUILDINGS, "b%d.png" % i),
                         os.path.join(SRC_DIR, "b%d.png" % i))
        print("[facade] 已备份 58 张原图 -> assets/_buildings_src/（带 .gdignore）")
    for i, b in enumerate(world["buildings"]):
        src = Image.open(os.path.join(SRC_DIR, "b%d.png" % i)).convert("RGBA")
        out, stats = apply(src, i, b)
        stats["idx"] = i
        check(stats)
        out.save(os.path.join(BUILDINGS, "b%d.png" % i))
    print("[facade] 已写回 58 张贴图。接下来：重跑 bake_art.py 确认 glow 不变 -> "
          "升 Arena.gd MINIMAP_CACHE -> godot --headless --path . --import -> 双端回归")


def main():
    args = sys.argv[1:]
    world = load_world()
    blds = world["buildings"]

    if "--apply" in args:
        if "--force" not in args:
            raise SystemExit("[facade] 全图铺开会覆盖 58 张建筑贴图，请显式加 --force")
        _apply_full(world)
        return

    ids = SAMPLE_IDS
    if "--ids" in args:
        ids = [int(v) for v in args[args.index("--ids") + 1].split(",")]
    recs = []
    for idx in ids:
        b = blds[idx]
        path = os.path.join(BUILDINGS, "b%d.png" % idx)
        before = Image.open(path).convert("RGBA")
        after, stats = apply(before, idx, b)
        stats["idx"] = idx
        check(stats)
        recs.append({"idx": idx, "bld": b, "before": before, "after": after,
                     "stats": stats})
        s = stats
        print("[facade] b%-2d %-14s %dx%d  玻璃 %6d px / %4d 窗格 "
              "(亮%d 暗%d 帘%d，其中幕墙格%d) / 平坦区 %2d / "
              "空调%d 通风%d 落水%d 名牌%d | mask diff %d / alpha %d / semi %d" %
              (idx, shorten(b.get("name", "")), s["size"][0], s["size"][1],
               s["pane_px"], s["cells"], s["bright"], s["dim"], s["curtain"],
               s["mullion"], s["regions"], s["ac"], s["vent"], s["pipe"],
               s["plate"], s["glass_diff"], s["alpha_diff"], s["semi_changed"]))

    total_ac = sum(r["stats"]["ac"] for r in recs)
    total_plate = sum(r["stats"]["plate"] for r in recs)
    total_cells = sum(r["stats"]["cells"] for r in recs)
    if total_ac == 0 or total_plate == 0 or total_cells == 0:
        raise SystemExit("[facade] 小样没有生成任何细节，检查平坦区/玻璃分组逻辑")

    main_rec = recs[0]
    self_test(main_rec["before"], main_rec["after"], main_rec["idx"], main_rec["bld"])
    if "--no-glow-check" not in args:
        verify_glow(main_rec["before"], main_rec["after"], main_rec["bld"])

    compare_lib(main_rec, OUT_LIB)
    compare_set(recs, OUT_SET)
    print("[facade] 未写入 assets/buildings/，未改 world.json / glow_winb_*；本轮仅小样对比图。")


if __name__ == "__main__":
    main()
