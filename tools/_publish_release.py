#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把三端安装包发到 GitHub Release（作为正式分发源，服务器只留下载页）。

用法：
    python tools/_publish_release.py <tag> <target_branch> <notes_file> <asset1> [asset2 ...]

令牌从 Windows 凭据管理器取（git credential fill），不落盘、不进命令行。
已存在的同名资产会先删掉再重传，方便补传。
"""
import json
import mimetypes
import os
import subprocess
import sys
import urllib.error
import urllib.request
import hashlib

OWNER, REPO = "ctrl36122", "npu-campus-pixel"
API = "https://api.github.com"


def token() -> str:
    p = subprocess.run(
        ["git", "credential", "fill"],
        input="protocol=https\nhost=github.com\n\n",
        capture_output=True, text=True,
    )
    for line in p.stdout.splitlines():
        if line.startswith("password="):
            return line.split("=", 1)[1]
    raise SystemExit("拿不到 GitHub 令牌")


TOK = token()


def call(method, url, data=None, ctype="application/json", raw_path=None):
    headers = {
        "Authorization": f"token {TOK}",
        "Accept": "application/vnd.github+json",
        "User-Agent": "xgd-publish",
    }
    body = None
    if data is not None:
        body = json.dumps(data).encode()
        headers["Content-Type"] = ctype
    elif raw_path:
        size = os.path.getsize(raw_path)
        body = open(raw_path, "rb")
        headers["Content-Type"] = mimetypes.guess_type(raw_path)[0] or "application/octet-stream"
        headers["Content-Length"] = str(size)
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=1800) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    tag, target, notes_file, *assets = sys.argv[1:]
    body = open(notes_file, encoding="utf-8").read()

    # 已存在就先删（重建更干净，避免资产重复）
    st, rel = call("GET", f"{API}/repos/{OWNER}/{REPO}/releases/tags/{tag}")
    if st == 200:
        print(f"[release] {tag} 已存在，删除重建 id={rel['id']}")
        call("DELETE", f"{API}/repos/{OWNER}/{REPO}/releases/{rel['id']}")
    elif st != 404:
        raise SystemExit(f"查询 release 失败 {st}: {rel}")

    st, rel = call("POST", f"{API}/repos/{OWNER}/{REPO}/releases", {
        "tag_name": tag,
        "target_commitish": target,
        "name": f"像素工大 {tag}",
        "body": body,
        "draft": False,
        "prerelease": False,
    })
    if st not in (200, 201):
        raise SystemExit(f"创建 release 失败 {st}: {rel}")
    print(f"[release] 已创建 {tag} on {target} -> {rel['html_url']}")

    upload_url = rel["upload_url"].split("{")[0]
    for path in assets:
        name = os.path.basename(path)
        size = os.path.getsize(path)
        print(f"[upload] {name}  {size/1048576:.1f} MB ...", flush=True)
        st, res = call("POST", f"{upload_url}?name={name}", raw_path=path)
        if st not in (200, 201):
            raise SystemExit(f"上传 {name} 失败 {st}: {res}")
        want = sha256(path)
        got = (res.get("digest") or "").replace("sha256:", "") or res.get("digest", "")
        ok = (got == want) if got else None
        print(f"[upload] OK  server_digest={'一致' if ok else ('缺失' if ok is None else '不一致!')}"
              f"  sha256={want[:16]}…")
        if ok is False:
            raise SystemExit(f"{name} 校验失败")

    st, rel = call("GET", f"{API}/repos/{OWNER}/{REPO}/releases/tags/{tag}")
    print(f"\n[verify] {len(rel['assets'])} 个资产：")
    for a in rel["assets"]:
        print(f"   {a['name']:<26} {a['size']/1048576:6.1f} MB  {a['browser_download_url']}")


if __name__ == "__main__":
    main()
