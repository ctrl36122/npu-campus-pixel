"""把 PNG 裁剪并放大，便于人工/AI 核对像素细节。用法: python3 tools/crop.py src x0 y0 x1 y1 [scale] [out]"""
import sys, zlib, struct


def decode(path):
    d = open(path, 'rb').read(); pos = 8; w = h = colt = None; idat = b""
    while pos < len(d):
        ln = struct.unpack(">I", d[pos:pos + 4])[0]; typ = d[pos + 4:pos + 8]; ch = d[pos + 8:pos + 8 + ln]
        if typ == b"IHDR":
            w, h, _, colt = struct.unpack(">IIBB", ch[:10])
        elif typ == b"IDAT":
            idat += ch
        elif typ == b"IEND":
            break
        pos += 12 + ln
    raw = zlib.decompress(idat); ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colt]; stride = w * ch
    out = bytearray(); prev = bytearray(stride); p = 0
    for _ in range(h):
        f = raw[p]; p += 1; line = bytearray(raw[p:p + stride]); p += stride
        for i in range(stride):
            a = line[i - ch] if i >= ch else 0; b = prev[i]; c = prev[i - ch] if i >= ch else 0
            if f == 1:
                line[i] = (line[i] + a) & 255
            elif f == 2:
                line[i] = (line[i] + b) & 255
            elif f == 3:
                line[i] = (line[i] + ((a + b) >> 1)) & 255
            elif f == 4:
                pp = a + b - c; pa = abs(pp - a); pb = abs(pp - b); pc = abs(pp - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c); line[i] = (line[i] + pr) & 255
        out += line; prev = line
    return w, h, ch, bytes(out)


def enc(path, w, h, ch, px):
    raw = bytearray(); stride = w * ch
    for y in range(h):
        raw.append(0); raw += px[y * stride:(y + 1) * stride]
    comp = zlib.compress(bytes(raw), 9); colt = 2 if ch == 3 else 6
    out = bytearray(b"\x89PNG\r\n\x1a\n")

    def ck(t, b):
        out.extend(struct.pack(">I", len(b))); out.extend(t); out.extend(b)
        out.extend(struct.pack(">I", zlib.crc32(t + b) & 0xFFFFFFFF))
    ck(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, colt, 0, 0, 0)); ck(b"IDAT", comp); ck(b"IEND", b"")
    open(path, "wb").write(out)


def crop(src, x0, y0, x1, y1, S, dst):
    w, h, ch, px = decode(src)
    x0 = max(0, min(x0, w - 1)); y0 = max(0, min(y0, h - 1))
    x1 = max(x0 + 1, min(x1, w)); y1 = max(y0 + 1, min(y1, h))
    cw, chh = x1 - x0, y1 - y0
    o = bytearray(cw * S * chh * S * 4)
    for oy in range(chh * S):
        sy = y0 + oy // S
        for ox in range(cw * S):
            sx = x0 + ox // S; si = (sy * w + sx) * ch; di = (oy * cw * S + ox) * 4
            o[di] = px[si]; o[di + 1] = px[si + 1]; o[di + 2] = px[si + 2]; o[di + 3] = px[si + 3] if ch == 4 else 255
    enc(dst, cw * S, chh * S, 4, bytes(o))
    print("%s  %dx%d  (src %dx%d crop %d,%d-%d,%d x%d)" % (dst, cw * S, chh * S, w, h, x0, y0, x1, y1, S))


if __name__ == "__main__":
    a = sys.argv
    src = a[1]; x0, y0, x1, y1 = int(a[2]), int(a[3]), int(a[4]), int(a[5])
    S = int(a[6]) if len(a) > 6 else 4
    dst = a[7] if len(a) > 7 else "crop_out.png"
    crop(src, x0, y0, x1, y1, S, dst)
