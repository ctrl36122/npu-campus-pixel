"""修正「翱翔学生中心」(b11) 俯视屋顶贴图，可复现。

## 教训（2026-11-18，用户强烈不满后返工）
这张贴图是**2.5D 建筑**:上半部(y<~430)是俯视屋顶，下半部(y>=440)是面向
镜头的**楼体立面**——整齐的蓝玻璃窗网格 + 白瓷砖墙 + 门厅。
上一版把整个下半部立面连同窗户一起涂成纯色块，等于把楼"抹平"了，
这才是「像垃圾色块」的真正原因。00/01.jpg 的飞碟顶还是别的楼（体育馆），
照它画蓝色大板更是错上加错。

## 本版原则
  * 立面原样保留：y>=440 的玻璃窗/墙面/门厅像素逐字节不动（夜间窗光依赖玻璃 mask）。
  * 只重绘俯视屋顶 y<440：按用户卫星图 .tmp/sc_sat_zoom.png 的灰白矩形屋面 +
    两条白色天窗 + 网格，配色中性灰白，不再是蓝色大板/死褐色。
  * 清掉三块跑到楼外的孤立 solid（电梯井/独立门厅）——沿用上一版纠错。
  * alpha 除孤立块外逐字节不变；bbox 不变；不新增玻璃色。

## 依据
  * 卫星图 .tmp/sc_sat_zoom.png（用户提供）
  * 官方竖排招牌照片 .tmp/imgs2/student_center/02.jpg（方正 LED 屏大楼）

## 流程
  python tools/gen_student_center.py          # 写 assets/_buildings_src/b11.png
  python tools/bake_facade.py --ids 11 --apply --force
  python tools/bake_art.py                    # 重烘 glow（只保留 b11 变化）
  godot --headless --import
"""
import sys
sys.path.insert(0, 'tools')
import numpy as np
from PIL import Image, ImageDraw, ImageFont

W, H = 390, 685
src = Image.open('backup/before-sc-20261118/b11_src.png').convert('RGBA')
a0 = np.asarray(src).copy()
alpha = a0[:, :, 3].copy()

# 清掉三块与主体完全不连通的孤立 solid（跑出楼外的电梯井 / 独立门厅）
alpha[63:90, 133:190] = 0
alpha[633:660, 175:214] = 0
alpha[660:676, 170:220] = 0
solid = alpha == 255
Y, X = np.indices((H, W))

# 输出图：先整体复制原图，再只改俯视屋顶区域 —— 立面/窗户/门厅原样保留
out = a0.copy()

# 清掉的孤立块也把 RGB 归零（alpha=0 时 RGB 无所谓，保持一致）
for (y0, y1, x0, x1) in ((63, 90, 133, 190), (633, 660, 175, 214), (660, 676, 170, 220)):
    out[y0:y1, x0:x1, :3] = 0

img = Image.fromarray(out, 'RGBA')
d = ImageDraw.Draw(img)


def is_solid(x, y):
    return 0 <= x < W and 0 <= y < H and solid[y, x]


def noise_rect(x0, y0, x1, y1, base, amp, seed=11):
    for y in range(max(0, y0), min(H, y1)):
        for x in range(max(0, x0), min(W, x1)):
            if not solid[y, x]:
                continue
            n = int((np.sin(x * 12.9898 + y * 78.233 + seed) * 43758.5453) % 1.0 * 2 - 1)
            dv = n * amp
            c = tuple(max(0, min(255, v + dv)) for v in base) + (255,)
            img.putpixel((x, y), c)


# ================= 只重绘俯视屋顶 y < 440 =================
# 先把屋顶 solid 统一铺成灰白基色（中性，不会判成玻璃）
for y in range(0, 440):
    for x in range(W):
        if solid[y, x]:
            img.putpixel((x, y), (176, 178, 174, 255))

# ---- 左块（x<200）：配套裙房屋面 + 铺装庭院 ----
noise_rect(16, 40, 200, 200, (166, 163, 154), 4, 11)
noise_rect(16, 200, 200, 440, (172, 169, 160), 4, 12)
# 庭院铺装分格（细线，低对比）
for gy in range(60, 440, 18):
    d.line([(16, gy), (199, gy)], fill=(158, 154, 146, 255), width=1)
for gx in range(20, 200, 20):
    d.line([(gx, 40), (gx, 439)], fill=(162, 158, 150, 255), width=1)

# 左上浅灰网格小屋面（卫星图左上独立方块）
d.rectangle([20, 44, 92, 108], fill=(188, 188, 180, 255))
for k in range(24, 92, 12):
    d.line([(k, 44), (k, 108)], fill=(170, 170, 162, 255), width=1)
for k in range(48, 108, 12):
    d.line([(20, k), (92, k)], fill=(170, 170, 162, 255), width=1)

# 中上部「回」字裙房（卫星图深色结构）——深灰屋面+女儿墙+内天井+天窗
d.rectangle([58, 150, 152, 330], fill=(96, 96, 92, 255))
d.rectangle([64, 156, 146, 324], fill=(108, 107, 102, 255))
d.rectangle([74, 166, 136, 314], fill=(80, 80, 77, 255))
d.rectangle([80, 172, 130, 308], fill=(120, 119, 112, 255))
d.rectangle([86, 184, 92, 296], fill=(176, 178, 174, 255))
d.rectangle([118, 184, 124, 296], fill=(176, 178, 174, 255))
for ex, ey in ((68, 170), (140, 170), (68, 310), (140, 310)):
    d.rectangle([ex, ey, ex + 6, ey + 8], fill=(132, 132, 126, 255))

# 左块下部两排树/采光井（只在上半屋顶区 y<440 的那排）
for xx in range(30, 180, 26):
    yy = 430
    if is_solid(xx, yy):
        d.ellipse([xx - 5, yy - 5, xx + 5, yy + 5], fill=(100, 114, 96, 255))
        d.ellipse([xx - 2, yy - 3, xx + 2, yy + 1], fill=(128, 142, 118, 255))

# ---- 右块（x>=200）：主楼矩形屋顶 ----
# 北侧深绿阴影带
noise_rect(200, 40, 373, 100, (84, 90, 84), 4, 13)
# 两条白色屋面天窗（卫星图北侧两个白矩形）
for (ry0, ry1) in ((100, 138), (142, 178)):
    d.rectangle([222, ry0, 360, ry1], fill=(214, 216, 212, 255))
    d.line([(222, ry0), (360, ry0)], fill=(232, 234, 230, 255), width=2)
    d.line([(222, ry1), (360, ry1)], fill=(152, 154, 150, 255), width=1)
    for k in range(230, 360, 22):
        d.line([(k, ry0), (k, ry1)], fill=(202, 204, 200, 255), width=1)
# 南侧灰白网格屋面
noise_rect(200, 180, 373, 430, (206, 206, 198), 3, 14)
for gx in range(204, 372, 14):
    d.line([(gx, 180), (gx, 430)], fill=(188, 188, 180, 255), width=1)
for gy in range(184, 430, 16):
    d.line([(200, gy), (372, gy)], fill=(190, 190, 182, 255), width=1)
# 屋面设备平台
d.rectangle([250, 200, 282, 228], fill=(190, 190, 182, 255))
d.rectangle([314, 250, 340, 274], fill=(190, 190, 182, 255))
# 底边女儿墙压顶齿
for x in range(205, 370, 16):
    if is_solid(x, 428):
        d.rectangle([x, 428, x + 6, 434], fill=(178, 176, 168, 255))

# ---- 屋顶区内的名牌（画在左块实心区，避开孤立块）----
f = ImageFont.truetype('assets/fonts/noto_sc_game.ttf', 13)
d.rectangle([36, 118, 152, 140], fill=(52, 58, 64, 255))
d.text((40, 119), '翱翔学生中心', font=f, fill=(238, 242, 246, 255))

# ================= 合成：alpha 除孤立块外不变，玻璃 mask 不变 =================
out2 = np.asarray(img).copy()
out2[:, :, 3] = alpha


def isgl(r, g, b):
    r, g, b = int(r), int(g), int(b)
    return b > r + 8 and b > g + 15 and (r + g + b) / 3.0 > 120 and b > 110


g0 = np.array([[isgl(*a0[y, x, :3]) for x in range(W)] for y in range(H)]) & (a0[:, :, 3] == 255)
g1 = np.array([[isgl(*out2[y, x, :3]) for x in range(W)] for y in range(H)]) & solid
print('glass add', int((g1 & ~g0).sum()), 'lost', int((g0 & ~g1).sum()))
# alpha 只允许孤立块那几处变化
diff = np.where(alpha != a0[:, :, 3])
print('alpha diff pixels', len(diff[0]), '(expect only isolated blocks)')
ys0, xs0 = np.where(a0[:, :, 3] > 0); ys1, xs1 = np.where(out2[:, :, 3] > 0)
print('bbox same', (xs0.min(), xs0.max(), ys0.min(), ys0.max()) == (xs1.min(), xs1.max(), ys1.min(), ys1.max()))
Image.fromarray(out2, 'RGBA').save('assets/_buildings_src/b11.png')
Image.fromarray(out2, 'RGBA').save('.tmp/sc_new_src.png')

board = Image.new('RGB', (W * 2 + 30, H + 34), (232, 234, 238))
board.paste(src.convert('RGB'), (8, 26))
board.paste(Image.fromarray(out2, 'RGBA').convert('RGB'), (W + 22, 26))
board.save('.tmp/sc_new_compare.png')
print('saved')
