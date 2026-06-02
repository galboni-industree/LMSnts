#!/usr/bin/env python3
"""Generate a square NTS icon (white "NTS" wordmark on black) with no deps.

Pure stdlib (zlib/struct). The three letters are drawn as geometric vector
shapes and rasterised with 4x supersampling for smooth, anti-aliased edges:

  N  -> two vertical bars + a thick diagonal
  T  -> top bar + centred stem
  S  -> two 270-degree rings (missing opposite quadrants) = classic geometric S

This is a faithful reconstruction of the NTS wordmark, not the official SVG
(which can't be fetched from this sandbox). Swap in the real asset if desired.
"""
import math
import struct
import sys
import zlib

N = 512                 # canvas size
SS = 4                  # supersampling factor (SS*SS samples per pixel)
BG = (0, 0, 0)
FG = (255, 255, 255)

# Layout (in final 512px space)
H = 230                 # cap height
T = 40                  # stroke thickness
W = 132                 # letter width
GAP = 26
Y0 = (N - H) / 2.0      # = 141
X_N = (N - (3 * W + 2 * GAP)) / 2.0   # left margin, = 32
X_T = X_N + W + GAP
X_S = X_T + W + GAP


def _dist_seg(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    L2 = dx * dx + dy * dy
    if L2 == 0:
        return math.hypot(px - ax, py - ay)
    t = ((px - ax) * dx + (py - ay) * dy) / L2
    t = 0.0 if t < 0 else 1.0 if t > 1 else t
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def inside(x, y):
    # --- N ---
    nx = X_N
    if Y0 <= y <= Y0 + H:
        if nx <= x <= nx + T:                 # left bar
            return True
        if nx + W - T <= x <= nx + W:          # right bar
            return True
        if _dist_seg(x, y, nx + T / 2, Y0, nx + W - T / 2, Y0 + H) <= T / 2:
            return True                        # diagonal

    # --- T ---
    tx = X_T
    cx = tx + W / 2
    if tx <= x <= tx + W and Y0 <= y <= Y0 + T:        # top bar
        return True
    if cx - T / 2 <= x <= cx + T / 2 and Y0 <= y <= Y0 + H:  # stem
        return True

    # --- S --- two thick rings, opposite quadrants removed
    r = W / 2.0
    scx = X_S + r
    ri = r - T
    c1y = Y0 + r            # top ring centre
    c2y = Y0 + H - r        # bottom ring centre
    d1 = math.hypot(x - scx, y - c1y)
    if ri <= d1 <= r and not (x > scx and y > c1y):     # drop lower-right
        return True
    d2 = math.hypot(x - scx, y - c2y)
    if ri <= d2 <= r and not (x < scx and y < c2y):     # drop upper-left
        return True

    return False


def build_pixels():
    px = [[BG] * N for _ in range(N)]
    inv = 1.0 / (SS * SS)
    offs = [(i + 0.5) / SS for i in range(SS)]
    for y in range(N):
        row = px[y]
        for x in range(N):
            hits = 0
            for oy in offs:
                fy = y + oy
                for ox in offs:
                    if inside(x + ox, fy):
                        hits += 1
            if hits:
                c = hits * inv
                row[x] = tuple(int(BG[i] + (FG[i] - BG[i]) * c) for i in range(3))
    return px


def write_png(path, px):
    raw = bytearray()
    for row in px:
        raw.append(0)
        for (r, g, b) in row:
            raw += bytes((r, g, b))

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", N, N, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        f.write(chunk(b"IEND", b""))


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "icon.png"
    write_png(out, build_pixels())
    print(f"wrote {out} ({N}x{N}, {SS}x supersampled)")
