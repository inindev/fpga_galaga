#!/usr/bin/env python3
"""Pictures, visible window, pixel stream and audio from the V1 testbench output.

Usage:
  frames.py <stream.bin> --info [--first N]
  frames.py <stream.bin> --window [--first N]
  frames.py <stream.bin> --png N[,N...] [--outdir DIR] [--active] [--rotate cw|ccw|180]
  frames.py <stream.bin> --flips
  frames.py <stream.bin> --rot180 A B [--outdir DIR]
  frames.py <stream.bin> --stream FIRST COUNT <out.hex>
  frames.py <audio.bin> --wav <out.wav>

stream.bin (written by tb_v1.vhd): 2 bytes per pixel enable of the core, from
the first pixel of frame 0 (hcnt 192, vcnt 0), 384 x 264 = 101376 per frame:
  byte 0: r[2:0] g[2:0] b[1:0] (bit 7 = r[2] ... bit 0 = b[0])
  byte 1: bit 0 blankn, bit 1 hs, bit 2 vs, bit 3 csync, bit 4 flip_h (the
          game's screen flip, 0xA007; not a core output)
Frame N is samples N*101376 to (N+1)*101376-1, drawn 384 wide, 264 high (x:
hcnt 192..511, 128..191; y: vcnt 0..263). The game's monitor is turned: the
picture is upright when this raster is turned clockwise (MAME ROT90).

--info: the active picture (blankn = 1) of every frame: its size and position
in the 384 x 264 raster, and whether it is the same in all frames (frames
from --first on, default 0).

--window: lit pixels (colour not 0) outside the active picture, and how many
frames have a lit pixel in each edge column and row of the active picture
and in the columns and rows just outside it (frames from --first on).

--png: frame N as <outdir>/frame_NNNN.png (whole raster, blanking dimmed and
tinted; with --active, only the active picture; --rotate turns the picture,
cw shows it upright as on the cabinet).

--flips: the frames where flip_h changes.

--rot180: compares the active picture of frame A with frame B turned by 180
degrees: the number of differing pixels, and A, B turned and a difference
picture as PNG files (differences in white).

--stream: the pixel stream for the frame buffer test (V2): COUNT whole frames
starting at frame FIRST. Text, one line per pixel enable, 4 hex digits
($readmemh):
  bits 7:0  pixel, RGB 3:3:2: r[2:0] g[2:0] b[1:0] (as video_r, video_g, video_b)
  bit 8     blankn        bit 9   hs
  bit 10    vs            bit 11  csync
  bit 12    flip_h
Consecutive frames continue the stream without a gap (the core's timing: 384
pixel enables per line, 264 lines, at 6.144 MHz = 60.61 Hz).

--wav: audio.bin (16-bit little-endian samples of the core's 10-bit unsigned
audio, one per 128 pixel enables, 6.144 MHz / 128 = 48 kHz) as a WAV file.
"""
import argparse
import os
import struct
import sys
import zlib

W, H = 384, 264
FRAME = W * H


def load(path):
    with open(path, 'rb') as f:
        d = f.read()
    return d[0::2], d[1::2]


def png(path, w, h, rows):
    raw = b''.join(b'\x00' + bytes(r) for r in rows)

    def chunk(t, b):
        c = struct.pack('>I', len(b)) + t + b
        return c + struct.pack('>I', zlib.crc32(t + b) & 0xffffffff)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b'IDAT', zlib.compress(raw, 9)))
        f.write(chunk(b'IEND', b''))


def rgb(p):
    r, g, b = p >> 5, (p >> 2) & 7, p & 3
    return (r * 255 // 7, g * 255 // 7, b * 255 // 3)


def active_box(ctl, n):
    base = n * FRAME
    xs, ys, count = set(), set(), 0
    for i in range(FRAME):
        if ctl[base + i] & 1:
            xs.add(i % W)
            ys.add(i // W)
            count += 1
    if not count:
        return None
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    rect = count == (x1 - x0 + 1) * (y1 - y0 + 1)
    return (x0, y0, x1 - x0 + 1, y1 - y0 + 1, rect)


def turn(grid, how):
    """grid: list of rows. how: cw, ccw, 180 or None."""
    if how == 'cw':
        return [list(r) for r in zip(*grid[::-1])]
    if how == 'ccw':
        return [list(r) for r in zip(*grid)][::-1]
    if how == '180':
        return [r[::-1] for r in grid[::-1]]
    return grid


def grid_of(pix, n, box):
    x0, y0, w, h = box[:4]
    base = n * FRAME
    return [[pix[base + y * W + x] for x in range(x0, x0 + w)] for y in range(y0, y0 + h)]


def write_grid(path, grid, colour=rgb):
    rows = []
    for r in grid:
        row = []
        for p in r:
            row.extend(colour(p))
        rows.append(row)
    png(path, len(grid[0]), len(grid), rows)
    print(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('file')
    ap.add_argument('--info', action='store_true')
    ap.add_argument('--window', action='store_true')
    ap.add_argument('--first', type=int, default=0)
    ap.add_argument('--png')
    ap.add_argument('--active', action='store_true')
    ap.add_argument('--rotate', choices=['cw', 'ccw', '180'])
    ap.add_argument('--outdir', default='.')
    ap.add_argument('--flips', action='store_true')
    ap.add_argument('--rot180', nargs=2, type=int, metavar=('A', 'B'))
    ap.add_argument('--stream', nargs=3, metavar=('FIRST', 'COUNT', 'OUT'))
    ap.add_argument('--wav')
    a = ap.parse_args()

    if a.wav:
        with open(a.file, 'rb') as f:
            d = f.read()
        s = struct.unpack('<%dH' % (len(d) // 2), d)
        pcm = b''.join(struct.pack('<h', (v << 6) - 32768) for v in s)
        rate = 48000
        with open(a.wav, 'wb') as f:
            f.write(b'RIFF' + struct.pack('<I', 36 + len(pcm)) + b'WAVE')
            f.write(b'fmt ' + struct.pack('<IHHIIHH', 16, 1, 1, rate, rate * 2, 2, 16))
            f.write(b'data' + struct.pack('<I', len(pcm)) + pcm)
        print('%s: %d samples, min %d, max %d, %d distinct values' %
              (a.wav, len(s), min(s), max(s), len(set(s))))
        return

    pix, ctl = load(a.file)
    frames = len(ctl) // FRAME
    print('%s: %d samples, %d whole frames' % (a.file, len(ctl), frames))

    if a.info:
        boxes = {}
        for n in range(a.first, frames):
            boxes.setdefault(active_box(ctl, n), []).append(n)
        for b, ns in boxes.items():
            if b is None:
                print('no active picture: %d frames (%d..%d)' % (len(ns), ns[0], ns[-1]))
            else:
                print('active %d x %d at x %d, y %d of the 384 x 264 raster%s: %d frames (%d..%d)' %
                      (b[2], b[3], b[0], b[1], '' if b[4] else ' (NOT a rectangle)',
                       len(ns), ns[0], ns[-1]))

    if a.window:
        box = active_box(ctl, a.first)
        x0, y0, w, h = box[:4]
        x1, y1 = x0 + w - 1, y0 + h - 1
        print('active picture of frame %d: x %d..%d, y %d..%d' % (a.first, x0, x1, y0, y1))
        outside = 0
        out_frames = 0
        cols = {x: 0 for x in (x0 - 2, x0 - 1, x0, x0 + 1, x1 - 1, x1, x1 + 1, x1 + 2)}
        rows = {y: 0 for y in (y0 - 2, y0 - 1, y0, y0 + 1, y1 - 1, y1, y1 + 1, y1 + 2)}
        out_x, out_y = {}, {}
        for n in range(a.first, frames):
            base = n * FRAME
            lit_c, lit_r = set(), set()
            o = 0
            for i in range(FRAME):
                p = pix[base + i]
                if not p:
                    continue
                x, y = i % W, i // W
                if not ctl[base + i] & 1:
                    o += 1
                    out_x[x] = out_x.get(x, 0) + 1
                    out_y[y] = out_y.get(y, 0) + 1
                if x in cols and y0 <= y <= y1:
                    lit_c.add(x)
                if y in rows and x0 <= x <= x1:
                    lit_r.add(y)
            outside += o
            out_frames += o > 0
            for x in lit_c:
                cols[x] += 1
            for y in lit_r:
                rows[y] += 1
        nf = frames - a.first
        print('lit pixels outside the active picture: %d, in %d of %d frames' % (outside, out_frames, nf))
        if out_x:
            print('  by column (x: count): %s' % ', '.join('%d: %d' % kv for kv in sorted(out_x.items())))
            print('  by line (y: count): %s' % ', '.join('%d: %d' % kv for kv in sorted(out_y.items())))
        print('frames with a lit pixel in column (inside lines %d..%d):' % (y0, y1))
        for x in sorted(cols):
            print('  x %d%s: %d' % (x, ' (edge)' if x in (x0, x1) else '', cols[x]))
        print('frames with a lit pixel in line (inside columns %d..%d):' % (x0, x1))
        for y in sorted(rows):
            print('  y %d%s: %d' % (y, ' (edge)' if y in (y0, y1) else '', rows[y]))

    if a.flips:
        prev = None
        for n in range(frames):
            f = ctl[n * FRAME] >> 4 & 1
            if f != prev:
                print('frame %d: flip_h %d' % (n, f))
                prev = f

    if a.png:
        os.makedirs(a.outdir, exist_ok=True)
        for n in [int(x) for x in a.png.split(',')]:
            if a.active:
                box = active_box(ctl, n)
            else:
                box = (0, 0, W, H)
            base = n * FRAME
            x0, y0, w, h = box[:4]
            grid = []
            for y in range(y0, y0 + h):
                row = []
                for x in range(x0, x0 + w):
                    i = base + y * W + x
                    c = rgb(pix[i])
                    if not ctl[i] & 1:
                        c = (c[0] // 3 + 40, c[1] // 3, c[2] // 3 + 40)
                    row.append(c)
                grid.append(row)
            grid = turn(grid, a.rotate)
            write_grid(os.path.join(a.outdir, 'frame_%04d.png' % n), grid, colour=lambda c: c)

    if a.rot180:
        fa, fb = a.rot180
        box = active_box(ctl, fa)
        ga = grid_of(pix, fa, box)
        gb = turn(grid_of(pix, fb, box), '180')
        diff = [[0 if p == q else 0xff for p, q in zip(ra, rb)] for ra, rb in zip(ga, gb)]
        nd = sum(v != 0 for r in diff for v in r)
        print('frame %d vs frame %d turned 180: %d of %d pixels differ' %
              (fa, fb, nd, len(ga) * len(ga[0])))
        os.makedirs(a.outdir, exist_ok=True)
        write_grid(os.path.join(a.outdir, 'rot_a_%04d.png' % fa), turn(ga, 'cw'))
        write_grid(os.path.join(a.outdir, 'rot_b_%04d_180.png' % fb), turn(gb, 'cw'))
        write_grid(os.path.join(a.outdir, 'rot_diff_%04d_%04d.png' % (fa, fb)), turn(diff, 'cw'))

    if a.stream:
        first, count, out = int(a.stream[0]), int(a.stream[1]), a.stream[2]
        i = first * FRAME
        if i + count * FRAME > len(ctl):
            sys.exit('not enough samples for %d frames from frame %d' % (count, first))
        with open(out, 'w') as f:
            for k in range(i, i + count * FRAME):
                f.write('%04x\n' % (((ctl[k] & 0x1f) << 8) | pix[k]))
        print('%s: %d frames from frame %d' % (out, count, first))


if __name__ == '__main__':
    main()
