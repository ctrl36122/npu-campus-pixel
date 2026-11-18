"""按卫星俯视图重画「翱翔学生中心」(b11) 贴图，可复现。

照片/卫星依据：用户提供的卫星俯视图 + .tmp/imgs2/student_center/00.jpg、01.jpg。
平面：左块狭长深褐屋顶（带回字内凹中庭）、右块白色矩形顶 + 蓝灰竖分格玻璃斜顶、
      中间浅色网格连接体、前方是广场（不画台阶）。

关键：源图里有三块与主体**完全不连通**的孤立 solid —— 左上电梯井(x135..187,y65..87)、
底部门厅石柱(x177..211,y635..658)和台阶(x172..217,y662..673)。这正是「电梯井跑到楼外、
门独立出来」的根源。脚本直接把它们从 alpha 清成透明（都不是 bbox 边界像素）。

流程:
    python tools/gen_student_center.py          # 写 assets/_buildings_src/b11.png
    # 再走标准链：bake_facade.apply(src,11,bld) -> assets/buildings/b11.png
    # 因为玻璃位置全变，必须重烘窗光：python tools/bake_art.py
    # （全量会重写其它楼的 glow，注意只保留 b11 的变化，其余恢复）
    最后 Godot --headless --import 刷新资源。
"""
"""翱翔学生中心 b11 按卫星俯视图重画（只改 RGB，alpha/半透明/bbox 不变）。

依据用户提供的卫星图（.tmp/sc_sat_zoom.png）：
  左块（狭长）—— 深褐色大屋顶，中上部一个「回」字深色内凹中庭（中间浅、四周深），
                  下端两排小圆采光点。
  右块（较宽）—— 北侧一大块白色矩形屋顶；其下是浅米色带竖向细分的斜屋顶（飞碟顶
                  俯视的样子），底边一排小突起；屋顶最上有一条深色带。
  中间下部    —— 浅色网格连接体。
  前方        —— 台阶门厅（连着主体，不再独立）。

同时修掉原贴图两处游离结构：左上独立电梯井、底部独立石柱门厅。
夜间窗光在落地后单独重烘 glow_winb_11.png。
"""
import sys
sys.path.insert(0, 'tools')
import numpy as np
from PIL import Image, ImageDraw

W, H = 390, 685
src = Image.open('backup/before-sc-20261118/b11_src.png').convert('RGBA')
a0 = np.asarray(src)
alpha = a0[:, :, 3].copy()

# 清掉三块与主体完全不连通的孤立 solid（正是用户说的「电梯井跑到楼外」「门独立出来」）：
#   x135..187,y65..87  = 左上独立电梯井小方块
#   x177..211,y635..658 / x172..217,y662..673 = 底部独立门厅石柱+台阶
# 这些块都在贴图内部，清掉不影响不透明 bbox（bbox 边界由其它像素撑着）。
alpha[63:90, 133:190] = 0
alpha[633:660, 175:214] = 0
alpha[660:676, 170:220] = 0

solid = alpha == 255
Y, X = np.indices((H, W))

def isgl(r, g, b):
    r, g, b = int(r), int(g), int(b)
    L = (r + g + b) / 3.0
    return b > r + 8 and b > g + 15 and L > 120 and b > 110

g0 = np.array([[isgl(*a0[y, x, :3]) for x in range(W)] for y in range(H)]) & solid

img = Image.new('RGBA', (W, H), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

def fill(mask, color):
    for y in range(H):
        xs = np.where(mask[y])[0]
        for x in xs:
            img.putpixel((int(x), int(y)), color)

# 左右块的划分：以 x=200 为界（从贴图行范围看，右块在 x200..372）
left = solid & (X < 200)
right = solid & (X >= 200)

# ---------- 左块：深褐色屋顶 ----------
fill(left, (150, 140, 122, 255))
# 深褐色调加轻微明暗（大块，不做高频噪声）
for y in range(40, 620):
    for x in range(16, 200):
        if x < W and solid[y, x] and X[y, x] < 200:
            v = int(150 - (y - 40) / 600.0 * 16)
            img.putpixel((x, y), (v, v - 10, v - 28, 255))

# 「回」字形内凹中庭（卫星图左块中上部）：外深内浅的矩形环
# 位置约 x60..150, y150..330
d.rectangle([58, 150, 152, 330], fill=(70, 66, 58, 255))
d.rectangle([72, 166, 138, 314], fill=(168, 160, 142, 255))
d.rectangle([86, 182, 124, 298], fill=(150, 144, 128, 255))
# 中庭中间的深色长条（天窗缝）
d.rectangle([92, 190, 118, 290], fill=(64, 60, 54, 255))

# 左块下端两排小圆采光点（卫星图可见）
for yy in (430, 470):
    for xx in range(30, 180, 26):
        if solid[yy, xx]:
            d.ellipse([xx - 4, yy - 4, xx + 4, yy + 4], fill=(120, 130, 122, 255))

# 左块最顶的浅色网格小方块（卫星图左上角）
d.rectangle([20, 44, 92, 108], fill=(196, 196, 182, 255))
for k in range(24, 92, 12):
    d.line([k, 44, k, 108], fill=(168, 168, 156, 255), width=1)
for k in range(48, 108, 12):
    d.line([20, k, 92, k], fill=(168, 168, 156, 255), width=1)

# ---------- 右块：白色矩形顶 + 浅米色竖分格斜顶 ----------
# 顶部一条深色带（卫星图上缘的深色阴影）
for y in range(40, 200):
    for x in range(200, 373):
        if x < W and solid[y, x]:
            img.putpixel((x, y), (72, 80, 86, 255))
# 北侧白色大矩形屋顶
d.rectangle([222, 100, 360, 176], fill=(228, 230, 226, 255))
d.rectangle([222, 100, 360, 103], fill=(248, 248, 246, 255))
# 白色屋顶下的横向分界
d.line([222, 176, 360, 176], fill=(120, 126, 130, 255), width=2)

# 浅米色斜屋顶（飞碟顶俯视），带竖向细分 + 两侧收边
for y in range(178, 430):
    for x in range(200, 373):
        if x >= W or not solid[y, x]:
            continue
        # 中间亮两侧暗的曲面感
        dn = abs(x - 286) / 86.0
        base = int(218 - dn * 22 - (y - 178) / 252.0 * 10)
        img.putpixel((x, y), (base - 24, base + 1, base + 20, 255))
# 竖向分格线（飞碟顶的径向肋），每 20px 一条
for x in range(206, 370, 20):
    for y in range(180, 428):
        if y < H and x < W and solid[y, x]:
            r, g, b, _ = img.getpixel((x, y))
            img.putpixel((x, y), (r - 24, g - 24, b - 24, 255))
# 底边一排小突起（卫星图可见的齿状结构）
for x in range(205, 370, 16):
    if x + 6 < W and solid[428, x]:
        d.rectangle([x, 428, x + 6, 438], fill=(150, 142, 128, 255))

# ---------- 中间下部：浅色网格连接体 ----------
d.rectangle([150, 430, 250, 510], fill=(214, 214, 206, 255))
for x in range(152, 250, 12):
    d.line([x, 430, x, 510], fill=(176, 176, 168, 255), width=1)
for y in range(432, 510, 12):
    d.line([150, y, 250, y], fill=(176, 176, 168, 255), width=1)

# ---------- 底部：不画台阶（卫星图前方是广场），把所有 solid 铺成建筑基座色 ----------
# 原独立门厅的 solid 也一并变成主体基座，不再有孤立的门
for yy in range(560, 685):
    for xx in range(W):
        if solid[yy, xx]:
            img.putpixel((xx, yy), (196, 192, 180, 255))
# 基座檐口线
for yy in (586, 610):
    for xx in range(W):
        if solid[yy, xx]:
            img.putpixel((xx, yy), (158, 154, 146, 255))

# ---------- 右块下半（y430..560）solid 全部铺成基座/屋顶色，盖掉原图残留的深色阴影 ----------
for yy in range(430, 565):
    for xx in range(195, 375):
        if xx < W and solid[yy, xx]:
            img.putpixel((xx, yy), (206, 202, 190, 255))

# ---------- 名牌：画在左块褐色屋顶的实心区（不能落在清掉的孤立块上） ----------
from PIL import ImageFont
f = ImageFont.truetype('assets/fonts/noto_sc_game.ttf', 13)
d.rectangle([36, 118, 152, 140], fill=(52, 58, 64, 255))
d.text((40, 119), '翱翔学生中心', font=f, fill=(238, 242, 246, 255))

# ---------- 合成：alpha/半透明/bbox 不变 ----------
out = np.asarray(img).copy()
out[:, :, 3] = alpha
g1 = np.array([[isgl(*out[y, x, :3]) for x in range(W)] for y in range(H)]) & solid
print('glass add', int((g1 & ~g0).sum()), 'lost', int((g0 & ~g1).sum()))
print('alpha same', np.array_equal(out[:, :, 3], a0[:, :, 3]))
ys0, xs0 = np.where(a0[:, :, 3] > 0); ys1, xs1 = np.where(out[:, :, 3] > 0)
print('bbox same', (xs0.min(), xs0.max(), ys0.min(), ys0.max()) == (xs1.min(), xs1.max(), ys1.min(), ys1.max()))
Image.fromarray(out, 'RGBA').save('.tmp/sc_satcand6.png')

board = Image.new('RGB', (W * 2 + 30, H + 34), (232, 234, 238))
board.paste(src.convert('RGB'), (8, 26))
board.paste(Image.fromarray(out, 'RGBA').convert('RGB'), (W + 22, 26))
board.save('.tmp/sc_satcompare6.png')
print('saved')
