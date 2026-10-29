"""从项目文本里收集用到的字符，把 Noto Sans SC 子集化成游戏内嵌字体。

网页版没有系统字体可回退，不内嵌字体的话中文全是方块。
"""
import json
import os
import re
import sys

from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.environ.get("NOTO_SC", r"C:/Windows/Fonts/NotoSansSC-VF.ttf")  # Noto Sans SC 变量字体
OUT_DIR = os.path.join(ROOT, "assets/fonts")
OUT = os.path.join(OUT_DIR, "noto_sc_game.ttf")

chars = set()


def add_text(s: str):
    for ch in s:
        if ch.isprintable():
            chars.add(ch)


def walk_json(o):
    if isinstance(o, str):
        add_text(o)
    elif isinstance(o, dict):
        for v in o.values():
            walk_json(v)
    elif isinstance(o, list):
        for v in o:
            walk_json(v)


# 1) world.json 里的所有文案（楼名 / POI / 分类）
with open(os.path.join(ROOT, "assets/world.json"), encoding="utf-8") as f:
    walk_json(json.load(f))

# 2) 脚本与场景里引号内的字符串
STR_RE = re.compile(r'"((?:[^"\\]|\\.)*)"')
for dirpath, dirnames, filenames in os.walk(ROOT):
    dirnames[:] = [d for d in dirnames if d not in (".godot", "build", "addons", "tools")]
    for fn in filenames:
        if not fn.endswith((".gd", ".tscn", ".tres", ".cfg")):
            continue
        p = os.path.join(dirpath, fn)
        try:
            src = open(p, encoding="utf-8").read()
        except (UnicodeDecodeError, OSError):
            continue
        for m in STR_RE.finditer(src):
            add_text(m.group(1))

# 3) 基础 ASCII + 常用中文标点（数字/西文/坐标等运行时拼出来的）
for i in range(32, 127):
    chars.add(chr(i))
add_text("　、。，．·：；！？（）【】《》“”‘’—…～±×÷°①②③④⑤→←↑↓▲▼■□●○★☆·ⅠⅡⅢ")

chars.discard("\n")
chars.discard("\r")
chars.discard("\t")

text = "".join(sorted(chars))
print("字符数:", len(text))

os.makedirs(OUT_DIR, exist_ok=True)

# 4) 把可变字体固定到 wght=500（UI 主体用中等偏粗，像素风里更清楚）
f = TTFont(SRC)
inst = instantiateVariableFont(f, {"wght": 500}, updateFontNames=False)
tmp = os.path.join(OUT_DIR, "_tmp_static.ttf")
inst.save(tmp)

# 5) 子集化
from fontTools.subset import Subsetter, Options

font = TTFont(tmp)
opts = Options()
opts.layout_features = ["*"]
opts.name_IDs = ["*"]
opts.name_legacy = True
opts.name_languages = ["*"]
opts.notdef_outline = True
opts.recommended_glyphs = True
opts.glyph_names = True
sub = Subsetter(options=opts)
sub.populate(text=text)
sub.subset(font)
font.save(OUT)
os.remove(tmp)

print("输出:", OUT, os.path.getsize(OUT) // 1024, "KB")
with open(os.path.join(OUT_DIR, "chars.txt"), "w", encoding="utf-8") as f:
    f.write(text)
