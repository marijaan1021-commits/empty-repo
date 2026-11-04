#!/usr/bin/env python3
"""Decodes a PNG from stdin and reports whether the screen has content.

    adb exec-out screencap -p | python3 screen-check.py

Exit code 0 = the screen shows something, 1 = it is blank (all black).
A sleeping or freshly-booted emulator can hand out an all-black frame, and
printing "READY" on top of a black screen is worse than waiting.
"""
import struct
import sys
import zlib


def decode(data):
    pos, idat, width, height = 8, b"", 0, 0
    color_type = 6
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        ctype = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        if ctype == b"IHDR":
            width, height, _bits, color_type = struct.unpack(">IIBB", chunk[:10])
        elif ctype == b"IDAT":
            idat += chunk
        elif ctype == b"IEND":
            break
        pos += 12 + length

    raw = zlib.decompress(idat)
    bpp = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color_type]
    stride = width * bpp
    prev = bytearray(stride)
    rows = []
    i = 0
    for _ in range(height):
        filt = raw[i]
        i += 1
        line = bytearray(raw[i:i + stride])
        i += stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if filt == 1:
                line[x] = (line[x] + a) & 255
            elif filt == 2:
                line[x] = (line[x] + b) & 255
            elif filt == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif filt == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pred) & 255
        prev = line
        rows.append(bytes(line))
    return width, height, color_type, bpp, rows


def main():
    data = sys.stdin.buffer.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        print("no-png", file=sys.stderr)
        return 2
    width, height, color_type, bpp, rows = decode(data)
    levels = set()
    for y in range(0, height, 4):
        row = rows[y]
        for x in range(0, width, 4):
            o = x * bpp
            if color_type == 0:
                levels.add(row[o])
            else:
                levels.add((row[o] * 299 + row[o + 1] * 587 + row[o + 2] * 114) // 1000)
    blank = len(levels) <= 1 and levels and max(levels) < 24
    print(f"{width}x{height} levels={len(levels)}")
    return 1 if blank else 0


if __name__ == "__main__":
    sys.exit(main())
