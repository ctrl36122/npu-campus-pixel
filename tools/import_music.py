#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把背景音乐源文件转成游戏里用的紧凑 mp3，放到 sxgd-game/assets/music/。

用法:
    python tools/import_music.py                     # 按下面的 SOURCES 转码
    python tools/import_music.py --dry               # 只看会做什么

为什么转码:
    原素材有的是 320kbps 立体声（3 分钟就 7.7MB），四条加起来 18MB，
    手机包里太占地方。背景音乐 96kbps 已经完全够用，体积能砍一半。

依赖: pip install av   （PyAV，自带 ffmpeg，不用另外装 ffmpeg.exe）

注意:
    assets/music/ 里的成品**不进 git**（第三方音乐不做二次分发），
    但本地打包会带上。clone 后缺文件时 Music.gd 自动静音，不影响跑。
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    import av
except ImportError:
    sys.exit("需要 PyAV：python -m pip install av")

GAME = Path(__file__).resolve().parent.parent
ROOT = GAME.parent
OUT_DIR = GAME / "assets" / "music"

# 输出名（别改，Music.gd 的 TRACKS 按键名找文件）-> (源文件, 码率)
SOURCES = {
    "campus_day": (ROOT / "references" / "walking_to_the_park_at_3_a.m.mp3", 96_000),
    "campus_night": (ROOT / "references" / "brain_fog.mp3", 96_000),
    "dorm": (ROOT / "references" / "Next to You.mp3", 112_000),
    "study": (ROOT / "references" / "Winter Snow.mp3", 96_000),
}

# 菜单循环曲只有 ~15 秒，**不做有损转码**：lossy 编码会在首尾补静音，
# 循环接缝每 15 秒就响一下「咔」，原样拷 WAV 才是无缝的。
WAV_COPY = {
    "menu": ROOT / "references" / "Loop-Menu.wav",
}


def transcode(src: Path, dst: Path, bitrate: int) -> tuple[float, int]:
    """解码 -> 统一 44.1k -> libmp3lame 重编码。返回 (时长秒, 体积字节)。"""
    inp = av.open(str(src))
    in_stream = inp.streams.audio[0]
    out = av.open(str(dst), "w", format="mp3")
    out_stream = out.add_stream("libmp3lame", rate=44100)
    out_stream.bit_rate = bitrate
    out_stream.layout = in_stream.layout if in_stream.layout.name in ("mono", "stereo") else "stereo"

    resampler = av.AudioResampler(format=out_stream.format.name, layout=out_stream.layout.name,
                                  rate=44100)
    secs = 0.0
    for frame in inp.decode(in_stream):
        secs += float(frame.samples) / float(frame.sample_rate)
        for rf in resampler.resample(frame):
            for packet in out_stream.encode(rf):
                out.mux(packet)
    for rf in resampler.resample(None):
        for packet in out_stream.encode(rf):
            out.mux(packet)
    for packet in out_stream.encode(None):
        out.mux(packet)
    out.close()
    inp.close()
    return secs, dst.stat().st_size


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry", action="store_true")
    ap.add_argument("--force", action="store_true", help="已存在也重转")
    args = ap.parse_args()

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    total_in = total_out = 0

    for name, src in WAV_COPY.items():
        if not src.exists():
            print(f"[跳过] {name}: 找不到 {src}")
            continue
        dst = OUT_DIR / f"{name}.wav"
        if dst.exists() and not args.force:
            print(f"[已存在] {dst.relative_to(ROOT)}  {dst.stat().st_size / 1048576:.1f}MB")
        elif args.dry:
            print(f"[dry] {src.name} -> {dst.name}（原样拷贝）")
        else:
            dst.write_bytes(src.read_bytes())
            print(f"[ok] {name:13s} wav 原样拷贝  {dst.stat().st_size / 1048576:5.2f}MB")
        total_in += src.stat().st_size
        if dst.exists():
            total_out += dst.stat().st_size

    for name, (src, br) in SOURCES.items():
        if not src.exists():
            print(f"[跳过] {name}: 找不到 {src}")
            continue
        dst = OUT_DIR / f"{name}.mp3"
        if dst.exists() and not args.force:
            print(f"[已存在] {dst.relative_to(ROOT)}  {dst.stat().st_size / 1048576:.1f}MB")
            total_out += dst.stat().st_size
            total_in += src.stat().st_size
            continue
        if args.dry:
            print(f"[dry] {src.name} -> {dst.name} @{br // 1000}kbps")
            continue
        secs, size = transcode(src, dst, br)
        print(f"[ok] {name:13s} {secs / 60:5.1f}min  {br // 1000}kbps  "
              f"{src.stat().st_size / 1048576:5.2f}MB -> {size / 1048576:5.2f}MB  {dst.name}")
        total_in += src.stat().st_size
        total_out += size

    if total_out:
        print(f"\n合计 {total_in / 1048576:.1f}MB -> {total_out / 1048576:.1f}MB"
              f"（省 {100 - total_out * 100 // max(1, total_in)}%）")
    print("别忘了：assets/music/ 在 .gitignore 里，只留本机。")


if __name__ == "__main__":
    main()
