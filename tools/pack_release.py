#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把三端导出产物打成 Release 用的 zip，结构对齐 v1.2.3：
   win64/android -> 顶层一个 XGD-Campus-xxx/ 目录，内含程序 + 两个说明
   macos         -> 顶层直接是 像素工大.app/ + macOS 安装说明.txt
"""
import hashlib
import os
import shutil
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REL = os.path.join(ROOT, "build", "release")
BUILD = os.path.join(ROOT, "build")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def zip_dir(src_dir, out_zip, arc_prefix):
    """把 src_dir 下的内容以 arc_prefix/ 为前缀写进 out_zip。"""
    if os.path.exists(out_zip):
        os.remove(out_zip)
    with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        z.write(src_dir, arc_prefix + "/")
        for name in sorted(os.listdir(src_dir)):
            full = os.path.join(src_dir, name)
            if os.path.isdir(full):
                for dirpath, _dirs, files in os.walk(full):
                    rel = os.path.relpath(dirpath, src_dir).replace("\\", "/")
                    z.write(dirpath, f"{arc_prefix}/{rel}/")
                    for fn in sorted(files):
                        z.write(os.path.join(dirpath, fn), f"{arc_prefix}/{rel}/{fn}")
            else:
                z.write(full, f"{arc_prefix}/{name}")


def main():
    # --- win64 ---
    win_dir = os.path.join(REL, "XGD-Campus-win64")
    shutil.copy2(os.path.join(BUILD, "windows", "像素工大.exe"),
                 os.path.join(win_dir, "像素工大.exe"))
    win_zip = os.path.join(REL, "XGD-Campus-win64.zip")
    zip_dir(win_dir, win_zip, "XGD-Campus-win64")
    print(f"[win64]   {os.path.getsize(win_zip)/1048576:.1f} MB")

    # --- android ---
    and_dir = os.path.join(REL, "XGD-Campus-android")
    shutil.copy2(os.path.join(BUILD, "android", "像素工大.apk"),
                 os.path.join(and_dir, "像素工大.apk"))
    and_zip = os.path.join(REL, "XGD-Campus-android.zip")
    zip_dir(and_dir, and_zip, "XGD-Campus-android")
    print(f"[android] {os.path.getsize(and_zip)/1048576:.1f} MB")

    # --- macOS：Godot 已导出的 zip 里是 像素工大.app/，补上安装说明再重打 ---
    tmp = os.path.join(BUILD, "_macos_pack")
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    with zipfile.ZipFile(os.path.join(BUILD, "macos", "像素工大.zip")) as z:
        z.extractall(tmp)
    # 签名脚本 + 安装说明得一起进包，用户首次打开要 ad-hoc 签
    shutil.copy2(os.path.join(BUILD, "macos", "macOS 安装说明.txt"), tmp)
    for extra in ("macos-sign.sh",):
        p = os.path.join(ROOT, "tools", extra)
        if os.path.exists(p):
            shutil.copy2(p, tmp)
    mac_zip = os.path.join(REL, "XGD-Campus-macos.zip")
    if os.path.exists(mac_zip):
        os.remove(mac_zip)
    with zipfile.ZipFile(mac_zip, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for dirpath, dirs, files in os.walk(tmp):
            rel = os.path.relpath(dirpath, tmp).replace("\\", "/")
            if rel == ".":
                rel = ""
            if rel:
                z.write(dirpath, rel + "/")
            for fn in sorted(files):
                arc = f"{rel}/{fn}" if rel else fn
                z.write(os.path.join(dirpath, fn), arc)
    shutil.rmtree(tmp, ignore_errors=True)
    print(f"[macos]   {os.path.getsize(mac_zip)/1048576:.1f} MB")

    # --- 校验和 ---
    lines = []
    for name in ("XGD-Campus-win64.zip", "XGD-Campus-macos.zip", "XGD-Campus-android.zip"):
        p = os.path.join(REL, name)
        lines.append(f"{sha256(p)}  {name}")
    with open(os.path.join(REL, "SHA256SUMS.txt"), "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
