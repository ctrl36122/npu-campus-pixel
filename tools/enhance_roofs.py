"""屋面构件补细节：把「没画完的纯色大板」补成有结构的真实屋面。

为什么做这个:
    俯视 2.5D 下屋顶占建筑贴图一半以上、也占屏幕面积最大。海天苑大楼群
    （回字形综合体）北楼/东西楼屋顶中央各有一块完美矩形的纯色浅灰板
    （实测 b53 是 454x78、b54/55 是 92x278，矩形覆盖率 1.00），中楼是
    一整块纯绿。实机里前者像「没铺装的水泥地」、后者像「一块绿板」，
    是整个片区最假的地方。

做法（分三类，各自参数化，不写死坐标）:
    1. 采光天窗 —— 识别近 (188,194,200) 的大矩形，补铝合金外框 + 玻璃格架
       + 格内高光，读作大面积采光顶。
    2. 屋顶绿化 —— 识别大块绿色屋面，补草簇明暗 + 周边深色种植带 + 灌木投影。
    3. 女儿墙阴影 —— 沿屋顶轮廓内圈渐进变暗，补出女儿墙的立体感。

红线:
    * 只改 RGB；alpha 逐像素不变。
    * 玻璃像素集合（`bake_art.is_window_pane`，夜间窗光按它预烘）新增/丢失必须为 0。
    * 幂等：每次都从 `backup/before-roof-20261117/` 的原图重算，不会叠加。

用法:
    python tools/enhance_roofs.py --dry      # 只报告，不写
    python tools/enhance_roofs.py            # 写源图（之后自行跑 bake_facade.apply）
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from bake_art import is_window_pane  # noqa: E402  权威判定，绝不另写阈值

SRC = os.path.join(ROOT, "assets", "_buildings_src")
OUT = os.path.join(ROOT, "assets", "buildings")
BAK = os.path.join(os.path.dirname(ROOT), "backup", "before-roof-20261117")
RECTS = os.path.join(BAK, "skylight_rects.json")

TARGETS = [53, 54, 55, 56, 57]   # 海天苑大楼群：纯色大板 → 采光天窗 / 内院绿化
# 11/25/32/43 这类「深蓝灰 + 40px 网格」的大屋顶试过压顶 + 板块明暗：板块会切出
# 硬边田字格，实机像屋顶裂成几块，比原样更差，所以不做。它们本来就够规整。
ARCH = []                        # 翱翔游泳馆试过「柔化密横条纹 + 弧面受光 + 顶部采光带」：
                                 # 采光带像白色相框；柔化后中部糊成一块亮矩形，比原图的
                                 # 清晰等距条纹更差。保留原样。

ARCH_BAND = (204, 219, 229)      # 采光带玻璃
ARCH_BAND_LINE = (108, 122, 136)  # 采光带分格
ARCH_BAND_IN = 20                # 采光带起始深度（距轮廓层数）
ARCH_BAND_W = 13                 # 采光带宽度（层数）

PALE_RGB = (188, 194, 200)      # 纯色大板的底色
PALE_TOL = 14
PALE_MIN_AREA = 3000
PALE_MIN_FILL = 0.88            # bbox 内覆盖率下限，防止把散点当大板

SKY_BASE = (200, 212, 220)      # 天窗玻璃底（偏青，反射天空）
SKY_CELL = 46                   # 格架间距
SKY_MULLION = (96, 103, 110)    # 铝框/格架
SKY_FRAME = (84, 90, 96)        # 外框
SKY_FRAME_HI = (218, 226, 232)  # 受光边
SKY_GLINT = (224, 234, 240)     # 格内高光

GREEN_MIN_AREA = 5000
GREEN_EDGE = 9                  # 周边种植带宽度
GREEN_DEEP = (74, 112, 70)      # 种植带
GREEN_BUSH = (64, 102, 58)      # 灌木主体
GREEN_BUSH_HI = (84, 126, 74)   # 灌木左上受光
GREEN_SHADOW = (44, 80, 42)     # 灌木投影

WALL_K = 0.90                   # 女儿墙正下方最暗
WALL_RING = 5                   # 明显变暗的圈数


def glass_mask(a):
    r, g, b = a[:, :, 0].astype(int), a[:, :, 1].astype(int), a[:, :, 2].astype(int)
    solid = a[:, :, 3] == 255
    m = np.zeros(solid.shape, bool)
    if not solid.any():
        return m
    rs, gs, bs = r[solid], g[solid], b[solid]
    v = np.array([is_window_pane(int(x), int(y), int(z)) for x, y, z in zip(rs, gs, bs)])
    m[solid] = v
    return m


def erode(m, it=1):
    im = Image.fromarray((m * 255).astype(np.uint8), "L")
    for _ in range(it):
        im = im.filter(ImageFilter.MinFilter(3))
    return np.asarray(im) > 127


def dilate(m, it=1):
    im = Image.fromarray((m * 255).astype(np.uint8), "L")
    for _ in range(it):
        im = im.filter(ImageFilter.MaxFilter(3))
    return np.asarray(im) > 127


def dist_layers(m, n):
    """rings[i] = 距边界第 i+1 层"""
    rings, cur = [], m.copy()
    for _ in range(n):
        nxt = erode(cur)
        rings.append(cur & ~nxt)
        cur = nxt
        if not cur.any():
            break
    return rings


def hashf(x, y, s=0):
    h = (int(x) * 73856093) ^ (int(y) * 19349663) ^ (int(s) * 83492791)
    return ((h & 0x7FFFFFFF) % 10000) / 10000.0


def roof_region(a, gtop):
    H, W = a.shape[:2]
    Y = np.indices((H, W))[0]
    return (a[:, :, 3] == 255) & (Y < gtop) & (Y > 2)


def find_pale_slabs(a, roof):
    r, g, b = a[:, :, 0].astype(int), a[:, :, 1].astype(int), a[:, :, 2].astype(int)
    m = (np.abs(r - PALE_RGB[0]) < PALE_TOL) & (np.abs(g - PALE_RGB[1]) < PALE_TOL) \
        & (np.abs(b - PALE_RGB[2]) < PALE_TOL) & roof
    if m.sum() < PALE_MIN_AREA:
        return []
    # 只保留主体块：腐蚀后剩下的最大连通区域用 bbox 近似（这些板实测都是矩形）
    core = erode(m, 2)
    if not core.any():
        return []
    ys, xs = np.where(core)
    x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()
    box = m[y0:y1 + 1, x0:x1 + 1]
    if box.sum() / box.size < PALE_MIN_FILL:
        return []
    return [(x0, y0, x1, y1)]


def draw_skylight(a, rect, mask=None):
    """在浅灰大板上画采光顶：铝框 + 格架 + 格内高光。

    mask=None 时只认原底色 PALE_RGB（改源图阶段）；传入布尔掩膜时按掩膜画
    （烘焙后阶段用，此时底色已被换成 SKY_BASE，且缝里可能被塞了空调外机）。
    """
    x0, y0, x1, y1 = rect
    H, W = a.shape[:2]
    x1 = min(x1, W - 1)
    y1 = min(y1, H - 1)
    sub = a[y0:y1 + 1, x0:x1 + 1]
    if mask is None:
        r, g, b = sub[:, :, 0].astype(int), sub[:, :, 1].astype(int), sub[:, :, 2].astype(int)
        mask = (np.abs(r - PALE_RGB[0]) < PALE_TOL) & (np.abs(g - PALE_RGB[1]) < PALE_TOL) \
            & (np.abs(b - PALE_RGB[2]) < PALE_TOL) & (sub[:, :, 3] == 255)
    else:
        mask = mask & (sub[:, :, 3] == 255)
    if mask.sum() < 500:
        return 0
    inner = erode(mask, 2)
    ring = mask & ~inner           # 外框环

    # 玻璃底
    sub[mask, 0] = SKY_BASE[0]
    sub[mask, 1] = SKY_BASE[1]
    sub[mask, 2] = SKY_BASE[2]

    # 格架：横竖 mullion，间距自适应保证至少 2 格
    hh, ww = sub.shape[:2]
    stepx = max(28, min(SKY_CELL, ww // 3))
    stepy = max(24, min(SKY_CELL, hh // 2))
    Ys, Xs = np.indices((hh, ww))
    mx = (Xs % stepx) < 2
    my = (Ys % stepy) < 2
    mull = inner & (mx | my)
    sub[mull, 0] = SKY_MULLION[0]
    sub[mull, 1] = SKY_MULLION[1]
    sub[mull, 2] = SKY_MULLION[2]

    # 格内高光：每格左上一小段亮线，制造玻璃反光
    glint = inner & (((Xs % stepx) == 3) | ((Ys % stepy) == 3))
    sub[glint, 0] = SKY_GLINT[0]
    sub[glint, 1] = SKY_GLINT[1]
    sub[glint, 2] = SKY_GLINT[2]

    # 格内亮度差（玻璃反射不均）
    cells = inner & ~mull & ~glint
    for cy in range(0, hh, stepy):
        for cx in range(0, ww, stepx):
            blk = cells[cy:cy + stepy, cx:cx + stepx]
            if not blk.any():
                continue
            d = (hashf(cx, cy, 11) - 0.5) * 9
            part = sub[cy:cy + stepy, cx:cx + stepx, :3]
            part[blk] += d

    # 铝框
    sub[ring, 0] = SKY_FRAME[0]
    sub[ring, 1] = SKY_FRAME[1]
    sub[ring, 2] = SKY_FRAME[2]
    # 受光边：框的内侧上/右各 1px 亮
    hi = ring & (((Ys % max(1, hh - 1)) == 0) | ((Xs % max(1, ww - 1)) == 0)) & mask
    sub[hi, 0] = SKY_FRAME_HI[0]
    sub[hi, 1] = SKY_FRAME_HI[1]
    sub[hi, 2] = SKY_FRAME_HI[2]
    return int(mask.sum())


def draw_green_roof(a, roof):
    """屋顶绿化：草簇明暗 + 周边种植带。"""
    r, g, b = a[:, :, 0].astype(int), a[:, :, 1].astype(int), a[:, :, 2].astype(int)
    m = (g > r + 30) & (g > b + 30) & roof
    if m.sum() < GREEN_MIN_AREA:
        return 0
    H, W = a.shape[:2]
    Ys, Xs = np.indices((H, W))
    inner = erode(m, GREEN_EDGE)
    edge = m & ~inner

    # 种植带
    a[edge, 0] = GREEN_DEEP[0]
    a[edge, 1] = GREEN_DEEP[1]
    a[edge, 2] = GREEN_DEEP[2]

    # 草簇：4x4 小簇伪随机明暗
    for cy in range(0, H, 4):
        for cx in range(0, W, 4):
            blk = inner[cy:cy + 4, cx:cx + 4]
            if not blk.any():
                continue
            d = (hashf(cx // 4, cy // 4, 23) - 0.5) * 10
            part = a[cy:cy + 4, cx:cx + 4, :3]
            part[blk] += d

    # 点景树/灌木：试过两版（小球、大冠）都像「绿气球/绿罐子」——在这个尺寸下
    # 手写程序化树冠撑不住细节，加了反而比纯草更假。所以不画，只留纹理和种植带。
    return int(m.sum())


def draw_arch_roof(a_in, a, roof, idx):
    """拱顶（游泳馆）：减弱原有的密横条纹 → 弧面受光 → 沿轮廓一圈采光带。

    实景是银灰金属穹顶，顶部沿弧面有一圈天窗采光带。原贴图是等间距密横条纹，
    实机看像瓦楞纸/百叶，压住了整体的「穹顶」观感。
    """
    H, W = a.shape[:2]
    # 1) 横条纹向局部均值收敛 32%，保留大尺度明暗
    base = Image.fromarray(a_in.astype(np.uint8), "RGBA").convert("RGB")
    soft = np.asarray(base.filter(ImageFilter.GaussianBlur(3.2))).astype(np.float32)
    idxm = roof
    for c in range(3):
        a[:, :, c] = np.where(idxm, a[:, :, c] * 0.68 + soft[:, :, c] * 0.32, a[:, :, c])

    # 2) 弧面受光：中间亮、两侧暗（俯视穹顶的受光）
    xs = np.where(roof.any(axis=0))[0]
    if len(xs) < 10:
        return 0
    cx = (xs.min() + xs.max()) / 2.0
    half = max(1.0, (xs.max() - xs.min()) / 2.0)
    X = np.indices((H, W))[1]
    dn = np.abs(X - cx) / half
    lamp = (1.05 - 0.16 * dn ** 2).astype(np.float32)
    for c in range(3):
        a[:, :, c] = np.where(roof, a[:, :, c] * lamp, a[:, :, c])

    # 3) 采光带：试过「沿轮廓一圈」的画法 —— 13px 宽的一圈浅色在实机里像给屋顶
    #    套了个白色相框，比原来的密条纹更糟。实景的天窗是跟着屋面分板走的，
    #    程序化画不准，索性不画，靠弧面受光表达穹顶。
    return 0


def wall_shadow(a, roof):
    """女儿墙：外 3 层是受光压顶（加法提亮，不改色相），往里是墙投在屋面的影。"""
    rings = dist_layers(roof, WALL_RING + 10)
    CAP = 16.0
    for rg in rings[:3]:
        for c in range(3):
            a[rg, c] = np.minimum(255.0, a[rg, c] + CAP)
    for i, rg in enumerate(rings[3:WALL_RING + 4]):
        k = 1.0 - (1.0 - WALL_K) * (1.0 - i / (WALL_RING + 2))
        a[rg, 0] *= k
        a[rg, 1] *= k
        a[rg, 2] *= k
    for i, rg in enumerate(rings[WALL_RING + 4:WALL_RING + 10]):
        k = 1.0 - (1.0 - WALL_K) * 0.5 * (1.0 - (i + 1) / 7.0)
        a[rg, 0] *= k
        a[rg, 1] *= k
        a[rg, 2] *= k


PATTERN_STEP = 124       # 屋面板块尺寸：必须远大于贴图自带的 40px 网格，否则互相打架
PATTERN_AMP = 0.0        # 实测硬边板块在实机像「屋顶裂成几块」，关掉；压顶/阴影已够


def roof_pattern(a, roof, idx):
    """大尺度屋面板块明暗：把「一块均匀毯子」打散成几块拼接的屋面。

    刻意只用 84px 的大块、幅度很小 —— 小幅高频噪声会把屋顶弄脏（地图降噪
    那轮已经吃过这个教训）。
    """
    H, W = a.shape[:2]
    inner = roof.copy()
    for rg in dist_layers(roof, 14):
        inner &= ~rg
    if inner.sum() < 2000:
        return 0
    for cy in range(0, H, PATTERN_STEP):
        for cx in range(0, W, PATTERN_STEP):
            y2, x2 = min(cy + PATTERN_STEP, H), min(cx + PATTERN_STEP, W)
            m = inner[cy:y2, cx:x2]
            if not m.any():
                continue
            d = (hashf(cx // PATTERN_STEP, cy // PATTERN_STEP, idx + 71) - 0.5) * PATTERN_AMP
            part = a[cy:y2, cx:x2, :3]
            part[m] += d
    return int(inner.sum())


def pane_top(a):
    """屋顶底边 = 立面上第一个"窗"的行号。

    先按权威玻璃判定找；海天苑大楼群那种深蓝横条窗太暗（L<120）不满足玻璃条件，
    但它满足「明显偏蓝」——用 b>r+30 & b>g+15 兜底，避免把整栋楼都当屋顶。
    """
    g = glass_mask(a)
    ys = np.where(g.any(axis=1))[0]
    if len(ys):
        return int(ys.min())
    r, b_, b = a[:, :, 0].astype(int), a[:, :, 1].astype(int), a[:, :, 2].astype(int)
    deep = (b > r + 30) & (b > b_ + 15) & (a[:, :, 3] == 255)
    ys = np.where(deep.any(axis=1))[0]
    return int(ys.min()) if len(ys) else a.shape[0]


def enhance(a_in, idx):
    a = a_in.astype(np.float32)
    a[:, :, 3] = a_in[:, :, 3]
    g0 = glass_mask(a_in)
    gtop = pane_top(a_in)
    roof = roof_region(a_in, gtop)
    if roof.sum() < 800:
        return a_in, None

    solid_before = a_in[:, :, 3] == 255
    stat = {"roof": int(roof.sum()), "gtop": gtop, "sky": 0, "green": 0, "rects": []}

    for rect in find_pale_slabs(a_in, roof):
        stat["sky"] += draw_skylight(a, rect)
        stat["rects"].append([int(v) for v in rect])
    stat["green"] = draw_green_roof(a, roof)
    if idx in ARCH:
        stat["arch"] = draw_arch_roof(a_in, a, roof, idx)
    # 绿化区已有自己的草簇起伏，别再叠大板块差
    r_, g_, b_ = a[:, :, 0].astype(int), a[:, :, 1].astype(int), a[:, :, 2].astype(int)
    green_now = (g_ > r_ + 30) & (g_ > b_ + 30) & (a[:, :, 3] == 255)
    stat["pattern"] = roof_pattern(a, roof & ~green_now, idx)
    wall_shadow(a, roof)

    out = np.clip(a, 0, 255).astype(np.uint8)
    out[:, :, 3] = a_in[:, :, 3]
    g1 = glass_mask(out)
    # 压顶提亮可能把个别「b-g 正好卡在阈值附近」的像素推进玻璃集合 ——
    # 夜间窗光是按玻璃位置预烘的，多一个像素就错一个亮点，所以一律回退。
    fix = g1 & ~g0
    if fix.any():
        out[fix] = a_in[fix]
        g1 = glass_mask(out)
    stat["glass_fix"] = int(fix.sum())
    stat["glass_add"] = int((g1 & ~g0).sum())
    stat["glass_lost"] = int((g0 & ~g1).sum())
    stat["alpha_same"] = bool(np.array_equal(out[:, :, 3], a_in[:, :, 3]))
    stat["solid_same"] = bool(np.array_equal(out[:, :, 3] == 255, solid_before))
    return out, stat


def post_skylight():
    """烘焙后阶段：盖掉 bake_facade 撒在玻璃天窗上的空调外机。

    bake_facade 会给「平坦区」补外机，而采光顶的玻璃底正是一片纯色平坦区，
    于是外机会被摆在玻璃上（真实建筑不会这么干）。这里按 --src 阶段记下的
    rect 重画一遍天窗，把外机覆盖掉。必须在 apply 之后跑。
    """
    import json
    if not os.path.exists(RECTS):
        print("没有 skylight_rects.json，先跑 --src")
        return
    rects = json.load(open(RECTS, encoding="utf-8"))
    for idx_s, rs in rects.items():
        if not rs:
            continue
        idx = int(idx_s)
        p = os.path.join(OUT, f"b{idx}.png")
        if not os.path.exists(p):
            print(f"b{idx} 缺成品，跳过")
            continue
        im = Image.open(p).convert("RGBA")
        a0 = np.asarray(im)
        a = a0.astype(np.float32)
        a[:, :, 3] = a0[:, :, 3]
        g0 = glass_mask(a0)
        painted = 0
        for rect in rs:
            x0, y0, x1, y1 = rect
            x1, y1 = min(x1, a.shape[1] - 1), min(y1, a.shape[0] - 1)
            sub = a[y0:y1 + 1, x0:x1 + 1]
            al = sub[:, :, 3] == 255
            r, g, b = sub[:, :, 0].astype(int), sub[:, :, 1].astype(int), sub[:, :, 2].astype(int)
            near = (np.abs(r - SKY_BASE[0]) < 46) & (np.abs(g - SKY_BASE[1]) < 46) \
                & (np.abs(b - SKY_BASE[2]) < 46)
            if al.any() and near[al].mean() < 0.45:
                print(f"b{idx} rect {rect} 不像采光顶，跳过")
                continue
            painted += draw_skylight(a, rect, mask=al)
        out = np.clip(a, 0, 255).astype(np.uint8)
        out[:, :, 3] = a0[:, :, 3]
        g1 = glass_mask(out)
        add, lost = int((g1 & ~g0).sum()), int((g0 & ~g1).sum())
        ok = add == 0 and lost == 0 and np.array_equal(out[:, :, 3], a0[:, :, 3])
        print(f"b{idx:2d} post 重画={painted:5d} 玻璃+{add}/-{lost} "
              f"{'OK' if ok else '!! 违反红线'}")
        if ok:
            Image.fromarray(out, "RGBA").save(p, optimize=True)


def main():
    if "--post" in sys.argv:
        post_skylight()
        return
    dry = "--dry" in sys.argv
    os.makedirs(BAK, exist_ok=True)
    bad = 0
    rects = {}
    for idx in TARGETS + ARCH:
        src_p = os.path.join(SRC, f"b{idx}.png")
        bak_p = os.path.join(BAK, f"b{idx}.png")
        if not os.path.exists(src_p):
            print(f"b{idx} 缺源图，跳过")
            continue
        if not os.path.exists(bak_p):
            Image.open(src_p).save(bak_p)
        base = np.asarray(Image.open(bak_p).convert("RGBA"))
        out, st = enhance(base, idx)
        if st is None:
            print(f"b{idx} 无有效屋顶，跳过")
            continue
        rects[str(idx)] = st["rects"]
        ok = st["glass_add"] == 0 and st["glass_lost"] == 0 and st["alpha_same"] and st["solid_same"]
        bad += 0 if ok else 1
        print(f"b{idx:2d} roof={st['roof']:6d} gtop={st['gtop']:3d} "
              f"天窗={st['sky']:5d} 绿化={st['green']:5d} "
              f"玻璃+{st['glass_add']}/-{st['glass_lost']} alpha{'✓' if st['alpha_same'] else '✗'} "
              f"{'OK' if ok else '!! 违反红线'}")
        if not dry and ok:
            Image.fromarray(out, "RGBA").save(src_p, optimize=True)
    if dry:
        print("\n[dry] 未写文件")
        return
    import json
    json.dump(rects, open(RECTS, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"\n天窗 rect 已记入 {RECTS}；烘焙后记得跑 --post")
    if bad:
        print(f"⚠ {bad} 栋违反红线，未写")
        sys.exit(1)


if __name__ == "__main__":
    main()
