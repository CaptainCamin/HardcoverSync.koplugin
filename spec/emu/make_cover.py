#!/usr/bin/env python3
"""Writes spec/emu/fixtures/cover.png: a synthetic book cover for the emulator.

Not a real cover. It is a grayscale picture with a border, a sun, and blocks
standing in for the title and author, so a screenshot shows where a cover goes
and how it is scaled and bordered, without shipping anyone's artwork. Standard
library only (no Pillow), so it runs anywhere:

    python3 spec/emu/make_cover.py
"""
import struct, zlib, os, math

W, H = 240, 360

def pixel(x, y):
    # vertical gradient, dark at the top
    v = 70 + int(110 * y / H)
    # frame
    if x < 10 or x >= W - 10 or y < 10 or y >= H - 10:
        return 20
    if x < 14 or x >= W - 14 or y < 14 or y >= H - 14:
        return 235
    # a sun
    cx, cy, r = W // 2, 215, 62
    d = math.hypot(x - cx, y - cy)
    if d < r:
        return 245
    if d < r + 4:
        return 25
    # horizon band
    if 262 <= y < 330:
        return 40 if (x // 6 + y // 6) % 2 == 0 else 55
    # title blocks
    if 50 <= y < 66 and 36 <= x < W - 36:
        return 250
    if 76 <= y < 92 and 60 <= x < W - 60:
        return 250
    # author block
    if 120 <= y < 130 and 80 <= x < W - 80:
        return 225
    return v

raw = b"".join(b"\x00" + bytes(pixel(x, y) for x in range(W)) for y in range(H))

def chunk(tag, data):
    c = struct.pack(">I", len(data)) + tag + data
    return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 0, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw, 9))
       + chunk(b"IEND", b""))

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "cover.png")
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "wb") as f:
    f.write(png)
print(out, len(png), "bytes", f"{W}x{H}")
