#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""地面精修 v3 —— 楼前踩踏草径 + 路口过街标线 + 广场石板铺装。

（草地柔化试过两版已关闭，见 SOFTEN 注释。）

接在既有幂等链的最后一环：

    assets/_ground_src/ -> bake_roads.build() -> detail.apply() -> refine.apply() -> E.save()

## 为什么要有这一层
铺开静态质感后，1:1 视角下仍有三处明显「空」的地方：
  * 楼门与道路之间没有任何连接，楼像孤立地插在草坪里；
  * 路口没有任何过街标线，道路读起来只有「带子」没有「路口」；
  * 中央广场是一整片 `(201,184,150)` 纯色，连一块石板缝都没有。
（原始草地 8x8 方块曾尝试柔化，两版都更假，见 SOFTEN 注释，当前不动；
水面本来就有细密 4 色纹理，不再叠加波纹。）

## 颜色红线（改一处就会连锁破坏道具摆放 / 水面 / 光照图）
  * `place_life_props.py` 认路面：`max-min<=12 and 92<=r<=182`，认草：`g>r+14 and g>b+28 and g>100`
  * `bake_ground_detail.grass_mask`：`g>=r and g>=b` 且非路非水
  * `bake_channels.py` 用精确 4 色认水面
因此本层所有新颜色：
  * 草地系全部 g 主导且 `g-r>=20 / g-b>=55`，画在已有 grass 掩码内；
  * 标线系用 (180,182,180)，spread=2 / r=180，仍判为 road，画在已有 road 掩码内；
  * 广场石板系全部是「米色底色 + 三通道同一个 delta」，`max-min` 仍是 51、
    `g<r`，既不是 road 也不是 grass 也不是 water；只在 `r>g>b / r-g∈[8,26] /
    g-b∈[20,46]` 的米色铺装掩码内落笔（草 / 路 / 水都不满足该判定）；
  * 水面像素一个都不碰。
结果：road / grass / water 三张掩码逐像素 0 差异，401 个道具候选格不变。

## 确定性 / 幂等
apply() 是纯函数也是覆盖式变换：草径 / 标线 / 砖缝 / 格栅都是固定色覆盖；
板块色全部不等于两种精确底色，第二次调用时不再命中 tone_idx；砖缝与格栅
第二次写的是同一个固定色，阴影像素原样保留，因此 apply(apply(x)) == apply(x)
逐字节成立。全图细节参数按全局坐标（砖号 /
路口 / 楼号）一次性预生成，裁剪区外不消耗随机序列，所以小样所见 == 全图铺开所得。
整条烘焙链仍从 assets/_ground_src/ 重算，--dry / 写回验收按「链重算」比对。

## 用法
    python tools/bake_ground_refine.py                      # 小样对比图，不写任何资源
    python tools/bake_ground_refine.py --dry               # 铺开前：以「第 6 层」为基准的全图零写回预演
    python tools/bake_ground_refine.py --apply --force     # 全图铺开（覆盖 28 张地面贴图）
    python tools/bake_ground_refine.py --verify            # 铺开后：链重算验收
"""
import json
import math
import os
import sys
from functools import lru_cache

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont, ImageStat

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
ROOT = os.path.dirname(HERE)

import bake_road_edge as E          # noqa: E402
import bake_roads as B              # noqa: E402
import bake_ground_detail as D      # noqa: E402
import road_net as N                # noqa: E402

WORLD_JSON = os.path.join(ROOT, "assets", "world.json")
OUT_LIB = os.path.join(ROOT, "shot_ground_refine_lib.png")
OUT_CLOSE = os.path.join(ROOT, "shot_ground_refine_closeup.png")
OUT_JUNCTION = os.path.join(ROOT, "shot_ground_refine_junction.png")
OUT_SCENE = os.path.join(ROOT, "shot_ground_refine_scene.png")
OUT_PLAZA = os.path.join(ROOT, "shot_ground_refine_plaza.png")
OUT_PLAZA_CLOSE = os.path.join(ROOT, "shot_ground_refine_plaza_close.png")
OUT_PLAZA_SCENE = os.path.join(ROOT, "shot_ground_refine_plaza_scene.png")

CELL = 8
WORLD_W, WORLD_H = E.WORLD_W, E.WORLD_H
SEED = 20261111

# 小样取景必须严格对齐全局 8px 网格，否则块均值会与小样/全图分叉
LIB_BOX = (1560, 2360, 2376, 3176)      # 816x816，图书馆周边：草地 / 弧路 / 水岸
JUNCTION_BOX = (544, 0, 1360, 816)      # 816x816，8 栋楼 + 4 个路口，最像真实校园街角
CLOSE_BOX = (1584, 2688, 2160, 2976)    # 576x288，含路 / 草 / 水岸
PLAZA_BOX = (1664, 3520, 2240, 4480)    # 576x960，中央纯色广场 + 周边路 / 草
PLAZA_CLOSE_BOX = (1760, 3760, 2000, 4080)  # 240x320，石板纹理 2 倍放大

# ---- 草地方块柔化 ----
GRASS_BASE = (138, 190, 102)   # 从 g*_*.png 统计出的草地基准色
BLOCK_BLUR = 1.3               # 在 1/8 尺度上平滑块均值的半径（≈3 块）
SOFT_ERODE = 2                 # 只在草地内部动笔，避开路肩 / 水岸的过渡像素
# 试过两版柔化（固定 target 替换 / 块均值低频平滑），都会留下 8px 网格线、
# 路缘亮绿边和大块色斑，比原图更假 —— 当前关闭，只保留纯增量细节。
SOFTEN = False

# ---- 楼前踩踏草径（全部 g 主导，仍是 grass）----
PATH_MAIN = (162, 180, 104)    # 偏土黄，和草地 (138,190,102) 拉开对比
PATH_EDGE = (150, 168, 96)
PATH_W = 10
PATH_MIN_LEN = 36              # 太短的门口不画（避免一坨短粗线）
PATH_MAX_LEN = 264             # 超过就认为这栋楼不临路
PATH_BEND = 9                  # 中段横向弯曲幅度

# ---- 路口过街标线（仍是 road）----
MARK_COLOR = (180, 182, 180)
MARK_W = 2
MARK_GAP = 4
MARK_LEN = 11
MARK_STRIPES = 3
MARK_OFFSET = 14                # 标线组离路口中心的距离（太远会伸出路面）
JUNCTION_MIN_GAP = 44           # 相邻路口合并半径

# ---- 广场石板铺装（仍是「非路非草非水」的米色系）----
PLAZA_TONES = ((201, 184, 150), (213, 196, 162))  # 广场铺装的两种精确底色（暗/亮）
SLAB_W, SLAB_H = 32, 16        # 横向砖，奇数行错缝半块
SLAB_DELTAS = (-4, 1, -2, 3)   # 三通道同 delta；都不为 0，保证改后 != 任一底色
SEAM_DELTA = -18               # 砖缝（固定色，跨过阴影带也不断）
GRATE_DELTA = -28              # 排水格栅
SLAB_COVER = 0.88              # 整块内「米色系」占比，低于就跳过（保住细步道/边界）
PLAZA_ON = True

def load_world():
    with open(WORLD_JSON, encoding="utf-8") as f:
        return json.load(f)


# ---------------------------------------------------------------- 草地柔化
def _strict_grass(im):
    """与 place_life_props 同判定的「真草」掩码。

    D.grass_mask 只要求 g>=r and g>=b，会把路肩上偏灰绿的过渡像素也算成草；
    用严格判定才能在柔化时不给路缘留下一圈亮绿边。
    """
    r, g, b = im.split()
    m = ImageChops.subtract(g, r).point(lambda v: 255 if v > 14 else 0)
    m = ImageChops.multiply(
        m, ImageChops.subtract(g, b).point(lambda v: 255 if v > 28 else 0))
    m = ImageChops.multiply(m, g.point(lambda v: 255 if v > 100 else 0))
    return m


def _soften_blocks(im, ox, oy):
    """把 8x8 贴片的「块间硬跳变」换成连续低频，保留块内全部草簇高频纹理。

    第一版直接把块均值换成固定常数，结果草地变平、还留下 8px 网格线 ——
    正确做法是只平滑「块均值」这一层低频，高频残差原样保留。
    """
    W, H = im.size
    if ox % CELL or oy % CELL or W % CELL or H % CELL:
        raise ValueError("refine.apply 需要 8px 对齐的裁剪框，收到 ox=%d oy=%d %dx%d"
                         % (ox, oy, W, H))
    strict = _strict_grass(im)
    inner = strict.filter(ImageFilter.MinFilter(2 * SOFT_ERODE + 1))
    gw, gh = W // CELL, H // CELL

    bm8 = im.resize((gw, gh), Image.BOX)
    # 非全草块（含路/水）先填成周围草色，避免低频平滑把灰色混进草地
    frac = strict.resize((gw, gh), Image.BOX)
    full = frac.point(lambda v: 255 if v >= 250 else 0)
    rough = bm8.filter(ImageFilter.GaussianBlur(4.0))
    bm8 = Image.composite(bm8, rough, full)

    sm8 = bm8.filter(ImageFilter.GaussianBlur(BLOCK_BLUR))
    low = sm8.resize((W, H), Image.BILINEAR)     # 连续低频：没有 8px 硬边
    bmn = bm8.resize((W, H), Image.NEAREST)      # 硬块均值：用来取块内高频
    pos = ImageChops.subtract(im, bmn)
    neg = ImageChops.subtract(bmn, im)
    out = ImageChops.add(low, pos)
    out = ImageChops.subtract(out, neg)

    # 分类保护：柔化后仍必须 g 主导，否则 place_life_props 会把它当非草
    r2, g2, b2 = out.split()
    g3 = ImageChops.lighter(g2, ImageChops.lighter(r2, b2))
    out = Image.merge("RGB", (r2, g3, b2))
    return Image.composite(out, im, inner)


# ---------------------------------------------------------------- 楼前草径
def _find_road(rp, W, H, x0, y0, ox, oy):
    """只朝正南找路 —— 游戏里所有建筑入口都取 box 南沿，步道方向必须统一。

    四个方向取最近的写法会让草径朝各个方向乱伸，看起来像草地上的划痕。
    """
    for dist in range(10, PATH_MAX_LEN, 2):
        x, y = x0, y0 + dist
        lx, ly = x - ox, y - oy
        if not (2 <= lx < W - 2 and 2 <= ly < H - 2):
            break
        probes = [(int(lx), int(ly + k)) for k in (0, 2, 4)]
        if any(not (0 <= sx < W and 0 <= sy < H) for sx, sy in probes):
            break
        if all(rp[sx, sy] for sx, sy in probes):
            return ((x, y), dist)
    return None


@lru_cache(maxsize=1)
def _path_specs(world_stamp):
    """全局坐标一次性预生成所有草径折线（避免裁剪区外 continue 造成随机分叉）。"""
    world = load_world()
    specs = []
    for idx, b in enumerate(world.get("buildings", [])):
        box = b.get("box") or {}
        if not all(k in box for k in ("minx", "maxx", "maxy")):
            continue
        # 门点：建筑底边中点（格 -> 像素）
        x0 = int((float(box["minx"]) + float(box["maxx"])) / 2 * CELL)
        y0 = int(float(box["maxy"]) * CELL)
        bend = (D._hash8(SEED + 31, idx, 3) - 128) * PATH_BEND / 128.0
        specs.append((idx, x0, y0, bend))
    return tuple(specs)


def _paint_paths(im, strict_grass, road, ox, oy, world):
    W, H = im.size
    rp = road.load()
    layer = Image.new("RGB", (W, H), PATH_EDGE)
    ld = ImageDraw.Draw(layer)
    marks = Image.new("L", (W, H), 0)
    md = ImageDraw.Draw(marks)
    n = 0
    for idx, x0, y0, bend in _path_specs(id(world)):
        if not (ox - 40 <= x0 < ox + W + 40 and oy - 40 <= y0 < oy + H + 40):
            continue
        hit = _find_road(rp, W, H, x0, y0, ox, oy)
        if hit is None or hit[1] < PATH_MIN_LEN:
            continue
        (x1, y1), dist = hit
        vx, vy = x1 - x0, y1 - y0
        L = math.hypot(vx, vy) or 1.0
        px, py = -vy / L, vx / L        # 垂直方向，用来做自然弯曲
        pts = []
        for k in range(13):
            t = k / 12.0
            s = math.sin(t * math.pi) * bend
            pts.append((x0 + vx * t + px * s - ox,
                        y0 + vy * t + py * s - oy))
        ld.line(pts, fill=PATH_EDGE, width=PATH_W + 2, joint="curve")
        ld.line(pts, fill=PATH_MAIN, width=PATH_W, joint="curve")
        md.line(pts, fill=255, width=PATH_W + 2, joint="curve")
        n += 1
    # 必须用「严格草」裁剪：宽松的 D.grass_mask 会把路肩过渡像素也算成草，
    # 染上草径色后那些格子在 place_life_props 里从非草变草，候选网格就动了。
    marks = ImageChops.multiply(marks, strict_grass)
    return Image.composite(layer, im, marks), n


# ---------------------------------------------------------------- 路口标线
def _dseg(p, a, b):
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    L2 = dx * dx + dy * dy
    t = 0.0 if L2 == 0 else max(0.0, min(1.0, ((p[0] - ax) * dx + (p[1] - ay) * dy) / L2))
    return math.hypot(p[0] - (ax + t * dx), p[1] - (ay + t * dy))


@lru_cache(maxsize=1)
def _junction_specs(_stamp):
    """端点落在别的路段上 = 丁字/十字路口。全图只算一次，聚类去重。"""
    roads = N.load()
    raw = []
    for i, r in enumerate(roads):
        pts = r["pts"]
        if r["cls"] < 1:
            continue
        for p in (pts[0], pts[-1]):
            for j, o in enumerate(roads):
                if i == j or o["cls"] < 1:
                    continue
                q = o["pts"]
                if len(q) < 2:
                    continue
                if min(_dseg(p, q[k], q[k + 1]) for k in range(len(q) - 1)) < 1.6:
                    raw.append((p[0] * CELL, p[1] * CELL))
                    break
    clusters = []
    for x, y in raw:
        for c in clusters:
            if abs(x - c[0][0]) < JUNCTION_MIN_GAP and abs(y - c[0][1]) < JUNCTION_MIN_GAP:
                c.append((x, y))
                break
        else:
            clusters.append([(x, y)])
    return tuple((sum(p[0] for p in c) / len(c), sum(p[1] for p in c) / len(c))
                 for c in clusters)


def _paint_marks(im, road, ox, oy, world):
    """每个路口朝四个进口各画一组横条；只有整条都落在路面掩码内才保留。"""
    W, H = im.size
    rp = road.load()
    layer = Image.new("RGB", (W, H), MARK_COLOR)
    marks = Image.new("L", (W, H), 0)
    md = ImageDraw.Draw(marks)
    n = 0
    for gx, gy in _junction_specs(id(world)):
        if not (ox - 60 <= gx < ox + W + 60 and oy - 60 <= gy < oy + H + 60):
            continue
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            # 条纹沿垂直于行进方向展开，逐条往路口里排
            tx, ty = -dy, dx
            stripes = []
            for k in range(MARK_STRIPES):
                d = MARK_OFFSET + k * (MARK_W + MARK_GAP)
                cx, cy = gx + dx * d, gy + dy * d
                a = (cx - ox - tx * MARK_LEN / 2, cy - oy - ty * MARK_LEN / 2)
                b = (cx - ox + tx * MARK_LEN / 2, cy - oy + ty * MARK_LEN / 2)
                # 两端 + 中点都必须是路面，避免条纹伸进草地
                ok = True
                for t in (0.0, 0.5, 1.0):
                    sx, sy = int(a[0] + (b[0] - a[0]) * t), int(a[1] + (b[1] - a[1]) * t)
                    if not (0 <= sx < W and 0 <= sy < H) or not rp[sx, sy]:
                        ok = False
                        break
                if not ok:
                    break
                stripes.append((a, b))
            if len(stripes) < MARK_STRIPES:
                continue
            for a, b in stripes:
                md.line([a, b], fill=255, width=MARK_W)
            n += 1
    marks = ImageChops.multiply(marks, road)
    return Image.composite(layer, im, marks), n


# ---------------------------------------------------------------- 广场石板
def _exact_color_mask(im, color):
    """精确 RGB 相等的 L 掩码（不用容差，这是覆盖式幂等的关键）。"""
    def eq(ch, v):
        return ImageChops.difference(
            ch, Image.new("L", im.size, v)).point(lambda x: 255 if x == 0 else 0)
    r, g, b = im.split()
    return ImageChops.multiply(
        ImageChops.multiply(eq(r, color[0]), eq(g, color[1])), eq(b, color[2]))


def _beige_mask(im):
    """米色铺装系（含阴影渐变），但绝不含草 / 路 / 水。"""
    r, g, b = im.split()
    rg = ImageChops.subtract(r, g)
    gb = ImageChops.subtract(g, b)
    m = rg.point(lambda v: 255 if 8 <= v <= 26 else 0)
    m = ImageChops.multiply(m, gb.point(lambda v: 255 if 20 <= v <= 46 else 0))
    return ImageChops.multiply(m, r.point(lambda v: 255 if 165 <= v <= 225 else 0))


def _paint_plaza(im, ox, oy):
    """只在整块米色铺装内画错缝石板。

    * 砖号 / 行号全部用全局坐标算，小样与全图逐像素一致；
    * 砖缝与格栅是**固定色**，也画在阴影渐变像素上，所以分格不会被阴影切断；
    * 板块色只画在两种精确底色上，且全部不等于底色，二次 apply 不再命中
      tone_idx；缝/格栅位置写的是同一个固定色 -> apply² 逐字节幂等；
    * 阴影像素除缝线外保持原样，明暗层次不丢；细步道覆盖率不足自动跳过。
    """
    W, H = im.size
    area = _beige_mask(im)
    bbox = area.getbbox()
    if bbox is None:
        return im, (0, 0, 0)
    ap = area.load()
    # 每种精确底色一张掩码，tone_idx 记住每个像素原本是哪档底色
    cores = [_exact_color_mask(im, t) for t in PLAZA_TONES]
    tone_idx = Image.new("L", (W, H), 0)
    for k, cm in enumerate(cores):
        tone_idx = ImageChops.lighter(tone_idx, cm.point(lambda v: k + 1 if v else 0))
    ti = tone_idx.load()
    # 只在有主色的全局矩形内枚举砖，省掉整片草地/水面的空转
    GX0, GY0 = ox + bbox[0], oy + bbox[1]
    GX1, GY1 = ox + bbox[2], oy + bbox[3]

    out = im.copy()
    op = out.load()
    n_slab = n_px = n_grate = 0
    by0 = (GY0 + SLAB_H - 1) // SLAB_H
    by1 = GY1 // SLAB_H
    for by in range(by0, by1):
        ly = by * SLAB_H - oy
        if ly < 0 or ly + SLAB_H > H:
            continue
        shift = (SLAB_W // 2) if (by % 2) else 0
        bx0 = (GX0 - shift) // SLAB_W
        bx1 = (GX1 - shift + SLAB_W - 1) // SLAB_W
        for bx in range(bx0, bx1 + 1):
            lx = bx * SLAB_W + shift - ox
            if lx < 0 or lx + SLAB_W > W:
                continue
            cover = ImageStat.Stat(
                area.crop((lx, ly, lx + SLAB_W, ly + SLAB_H))).mean[0] / 255.0
            if cover < SLAB_COVER:
                continue
            d = SLAB_DELTAS[D._hash8(SEED + 31, bx, by) % len(SLAB_DELTAS)]
            grate = D._hash8(SEED + 37, bx, by) % 23 == 0
            slabs = [tuple(t[i] + d for i in range(3)) for t in PLAZA_TONES]
            seam = tuple(PLAZA_TONES[0][i] + SEAM_DELTA for i in range(3))
            grill = tuple(PLAZA_TONES[0][i] + GRATE_DELTA for i in range(3))
            for yy in range(SLAB_H):
                for xx in range(SLAB_W):
                    if not ap[lx + xx, ly + yy]:
                        continue
                    if xx == 0 or yy == SLAB_H - 1:
                        c = seam
                    elif grate and 10 <= xx <= 19 and yy in (4, 7, 10):
                        c = grill
                    else:
                        k = ti[lx + xx, ly + yy] - 1
                        if k < 0:
                            continue        # 阴影渐变像素保留原明暗
                        c = slabs[k]
                    op[lx + xx, ly + yy] = c
                    n_px += 1
            n_slab += 1
            n_grate += 1 if grate else 0
    return out, (n_slab, n_px, n_grate)


# ---------------------------------------------------------------- 主入口
def apply(im, ox=0, oy=0, world=None, plaza_on=True):
    """确定性、幂等。plaza=False 可复现「第 6 层已铺开、石板未铺开」的旧链。"""
    if world is None:
        world = load_world()
    road = D.road_mask(im)
    water = D.water_mask(im)
    grass = D.grass_mask(im, road, water)

    strict = _strict_grass(im)
    out = _soften_blocks(im, ox, oy) if SOFTEN else im
    out, n_path = _paint_paths(out, strict, road, ox, oy, world)
    out, n_mark = _paint_marks(out, road, ox, oy, world)
    plaza = (0, 0, 0)
    if PLAZA_ON and plaza_on:
        out, plaza = _paint_plaza(out, ox, oy)

    # 分类回滚兜底：任何让三张掩码变化的像素都恢复原值
    road2 = D.road_mask(out)
    water2 = D.water_mask(out)
    grass2 = D.grass_mask(out, road2, water2)
    bad = ImageChops.lighter(ImageChops.lighter(
        D._diff_mask(road, road2), D._diff_mask(water, water2)),
        D._diff_mask(grass, grass2))
    restored = D._nz(bad)
    if restored:
        out = Image.composite(im, out, bad)

    stats = {
        "size": im.size, "ox": ox, "oy": oy,
        "grass_px": D._nz(grass), "road_px": D._nz(road), "water_px": D._nz(water),
        "paths": n_path, "mark_groups": n_mark, "restored_px": restored,
        "plaza_slabs": plaza[0], "plaza_px": plaza[1], "grates": plaza[2],
        "junctions": len(_junction_specs(id(world))),
    }
    return out, stats


def check(stats):
    need = lambda ok, msg: None if ok else (_ for _ in ()).throw(AssertionError(msg))
    need(stats["restored_px"] == 0,
         "分类回滚 %d px：新层的颜色破坏了 road/grass/water 掩码" % stats["restored_px"])
    need(stats["grass_px"] > 0 and stats["road_px"] > 0, "小样区域缺少草地或路面")
    return True


def _font(size):
    p = os.path.join(ROOT, "assets", "fonts", "noto_sc_game.ttf")
    if os.path.exists(p):
        return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def _compare(before, after, path, scale, title, note):
    w, h = before.size
    W, H = int(w * scale), int(h * scale)
    a = before.resize((W, H), Image.NEAREST)
    b = after.resize((W, H), Image.NEAREST)
    top, gap, foot = 62, 14, 54
    canvas = Image.new("RGB", (W * 2 + gap, H + top + foot), (24, 26, 30))
    d = ImageDraw.Draw(canvas)
    d.text((14, 10), title, font=_font(24), fill=(238, 240, 244))
    d.text((14, 38), "LEFT: BEFORE (current ground)    RIGHT: AFTER (ground refine v3)",
           font=_font(16), fill=(150, 160, 172))
    canvas.paste(a, (0, top))
    canvas.paste(b, (W + gap, top))
    d.rectangle([0, top, W - 1, top + H - 1], outline=(70, 76, 84), width=1)
    d.rectangle([W + gap, top, W * 2 + gap - 1, top + H - 1],
                outline=(70, 76, 84), width=1)
    d.text((12, top + H + 10), note, font=_font(16), fill=(160, 170, 180))
    canvas.save(path)
    print("[refine] 对比图 -> %s (%dx%d, %d B)" %
          (os.path.basename(path), canvas.width, canvas.height, os.path.getsize(path)))


def _local_scene(ground_crop, world, box):
    """把建筑 sprite 按游戏里的 (x*CELL, y*CELL) + baseY 顺序贴到地面裁切上。

    纯地面对比图会高估草径的突兀感 —— 草径起点本来就被建筑盖住，
    只有按真实遮挡关系看，才能判断它在游戏里自不自然。
    """
    x0, y0, x1, y1 = box
    g = ground_crop.convert("RGBA")
    g.putalpha(255)
    bl = []
    for i, b in enumerate(world["buildings"]):
        x = float(b.get("x", 0.0)) * CELL
        y = float(b.get("y", 0.0)) * CELL
        p = os.path.join(ROOT, "assets", "buildings", "b%d.png" % i)
        if not os.path.exists(p):
            continue
        im = Image.open(p).convert("RGBA")
        if x >= x1 or x + im.width <= x0 or y >= y1 or y + im.height <= y0:
            continue
        bl.append((float(b.get("baseY", y / CELL)), x, y, im))
    bl.sort(key=lambda t: t[0])
    for _, x, y, im in bl:
        dx, dy = int(x - x0), int(y - y0)
        sx0, sy0 = max(0, -dx), max(0, -dy)
        sx1, sy1 = min(im.width, g.width - dx), min(im.height, g.height - dy)
        if sx1 <= sx0 or sy1 <= sy0:
            continue
        g.alpha_composite(im.crop((sx0, sy0, sx1, sy1)), (max(0, dx), max(0, dy)))
    return g.convert("RGB")


def _chain(world):
    """从真源重算整条链，返回 (基础图=当前地面, 精修图)。"""
    E.ensure_src()
    src = E.load_mosaic()
    base, _ = B.build(src)
    mid, _ = D.apply(base, 0, 0, world)
    return mid


def _validate(world, expect_refined):
    """全图校验：链重算 + 分类掩码 + 道具网格 + 确定性。

    expect_refined=False -> --dry    （地面 = 第 6 层，石板层还没写回）
    expect_refined=True  -> --verify （地面已写回石板层，用于铺开后验收）
    legacy = 链重算 + 第 6 层（plaza_on=False）；candidate = legacy + 石板层。
    --dry 拿 legacy 对当前地面，--verify 拿 candidate 对当前地面。
    """
    import hashlib
    import glob
    import tempfile
    import preview_full_apply as V

    tag = "verify" if expect_refined else "dry"
    mid = _chain(world)                        # 精修前的幂等链产物
    cur = D.load_ground((0, 0, WORLD_W, WORLD_H))
    legacy, lst = apply(mid, 0, 0, world, plaza_on=False)  # 第 6 层（当前已铺开）
    candidate, st = apply(mid, 0, 0, world)                # + 广场石板层
    check(st)
    check(lst)

    ref = candidate if expect_refined else legacy
    dchain = D._nz(D._pix_changed(ref, cur))
    print("[%s] 链重算%s vs 当前地面: %d px 差异（应为 0）" %
          (tag, "(含石板)" if expect_refined else "(第 6 层, 不含石板)", dchain))
    if dchain:
        raise SystemExit("[%s] 当前地面与幂等链不一致" % tag)

    again, _ = apply(mid, 0, 0, world)
    ok = candidate.tobytes() == again.tobytes()
    print("[%s] 二次 apply 一致: %s" % (tag, ok))
    if not ok:
        raise SystemExit("[%s] apply 不是确定性的" % tag)
    nd = D._nz(D._pix_changed(legacy, candidate))
    print("[%s] 石板层新增差异 %d px（绘制统计 %d px）" %
          (tag, nd, st["plaza_px"]))
    if nd != st["plaza_px"]:
        raise SystemExit("[%s] 差异像素数与石板绘制统计不符" % tag)
    print("[%s] 草径 %d 条 / 过街标线 %d 组 / 路口 %d 个 / 广场石板 %d 块(%d px, 格栅 %d) / 回滚 %d px" %
          (tag, st["paths"], st["mark_groups"], st["junctions"],
           st["plaza_slabs"], st["plaza_px"], st["grates"], st["restored_px"]))

    # 分类掩码：本轮只比较「第 6 层」与「+ 石板层」
    for name, fn in (("road", D.road_mask), ("water", D.water_mask)):
        d = D._nz(D._diff_mask(fn(legacy), fn(candidate)))
        print("[%s] %s 掩码 diff: %d px" % (tag, name, d))
        if d:
            raise SystemExit("[%s] %s 掩码变了" % (tag, name))
    gm = D.grass_mask(legacy, D.road_mask(legacy), D.water_mask(legacy))
    gc = D.grass_mask(candidate, D.road_mask(candidate), D.water_mask(candidate))
    d = D._nz(D._diff_mask(gm, gc))
    print("[%s] grass 掩码 diff: %d px" % (tag, d))
    if d:
        raise SystemExit("[%s] grass 掩码变了" % tag)

    # 道具候选网格（401 个道具的选址依据）：复用预演脚本的隔离目录方案
    with tempfile.TemporaryDirectory(prefix="xgd_refine_" + tag + "_") as td:
        rb, gb = V.prop_grids(legacy, td, "before")
        ra, ga = V.prop_grids(candidate, td, "after")
    for name, a, b in (("road", rb, ra), ("grass", gb, ga)):
        diff = V.grid_diff(a, b)
        print("[%s] %s 道具网格 diff: %d 格" % (tag, name, diff))
        if diff:
            raise SystemExit("[%s] %s 道具候选网格变了" % (tag, name))

    pats = ["assets/world.json", "assets/osm_tags.json", "assets/ground/g*_*.png",
            "assets/_ground_src/g*_*.png", "assets/buildings/b*.png",
            "assets/glow_winb_*.png"]
    h = hashlib.sha256()
    for pat in pats:
        for p in sorted(glob.glob(os.path.join(ROOT, pat))):
            h.update(os.path.relpath(p, ROOT).encode("utf-8"))
            h.update(open(p, "rb").read())
    print("[%s] 174 资源总哈希 %s" % (tag, h.hexdigest()[:16]))
    print("[%s] ALL PASS" % tag)
    return candidate


def _apply_full(world):
    mid = _chain(world)
    out, st = apply(mid, 0, 0, world)
    check(st)
    E.save(out)
    print("[refine] 已全图写回 assets/ground/：草径 %d 条 / 标线 %d 组 / "
          "石板 %d 块 / 回滚 %d px"
          % (st["paths"], st["mark_groups"], st["plaza_slabs"], st["restored_px"]))
    print("[refine] 记得升 Arena.gd 的 MINIMAP_CACHE 并跑 godot --headless --path . --import")


def main():
    args = sys.argv[1:]
    world = load_world()
    if "--apply" in args:
        if "--force" not in args:
            raise SystemExit("[refine] 全图铺开会覆盖 28 张地面贴图，请显式加 --force")
        _apply_full(world)
        return
    if "--dry" in args or "--verify" in args:
        _validate(world, "--verify" in args)
        return

    box = LIB_BOX
    if "--box" in args:
        box = tuple(int(v) for v in args[args.index("--box") + 1].split(","))
    scale = 1.4
    if "--scale" in args:
        scale = float(args[args.index("--scale") + 1])

    before = D.load_ground(box)
    after, st = apply(before, box[0], box[1], world)
    check(st)
    again, _ = apply(before, box[0], box[1], world)
    if after.tobytes() != again.tobytes():
        raise SystemExit("[refine] 同输入两次结果不一致")
    twice, _ = apply(after, box[0], box[1], world)
    idem = D._nz(D._pix_changed(after, twice))
    if idem:
        raise SystemExit("[refine] apply² 不是幂等的：%d px" % idem)
    print("[refine] 小样 %s：草 %d px / 路 %d px / 水 %d px / 草径 %d 条 / "
          "标线 %d 组 / 石板 %d 块(%d px, 格栅 %d) / 回滚 %d px / apply² 差异 %d px" %
          (str(box), st["grass_px"], st["road_px"], st["water_px"], st["paths"],
           st["mark_groups"], st["plaza_slabs"], st["plaza_px"], st["grates"],
           st["restored_px"], idem))

    note = ("Entry paths + crosswalk stripes + plaza stone slabs. "
            "Grass / water untouched; road / grass / water masks unchanged.")
    _compare(before, after, OUT_LIB, scale,
             "Library area - ground refine v3 (SAMPLE ONLY, ground PNGs untouched)", note)

    jb = JUNCTION_BOX
    j_before = D.load_ground(jb)
    j_after, jst = apply(j_before, jb[0], jb[1], world)
    check(jst)
    print("[refine] 路口区 %s：草径 %d 条 / 标线 %d 组 / 回滚 %d px" %
          (str(jb), jst["paths"], jst["mark_groups"], jst["restored_px"]))
    _compare(j_before, j_after, OUT_JUNCTION, scale,
             "Junctions - ground refine v3 (SAMPLE ONLY)", note)
    _compare(_local_scene(j_before, world, jb),
             _local_scene(j_after, world, jb), OUT_SCENE, 1.0,
             "In-game view (1:1) - building sprites occlude path starts", note)

    cb = CLOSE_BOX
    b2 = D.load_ground(cb)
    a2, _ = apply(b2, cb[0], cb[1], world)
    _compare(b2, a2, OUT_CLOSE, 2.0,
             "Ground refine v3 - closeup (2x)", note)

    pb = PLAZA_BOX
    p_before = D.load_ground(pb)
    p_after, pst = apply(p_before, pb[0], pb[1], world)
    check(pst)
    twice_p, _ = apply(p_after, pb[0], pb[1], world)
    if p_after.tobytes() != twice_p.tobytes():
        raise SystemExit("[refine] 广场石板 apply² 不是幂等的")
    print("[refine] 广场 %s：石板 %d 块 / %d px / 格栅 %d / 回滚 %d px" %
          (str(pb), pst["plaza_slabs"], pst["plaza_px"], pst["grates"],
           pst["restored_px"]))
    plaza_note = ("Stone slab joints + per-slab tone + sparse drain grates on the plaza. "
                  "Only exact base-color pixels touched; masks unchanged.")
    _compare(p_before, p_after, OUT_PLAZA, 1.0,
             "Central plaza - stone paving (SAMPLE ONLY)", plaza_note)

    pcb = PLAZA_CLOSE_BOX
    pc_before = D.load_ground(pcb)
    pc_after, _ = apply(pc_before, pcb[0], pcb[1], world)
    _compare(pc_before, pc_after, OUT_PLAZA_CLOSE, 2.0,
             "Plaza slabs - closeup (2x)", plaza_note)
    _compare(_local_scene(p_before, world, pb),
             _local_scene(p_after, world, pb), OUT_PLAZA_SCENE, 1.0,
             "Plaza in-game view (1:1) - building sprites occlude the courtyard",
             plaza_note)


if __name__ == "__main__":
    main()
