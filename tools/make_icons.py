"""把西工大校徽（像素风）做成各平台的应用图标。

源图是截图，背景是 PS 的透明棋盘格（两种浅灰），已经烤进像素里。
所以不能用「取色转透明」，而是按「蓝色纯度」反推 alpha：
    灰底 (211,212,214) → 蓝度 0
    校徽蓝 (2,45,114)  → 蓝度 ~90
边缘抗锯齿像素落在中间 → 得到干净的半透明边，不发白边。

用法：python tools/make_icons.py
产出：
    assets/icon.png            512×512  项目图标 / Windows 窗口图标
    assets/icon.ico            多尺寸   Windows exe 图标
    assets/icon_192.png        192×192  Android 传统图标
    assets/icon_fg_432.png     432×432  Android 自适应前景（留安全区）
    assets/icon_bg_432.png     432×432  Android 自适应背景（纯色）
    assets/icon_512_web.png    512×512  Web/PWA 图标
"""

import os
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets")
SRC = os.path.join(OUT, "icon_source.jpg")   # 校徽原图（含棋盘格透明底），改图标就换这张

INK = (2, 45, 114)          # 校徽蓝
BG = (251, 252, 255)        # 自适应背景：near-white，衬托蓝色


def blueness(px):
    r, g, b = px[0], px[1], px[2]
    return b - (r + g) * 0.5


def build_master() -> Image.Image:
    im = Image.open(SRC).convert("RGB")
    w, h = im.size
    px = im.load()

    # 1) 反推 alpha：蓝度 12 以下全透明，60 以上不透明，中间线性
    alpha = Image.new("L", (w, h), 0)
    ap = alpha.load()
    for y in range(h):
        for x in range(w):
            v = blueness(px[x, y])
            if v <= 12.0:
                a = 0
            elif v >= 60.0:
                a = 255
            else:
                a = int((v - 12.0) / 48.0 * 255.0)
            ap[x, y] = a

    # 2) 统一成校徽蓝（原图是单色徽，JPEG 噪点直接抹平，边缘更干净）
    flat = Image.new("RGBA", (w, h), INK + (0,))
    flat.putalpha(alpha)

    # 3) 裁到内容、留 6% 边距、补成正方形
    box = alpha.getbbox()
    art = flat.crop(box)
    side = int(max(art.size) * 1.12)
    canvas = Image.new("RGBA", (side, side), INK + (0,))
    canvas.paste(art, ((side - art.width) // 2, (side - art.height) // 2), art)
    return canvas.resize((1024, 1024), Image.LANCZOS)


def square(img: Image.Image, size: int, scale: float, bg=None) -> Image.Image:
    """把图按 scale 缩进 size×size 画布（bg 为 None 时透明），用于自适应图标的安全区。"""
    inner = max(1, int(size * scale))
    art = img.resize((inner, inner), Image.LANCZOS)
    out = Image.new("RGBA", (size, size), (bg + (255,)) if bg else (0, 0, 0, 0))
    out.paste(art, ((size - inner) // 2, (size - inner) // 2), art)
    return out


def plated(size: int, scale: float, radius_ratio: float = 0.20, master=None) -> Image.Image:
    """浅色圆角底板 + 校徽。深色桌面/任务栏上透明底的深蓝徽几乎看不见，
    所以 exe 图标、网页图标都自带一块接近白的底板，和 Android 自适应图标观感一致。"""
    img = master if master is not None else Image.open(os.path.join(OUT, "icon_master.png"))
    inner = max(1, int(size * scale))
    art = img.resize((inner, inner), Image.LANCZOS)
    plate = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(plate)
    r = int(size * radius_ratio)
    d.rounded_rectangle((0, 0, size - 1, size - 1), radius=r, fill=BG + (255,))
    plate.alpha_composite(art, ((size - inner) // 2, (size - inner) // 2))
    return plate


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    master = build_master()
    master.save(os.path.join(OUT, "icon_master.png"))

    plated(512, 0.80, master=master).save(os.path.join(OUT, "icon.png"))
    plated(512, 0.80, master=master).save(os.path.join(OUT, "icon_512_web.png"))
    plated(192, 0.84, master=master).save(os.path.join(OUT, "icon_192.png"))
    # 自适应前景：Android 会裁掉外围，内容压到 62%（安全区 66% 直径以内）
    square(master, 432, 0.62).save(os.path.join(OUT, "icon_fg_432.png"))
    # 自适应背景：纯色（不能是透明，否则部分启动器显示成黑色）
    Image.new("RGBA", (432, 432), BG + (255,)).save(os.path.join(OUT, "icon_bg_432.png"))

    plated(256, 0.80, master=master).save(
        os.path.join(OUT, "icon.ico"),
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )

    for fn in ("icon.png", "icon.ico", "icon_192.png", "icon_fg_432.png", "icon_bg_432.png"):
        p = os.path.join(OUT, fn)
        print("%-20s %6.1f KB" % (fn, os.path.getsize(p) / 1024))


if __name__ == "__main__":
    main()
