#!/usr/bin/env python3
"""Build probe bundles that isolate which property of Resources breaks install.

The first probe round settled the payload question:

  probe-d  executable, icons, plist only          installed
  probe-b  executable plus Frameworks/            installed
  probe-c  executable plus Resources/             failed
  probe-a  the whole app, fresh identifier        failed
  probe-e  whole app, control executable          failed

So the nested Python framework is clean, and the fault needs Resources/ present.
Everything about Resources/ correlates with the failure, so these probes vary one
property at a time on top of probe-b, which is known to install:

  probe-f  one 70 MiB file, stored uncompressed  -> bundle size
  probe-g  a relative symlink inside the bundle  -> symlinks
  probe-h  one real Mach-O from the tree         -> Mach-O content
  probe-i  2000 tiny files                       -> file count

Each probe is built from probe-b's shape, so a failure is caused by the one thing
that probe adds. probe-f stores its padding uncompressed: the download stays
small while the bundle still expands to 70 MiB on the device, which separates
bundle size from download size.
"""
import os
import plistlib
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = os.path.join(ROOT, "build", "products", "ios-arm64")
FULL = os.path.join(BASE, "PySCF.app")
OUT = os.path.join(BASE, "probes")

REAL_SO = os.path.join(
    "Resources", "python", "lib", "python3.13", "lib-dynload",
    "math.cpython-313-iphoneos.so",
)


def set_bundle_id(app, bundle_id):
    path = os.path.join(app, "Info.plist")
    with open(path, "rb") as handle:
        info = plistlib.load(handle)
    info["CFBundleIdentifier"] = bundle_id
    with open(path, "wb") as handle:
        plistlib.dump(info, handle, fmt=plistlib.FMT_BINARY)


def base_app(name, bundle_id):
    """The app with Frameworks/ kept and Resources/ dropped: known to install."""
    target = os.path.join(OUT, name)
    shutil.rmtree(target, ignore_errors=True)
    shutil.copytree(FULL, target, symlinks=True)
    shutil.rmtree(os.path.join(target, "Resources"))
    set_bundle_id(target, bundle_id)
    return target


def main():
    if not os.path.isdir(FULL):
        sys.exit(f"missing {FULL}; run scripts/build-ios-app.sh first")

    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(OUT)

    # F: one large file, to test whether size alone breaks the install. The
    # padding is all zeros, so it stores tiny while expanding to the size of the
    # real Resources tree on the device.
    probe_f = base_app("PySCFF.app", "dev.pyscf.probe.f")
    resources = os.path.join(probe_f, "Resources")
    os.makedirs(resources, exist_ok=True)
    with open(os.path.join(resources, "pad.bin"), "wb") as handle:
        handle.truncate(150 * 1024 * 1024)

    # G: a relative symlink inside the bundle.
    probe_g = base_app("PySCFG.app", "dev.pyscf.probe.g")
    links = os.path.join(probe_g, "Resources", "links")
    os.makedirs(links)
    with open(os.path.join(links, "target.txt"), "w") as handle:
        handle.write("payload\n")
    os.symlink("target.txt", os.path.join(links, "alias.txt"))

    # H: one genuine Mach-O from the real tree.
    probe_h = base_app("PySCFH.app", "dev.pyscf.probe.h")
    destination = os.path.join(probe_h, REAL_SO)
    os.makedirs(os.path.dirname(destination), exist_ok=True)
    shutil.copy2(os.path.join(FULL, REAL_SO), destination)

    # I: many small files.
    probe_i = base_app("PySCFI.app", "dev.pyscf.probe.i")
    many = os.path.join(probe_i, "Resources", "many")
    os.makedirs(many)
    for index in range(2000):
        with open(os.path.join(many, f"f{index:04d}.txt"), "w") as handle:
            handle.write("x\n")

    for name, app in (
        ("F", probe_f),
        ("G", probe_g),
        ("H", probe_h),
        ("I", probe_i),
    ):
        files = sum(len(f) for _, _, f in os.walk(app))
        size = sum(
            os.lstat(os.path.join(d, f)).st_size
            for d, _, fs in os.walk(app)
            for f in fs
        )
        print(f"probe {name}: {os.path.basename(app):12} files={files:5} "
              f"size={size / 1048576:.1f}MiB")


if __name__ == "__main__":
    main()
