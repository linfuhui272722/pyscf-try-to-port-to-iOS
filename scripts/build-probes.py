#!/usr/bin/env python3
"""Test whether the top-level directory name `Resources` is what breaks install.

Every probe so far lines up without exception:

  probe-b/d  no Resources/          installed
  probe-c/a/e/f/g/h/i  Resources/   failed

Size, symlinks, Mach-O content and file count are all ruled out by f/g/h/i, each
of which added exactly one of those to a bundle that installs. What is left is
the directory name itself: a top-level `Resources` folder is a macOS bundle
convention, and iOS apps normally keep resources at the top level of the .app.

  probe-j  the whole app with Resources/ renamed to Payload/
  probe-k  the whole app with Resources/python moved to python/

probe-j keeps the content byte-identical and changes only the name, so it tests
the name on its own. probe-k is the candidate fix, and it is the layout the
Swift bridge already looks for first (Bundle.main.resourceURL/python).
"""
import os
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = os.path.join(ROOT, "build", "products", "ios-arm64")
FULL = os.path.join(BASE, "PySCF.app")
OUT = os.path.join(BASE, "probes")


def clone(name):
    target = os.path.join(OUT, name)
    shutil.rmtree(target, ignore_errors=True)
    shutil.copytree(FULL, target, symlinks=True)
    return target


def main():
    if not os.path.isdir(FULL):
        sys.exit(f"missing {FULL}; run scripts/build-ios-app.sh first")

    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(OUT)

    # J: same content, different top-level directory name.
    probe_j = clone("PySCFJ.app")
    os.rename(os.path.join(probe_j, "Resources"), os.path.join(probe_j, "Payload"))

    # K: the Python tree at the top level, which is where the bridge looks first.
    probe_k = clone("PySCFK.app")
    os.rename(os.path.join(probe_k, "Resources", "python"),
              os.path.join(probe_k, "python"))
    os.rmdir(os.path.join(probe_k, "Resources"))

    for name, app in (("J", probe_j), ("K", probe_k)):
        files = sum(len(f) for _, _, f in os.walk(app))
        size = sum(
            os.lstat(os.path.join(d, f)).st_size
            for d, _, fs in os.walk(app)
            for f in fs
        )
        top = sorted(os.listdir(app))
        print(f"probe {name}: files={files:5} size={size / 1048576:6.1f}MiB")
        print(f"          top level: {top}")


if __name__ == "__main__":
    main()
