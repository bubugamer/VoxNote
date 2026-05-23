#!/usr/bin/env python3

import os
import struct
import subprocess
import zlib


ROOT = os.path.dirname(os.path.abspath(__file__))
ICONSET = os.path.join(ROOT, "VoxNote.iconset")
ICNS = os.path.join(ROOT, "VoxNote.icns")


def png_chunk(kind, data):
    return (
        struct.pack(">I", len(data))
        + kind
        + data
        + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    )


def write_png(path, width, height, pixels):
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        start = y * width * 4
        raw.extend(pixels[start:start + width * 4])
    data = b"\x89PNG\r\n\x1a\n"
    data += png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    data += png_chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    data += png_chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(data)


def rounded_alpha(x, y, size, radius):
    dx = min(x, size - 1 - x)
    dy = min(y, size - 1 - y)
    if dx >= radius or dy >= radius:
        return 255
    cx = radius if x < radius else size - radius - 1
    cy = radius if y < radius else size - radius - 1
    dist = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5
    edge = radius - dist
    if edge >= 1:
        return 255
    if edge <= 0:
        return 0
    return int(edge * 255)


def draw_icon(size):
    pixels = bytearray(size * size * 4)
    radius = int(size * 0.215)
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * max(1, size - 1))
            r = int(33 * (1 - t) + 20 * t)
            g = int(158 * (1 - t) + 91 * t)
            b = int(230 * (1 - t) + 180 * t)
            a = rounded_alpha(x, y, size, radius)
            idx = (y * size + x) * 4
            pixels[idx:idx + 4] = bytes((r, g, b, a))

    def rect(x0, y0, x1, y1, color=(255, 255, 255, 255)):
        for yy in range(max(0, y0), min(size, y1)):
            for xx in range(max(0, x0), min(size, x1)):
                idx = (yy * size + xx) * 4
                if pixels[idx + 3] > 0:
                    pixels[idx:idx + 4] = bytes(color)

    bars = [
        (0.21, 0.39, 0.25, 0.61),
        (0.29, 0.31, 0.33, 0.69),
        (0.37, 0.23, 0.41, 0.77),
        (0.45, 0.34, 0.49, 0.66),
    ]
    for x0, y0, x1, y1 in bars:
        rect(int(size * x0), int(size * y0), int(size * x1), int(size * y1))

    rect(int(size * 0.56), int(size * 0.34), int(size * 0.79), int(size * 0.39))
    rect(int(size * 0.56), int(size * 0.48), int(size * 0.73), int(size * 0.53))
    rect(int(size * 0.56), int(size * 0.62), int(size * 0.82), int(size * 0.67))
    return pixels


def main():
    os.makedirs(ICONSET, exist_ok=True)
    sizes = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]
    for size, name in sizes:
        write_png(os.path.join(ICONSET, name), size, size, draw_icon(size))
    subprocess.run(["iconutil", "-c", "icns", ICONSET, "-o", ICNS], check=True)


if __name__ == "__main__":
    main()
