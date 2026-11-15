#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把背景音乐源文件转成游戏里用的紧凑 mp3，放到 sxgd-game/assets/music/。

用法:
    python tools/import_music.py                     # 按下面的 SOURCES 转码
    python tools/import_music.py --dry               # 只看会做什么
    python tools/import_music.py --only campus_snow  # 只补某一首

输出名 = Music.gd 的曲目键，按用途分（别随便改名）：
    menu              加载 / 声明页 loop（WAV 原样拷贝，无缝）
    campus_clear      校园 · 晴 / 阴（原图书馆那首 Winter Snow）
    campus_rain_day   校园 · 雨天 · 白天
    campus_rain_night 校园 · 雨天 · 夜晚
    campus_snow       校园 · 雪天（8bit 版 Winter Snow）
    dorm              宿舍（8bit 版 Next to You）
    图书馆 / 自习室  不放 BGM，只留雨天的环境雨声

为什么转码:
    原素材有的是 320kbps 立体声，8bit 那两首更是 48kHz WAV 16MB / 46MB，
    手机包里太占地方。背景音乐 96~160kbps 已经够用，体积能砍一半以上。

依赖: pip install av   （PyAV，自带 ffmpeg，不用另外装 ffmpeg.exe）

注意:
    assets/music/ 里的成品**不进 git**（第三方音乐不做二次分发），
    但本地打包会带上。clone 后缺文件时 Music.gd 自动静音，不影响跑。
    新增 / 改名 mp3 后要跑 godot --headless --path . --import，
    并把新生成的 .import 里 loop 设成 true（Godot 默认给 false）。
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
    # 晴 / 阴：原来是图书馆那首，用户要求挪到校园晴天
    "campus_clear": (ROOT / "references" / "Winter Snow.mp3", 96_000),
    # 雨天：沿用原来那两首校园曲，仍按昼夜分
    "campus_rain_day": (ROOT / "references" / "walking_to_the_park_at_3_a.m.mp3", 96_000),
    "campus_rain_night": (ROOT / "references" / "brain_fog.mp3", 96_000),
    # 雪天：用户指定的 8bit 版 Winter Snow（48kHz 立体声 WAV 46MB）
    "campus_snow": (ROOT / "references" / "8bit-Winter Snow.wav", 160_000),
    # 宿舍曲：用户指定的 8bit 版 Next to You（48kHz 立体声 WAV 16MB）
    "dorm": (ROOT / "references" / "8bit-Next to You.wav", 160_000),
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
    ap.add_argument("--only", default="", help="只处理这些键名，逗号分隔（如 dorm）")
    args = ap.parse_args()
    only = [x.strip() for x in args.only.split(",") if x.strip()]

    def want(name: str) -> bool:
        return not only or name in only

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    total_in = total_out = 0

    for name, src in WAV_COPY.items():
        if not want(name):
            continue
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
        if not want(name):
            continue
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
