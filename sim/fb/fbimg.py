#!/usr/bin/env python3
"""V2 image helpers.

  fbimg.py pattern <out.hex>          write the synthetic 288x224 RGB 3:3:2 source image
                                      (the core's active picture as it draws it, before
                                      rotation) for tb_fb.sv, row by row
  fbimg.py png <in.ppm> [<out.png>]   convert a binary PPM written by tb_fb.sv to PNG
  fbimg.py srcpng <in.hex> <out.png>  the source image as PNG, for comparison
  fbimg.py stream <in.hex> <out.bin> <frames>
                                      the source image as a V1-format stream.bin (the core's
                                      384 x 264 raster from the frame start, see
                                      sim/core/frames.py), to test tb_fb.sv's +stream input

The pattern is meant to make the rotation direction and any mirroring obvious: a coloured
border per edge (top red, bottom white, left green, right blue), a big letter F near the top
left corner, the word TOP near the top edge, L / R / B near the left, right and bottom edges,
and a grid of 20-pixel cells numbered along the top (columns) and the right (rows). Turned
clockwise, as on the cabinet, the image's left edge (green) is at the top.
No third-party modules.
"""

import struct
import sys
import zlib

W, H = 288, 224

FONT = {   # 5x7, rows top to bottom, bit 4 = left
    '0': [0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E],
    '1': [0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E],
    '2': [0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F],
    '3': [0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E],
    '4': [0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02],
    '5': [0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E],
    '6': [0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E],
    '7': [0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08],
    '8': [0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E],
    '9': [0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C],
    'T': [0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04],
    'O': [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
    'P': [0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10],
    'F': [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10],
    'L': [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F],
    'R': [0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11],
    'B': [0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E],
}


def rgb332(r, g, b):
    return (r << 5) | (g << 2) | b


def pattern():
    img = [[rgb332(1, 1, 0)] * W for _ in range(H)]

    def put(x, y, c):
        if 0 <= x < W and 0 <= y < H:
            img[y][x] = c

    def text(s, x, y, c, scale=1):
        for ch in s:
            for row, bits in enumerate(FONT[ch]):
                for col in range(5):
                    if bits & (0x10 >> col):
                        for dy in range(scale):
                            for dx in range(scale):
                                put(x + col * scale + dx, y + row * scale + dy, c)
            x += 6 * scale

    grid = rgb332(3, 3, 1)
    for i in range(0, W, 20):
        for j in range(H):
            put(i, j, grid)
    for i in range(0, H, 20):
        for j in range(W):
            put(j, i, grid)
    for n in range(W // 20):
        text(str(n % 10), n * 20 + 3, 5, rgb332(5, 5, 2))    # column numbers, top
    for n in range(H // 20):
        text(str(n % 10), W - 18, n * 20 + 7, rgb332(5, 5, 2))  # row numbers, right
    for j in range(W):
        for k in range(3):
            put(j, k, rgb332(7, 0, 0))                       # top: red
            put(j, H - 1 - k, rgb332(7, 7, 3))               # bottom: white
    for j in range(H):
        for k in range(3):
            put(k, j, rgb332(0, 7, 0))                       # left: green
            put(W - 1 - k, j, rgb332(0, 0, 3))               # right: blue
    text('F', 24, 24, rgb332(7, 7, 0), 7)                    # big F, top left
    text('TOP', W // 2 - 27, 30, rgb332(0, 7, 3), 3)
    text('L', 10, H // 2 - 10, rgb332(0, 7, 0), 3)
    text('R', W - 44, H // 2 - 10, rgb332(0, 0, 3), 3)
    text('B', W // 2 - 8, H - 35, rgb332(7, 7, 3), 3)
    return img


def write_png(path, w, h, rows):
    raw = b''.join(b'\x00' + bytes(r) for r in rows)

    def chunk(t, d):
        c = struct.pack('>I', len(d)) + t + d
        return c + struct.pack('>I', zlib.crc32(t + d) & 0xFFFFFFFF)

    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b'IDAT', zlib.compress(raw, 9)))
        f.write(chunk(b'IEND', b''))


def read_ppm(path):
    data = open(path, 'rb').read()
    parts = data.split(maxsplit=4)
    assert parts[0] == b'P6'
    w, h = int(parts[1]), int(parts[2])
    pix = parts[4]
    return w, h, [pix[y * w * 3:(y + 1) * w * 3] for y in range(h)]


def c332(p):
    r, g, b = p >> 5, (p >> 2) & 7, p & 3
    return [(r << 5) | (r << 2) | (r >> 1), (g << 5) | (g << 2) | (g >> 1), b * 0x55]


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == 'pattern':
        img = pattern()
        with open(sys.argv[2], 'w') as f:
            for row in img:
                for p in row:
                    f.write('%02x\n' % p)
    elif len(sys.argv) >= 3 and sys.argv[1] == 'png':
        out = sys.argv[3] if len(sys.argv) > 3 else sys.argv[2].rsplit('.', 1)[0] + '.png'
        w, h, rows = read_ppm(sys.argv[2])
        write_png(out, w, h, rows)
    elif len(sys.argv) >= 5 and sys.argv[1] == 'stream':
        # the pattern as a V1-format stream.bin (frames.py: 2 bytes per pixel enable from the
        # frame start; blankn high for pixels 57..344 of lines 16..239, vs low on lines
        # 260..263 and 0..2), to test the stream input of tb_fb.sv
        vals = [int(l, 16) for l in open(sys.argv[2]) if l.strip()]
        out = bytearray()
        for _ in range(int(sys.argv[4])):
            for y in range(264):
                for x in range(384):
                    act = 57 <= x < 57 + W and 16 <= y < 16 + H
                    vs = 0 if (y >= 260 or y < 3) else 1
                    px = vals[(y - 16) * W + x - 57] if act else 0xE3
                    out += bytes([px, int(act) | 2 | (vs << 2) | 8])
        open(sys.argv[3], 'wb').write(out)
    elif len(sys.argv) >= 4 and sys.argv[1] == 'srcpng':
        vals = [int(l, 16) for l in open(sys.argv[2]) if l.strip()]
        rows = []
        for y in range(H):
            r = []
            for x in range(W):
                r += c332(vals[y * W + x])
            rows.append(r)
        write_png(sys.argv[3], W, H, rows)
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == '__main__':
    main()
