#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""地面「静态质感」二次烘焙 —— 投影/AO + 草地分层 + 路面细节。

本轮只做**图书馆周边小样**：默认只出前后对比图，不写 assets/ground/*.png。
用户确认方向后，`--apply --force` 才是全图铺开入口。

## 幂等链（为什么不直接改 PNG）
    assets/_ground_src/  ->  bake_roads.build()  ->  detail.apply()  ->  bake_road_edge.save()
`bake_roads.py` 每次全量重算会 100% 冲掉任何手写进 ground/ 的新层
（`bake_channels.py` 就踩过这个坑）。本模块只提供纯函数 apply(im, ox, oy, world)，
作用于「最终烘焙后的马赛克图」，天然是这条链上的一环。

## 颜色红线（违反会连锁破坏道具摆放/河道/夜间窗光）
  * `tools/place_life_props.py:49` 用 `max(r,g,b)-min(r,g,b)<=12 and 92<=r<=182` 认路面，
    401 个道具的候选点由此而来。
  * `tools/bake_channels.py:52` 用精确 4 色认水面；`bake_roads.py:52` 另有容差 8 的水掩码。
  * 草地 g 主导（g>=r 且 g>=b）。
因此所有明暗调制都用**单调通道压缩 LUT**：`f(v)=v (v<92)` / `92+(v-92)*k (v>=92)`。
三个通道过同一个 LUT → spread 只减不增、r 下限 92 不掉、g 主导不变。
最后再加一层「分类回滚」兜底：任何让 is_road / 草地 / 水 掩码变化的像素直接恢复原值。

## 用法
    python tools/bake_ground_detail.py                  # 出小样对比图（不写地面，默认自检）
    python tools/bake_ground_detail.py --apply --force  # 全图铺开（本轮不跑）
    python tools/bake_ground_detail.py --box x0,y0,x1,y1 --scale 1.5
"""
import json
import os
import random
import sys
from functools import lru_cache

from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
WORLD_JSON = os.path.join(ROOT, "assets", "world.json")
GROUND = os.path.join(ROOT, "assets", "ground")
OUT_LIB = os.path.join(ROOT, "shot_ground_detail_lib.png")
OUT_CLOSE = os.path.join(ROOT, "shot_ground_detail_closeup.png")

# 与 bake_road_edge.py / bake_roads.py 保持一致
CELL = 8
CHUNK = 1024
COLS, ROWS = 4, 7
WORLD_W, WORLD_H = 3392, 6400
ROAD_MIN, ROAD_MAX, ROAD_SPREAD = 92, 182, 12
WATER_COLORS = [(104, 146, 132), (120, 164, 146), (88, 128, 116), (142, 188, 164)]
WATER_TOL = 8

DETAIL_SEED = 20261110
# 图书馆（box 215.8,316.1 - 277.9,379.5 格）及周边，含道路、草坪、水岸
LIB_BOX = (1560, 2360, 2380, 3180)
CLOSE_BOX = (1580, 2680, 2180, 2980)   # 同时含弧形路 / 草地 / 水岸

# ---- 强度 ----
SHADOW_K = 0.64            # 最暗版压缩系数（仅 >=92 的通道被压）
# 建筑影分三段由近到远渐淡；只画建筑**外侧**的扫掠区，内部交给建筑 sprite 遮挡。
# 填满 poly 内部会在对比图里变成一大块污渍，而且建筑底面积比 poly 小。
SHADOW_SWEEP = ((0.42, 160), (0.75, 112), (1.0, 66))
SHADOW_CONTACT = 225       # 楼脚 3px 接触 AO
SHADOW_TREE = 108          # 树冠影
SUN = (0.62, 0.38)         # 光从西北来，影子投向右下
GRASS_AMP = (64, 38, 16)   # 大/中/小三尺度噪声幅度
GRASS_CONTRAST = 1.25      # 噪声对比度：拉太狠会变成方块迷彩
GRASS_BRIGHT, GRASS_DARK = 1.10, 0.88
TUFT_DARK = 0.78
TUFT_DENSITY = 600
# 路面细节色全部满足 is_road（r∈[92,182] 且 spread<=12），画上去不改变分类
DETAIL_COLORS = {
    "manhole": (108, 110, 113),
    "patch": (136, 138, 141),
    "crack": (100, 102, 105),
    "wear": (143, 145, 148),
}
DETAIL_DENSITY = 12000     # 每 N 平方像素撒 1 个细节候选


# ---------------------------------------------------------------- 基础工具
def _hash8(seed, i, j):
    """坐标哈希：让任意裁剪区域生成的噪声与全图同位置完全一致。"""
    x = (i * 374761393 + j * 668265263 + seed * 1442695041) & 0xFFFFFFFF
    x = ((x ^ (x >> 13)) * 1274126177) & 0xFFFFFFFF
    return (x ^ (x >> 16)) & 0xFF


def _nz(mask):
    """L 掩码里非 0 像素数。"""
    h = mask.histogram()
    return sum(h[1:])


def _diff_mask(a, b):
    return ImageChops.difference(a, b).point(lambda v: 255 if v else 0)


def _pix_changed(a, b):
    """两张 RGB 图有任意通道不同的像素 -> L 掩码 255。"""
    d = ImageChops.difference(a, b)
    r, g, bl = d.split()
    return ImageChops.lighter(ImageChops.lighter(r, g), bl).point(
        lambda v: 255 if v else 0)


def load_world():
    with open(WORLD_JSON, encoding="utf-8") as f:
        return json.load(f)


def load_ground(box):
    """从 assets/ground/ 读出指定全局矩形（跨块自动拼接）。只读，不写回。"""
    x0, y0, x1, y1 = box
    out = Image.new("RGB", (x1 - x0, y1 - y0))
    for cy in range(ROWS):
        for cx in range(COLS):
            gx0, gy0 = cx * CHUNK, cy * CHUNK
            ix0, iy0 = max(x0, gx0), max(y0, gy0)
            ix1, iy1 = min(x1, gx0 + CHUNK), min(y1, gy0 + CHUNK)
            if ix0 >= ix1 or iy0 >= iy1:
                continue
            p = os.path.join(GROUND, "g%d_%d.png" % (cx, cy))
            im = Image.open(p).convert("RGB")
            out.paste(im.crop((ix0 - gx0, iy0 - gy0, ix1 - gx0, iy1 - gy0)),
                      (ix0 - x0, iy0 - y0))
    return out


def road_mask(im):
    """与 bake_road_edge.road_mask / place_life_props.is_road 完全同判定。"""
    r, g, b = im.split()
    mx = ImageChops.lighter(ImageChops.lighter(r, g), b)
    mn = ImageChops.darker(ImageChops.darker(r, g), b)
    flat = ImageChops.subtract(mx, mn).point(
        lambda v: 255 if v <= ROAD_SPREAD else 0)
    lum = r.point(lambda v: 255 if ROAD_MIN <= v <= ROAD_MAX else 0)
    return ImageChops.multiply(flat, lum)


def water_mask(im):
    """水色 4 值容差 8 的并集（比精确匹配更保守，宁可多保护几像素）。"""
    m = Image.new("L", im.size, 0)
    for c in WATER_COLORS:
        d = ImageChops.difference(im, Image.new("RGB", im.size, c))
        r, g, b = d.split()
        near = ImageChops.lighter(ImageChops.lighter(r, g), b)
        m = ImageChops.lighter(m, near.point(lambda v: 255 if v <= WATER_TOL else 0))
    return m


def grass_mask(im, road, water):
    """g 主导（g>=r 且 g>=b）且不是路/水。"""
    r, g, b = im.split()
    le_rg = ImageChops.subtract(r, g).point(lambda v: 255 if v == 0 else 0)
    le_bg = ImageChops.subtract(b, g).point(lambda v: 255 if v == 0 else 0)
    m = ImageChops.multiply(le_rg, le_bg)
    return ImageChops.subtract(m, ImageChops.lighter(road, water))


def _compress_lut(k):
    """单调通道压缩：<92 不动，>=92 往 92 收。三通道共用 → spread 单调不增。"""
    return [v if v < ROAD_MIN else
            min(255, ROAD_MIN + int((v - ROAD_MIN) * k)) for v in range(256)]


# ---------------------------------------------------------------- 三层质感
@lru_cache(maxsize=1)
def _tuft_specs():
    """草簇参数表：一次性在全局坐标系里把随机序列走完。

    早先的写法在「点落在裁剪区外」时 continue，导致 random.Random 的后续
    状态依赖 ox/oy —— 小样和全图铺开会画出完全不同的草簇。预生成参数表
    后，随机序列与裁剪无关，任意裁剪所见 == 全图铺开所得。
    """
    rnd = random.Random(DETAIL_SEED + 77)
    out = []
    for _ in range(max(1, WORLD_W * WORLD_H // TUFT_DENSITY)):
        gx, gy = rnd.randrange(WORLD_W), rnd.randrange(WORLD_H)
        dx = rnd.choice((-1, 0, 1))
        ln = rnd.randrange(2, 8)
        v = rnd.randrange(140, 235)
        out.append((gx, gy, dx, ln, v))
    return tuple(out)


@lru_cache(maxsize=1)
def _detail_specs():
    """路面细节参数表，理由同 _tuft_specs。crack 的段数可变，必须整条
    预生成，否则局部/全图两种模式下随机序列会在第一个被跳过的点处分叉。"""
    rnd = random.Random(DETAIL_SEED + 505)
    total = WORLD_W * WORLD_H // DETAIL_DENSITY
    out = []
    for _ in range(total):
        gx, gy = rnd.randrange(WORLD_W), rnd.randrange(WORLD_H)
        kind = rnd.choices(("manhole", "patch", "crack", "wear"),
                           weights=(2, 3, 4, 3))[0]
        col = DETAIL_COLORS[kind]
        if kind == "manhole":
            params = (rnd.randrange(3, 6),)
        elif kind == "patch":
            params = (rnd.randrange(5, 13), rnd.randrange(4, 9))
        elif kind == "crack":
            seg = [(0, 0)]
            cx = cy = 0
            for _ in range(rnd.randrange(2, 5)):
                cx += rnd.randrange(-5, 6)
                cy += rnd.randrange(2, 7)
                seg.append((cx, cy))
            params = (tuple(seg),)
        else:
            params = (rnd.randrange(3, 9), rnd.randrange(2, 5))
        out.append((gx, gy, kind, col, params))
    return tuple(out)


def _noise_grid(size, ox, oy, scale, amp, seed, resample=Image.NEAREST):
    """全局对齐的多尺度噪声：任意裁剪区域都与全图同位置一致。

    大/中尺度用平滑插值，只有最小尺度保留 NEAREST 的像素颗粒；
    三层全用 NEAREST 会得到明显的方块迷彩，不像草地。
    """
    W, H = size
    # 左右各留 2 格 padding：BICUBIC/BILINEAR 会取邻格插值，不留的话
    # 局部小样在裁剪边界算出的颜色与全图铺开时不同（「小样好看、铺开变样」）。
    i0, j0 = ox // scale - 2, oy // scale - 2
    # 右/下再多留 2 格：BICUBIC 取 ±2 邻格，只留 +2 会在裁剪末行差 1~2 级
    w = (ox + W) // scale - i0 + 4
    h = (oy + H) // scale - j0 + 4
    buf = bytearray(w * h)
    for j in range(h):
        for i in range(w):
            buf[j * w + i] = _hash8(seed, i0 + i, j0 + j)
    small = Image.frombytes("L", (w, h), bytes(buf))
    big = small.resize((w * scale, h * scale), resample)
    cx0, cy0 = ox - i0 * scale, oy - j0 * scale
    crop = big.crop((cx0, cy0, cx0 + W, cy0 + H))
    return crop.point(lambda v, a=amp: max(0, min(255, 128 + int((v - 128) * a / 128))))


def _grass_layers(im, grass, ox, oy):
    """打破「单色绿 + 规则十字噪点」：三尺度明暗 + 随机草簇。"""
    W, H = im.size
    noise = Image.new("L", (W, H), 128)
    for idx, (scale, amp, resample) in enumerate(zip(
            (64, 16, 4), GRASS_AMP,
            (Image.BICUBIC, Image.BILINEAR, Image.NEAREST))):
        layer = _noise_grid((W, H), ox, oy, scale, amp,
                            DETAIL_SEED + idx * 31 + 1, resample)
        noise = ImageChops.add(noise, layer, scale=1.0, offset=-128)
    noise = noise.point(lambda v, c=GRASS_CONTRAST:
                        max(0, min(255, 128 + int((v - 128) * c))))
    bright = ImageEnhance.Brightness(im).enhance(GRASS_BRIGHT)
    dark = ImageEnhance.Brightness(im).enhance(GRASS_DARK)
    blended = Image.composite(bright, dark, noise)
    im = Image.composite(blended, im, grass)

    # 草簇：随机短竖线（不是规则网格），同乘暗化 → 保持 g 主导
    tuft = Image.new("L", (W, H), 0)
    td = ImageDraw.Draw(tuft)
    for gx, gy, dx, ln, v in _tuft_specs():
        if not (ox <= gx < ox + W and oy <= gy < oy + H):
            continue
        x, y = gx - ox, gy - oy
        td.line([(x, y), (x + dx, y + ln)], fill=v, width=1)
    tuft = ImageChops.multiply(tuft, grass)
    return Image.composite(ImageEnhance.Brightness(im).enhance(TUFT_DARK), im, tuft)


def _shadow_layer(size, ox, oy, world):
    """建筑扫掠影 + 楼脚接触 AO + 树冠影。坐标系是全局 px。"""
    W, H = size
    tree = Image.new("L", (W, H), 0)
    outlines = Image.new("L", (W, H), 0)   # 所有建筑轮廓：只膨胀一次，避免逐栋全图 MaxFilter
    sweeps = [Image.new("L", (W, H), 0) for _ in SHADOW_SWEEP]
    td, od = ImageDraw.Draw(tree), ImageDraw.Draw(outlines)
    sw_ds = [ImageDraw.Draw(x) for x in sweeps]

    n_bld = 0
    for b in world.get("buildings", []):
        poly = b.get("poly") or []
        if len(poly) < 3:
            continue
        pts = [(float(x) * CELL - ox, float(y) * CELL - oy) for x, y in poly]
        # 影长与楼层成正比：13 层图书馆 107px，比占地 500px 短但方向清楚。
        # 太短会退化成「沿轮廓的一圈暗边」，看不出是投影。
        h = int(b.get("floors", 3) or 3) * 7 + 16
        dx, dy = int(h * SUN[0]), int(h * SUN[1])
        xs, ys = [p[0] for p in pts], [p[1] for p in pts]
        if max(xs) + dx < 0 or min(xs) > W or max(ys) + dy < 0 or min(ys) > H:
            continue
        n_bld += 1
        od.polygon(pts, fill=255)
        for k, (ratio, strength) in enumerate(SHADOW_SWEEP):
            sx, sy = int(dx * ratio), int(dy * ratio)
            shifted = [(x + sx, y + sy) for x, y in pts]
            d = sw_ds[k]
            d.polygon(shifted, fill=strength)
            for i in range(len(pts)):
                j = (i + 1) % len(pts)
                d.polygon([pts[i], pts[j], shifted[j], shifted[i]], fill=strength)

    # 近段强度高、远段低；lighter 取最大 → 从楼脚往外自然渐淡
    sweep = sweeps[0]
    for x in sweeps[1:]:
        sweep = ImageChops.lighter(sweep, x)
    # 关键：挖掉建筑内部。那块地面会被建筑 sprite 盖住，填满只会变成一块污渍。
    sweep = ImageChops.subtract(sweep, outlines)
    # 接触 AO：轮廓外扩 3px 的一圈，比投影更深（全图只做一次膨胀）
    ring = ImageChops.subtract(outlines.filter(ImageFilter.MaxFilter(7)), outlines)
    bld = ImageChops.lighter(sweep, ring.point(lambda v: SHADOW_CONTACT if v else 0))

    n_tree = 0
    for idx, t in enumerate(world.get("instances", [])):
        if t.get("k") != "tree":
            continue
        x = float(t["x"]) * CELL - ox
        y = float(t["y"]) * CELL - oy
        s = float(t.get("s", 1) or 1)
        r = (6.0 * s + 4.0) * random.Random(DETAIL_SEED + idx * 7919).uniform(0.8, 1.25)
        cx, cy = x + 7.0 * s, y + 5.0 * s
        if cx + r < 0 or cx - r > W or cy + r < 0 or cy - r > H:
            continue
        n_tree += 1
        td.ellipse([cx - r, cy - r * 0.62, cx + r, cy + r * 0.62], fill=SHADOW_TREE)
        td.ellipse([x - 2, y - 1, x + 2, y + 2], fill=SHADOW_TREE + 45)

    sh = ImageChops.lighter(bld, tree).filter(ImageFilter.GaussianBlur(1.8))
    return sh, n_bld, n_tree


def _road_details(im, road, ox, oy):
    """井盖/补丁/裂缝/磨损：颜色全在 is_road 类别内，且只画在路面掩码里。"""
    W, H = im.size
    painted = im.copy()
    p = ImageDraw.Draw(painted)
    marks = Image.new("L", (W, H), 0)
    m = ImageDraw.Draw(marks)
    n = 0
    for gx, gy, kind, col, params in _detail_specs():
        if not (ox <= gx < ox + W and oy <= gy < oy + H):
            continue
        x, y = gx - ox, gy - oy
        if kind == "manhole":
            r = params[0]
            p.ellipse([x - r, y - r // 2, x + r, y + r // 2], fill=col)
            m.ellipse([x - r, y - r // 2, x + r, y + r // 2], fill=255)
        elif kind == "patch":
            w, h = params
            p.rectangle([x, y, x + w, y + h], fill=col)
            m.rectangle([x, y, x + w, y + h], fill=255)
        elif kind == "crack":
            seg = [(x + dx, y + dy) for dx, dy in params[0]]
            p.line(seg, fill=col, width=1)
            m.line(seg, fill=255, width=1)
        else:
            w, h = params
            p.ellipse([x, y, x + w, y + h], fill=col)
            m.ellipse([x, y, x + w, y + h], fill=255)
        n += 1
    marks = ImageChops.multiply(marks, road)
    return Image.composite(painted, im, marks), n


def apply(im, ox=0, oy=0, world=None):
    """给「最终烘焙后的地面图」加静态质感。返回 (新图, 统计)。

    ox/oy 是这张图左上角对应的全局像素坐标；全图铺开时传 (0,0)。
    保证：road / grass / water 三个掩码逐像素不变，水像素逐像素不变。
    """
    if world is None:
        world = load_world()
    original = im.copy()
    road0 = road_mask(im)
    water0 = water_mask(im)
    grass0 = grass_mask(im, road0, water0)

    im = _grass_layers(im, grass0, ox, oy)
    im, n_detail = _road_details(im, road0, ox, oy)
    sh, n_bld, n_tree = _shadow_layer(im.size, ox, oy, world)
    lut = _compress_lut(SHADOW_K)
    dark = Image.merge("RGB", tuple(ch.point(lut) for ch in im.split()))
    im = Image.composite(dark, im, sh)

    # 兜底：水像素无条件恢复；分类发生变化的像素恢复原值
    road1 = road_mask(im)
    grass1 = grass_mask(im, road1, water0)
    water1 = water_mask(im)
    restore = ImageChops.lighter(water0, water1)
    restore = ImageChops.lighter(restore, _diff_mask(road0, road1))
    restore = ImageChops.lighter(restore, _diff_mask(grass0, grass1))
    im = Image.composite(original, im, restore)

    stats = {
        "size": im.size, "road_px": _nz(road0), "grass_px": _nz(grass0),
        "water_px": _nz(water0), "shadow_px": _nz(sh),
        "buildings": n_bld, "trees": n_tree, "detail_marks": n_detail,
        "restored_px": _nz(restore),
        "road_diff": _nz(_diff_mask(road0, road_mask(im))),
        "grass_diff": _nz(_diff_mask(grass0, grass_mask(im, road_mask(im), water0))),
        "water_diff": _nz(ImageChops.multiply(_pix_changed(original, im), water0)),
    }
    return im, stats


def self_test(before, after, world, box):
    """幂等 / 全局对齐自检：保证小样所见即全图铺开后该位置所得。"""
    def need(cond, msg):
        if not cond:
            raise SystemExit("[detail] 自检失败：%s" % msg)
    ox, oy, x1, y1 = box
    W, H = x1 - ox, y1 - oy
    # ① 大尺度噪声：全图生成后裁剪 == 直接按局部坐标生成
    seed = DETAIL_SEED + 1
    full = _noise_grid((WORLD_W, WORLD_H), 0, 0, 64, GRASS_AMP[0],
                       seed, Image.BICUBIC)
    sub = _noise_grid((W, H), ox, oy, 64, GRASS_AMP[0], seed, Image.BICUBIC)
    need(sub.tobytes() == full.crop((ox, oy, x1, y1)).tobytes(),
         "多尺度噪声未全局对齐（小样与全图铺开会不一样）")
    # ② apply 纯函数幂等：同一输入两次结果逐字节相同
    again, _ = apply(before, ox, oy, world)
    need(again.tobytes() == after.tobytes(), "apply() 不是幂等的")
    # ③ --apply 全图入口必须显式 --force 才允许（防止误覆盖 28 张地面贴图）
    need("--apply" not in sys.argv or "--force" in sys.argv,
         "全图写回需要 --force")
    # ④ 草簇 / 路面细节的随机序列必须在全局坐标系里一次性走完，
    #    否则「点落在裁剪区外就 continue」会让小样与全图铺开的细节分叉。
    #    完整验证（全图裁切 == 局部）由 tools/preview_full_apply.py 承担。
    need(len(_tuft_specs()) == max(1, WORLD_W * WORLD_H // TUFT_DENSITY),
         "草簇参数表长度异常")
    need(len(_detail_specs()) == WORLD_W * WORLD_H // DETAIL_DENSITY,
         "路面细节参数表长度异常")
    full = None
    print("[detail] 结构自检通过：噪声全局对齐 / 细节随机序列与裁剪无关 / "
          "apply 幂等 / 全图写回有 force 守卫")


def check(stats):
    """像素级自检：任何一条不满足就抛错。"""
    def need(cond, msg):
        if not cond:
            raise SystemExit("[detail] 自检失败：%s" % msg)
    need(stats["road_diff"] == 0, "is_road 掩码发生变化（%d 像素）" % stats["road_diff"])
    need(stats["grass_diff"] == 0, "草地 g 主导掩码发生变化（%d 像素）" % stats["grass_diff"])
    need(stats["water_diff"] == 0, "水面像素被改动（%d 像素）" % stats["water_diff"])
    need(stats["shadow_px"] > 0, "没有生成任何阴影")
    need(stats["buildings"] > 0 and stats["trees"] > 0, "建筑/树影数据为空")
    need(stats["detail_marks"] > 0, "没有生成路面细节")
    print("[detail] 像素自检通过：road/grass/water 掩码逐像素不变，"
          "阴影 %d px（%d 栋楼 / %d 棵树）、路面细节 %d 处、回滚 %d px" %
          (stats["shadow_px"], stats["buildings"], stats["trees"],
           stats["detail_marks"], stats["restored_px"]))


# ---------------------------------------------------------------- 对比图
def _font(size):
    try:
        return ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", size)
    except Exception:
        return ImageFont.load_default(size=size)


def _footprints(world, box, scale):
    """对比图用的建筑占地轮廓：实际游戏里这块地面被建筑 sprite 盖住。
    画出轮廓才能看懂阴影是从哪投出来的。"""
    x0, y0, x1, y1 = box
    out = []
    for b in world.get("buildings", []):
        pts = [(float(x) * CELL, float(y) * CELL) for x, y in (b.get("poly") or [])]
        if len(pts) < 3:
            continue
        xs, ys = [p[0] for p in pts], [p[1] for p in pts]
        if max(xs) < x0 or min(xs) > x1 or max(ys) < y0 or min(ys) > y1:
            continue
        out.append((b.get("name", ""),
                    [((x - x0) * scale, (y - y0) * scale) for x, y in pts]))
    return out


def _compare(before, after, path, scale, title, note, footprints=None):
    w, h = before.size
    W, H = int(w * scale), int(h * scale)
    a = before.resize((W, H), Image.NEAREST)
    b = after.resize((W, H), Image.NEAREST)
    if footprints:
        layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ld = ImageDraw.Draw(layer)
        for _name, pts in footprints:
            # 只描边、不填充：填深色会被误读成「一大块建筑内部阴影」，
            # 也会遮住里面真实的地面质感。
            ld.line(pts + [pts[0]], fill=(244, 248, 252, 205), width=max(2, int(scale)))
            cx = sum(p[0] for p in pts) / len(pts)
            cy = sum(p[1] for p in pts) / len(pts)
            ld.text((cx, cy), "BUILDING", font=_font(max(14, int(15 * scale))),
                    fill=(244, 248, 252, 190), anchor="mm")
        b = Image.alpha_composite(b.convert("RGBA"), layer).convert("RGB")
    top, gap, foot = 62, 14, 54
    canvas = Image.new("RGB", (W * 2 + gap, H + top + foot), (24, 26, 30))
    d = ImageDraw.Draw(canvas)
    f_title, f_tag, f_note = _font(24), _font(19), _font(16)
    d.text((14, 10), title, font=f_title, fill=(238, 240, 244))
    d.text((14, 38), "LEFT: BEFORE (current baked ground)    RIGHT: AFTER (static detail sample)",
           font=f_note, fill=(150, 160, 172))
    canvas.paste(a, (0, top))
    canvas.paste(b, (W + gap, top))
    d.rectangle([0, top, W - 1, top + H - 1], outline=(70, 76, 84), width=1)
    d.rectangle([W + gap, top, W * 2 + gap - 1, top + H - 1],
                outline=(70, 76, 84), width=1)
    d.text((12, top + H + 10), note, font=f_note, fill=(160, 170, 180))
    canvas.save(path)
    print("[detail] 对比图 -> %s (%d x %d, %d B)" %
          (os.path.basename(path), canvas.width, canvas.height, os.path.getsize(path)))


def _apply_full(world):
    """全图铺开：从 _ground_src 幂等重算，再写回 assets/ground/。本轮不执行。"""
    import bake_road_edge as E
    import bake_roads as B
    E.ensure_src()
    src = E.load_mosaic()
    base, _ = B.build(src)
    out, stats = apply(base, 0, 0, world)
    check(stats)
    E.save(out)
    print("[detail] 已全图写回 assets/ground/ —— 记得升 Arena.gd 的 MINIMAP_CACHE "
          "并跑 godot --headless --path . --import")


def main():
    args = sys.argv[1:]
    world = load_world()
    box = LIB_BOX
    if "--box" in args:
        box = tuple(int(v) for v in args[args.index("--box") + 1].split(","))
    scale = 1.5
    if "--scale" in args:
        scale = float(args[args.index("--scale") + 1])

    if "--apply" in args:
        if "--force" not in args:
            raise SystemExit("[detail] 全图铺开会覆盖 28 张地面贴图，请显式加 --force")
        _apply_full(world)
        return

    before = load_ground(box)
    after, stats = apply(before, box[0], box[1], world)
    check(stats)          # 默认就做像素级自检：分类变化会让脚本直接失败
    self_test(before, after, world, box)
    print("[detail] 小样区域 %s：road %d px / grass %d px / water %d px / "
          "shadow %d px / 细节 %d 处 / 回滚 %d px" %
          (str(box), stats["road_px"], stats["grass_px"], stats["water_px"],
           stats["shadow_px"], stats["detail_marks"], stats["restored_px"]))

    _compare(before, after, OUT_LIB, scale,
             "Library area - static ground detail (SAMPLE ONLY, ground PNGs untouched)",
             "Soft building/tree shadows + contact AO / multi-scale grass / manholes, "
             "patches & cracks. WHITE OUTLINE = building footprint (hidden by sprite "
             "in game). Water & road mask preserved.",
             footprints=_footprints(world, box, scale))
    cb = CLOSE_BOX
    if cb[0] >= box[0] and cb[2] <= box[2] and cb[1] >= box[1] and cb[3] <= box[3]:
        b2 = load_ground(cb)
        a2, s2 = apply(b2, cb[0], cb[1], world)
        _compare(b2, a2, OUT_CLOSE, 2.2,
                 "Close-up: asphalt / grass / water edge",
                 "2.2x nearest-neighbour zoom. Grass tufts & manholes are visible; "
                 "water colour and road mask r=92..182 stay byte-identical.")
    print("[detail] 未写入 assets/ground/，未改 world.json；本轮仅小样对比图。")


if __name__ == "__main__":
    main()
