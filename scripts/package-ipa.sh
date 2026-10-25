#!/usr/bin/env bash
#
# Package the built .app as an unsigned .ipa for sideloading.
#
#   scripts/package-ipa.sh <app-dir> <output.ipa>
#
# The one thing this has to get right is symlinks. The Python payload reaches
# its native libraries through them — pyscf/lib/libcint.so points at
# libcint.6.1.3.so — and a packaging step that dereferences them stores a second
# full copy of every library instead of a name. That nearly doubles the archive
# (146 MB against 74 MB for the same app) without changing what it contains.
#
# `zip -y` does the right thing but is not available on the build host, and
# Python's shutil.make_archive dereferences by default, so the archive is written
# here with the symlink entries stored explicitly.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP="${1:-$ROOT/build/products/ios-arm64/PySCF.app}"
OUT="${2:-}"

if [ ! -d "$APP" ]; then
  echo "!! app bundle not found: $APP" >&2
  echo "   build it first: scripts/build-ios-app.sh" >&2
  exit 1
fi

if [ -z "$OUT" ]; then
  echo "!! output path required: scripts/package-ipa.sh <app-dir> <output.ipa>" >&2
  exit 1
fi

echo ">> packaging $APP"
echo "   -> $OUT"

python3 - "$APP" "$OUT" <<'PY'
import os
import sys
import zipfile

app, out = sys.argv[1], sys.argv[2]
app_name = os.path.basename(app.rstrip("/"))
prefix = f"Payload/{app_name}"

# Payload/ is what iOS looks for at the archive root; the app directory keeps
# its own name inside it.
root = os.path.dirname(os.path.abspath(app))

symlinks = 0
files = 0

with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for dirpath, dirnames, filenames in os.walk(app):
        # Do not follow symlinked directories: os.walk would otherwise descend
        # into them and store the target's contents again under the link's path.
        dirnames[:] = [
            d for d in dirnames if not os.path.islink(os.path.join(dirpath, d))
        ]

        for name in dirnames + filenames:
            path = os.path.join(dirpath, name)
            arcname = prefix + path[len(app):]

            if os.path.islink(path):
                # Store the link itself. The target is the link text, and the
                # mode marks the entry as a symlink so the extractor recreates a
                # link rather than a file containing a path.
                info = zipfile.ZipInfo(arcname)
                info.create_system = 3  # Unix
                info.external_attr = (0o120777 << 16)
                z.writestr(info, os.readlink(path))
                symlinks += 1
            else:
                z.write(path, arcname)
                files += 1

print(f"   stored {files} files and {symlinks} symlinks")
print(f"   size: {os.path.getsize(out) / 1048576:.1f} MB")
PY

echo ">> packaged $OUT"
