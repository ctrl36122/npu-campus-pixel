#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""离线夜景预览：把 assets/buildings/b{i}.png + assets/glow_winb_{i}.png 按游戏里的
合成方式（夜幕压暗墙面 + 窗光 add 叠加）合成成 png，便于不开引擎就检查窗光效果。

用法（项目根目录）：
  python3 tools/preview_night.py 28 50 51        # 指定楼号
  python3 tools/preview_night.py --all           # 全部楼（图多，慎用）
输出：preview/night_{i}.png
"""
import os, sys, json

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from bake_art import decode_png, encode_png  # noqa: E402

DARK = 0.42          # 夜幕对墙面的压暗系数（近似 Arena 的 NightDark）


def night(i, outdir):
    bp = os.path.join(ROOT, "assets/buildings/b%d.png" % i)
    gp = os.path.join(ROOT, "assets/glow_winb_%d.png" % i)
    if not os.path.exists(bp):
        return None
    w, h, ch, bb = decode_png(bp)
    gw, gh, gch, gg = decode_png(gp)
    out = bytearray(w * h * 4)
    lit = dark = 0
    for p in range(w * h):
        o = p * 4
        al = bb[o + 3]
        if al <= 0:
            continue
        r, g, b = bb[o], bb[o + 1], bb[o + 2]
        ga = gg[o + 3] / 255.0
        dr = r * DARK
        dg = g * DARK
        db = b * DARK
        if ga > 0:
            # add 混合：窗光直接加到压暗后的墙上
            dr += gg[o] * ga
            dg += gg[o + 1] * ga
            db += gg[o + 2] * ga
            if gg[o + 3] >= 90:
                lit += 1
            else:
                dark += 1
        out[o] = int(min(255, dr))
        out[o + 1] = int(min(255, dg))
        out[o + 2] = int(min(255, db))
        out[o + 3] = al
    os.makedirs(outdir, exist_ok=True)
    path = os.path.join(outdir, "night_%d.png" % i)
    encode_png(path, w, h, 4, bytes(out))
    return path, lit, dark


def main():
    args = sys.argv[1:]
    wj = json.load(open(os.path.join(ROOT, "assets/world.json"), encoding="utf-8"))
    if "--all" in args:
        ids = list(range(len(wj["buildings"])))
    else:
        ids = [int(a) for a in args if a.isdigit()]
    outdir = os.path.join(ROOT, "preview")
    for i in ids:
        res = night(i, outdir)
        if res is None:
            continue
        path, lit, dark = res
        name = wj["buildings"][i].get("name", "?") if i < len(wj["buildings"]) else "?"
        tot = lit + dark
        pct = (100.0 * lit / tot) if tot else 0.0
        print("#%2d %-20s 亮窗px=%6d 暗窗px=%6d 亮占比=%5.1f%%  → %s"
              % (i, name[:20], lit, dark, pct, os.path.relpath(path, ROOT)))


if __name__ == "__main__":
    main()
