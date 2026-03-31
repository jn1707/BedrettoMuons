#!/usr/bin/env python3
import struct
import zlib
from typing import List


def _png_chunk(tag: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + tag
        + data
        + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    )


def save_waveform_png(samples: List[float], out_png: str, title: str = "") -> None:
    w, h = 1200, 500
    bg = (255, 255, 255)
    fg = (0, 70, 180)
    axis = (200, 200, 200)
    textc = (30, 30, 30)
    left, right, top, bottom = 60, 20, 35, 45
    pw, ph = w - left - right, h - top - bottom
    img = bytearray([bg[0], bg[1], bg[2]] * (w * h))

    def set_px(x: int, y: int, c):
        if 0 <= x < w and 0 <= y < h:
            i = (y * w + x) * 3
            img[i:i + 3] = bytes(c)

    def line(x0: int, y0: int, x1: int, y1: int, c):
        dx = abs(x1 - x0)
        sx = 1 if x0 < x1 else -1
        dy = -abs(y1 - y0)
        sy = 1 if y0 < y1 else -1
        err = dx + dy
        while True:
            set_px(x0, y0, c)
            if x0 == x1 and y0 == y1:
                break
            e2 = 2 * err
            if e2 >= dy:
                err += dy
                x0 += sx
            if e2 <= dx:
                err += dx
                y0 += sy

    y0 = top + ph // 2
    line(left, top, left, top + ph, axis)
    line(left, y0, left + pw, y0, axis)

    vmin = min(samples) if samples else -1.0
    vmax = max(samples) if samples else 1.0
    if vmax <= vmin:
        vmax = vmin + 1.0

    n = len(samples)
    if n >= 2:
        for i in range(n - 1):
            x_a = left + int(i * (pw - 1) / (n - 1))
            x_b = left + int((i + 1) * (pw - 1) / (n - 1))
            ya_n = (samples[i] - vmin) / (vmax - vmin)
            yb_n = (samples[i + 1] - vmin) / (vmax - vmin)
            y_a = top + ph - 1 - int(ya_n * (ph - 1))
            y_b = top + ph - 1 - int(yb_n * (ph - 1))
            line(x_a, y_a, x_b, y_b, fg)

    for x in range(left, min(left + 700, w - right)):
        for y in range(5, 20):
            set_px(x, y, (245, 245, 245))
    if title:
        t = title[:80]
        x = left + 3
        for ch in t:
            v = ord(ch)
            for b in range(7):
                if v & (1 << b):
                    for yy in range(8, 18):
                        set_px(x + b, yy, textc)
            x += 9
            if x > w - right - 10:
                break

    raw = bytearray()
    row_bytes = w * 3
    for y in range(h):
        raw.append(0)
        start = y * row_bytes
        raw.extend(img[start:start + row_bytes])

    png = bytearray(b"\x89PNG\r\n\x1a\n")
    png.extend(_png_chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)))
    png.extend(_png_chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
    png.extend(_png_chunk(b"IEND", b""))
    with open(out_png, "wb") as f:
        f.write(png)

