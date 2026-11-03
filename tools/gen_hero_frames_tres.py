#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""纯文本方式给换装变体英雄生成 frames_*.tres。

不直接跑 Godot（headless --script 在本机被 AI 插件 + 4.7 的 static-string bug 拖死）。
frames_*.tres 本质是文本：克隆 frames_adam.tres（沿用 52 帧布局 / 动画名），
把 ext_resource 的 uid + path 指向变体 PNG（uid 取自该 PNG 的 .import），
再给文件头换一个全局唯一的随机 uid。Godot 打开工程时会按 uid 注册，无需 import。

用法：python tools/gen_hero_frames_tres.py
"""
import os
import random
import re
import string

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "assets", "sandbox")
BASE_TRES = os.path.join(ASSETS, "frames_adam.tres")

VARIANTS = {
    "adam_r":  "uid://5uuokmwo84uc",
    "adam_p":  "uid://c1eswb5bxdb04",
    "ash_g":   "uid://c1xxqoy2ai3qi",
    "ash_o":   "uid://dwyc5mihuvl4r",
    "lucy_b":  "uid://d1rtvwx7xptmr",
    "lucy_t":  "uid://dr20je5fs58e2",
    "nancy_v": "uid://gyibr1tikfwb",
    "nancy_c": "uid://bhjd335q02lxm",
}


def collect_existing_uids():
    uids = set()
    for base, _dirs, files in os.walk(ASSETS):
        for fn in files:
            if fn.endswith((".tres", ".import", ".gdshader", ".gd")):
                try:
                    with open(os.path.join(base, fn), encoding="utf-8") as f:
                        for m in re.findall(r'uid://([a-z0-9]+)', f.read()):
                            uids.add(m)
                except Exception:
                    pass
    return uids


def make_uid(existing):
    chars = string.ascii_lowercase + string.digits
    while True:
        u = "uid://" + "".join(random.choice(chars) for _ in range(12))
        if u not in existing:
            existing.add(u)
            return u


def main():
    with open(BASE_TRES, encoding="utf-8") as f:
        base = f.read()
    existing = collect_existing_uids()
    for vid, png_uid in VARIANTS.items():
        out = base
        # 文件头 uid 换成全局唯一随机
        new_file_uid = make_uid(existing)
        out = re.sub(r'(\[gd_resource[^\]]*uid=")uid://[a-z0-9]+(")',
                     lambda m: m.group(1) + new_file_uid + m.group(2), out, count=1)
        # ext_resource：uid + path 指向变体 PNG
        out = re.sub(
            r'(\[ext_resource type="Texture2D" uid=")uid://[a-z0-9]+(" path=")res://assets/sandbox/heroes/adam\.png(")',
            lambda m: m.group(1) + png_uid + m.group(2) + "res://assets/sandbox/heroes/%s.png" % vid + m.group(3),
            out, count=1)
        dst = os.path.join(ASSETS, "frames_%s.tres" % vid)
        with open(dst, "w", encoding="utf-8") as f:
            f.write(out)
        print("[frames] 生成 %s (png uid=%s)" % (dst, png_uid))


if __name__ == "__main__":
    random.seed(20261103)
    main()
