"""给角色动画资源补上坐姿（sit）四个方向。

SkyOffice 的角色图集是 52 帧：idle 24 + walk 24 + **sit 4**（48=down 49=left
50=right 51=up，各一帧）。当初生成 frames_*.tres 时只切了 idle/walk，
sit 那 4 帧留在图集里没用上 —— 这里把它们补成动画。

不改图集、不重切帧，只在 .tres 里追加 4 个 AtlasTexture + 4 个动画。
可重复执行：已经有 down_sit 就跳过。
"""
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIR = os.path.join(ROOT, "assets", "sandbox")

FRAME_W = 32
FRAME_H = 48
# 帧索引 → 方向名（顺序取自 SkyOffice client/src/anims/CharacterAnims.ts）
SIT = [(48, "down"), (49, "left"), (50, "right"), (51, "up")]


def patch(path: str) -> bool:
    src = open(path, encoding="utf-8").read()
    if "down_sit" in src:
        print("  已有 sit 动画，跳过")
        return False

    # 图集在哪：取任意一个 AtlasTexture 的 atlas 引用
    m = re.search(r'\[sub_resource type="AtlasTexture"[^\]]*\]\natlas = ExtResource\("([^"]+)"\)', src)
    if not m:
        print("  ✗ 找不到图集引用")
        return False
    atlas_ref = m.group(1)

    # ── 1) 4 个 AtlasTexture，插在 animations 之前 ──
    subs = []
    for idx, name in SIT:
        subs.append(
            f'[sub_resource type="AtlasTexture" id="AtlasTexture_sit_{name}"]\n'
            f'atlas = ExtResource("{atlas_ref}")\n'
            f'region = Rect2({idx * FRAME_W}, 0, {FRAME_W}, {FRAME_H})\n'
        )
    # ⚠️ 必须插在 `[resource]` 之前。放在它后面（比如紧贴 `animations = [`）
    #    会变成「主资源里冒出 sub_resource 标签」，Godot 直接 Parse Error:
    #    Extra tag found when parsing main resource file.
    marker = "[resource]"
    if marker not in src:
        print("  ✗ 找不到 [resource] 段")
        return False
    src = src.replace(marker, "\n".join(subs) + "\n" + marker, 1)

    # ── 2) 4 个动画追加到数组末尾（loop=0：单帧，别循环播） ──
    blocks = []
    for _, name in SIT:
        blocks.append(
            '}, {\n'
            '"frames": [{\n'
            '"duration": 1.0,\n'
            f'"texture": SubResource("AtlasTexture_sit_{name}")\n'
            '}],\n'
            '"loop": 0,\n'
            f'"name": &"{name}_sit",\n'
            '"speed": 1.0'
        )
    tail = src.rstrip()
    assert tail.endswith("}]"), "animations 数组结尾格式变了：" + tail[-20:]
    src = tail[:-2] + "\n".join(blocks) + "\n}]\n"

    open(path, "w", encoding="utf-8", newline="\n").write(src)
    return True


def main() -> None:
    n = 0
    for fn in sorted(os.listdir(DIR)):
        if not (fn.startswith("frames_") and fn.endswith(".tres")):
            continue
        print(fn)
        if patch(os.path.join(DIR, fn)):
            n += 1
    print(f"完成：{n} 个文件已补 sit 动画")


if __name__ == "__main__":
    main()
