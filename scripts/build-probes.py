#!/usr/bin/env python3
"""Build probe bundles that bisect the install failure.

PySCF.app fails to install with "Unable to register" (exit 181) while the
minimal control app installs. The control proves the Info.plist, the signing and
the toolchain are fine, so the fault is in the payload, which is the only
remaining difference.

Static inspection of the payload has now been exhausted: every Mach-O is a thin
arm64 iOS binary with a valid signature, the icons are well formed, there are no
fat binaries, no nested bundles beyond the Python framework, and no odd file
names. Rather than guess at a fourth layer, this script builds bundles that
isolate each payload half:

  probe-a  the whole app, under a fresh bundle identifier
  probe-b  the same app without the stdlib and engine tree
  probe-c  the same app without the nested Python framework
  probe-d  the executable, icons and plist only
  probe-e  the control executable with both trees left in place

Every probe keeps a real executable, so failures in b and c together point at
the executable rather than at either tree. Reading the results:

  a installs              -> the old identifier's on-device state was at fault
  e installs              -> the trees are fine, so the executable is at fault
  e fails                 -> one of the two trees is at fault
  b installs, c fails     -> the stdlib and engine tree is at fault
  c installs, b fails     -> the nested framework is at fault
  d installs              -> the failure needs one of the two trees present

Each probe gets its own identifier so they can all be installed side by side.
"""
import os
import plistlib
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = os.path.join(ROOT, "build", "products", "ios-arm64")
FULL = os.path.join(BASE, "PySCF.app")
OUT = os.path.join(BASE, "probes")


def set_bundle_id(app, bundle_id):
    path = os.path.join(app, "Info.plist")
    with open(path, "rb") as handle:
        info = plistlib.load(handle)
    info["CFBundleIdentifier"] = bundle_id
    with open(path, "wb") as handle:
        plistlib.dump(info, handle, fmt=plistlib.FMT_BINARY)


def clone(source, name):
    target = os.path.join(OUT, name)
    shutil.rmtree(target, ignore_errors=True)
    shutil.copytree(source, target, symlinks=True)
    return target


def main():
    if not os.path.isdir(FULL):
        sys.exit(f"missing {FULL}; run scripts/build-ios-app.sh first")

    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(OUT)

    # A: the whole app under a fresh identifier. The control app was installed
    # under dev.pyscf.mobile, so the real app may now be colliding with it.
    probe_a = clone(FULL, "PySCFA.app")
    set_bundle_id(probe_a, "dev.pyscf.probe.a")

    # B: everything except the stdlib and engine tree.
    probe_b = clone(FULL, "PySCFB.app")
    shutil.rmtree(os.path.join(probe_b, "Resources"))
    set_bundle_id(probe_b, "dev.pyscf.probe.b")

    # C: everything except the nested framework.
    probe_c = clone(FULL, "PySCFC.app")
    shutil.rmtree(os.path.join(probe_c, "Frameworks"))
    set_bundle_id(probe_c, "dev.pyscf.probe.c")

    # D: the executable, icons and plist only.
    probe_d = clone(FULL, "PySCFD.app")
    shutil.rmtree(os.path.join(probe_d, "Resources"))
    shutil.rmtree(os.path.join(probe_d, "Frameworks"))
    set_bundle_id(probe_d, "dev.pyscf.probe.d")

    # E: the whole app, but with the small control executable in place of the
    # real one. If this installs, neither tree is at fault and the real
    # executable is.
    probe_e = clone(FULL, "PySCFE.app")
    control = os.path.join(BASE, "PySCFControl.app", "PySCFControl")
    if not os.path.isfile(control):
        sys.exit(f"missing {control}; run scripts/build-control-app.sh first")
    shutil.copy2(control, os.path.join(probe_e, "PySCF"))
    set_bundle_id(probe_e, "dev.pyscf.probe.e")

    for name, app in (
        ("A", probe_a),
        ("B", probe_b),
        ("C", probe_c),
        ("D", probe_d),
        ("E", probe_e),
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
