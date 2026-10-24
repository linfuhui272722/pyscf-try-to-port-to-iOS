#!/usr/bin/env python3
"""Generate the app icon PNGs for the iOS bundle.

The bundle needs real icon files: an app with no icons is rejected by
LaunchServices during registration, which surfaces in TrollStore as
"Failed to add app to icon cache" (exit 181).

This writes a flat, dependency-free PNG set. The artwork is intentionally
plain - a rounded panel with the PySCF orbital motif - so the build does not
depend on any image library or binary asset.
"""

from __future__ import annotations

import math
import struct
import sys
import zlib
from pathlib import Path

# iPhone icon sizes. (base_name, points, scale) -> pixel size.
ICONS = [
    ("AppIcon60x60", 60, 2),   # 120 - home screen
    ("AppIcon60x60", 60, 3),   # 180 - home screen @3x
    ("AppIcon40x40", 40, 2),   # 80  - spotlight
    ("AppIcon40x40", 40, 3),   # 120 - spotlight @3x
    ("AppIcon29x29", 29, 2),   # 58  - settings
    ("AppIcon29x29", 29, 3),   # 87  - settings @3x
    ("AppIcon76x76", 76, 2),   # 152 - iPad
    ("AppIcon83.5x83.5", 83.5, 2),  # 167 - iPad Pro
    ("AppIcon20x20", 20, 2),   # 40  - notifications
    ("AppIcon20x20", 20, 3),   # 60  - notifications @3x
]

# Deep blue background, cyan orbitals, white nucleus.
BG = (18, 32, 61)
BG_EDGE = (28, 52, 96)
CYAN = (86, 204, 242)
WHITE = (240, 248, 255)
AMBER = (247, 181, 56)


def write_png(path: Path, pixels: list[list[tuple[int, int, int]]]) -> None:
    height = len(pixels)
    width = len(pixels[0])

    raw = bytearray()
    for row in pixels:
        raw.append(0)  # filter type 0 (None)
        for r, g, b in row:
            raw += bytes((r, g, b))

    def chunk(tag: bytes, data: bytes) -> bytes:
        body = tag + data
        return (
            struct.pack(">I", len(data))
            + body
            + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
        )

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )


def blend(base, top, alpha: float):
    return tuple(round(b + (t - b) * alpha) for b, t in zip(base, top))


def render(size: int) -> list[list[tuple[int, int, int]]]:
    """Draw the icon: rounded panel, two crossing orbital ellipses, nucleus."""
    cx = cy = (size - 1) / 2.0
    radius = size / 2.0

    # Ellipse geometry, scaled from the reference 120px design.
    a = size * 0.335
    b = size * 0.135
    tilt = 0.62  # radians

    cos_t, sin_t = math.cos(tilt), math.sin(tilt)
    stroke = max(size * 0.022, 1.0)

    pixels = []
    for y in range(size):
        row = []
        for x in range(size):
            # Subtle vertical gradient so the tile is not flat.
            shade = y / max(size - 1, 1)
            colour = blend(BG, BG_EDGE, shade * 0.55)

            # Two orbital ellipses, rotated about the centre.
            px, py = x - cx, y - cy
            rx = px * cos_t + py * sin_t
            ry = -px * sin_t + py * cos_t
            for sign in (1, -1):
                d = ((rx / a) ** 2 + (ry / b) ** 2) ** 0.5
                dist = abs(d - 1.0) * a
                if dist < stroke:
                    edge = 1.0 - (dist / stroke)
                    colour = blend(colour, CYAN, min(edge * 1.6, 1.0))
                # Mirror the second ellipse.
                rx = -rx
            row.append(colour)
        pixels.append(row)

    # Nucleus: solid disc with a soft amber halo.
    core = size * 0.058
    halo = size * 0.105
    for y in range(size):
        for x in range(size):
            d = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5
            if d <= halo:
                if d <= core:
                    pixels[y][x] = WHITE
                else:
                    t = (d - core) / (halo - core)
                    pixels[y][x] = blend(pixels[y][x], AMBER, (1.0 - t) * 0.75)

    return pixels


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <app-bundle>", file=sys.stderr)
        return 2

    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)

    written = 0
    for name, points, scale in ICONS:
        size = int(round(points * scale))
        suffix = "" if scale == 1 else f"@{scale}x"
        path = out / f"{name}{suffix}.png"
        write_png(path, render(size))
        written += 1
        print(f"   {path.name}  {size}x{size}")

    print(f"   {written} icons")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
