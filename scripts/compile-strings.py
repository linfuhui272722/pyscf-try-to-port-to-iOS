#!/usr/bin/env python3
"""Compile .strings text files into the binary plists iOS loads at runtime.

Xcode runs a step like this during a normal build. A hand-assembled bundle has
no such step, and NSLocalizedString ignores a text .strings file in an .lproj
directory: the lookup silently falls through to the development language, so the
app looks like it was never translated rather than failing loudly.

    compile-strings.py <Localizable.strings> [<output path>]

Without an output path the file is rewritten in place.
"""

from __future__ import annotations

import plistlib
import re
import sys


def parse(text: str) -> dict[str, str]:
    """Parses the .strings format, rejecting anything it cannot account for."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"^\s*//.*$", "", text, flags=re.M)

    def unescape(value: str) -> str:
        return (value
                .replace('\\"', '"')
                .replace("\\n", "\n")
                .replace("\\t", "\t")
                .replace("\\\\", "\\"))

    table: dict[str, str] = {}
    pattern = re.compile(r'"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.S)
    for match in pattern.finditer(text):
        table[unescape(match.group(1))] = unescape(match.group(2))

    # A malformed entry would otherwise be dropped in silence, and the missing
    # key would only show up as an English string on a Chinese device.
    residue = pattern.sub("", text).strip()
    if residue:
        raise SystemExit(f"{residue[:80]!r} could not be parsed")
    return table


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        raise SystemExit(__doc__)
    source = argv[1]
    destination = argv[2] if len(argv) > 2 else source

    with open(source, encoding="utf-8") as handle:
        table = parse(handle.read())
    with open(destination, "wb") as handle:
        plistlib.dump(table, handle, fmt=plistlib.FMT_BINARY)
    print(f"   {source}: {len(table)} entries")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
