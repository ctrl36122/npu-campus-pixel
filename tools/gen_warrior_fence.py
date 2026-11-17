"""生成「为国铸剑」勇士贴图（b52）：俯首横托宝剑、半身埋土 + 一圈立面石砌方形围栏。

真实：勇士是华山花岗岩雕成、半身埋在土中、俯首横托宝剑（"隐姓埋名、为国铸剑"），
      立于西侧草地上；何尊是另一座独立的青铜方尊，立在东侧水池里（见 gen_hezun_group.py）。

⚠️ 关键：建筑贴图的 y 轴是「垂直高度」，不是俯视纵深。所以围栏画成四面矮墙
   （前墙最显眼、后墙在雕塑背后、左右侧墙在两侧），不是俯视梯形框。
   地面线在贴图内约 y=325，内容不要超过它。
名牌「为国铸剑」手绘在前墙正面（facade 的自动落牌需要更大实心区，这里手绘更可控）。

产出：assets/_buildings_src/b52.png
再烘焙：bake_facade.apply(src, 52, bld) → assets/buildings/b52.png
"""
"""b52 v5 = 勇士 + 一圈【立面】石砌矮墙围栏。
⚠️ 关键认知：建筑贴图的 y 轴是「垂直高度」，不是俯视纵深。
   所以围栏画成四面矮墙（前墙最显眼、后墙在雕塑背后、左右墙在两侧），
   内部留空让地图草地透出来。地面线在贴图内约 y=325。
"""
from PIL import Image, ImageDraw
import numpy as np

H, W = 349, 224
img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

GRAN_DARK=(70,76,84); GRAN=(104,110,120); GRAN_LITE=(138,145,155)
BLADE=(232,238,244); BLADE_SH=(168,178,190)
GOLD=(198,162,72); BRONZE_D=(86,96,62)
GRASS=(74,124,66); GRASS_L=(100,152,82); GRASS_D=(52,94,50); SOIL=(112,92,54)
STONE=(182,186,192); STONE_D=(88,92,100); STONE_L=(216,220,224); STONE_M=(140,144,150)

def wall(x0, x1, ytop, ybot, seam_step=18):
    """一面矮石墙：正面 + 顶部压顶 + 高光 + 石缝。"""
    d.rectangle([x0, ytop, x1, ybot], fill=STONE_D)          # 描边/阴影底
    d.rectangle([x0+1, ytop+1, x1-1, ybot-1], fill=STONE)    # 正面
    d.rectangle([x0+1, ytop+1, x1-1, ytop+4], fill=STONE_L)  # 压顶高光
    d.line([x0+1, ytop+4, x1-1, ytop+4], fill=STONE_M)       # 压顶分界
    for sx in range(x0+6, x1-2, seam_step):                  # 石块竖缝
        d.line([sx, ytop+5, sx, ybot-1], fill=STONE_M)

def pillar(cx, cy, w=9, h=14):
    d.rectangle([cx-w//2, cy-h, cx+w//2, cy], fill=STONE_D)
    d.rectangle([cx-w//2+1, cy-h+1, cx+w//2-1, cy-1], fill=STONE_L)
    d.line([cx-w//2+1, cy-h//2, cx+w//2-1, cy-h//2], fill=STONE_M)

# 地面线 ~325。围栏整体落在 y 270..325
# ---- 后墙（远，被雕塑挡大半）----
wall(72, 146, 268, 280, 22)
# ---- 左右侧墙（正面看是两条竖直矮墙）----
wall(58, 70, 276, 324, 30)
wall(150, 162, 276, 324, 30)
# ---- 前墙（近，最显眼；正面留给名牌）----
wall(58, 162, 300, 326, 16)

# ---- 四角石柱 ----
pillar(64, 276, 10, 16)    # 后左
pillar(154, 276, 10, 16)   # 后右
pillar(64, 326, 11, 18)    # 前左
pillar(156, 326, 11, 18)   # 前右

# ===== 勇士（围栏中央，脚踩 y≈300，前墙挡住脚下部）=====
d.ellipse([86, 290, 130, 302], fill=GRASS_D)
d.ellipse([92, 288, 124, 297], fill=GRASS)
d.ellipse([98, 287, 118, 293], fill=GRASS_L)
for gx,gy in ((94,288),(104,285),(114,285)):
    d.line([gx,gy,gx-1,gy-3], fill=GRASS_L)
d.rectangle([96, 294, 120, 300], fill=SOIL)
d.polygon([(98,244),(116,244),(124,298),(88,298)], fill=GRAN_DARK)
d.polygon([(101,246),(113,246),(119,294),(93,294)], fill=GRAN)
d.ellipse([96,226,122,252], fill=GRAN)          # 背肩
d.ellipse([88,236,108,254], fill=GRAN_LITE)     # 头
d.polygon([(86,244),(95,242),(93,254),(84,254)], fill=GRAN)
d.rectangle([98,232,108,238], fill=GRAN_DARK)
d.line([86,252,95,254], fill=GRAN_DARK)
d.polygon([(92,256),(126,252),(128,262),(90,266)], fill=GRAN_LITE)
d.rectangle([94,260,122,268], fill=GRAN)
d.rectangle([76,256,138,261], fill=BLADE)       # 剑身（不伸出围栏）
d.rectangle([76,259,138,259], fill=BLADE_SH)
d.rectangle([72,253,78,264], fill=GOLD)
d.rectangle([66,256,72,261], fill=BRONZE_D)
d.polygon([(138,256),(145,258),(138,261)], fill=BLADE)
d.rectangle([90,252,96,259], fill=GRAN_LITE)
d.rectangle([118,252,124,260], fill=GRAN_DARK)

ImageDraw.Draw(img).ellipse([60,310,160,326], fill=(120,124,130,56))

# ===== 名牌「为国铸剑」手绘在前墙正面 =====
from PIL import ImageFont
f=ImageFont.truetype("assets/fonts/noto_sc_game.ttf", 12)
txt="为国铸剑"
bx0,bx1,by0,by1=68,152,306,323
d.rectangle([bx0,by0,bx1,by1], fill=(48,56,66))
d.rectangle([bx0,by0,bx1,by0], fill=(198,204,210))
d.rectangle([bx0,by1-1,bx1,by1], fill=(30,36,44))
bb=d.textbbox((0,0),txt,font=f); tw,th=bb[2]-bb[0],bb[3]-bb[1]
d.text((bx0+(bx1-bx0-tw)//2, by0+(by1-by0-th)//2-bb[1]), txt, font=f, fill=(238,242,246))

arr=np.asarray(img)
ys,xs=np.where(arr[:,:,3]==255)
print("bbox255 x%d..%d y%d..%d"%(xs.min(),xs.max(),ys.min(),ys.max()))
Image.fromarray(arr,"RGBA").save("assets/_buildings_src/b52.png")
Image.fromarray(arr,"RGBA").resize((W*3,H*3),Image.NEAREST).convert("RGB").save(".tmp/b52_fence4.png")
