#!/usr/bin/env python3
# Convert binary PPM images (scripts/world.lua QA images, one pixel per 8-tile cell) to PNG, scaled up.
# Usage: python3 -I tools/ppm2png.py <out-dir> <file.ppm> ...
import sys, zlib, struct, os
def read_ppm(path):
    data = open(path, "rb").read()
    parts = data.split(b"\n", 3)
    assert parts[0] == b"P6"
    w, h = map(int, parts[1].split())
    return w, h, parts[3]
def write_png(path, w, h, rgb, scale=1):
    rows = []
    for y in range(h):
        row = rgb[y*w*3:(y+1)*w*3]
        if scale > 1:
            row = b"".join(row[i:i+3] * scale for i in range(0, len(row), 3))
        for _ in range(scale):
            rows.append(b"\x00" + row)
    raw = b"".join(rows)
    def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w*scale, h*scale, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(png)
for p in sys.argv[2:]:
    w, h, rgb = read_ppm(p)
    out = os.path.join(sys.argv[1], os.path.basename(p).replace(".ppm", ".png"))
    write_png(out, w, h, rgb, scale=3 if w <= 256 else 2)
    print(out)
