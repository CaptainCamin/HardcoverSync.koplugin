#!/usr/bin/env python3
"""Writes spec/emu/fixtures/cover.png, cover_b.png and cover_c.png: synthetic
book covers for the emulator.

Not real covers. Each is a grayscale picture with a border and blocks standing in
for the title and author, plus a different motif (a sun, a mountain, stripes), so
a strip of covers in a screenshot looks like different books, without shipping
anyone's artwork. Standard library only (no Pillow), so it runs anywhere:

    python3 spec/emu/make_cover.py
"""
import struct, zlib, os, math

W, H = 240, 360

def frame(x, y):
    if x < 10 or x >= W - 10 or y < 10 or y >= H - 10:
        return 20
    if x < 14 or x >= W - 14 or y < 14 or y >= H - 14:
        return 235
    return None

def title_blocks(x, y):
    if 50 <= y < 66 and 36 <= x < W - 36:
        return 250
    if 76 <= y < 92 and 60 <= x < W - 60:
        return 250
    if 120 <= y < 130 and 80 <= x < W - 80:
        return 225
    return None

def sun(x, y):
    v = 70 + int(110 * y / H)  # vertical gradient, dark at the top
    f = frame(x, y)
    if f is not None: return f
    cx, cy, r = W // 2, 215, 62
    d = math.hypot(x - cx, y - cy)
    if d < r: return 245
    if d < r + 4: return 25
    if 262 <= y < 330:
        return 40 if (x // 6 + y // 6) % 2 == 0 else 55
    t = title_blocks(x, y)
    return t if t is not None else v

def mountain(x, y):
    v = 200 - int(120 * y / H)  # light at the top, dark below
    f = frame(x, y)
    if f is not None: return f
    # a triangle
    apex_x, apex_y, base_y = W // 2, 150, 320
    if y >= apex_y and y <= base_y:
        half = (y - apex_y) * 0.55
        if abs(x - apex_x) <= half:
            return 30 if abs(x - apex_x) > half - 5 else 70
    t = title_blocks(x, y)
    if t is not None: return 30  # dark blocks on a light cover
    return v

def stripes(x, y):
    f = frame(x, y)
    if f is not None: return f
    t = title_blocks(x, y)
    if t is not None: return 245
    if y >= 150:
        return 45 if ((y - 150) // 18) % 2 == 0 else 150
    return 110

def make(name, fn):
    raw = b"".join(b"\x00" + bytes(fn(x, y) for x in range(W)) for y in range(H))
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 0, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", name)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "wb") as f:
        f.write(png)
    print(out, len(png), "bytes", f"{W}x{H}")

def chunk(tag, data):
    c = struct.pack(">I", len(data)) + tag + data
    return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

make("cover.png", sun)
make("cover_b.png", mountain)
make("cover_c.png", stripes)
