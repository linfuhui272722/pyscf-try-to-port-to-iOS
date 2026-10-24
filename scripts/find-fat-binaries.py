#!/usr/bin/env python3
"""Print every fat (universal) Mach-O binary under a bundle.

A single-architecture fat binary is a valid Mach-O but not a shape Apple ships:
Xcode runs `lipo -thin` during a build, so every executable in a released .app
is thin. MobileInstallation refuses a bundle that contains one, so the build
needs to find them and thin them.
"""
import os
import struct
import sys

FAT_MAGICS = {0xCAFEBABE, 0xBEBAFECA, 0xCAFEBABF, 0xBFBAFECA}
THIN_MAGICS = {0xFEEDFACF, 0xFEEDFACE, 0xCEFAEDFE, 0xCFFAEDFE}


def is_fat(path):
    try:
        with open(path, "rb") as handle:
            header = handle.read(8)
    except OSError:
        return False
    if len(header) < 4:
        return False
    return struct.unpack(">I", header[:4])[0] in FAT_MAGICS


def main(root):
    for directory, _, filenames in os.walk(root):
        for name in filenames:
            path = os.path.join(directory, name)
            if os.path.islink(path):
                continue
            if is_fat(path):
                print(path)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: find-fat-binaries.py <bundle>")
    main(sys.argv[1])
