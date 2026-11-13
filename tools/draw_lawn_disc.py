#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""画草坪休憩节点的圆形碎石地贴（Ground 层 sprite）。

为什么不改地面 PNG：
  road / grass / water 三张掩码和道具候选网格都是按 ground/*.png 的颜色算的，
  直接在地面上画一块浅色铺装会把整片草地降级成「非草」，连锁破坏
  place_life_props 的候选点、夜间可见地面掩码和地面烘焙链的幂等验收。
  改成 Ground 层独立 sprite：视觉上一样有一块铺装，地面 PNG 一个字节都不动。

配色刻意压在偏灰绿、低对比：第一版停机坪用 (190,188,178) 白得像水泥广场，
后来调到 (162,168,154) 才和草地协调；这里沿用了同一档明度。

输出：assets/props_lawn_disc.png 192x192（24x24 格），四角透明。
"""
import math
import os
import random

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "props_lawn_disc.png")

SIZE = 192
C = SIZE // 2
R = 94

# 低对比灰绿石：比草地暗一点、灰一点，不抢眼
RING = (130, 140, 118)      # 外缘包边
BASE = (158, 166, 140)      # 主体
SLAB = (152, 160, 134)      # 交替扇形板块（只差 6，低对比）
SEAM = (140, 149, 124)      # 同心环 / 放射缝
PEBBLE = (170, 178, 152)    # 稀疏亮碎石
SEED = 20261113


def build():
    im = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)

    # 外圈包边 + 交替扇形石板（只差 6 级明度，读成铺装而不是线描靶子）
    d.ellipse([C - R, C - R, C + R, C + R], fill=RING + (255,))
    inner = R - 4
    for k in range(8):
        tone = BASE if k % 2 == 0 else SLAB
        d.pieslice([C - inner, C - inner, C + inner, C + inner],
                   start=k * 45, end=(k + 1) * 45, fill=tone + (255,))
    # 中心不画环，喷泉会盖住；只留一圈石板缝，避免「同心圆靶心」
    d.ellipse([C - 62, C - 62, C + 62, C + 62], outline=SEAM + (255,), width=1)
    for k in range(8):
        a = math.pi * k / 4
        x0, y0 = C + 28 * math.cos(a), C + 28 * math.sin(a)
        x1, y1 = C + inner * math.cos(a), C + inner * math.sin(a)
        d.line([(round(x0), round(y0)), (round(x1), round(y1))],
               fill=SEAM + (255,), width=1)
    d.ellipse([C - 28, C - 28, C + 28, C + 28], fill=BASE + (255,))

    # 稀疏碎石亮点：打散纯色圆盘，又不像噪点
    rnd = random.Random(SEED)
    for _ in range(150):
        a = rnd.random() * math.tau
        rr = math.sqrt(rnd.random()) * (inner - 2)
        x = round(C + rr * math.cos(a))
        y = round(C + rr * math.sin(a))
        if 0 <= x < SIZE and 0 <= y < SIZE:
            d.point((x, y), fill=PEBBLE + (255,))
    return im


if __name__ == "__main__":
    im = build()
    im.save(OUT)
    print("[lawn_disc] -> %s (%dx%d, %d B)" %
          (OUT, im.width, im.height, os.path.getsize(OUT)))
