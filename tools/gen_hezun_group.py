"""生成「何尊勇士组雕」拆开后的两张贴图（纯程序化像素画，无外部素材）。

真实：何尊组雕是【两座分开的雕塑】——
  勇士（华山花岗岩、半身埋土、俯首横托宝剑）立在西边草地上，背对图书馆；
  何尊（9.5m 青铜方尊、喇叭口/饕餮纹/宅兹中国铭文）立在东边水池里。
  资料：百度百科「何尊广场」「为国铸剑」、西工大软件学院参观稿。

⚠️ b52 勇士贴图已改由 tools/gen_warrior_fence.py 生成（含方形围栏）；本脚本只负责 props_hezun.png。

本脚本产出：
  assets/props_hezun.png         独立何尊道具（草地上、横托剑、名牌基座）
      —— 再走 tools/bake_facade.py 的 apply 烘焙成 assets/buildings/b52.png，
         facade 只落实心像素上的名牌「为国铸剑」，alpha/semi/glass 自检不变。
  assets/props_hezun.png         独立何尊道具（青铜方尊立在石砌圆池里）
      —— 作为 prop 放进 world.json / world.tscn，落在广场西侧水域，与勇士拉开距离。

2026-11-17 返工：上一版把两座画在同一张 b52 同一个底座、挤在广场中央、没有水池，
且左右/草地-vs-水池的结构全错；本版按真实拆成两座、何尊移到西侧水域。

⚠️ 改源图后必须重跑：python tools/gen_hezun_group.py
   再重烘 b52：python -c "import sys;sys.path.insert(0,'tools');..."（见日志）
   最后 Godot --headless --import 刷新贴图缓存。
"""
"""把何尊组雕彻底拆成两个独立对象：
  A) b52 源图 = 只保留勇士（草地上、俯首横托宝剑、名牌基座）
  B) props_hezun.png = 独立的何尊（青铜方尊立在石砌水池里），放到西侧水域
  两者都走各自的 alpha 规范；b52 仍由 bake_facade.apply 烘焙。
"""
from PIL import Image, ImageDraw
import numpy as np

# ---- 配色 ----
GRAN_DARK=(74,80,88); GRAN=(108,114,123); GRAN_LITE=(140,147,156)
BLADE=(232,238,244); BLADE_SH=(170,180,192)
BRONZE_D=(86,96,62); BRONZE=(122,138,84)
BRONZE_L=(158,172,106); BRONZE_HI=(196,206,140); GOLD=(198,162,72)
GRASS=(74,124,66); GRASS_L=(98,150,80); GRASS_D=(54,96,52)
STONE=(150,148,138); STONE_D=(112,110,102); STONE_L=(176,174,164)
WATER=(78,132,150); WATER_L=(104,158,176); WATER_HI=(140,190,204)

# ============ A) b52 勇士 ============
H,W=349,224
img=Image.new("RGBA",(W,H),(0,0,0,0)); d=ImageDraw.Draw(img)
# 草地土丘
d.ellipse([74,286,130,298],fill=GRASS_D); d.ellipse([78,284,126,294],fill=GRASS)
d.ellipse([84,282,120,290],fill=GRASS_L)
for gx,gy in ((80,284),(88,281),(96,283),(106,280),(116,283),(124,285)):
    d.line([gx,gy,gx-1,gy-3],fill=GRASS_L)
# 半身埋土的身躯
d.polygon([(94,248),(114,248),(120,290),(88,290)],fill=GRAN_DARK)
d.polygon([(97,250),(112,250),(116,286),(93,286)],fill=GRAN)
# 俯首弓背
d.ellipse([92,232,116,256],fill=GRAN); d.ellipse([86,240,104,256],fill=GRAN_LITE)
d.polygon([(84,248),(92,246),(90,256),(82,256)],fill=GRAN)
d.rectangle([92,238,100,242],fill=GRAN_DARK); d.line([84,254,92,255],fill=GRAN_DARK)
# 双臂横托剑
d.polygon([(90,256),(120,254),(122,262),(88,264)],fill=GRAN_LITE)
d.rectangle([92,260,118,266],fill=GRAN)
d.rectangle([76,256,132,260],fill=BLADE); d.rectangle([76,258,132,258],fill=BLADE_SH)
d.rectangle([72,254,78,262],fill=GOLD); d.rectangle([66,256,72,260],fill=BRONZE_D)
d.polygon([(132,256),(141,258),(132,260)],fill=BLADE)
d.rectangle([86,252,92,258],fill=GRAN_LITE); d.rectangle([116,252,122,258],fill=GRAN_DARK)
# 名牌基座（66x20 实心，给 facade 落"为国铸剑"）
d.rectangle([74,276,140,296],fill=(186,190,196))
# 半透明接地投影
ImageDraw.Draw(img).ellipse([68,294,142,308],fill=(120,124,130,56))
arr=np.asarray(img)
ys,xs=np.where(arr[:,:,3]==255)
print("b52 源图 bbox255 x%d..%d y%d..%d"%(xs.min(),xs.max(),ys.min(),ys.max()))
Image.fromarray(arr,"RGBA").save("assets/_buildings_src/b52.png")

# ============ B) props_hezun 独立道具 ============
# 画布 72x96；何尊在中央，石砌水池在底部
PW,PH=72,96
h=Image.new("RGBA",(PW,PH),(0,0,0,0)); p=ImageDraw.Draw(h)
# 石砌圆池（居中 x≈36，y≈78）
p.ellipse([8,70,64,92],fill=STONE_D)
p.ellipse([10,68,62,88],fill=STONE)
p.ellipse([14,71,58,85],fill=WATER)
p.ellipse([18,73,52,80],fill=WATER_L)
p.line([20,76,32,75],fill=WATER_HI); p.line([40,78,52,77],fill=WATER_HI)
for px in (18,30,42,54): p.point([px,69],fill=STONE_L)
# 何尊：高圈足 + 鼓腹饕餮纹 + 长颈 + 大喇叭口 + 四扉棱，立在池中央
CX=36
p.rectangle([CX-9,62,CX+9,74],fill=BRONZE_D)      # 圈足
p.rectangle([CX-7,62,CX+7,73],fill=BRONZE)
p.rectangle([CX-15,42,CX+15,62],fill=BRONZE_D)    # 鼓腹
p.rectangle([CX-13,43,CX+13,60],fill=BRONZE)
p.rectangle([CX-13,48,CX+13,50],fill=BRONZE_L)    # 饕餮纹带
p.rectangle([CX-9,52,CX-5,56],fill=BRONZE_D)      # 双目
p.rectangle([CX+5,52,CX+9,56],fill=BRONZE_D)
p.rectangle([CX-1,53,CX+1,55],fill=BRONZE_HI)     # 鼻
p.rectangle([CX-8,30,CX+8,43],fill=BRONZE)        # 长颈
p.rectangle([CX-6,30,CX+6,42],fill=BRONZE_L)
p.polygon([(CX-11,28),(CX+11,28),(CX+17,14),(CX-17,14)],fill=BRONZE_L)  # 喇叭口
p.polygon([(CX-9,27),(CX+9,27),(CX+14,16),(CX-14,16)],fill=BRONZE_HI)
p.rectangle([CX-17,13,CX+17,15],fill=BRONZE_HI)   # 口沿
for fx in (CX-14,CX+12):                           # 扉棱
    p.rectangle([fx,16,fx+2,60],fill=BRONZE_HI)
for bx,by in ((CX-8,46),(CX+9,54),(CX-3,38),(CX+6,68),(CX-11,52)):
    p.point([bx,by],fill=(150,170,96))             # 绿锈
# 投影（alpha=56）
ImageDraw.Draw(h).ellipse([6,88,66,95],fill=(120,124,130,56))
ha=np.asarray(h)
ys,xs=np.where(ha[:,:,3]==255)
print("props_hezun bbox255 x%d..%d y%d..%d"%(xs.min(),xs.max(),ys.min(),ys.max()))
Image.fromarray(ha,"RGBA").save("assets/props_hezun.png")
Image.fromarray(ha,"RGBA").resize((PW*5,PH*5),Image.NEAREST).convert("RGB").save(".tmp/hezun_prop2.png")
Image.fromarray(arr,"RGBA").resize((W*3,H*3),Image.NEAREST).convert("RGB").save(".tmp/b52_warrior2.png")
