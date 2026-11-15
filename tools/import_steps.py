#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把 [kdd]DifferentSteps 的脚步录音整理成游戏用的单步 WAV，放到 assets/steps/。

用法:
    python tools/import_steps.py            # 全量重做
    python tools/import_steps.py --dry      # 只看会做什么

为什么要处理一道:
    1. 原素材是 44.1kHz 立体声 ogg，单个 0.24~0.70s。脚步是点音源、玩家就在正前方，
       立体声没有意义，转单声道 22.05kHz 后每个只剩 10~20KB。
    2. 每条都有不同程度的头部静音和长尾，不裁的话「踩下去」的时刻会比动画帧晚一截，
       连续走起来就会糊成一片。
    3. 四条录音的电平差很多（gravel 峰值 -3dB、leaves 接近 0dB），必须统一响度，
       否则一从沥青走到草地音量就掉一半。
       ——按**峰值**归一到 0.85；不同材质之间「该多响」由 Sfx.gd 的 TIMBRE.level 调，
       不在这里压，改手感不用重跑这个脚本。

映射（材质名要跟 Ground.KINDS / Sfx.TIMBRE 对得上）:
    grass    <- leaves01 / leaves02      草地（落叶、草丛的摩擦声）
    asphalt  <- gravel                   沥青/水泥路面（碎石的沙砾感，最接近）
    stone    <- stone01                  石板广场（硬、脆、有余韵）
    wood     <- wood01 / wood02 / wood03 室内木地板
    mud02 没用：潮湿的「咕叽」声踩在干燥草坪上很出戏。

依赖: pip install av numpy
"""
from __future__ import annotations

import argparse
import math
import struct
import sys
import wave
from pathlib import Path

try:
    import av
    import numpy as np
except ImportError:
    sys.exit("需要 PyAV + numpy：python -m pip install av numpy")

GAME = Path(__file__).resolve().parent.parent
ROOT = GAME.parent
SRC_DIR = ROOT / "references" / "steps_src"
OUT_DIR = GAME / "assets" / "steps"

OUT_RATE = 22050
PEAK = 0.85                     # 归一到这个峰值（留一点余量给多路叠加）
PRE_ROLL = 0.005                # 起手保留 5ms，免得把脚步声的「咬合」削掉
FADE_OUT = 0.045                # 尾巴渐隐，硬切会有「啪」

# 输出名（Sfx.gd 按 <材质>_ 前缀找文件）-> (源文件, 最长时长)
# 最长时长按「一步大概 0.3s」定：太长会和下一步叠在一起糊掉，太短会像敲木鱼。
SOURCES = {
    "grass_1": ("leaves01.ogg", 0.34),
    "grass_2": ("leaves02.ogg", 0.34),
    # gravel 那条 0.38s 处还有一次明显的「咔嚓」，留着会和下一步（0.3s 后）叠成两团；
    # 截到 0.34s 只保留主踩踏那一下。
    "asphalt_1": ("gravel.ogg", 0.34),
    "stone_1": ("stone01.ogg", 0.30),
    "wood_1": ("wood01.ogg", 0.30),
    "wood_2": ("wood02.ogg", 0.30),
    "wood_3": ("wood03.ogg", 0.32),
}


def decode_mono(path: Path, rate: int) -> np.ndarray:
    """读到单声道 float32，并重采样到 rate。"""
    inp = av.open(str(path))
    stream = inp.streams.audio[0]
    rs = av.AudioResampler(format="flt", layout="mono", rate=rate)
    out = []
    for frame in inp.decode(stream):
        for f in rs.resample(frame):
            out.append(f.to_ndarray().reshape(-1))
    for f in rs.resample(None):
        out.append(f.to_ndarray().reshape(-1))
    inp.close()
    if not out:
        return np.zeros(0, dtype=np.float32)
    return np.concatenate(out).astype(np.float32)


def trim(x: np.ndarray, rate: int, max_sec: float) -> np.ndarray:
    """去掉头部静音 + 按最长时长截尾 + 渐隐。"""
    if x.size == 0:
        return x
    peak = float(np.abs(x).max())
    if peak <= 1e-6:
        return x
    # 头部：第一个超过峰值 4% 的采样，往前留 5ms
    loud = np.nonzero(np.abs(x) > peak * 0.04)[0]
    start = max(0, int(loud[0]) - int(PRE_ROLL * rate)) if loud.size else 0
    x = x[start:]
    # 长度：max_sec，且末尾再裁到「最后一个超过 1% 峰值的位置 + 40ms」
    # ⚠️ 阈值别用 4%：石头那种快速衰减的样本会在 0.13s 就被切断，
    #    听起来变成「敲木鱼」，那点余韵正是石板踩上去的味道。
    end = min(x.size, int(max_sec * rate))
    loud2 = np.nonzero(np.abs(x[:end]) > peak * 0.01)[0]
    if loud2.size:
        end = min(end, int(loud2[-1]) + int(0.04 * rate))
    x = x[:end].copy()
    # 渐隐
    n_fade = min(x.size, int(FADE_OUT * rate))
    if n_fade > 1:
        x[-n_fade:] *= np.linspace(1.0, 0.0, n_fade, dtype=np.float32) ** 1.5
    return x


def write_wav(path: Path, x: np.ndarray, rate: int) -> int:
    pcm = np.clip(x * 32767.0, -32768, 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm.tobytes())
    return path.stat().st_size


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry", action="store_true")
    args = ap.parse_args()

    if not SRC_DIR.exists():
        sys.exit(f"找不到源目录 {SRC_DIR}（把 [kdd]DifferentSteps 里的 ogg 放进去）")
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    total = 0
    print(f"{'输出':12s} {'源':14s} {'时长':>6s} {'峰值':>6s} {'体积':>7s}")
    for name, (src_name, max_sec) in SOURCES.items():
        src = SRC_DIR / src_name
        if not src.exists():
            print(f"[跳过] {name}: 找不到 {src_name}")
            continue
        x = decode_mono(src, OUT_RATE)
        raw_peak = float(np.abs(x).max()) if x.size else 0.0
        x = trim(x, OUT_RATE, max_sec)
        peak = float(np.abs(x).max()) if x.size else 0.0
        if peak > 1e-6:
            x = x * (PEAK / peak)
        dur = x.size / OUT_RATE
        if args.dry:
            print(f"[dry] {name:12s} {src_name:14s} {dur:6.2f}s 原峰值 {raw_peak:5.2f}")
            continue
        dst = OUT_DIR / f"{name}.wav"
        size = write_wav(dst, x, OUT_RATE)
        total += size
        print(f"{dst.name:12s} {src_name:14s} {dur:6.2f}s {raw_peak:6.2f} {size / 1024:6.1f}KB")

    if total:
        print(f"\n合计 {total / 1024:.0f}KB / {len(SOURCES)} 个单步")
    print("别忘了：在 Godot 里跑一次 --import，Sfx 才会用上（缺文件时自动退回合成音）。")


if __name__ == "__main__":
    main()
