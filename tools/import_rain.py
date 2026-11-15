#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把雨天环境录音放到游戏里（幂等，原样拷贝，不重编码）。

用法:
    python tools/import_rain.py            # 拷贝
    python tools/import_rain.py --dry      # 只看会做什么

为什么不转码:
    源是 44.1kHz 立体声 Ogg Vorbis，278.8s / 6.5MB（约 187kbps）。
    Vorbis 本身是**无缝**格式，循环没有 MP3 那种编码器补静音；
    本机也没有 libvorbis 编码器（PyAV 只有质量一般的原生 vorbis），
    再去压一道只会把雨声的高频糊掉。6.5MB 换 4.6 分钟不重复的雨声，划算。

    循环接缝在代码里处理：源文件开头 0.5s 全静音、前 20 多秒是很轻的渐强，
    结尾却是满电平雨声 —— 直接从头循环会每 4.6 分钟静音一秒。
    rain_audio.gd 用 loop_offset=24s 且首次也从 24s 起播，跳到平稳雨声段。

源在 references/（项目根，不在 git 仓库内）。产物 assets/ambience/ 已进
.gitignore，clone 后缺素材时 rain_audio.gd 自动回退程序合成的雨声。
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

GAME = Path(__file__).resolve().parent.parent
ROOT = GAME.parent
SRC = ROOT / "references" / "Dark_Rainy_Night(ambience).ogg"
DST = GAME / "assets" / "ambience" / "rain.ogg"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry", action="store_true")
    args = ap.parse_args()

    if not SRC.exists():
        sys.exit(f"找不到源文件 {SRC}")
    if DST.exists() and DST.read_bytes() == SRC.read_bytes():
        print(f"[已存在] {DST.relative_to(ROOT)}  {DST.stat().st_size / 1048576:.2f}MB")
        return
    if args.dry:
        print(f"[dry] {SRC.name} -> {DST.relative_to(ROOT)}（原样拷贝）")
        return
    DST.parent.mkdir(parents=True, exist_ok=True)
    DST.write_bytes(SRC.read_bytes())
    print(f"[ok] {DST.relative_to(ROOT)}  {DST.stat().st_size / 1048576:.2f}MB")
    print("别忘了在 Godot 里跑一次 --import；循环由 rain_audio.gd 运行时设置。")


if __name__ == "__main__":
    main()
