#!/usr/bin/env python3
"""Package an .app bundle into an unsigned IPA.

Uses an explicit ZipInfo per entry so file modes and symlinks survive, which
TrollStore's installer and the code signature both depend on. Apple's own
timestamp is irrelevant to installs, so entries are pinned to a fixed date to
keep builds reproducible.
"""
import os
import stat
import sys
import time
import zipfile

FIXED_TIME = time.mktime((2026, 1, 1, 0, 0, 0, 0, 0, 0))


def iter_entries(root):
    for directory, dirnames, filenames in os.walk(root):
        dirnames.sort()
        filenames.sort()
        for name in filenames + dirnames:
            path = os.path.join(directory, name)
            if os.path.islink(path) or os.path.isfile(path):
                yield path


def build(app_dir, out_path):
    staging = os.path.join(os.path.dirname(out_path), "ipa-staging")
    payload = os.path.join(staging, "Payload")
    os.makedirs(payload, exist_ok=True)

    target = os.path.join(payload, os.path.basename(app_dir))
    os.system(f"rm -rf {target!r}")
    os.system(f"cp -a {app_dir!r} {target!r}")

    entries = list(iter_entries(staging))
    with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in entries:
            arcname = os.path.relpath(path, staging)
            info = zipfile.ZipInfo(arcname, date_time=time.localtime(FIXED_TIME)[:6])
            info.create_system = 3
            if os.path.islink(path):
                info.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(info, os.readlink(path))
            else:
                # Mask setgid and world-write bits. The build tree lives on an
                # idmapped mount where chmod cannot clear them, and no shipped
                # app carries either.
                mode = stat.S_IMODE(os.lstat(path).st_mode) & 0o755
                info.external_attr = mode << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                with open(path, "rb") as handle:
                    archive.writestr(info, handle.read())
    os.system(f"rm -rf {staging!r}")
    return len(entries)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: make-ipa.py <App.app> <out.ipa>")
    count = build(sys.argv[1], sys.argv[2])
    print(f"packed {count} entries -> {sys.argv[2]}")
