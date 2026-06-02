#!/usr/bin/env python3
"""Generate a square NTS placeholder icon (white "NTS" on black) with no deps.

Produces a valid PNG using only the standard library (zlib/struct). Replace the
output with the real NTS logo for production use; this is just a clean, square
fallback so the plugin/menu/cover-art path is never missing an image.
"""
import struct
import zlib
import sys

SIZE = 512
BG = (0, 0, 0)
FG = (255, 255, 255)

# 5x7 block font for the three letters we need.
FONT = {
    "N": [
        "1...1",
        "11..1",
        "1.1.1",
        "1.1.1",
        "1..11",
        "1...1",
        "1...1",
    ],
    "T": [
        "11111",
        "..1..",
        "..1..",
        "..1..",
        "..1..",
        "..1..",
        "..1..",
    ],
    "S": [
        ".1111",
        "1....",
        "1....",
        ".111.",
        "....1",
        "....1",
        "1111.",
    ],
}


def build_pixels():
    px = [[BG for _ in range(SIZE)] for _ in range(SIZE)]

    word = "NTS"
    cell = 12                       # scale per font pixel
    gap = 2                         # blank font-columns between letters
    glyph_w = 5
    glyph_h = 7
    total_cols = len(word) * glyph_w + (len(word) - 1) * gap
    total_w = total_cols * cell
    total_h = glyph_h * cell

    ox = (SIZE - total_w) // 2
    oy = (SIZE - total_h) // 2

    col_cursor = 0
    for ch in word:
        rows = FONT[ch]
        for gy in range(glyph_h):
            for gx in range(glyph_w):
                if rows[gy][gx] == "1":
                    x0 = ox + (col_cursor + gx) * cell
                    y0 = oy + gy * cell
                    for yy in range(y0, y0 + cell):
                        for xx in range(x0, x0 + cell):
                            px[yy][xx] = FG
        col_cursor += glyph_w + gap

    return px


def write_png(path, px):
    raw = bytearray()
    for row in px:
        raw.append(0)  # filter type 0
        for (r, g, b) in row:
            raw += bytes((r, g, b))

    def chunk(tag, data):
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)  # 8-bit RGB
    idat = zlib.compress(bytes(raw), 9)

    with open(path, "wb") as f:
        f.write(sig)
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", idat))
        f.write(chunk(b"IEND", b""))


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "icon.png"
    write_png(out, build_pixels())
    print(f"wrote {out} ({SIZE}x{SIZE})")
