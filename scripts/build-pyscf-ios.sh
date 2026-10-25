#!/usr/bin/env bash
#
# Cross-compile PySCF's C extensions for arm64 iOS from a Linux host.
#
# PySCF's C code is built with CMake, driven from setup.py.  Rather than going
# through `pip wheel` (which would also try to build the dependencies), this
# script configures pyscf/lib directly with the iOS CMake toolchain and then
# assembles the result into the app's Python package tree.
#
# Prerequisites (produced by the other scripts in this directory):
#   build/products/ios-arm64/deps/lib/libcint.so   scripts/build-libcint-ios.sh
#   build/products/ios-arm64/deps/lib/libxc.so     scripts/build-libxc-ios.sh
#   build/products/ios-arm64/deps/lib/libomp.so    scripts/build-libomp-ios.sh
#   build/cross-venv                                scripts/make-cross-venv.sh
#
# Output:
#   build/products/ios-arm64/deps/lib/*.so          PySCF's extension modules
#   build/products/ios-arm64/pyscf-<ver>-ios.tar.gz complete Python package tree

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PYSCF_VERSION="${PYSCF_VERSION:-2.14.0}"
SRC="${PYSCF_SRC:-$ROOT/build/src/pyscf-$PYSCF_VERSION}"
BUILD="$ROOT/build/pyscf-ios"
DEPS="$ROOT/build/products/ios-arm64/deps"
OUT="$ROOT/build/products/ios-arm64"

export PATH="$HOME/.local/bin:$PATH"

if [[ ! -d "$SRC" ]]; then
  echo ">> PySCF source not found at $SRC"
  echo "   run scripts/fetch-sources.sh first"
  exit 1
fi
for lib in libcint.so libxc.so libomp.so; do
  if [[ ! -f "$DEPS/lib/$lib" ]]; then
    echo ">> missing $DEPS/lib/$lib - build libcint/libxc/libomp first" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# The CMake hook PySCF provides for build-time overrides
# ---------------------------------------------------------------------------
# pyscf/lib/CMakeLists.txt does `include(cmake.arch.inc)` if the file exists.
# Ours points CMake at the pre-built iOS libcint/libxc and supplies Accelerate
# as BLAS/LAPACK.  Copying it into the source tree is how PySCF is designed to
# be configured; no upstream file is edited.
cp "$ROOT/scripts/ios-cmake-arch.inc" "$SRC/pyscf/lib/cmake.arch.inc"

# config.h is generated into the source tree by PySCF's CMakeLists, and the
# iOS headers must win over any host headers.
rm -rf "$BUILD"

echo ">> configuring PySCF C extensions for arm64-ios"
cmake -S "$SRC/pyscf/lib" -B "$BUILD" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$ROOT/scripts/ios-cmake-toolchain.cmake" \
  -DCMAKE_BUILD_TYPE=RELEASE \
  -DCMAKE_INSTALL_PREFIX="$DEPS" \
  -DCMAKE_LIBRARY_OUTPUT_DIRECTORY="$DEPS/lib" \
  -DIOS_DEPS_PREFIX="$DEPS" \
  2>&1 | tee "$ROOT/build/logs/pyscf-configure.log"

echo ">> building PySCF C extensions"
cmake --build "$BUILD" --parallel "${JOBS:-4}" \
  2>&1 | tee "$ROOT/build/logs/pyscf-build.log"

# ---------------------------------------------------------------------------
# Collect the extension modules
# ---------------------------------------------------------------------------
# PySCF's CMakeLists sets LIBRARY_OUTPUT_DIRECTORY to the source tree, so the
# shared libraries land in pyscf/lib next to the Python modules that load them
# (pyscf/lib/misc.py looks in its own directory first).  We assemble a tree
# that mirrors what `pip install pyscf` produces.
echo ">> assembling the iOS package tree"
STAGE="$ROOT/build/pyscf-ios-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"

# Every runtime file in the package, minus tests, examples and build leftovers.
# pyscf/lib/*.py are runtime modules (misc.py, numpy_helper.py, ...), not part
# of the C build, so they must be kept.
#
# This used to be an allowlist of *.py and *.dat, which silently dropped
# pyscf/gto/basis/bse_meta.json.  pyscf/gto/mole.py opens that file at import
# time, so the omission did not degrade a feature: `import pyscf` failed
# outright, and the engine reported itself unavailable while the rest of the
# payload was fine.  The CP2K parsers read extensionless data files
# (GTH_POTENTIALS, POTENTIAL_UZH, BASIS_MOLOPT*, HFX_BASIS) in the same way, so
# a list of "data-looking" extensions will always be incomplete.  Copy
# everything and name the things to leave out instead, so a new data file in a
# future PySCF release ships by default rather than being silently lost.
DATA_EXCLUDES=(
  -name '*.c' -o -name '*.h' -o -name '*.f90' -o -name '*.F' -o -name '*.pyi'
  -o -name '*.cl' -o -name '*.in' -o -name '*.patch' -o -name '*.inc'
  -o -name 'inc-*' -o -name 'CMakeLists.txt' -o -name 'Makefile'
)
( cd "$SRC" && find pyscf \
    -name '__pycache__' -prune -o \
    -name 'test' -prune -o \
    -name 'tests' -prune -o \
    -name 'examples' -prune -o \
    -type f ! \( "${DATA_EXCLUDES[@]}" \) -print ) | while read -r f; do
  mkdir -p "$STAGE/$(dirname "$f")"
  cp "$SRC/$f" "$STAGE/$f"
done

# The C extension modules.  Only the .so flavour is used on iOS (see
# ios-cmake-project-include.cmake); drop the .dylib duplicates.
cp "$SRC"/pyscf/lib/lib*.so "$STAGE/pyscf/lib/"
rm -f "$STAGE/pyscf/lib/"*.dylib

# libcint, libxc and libomp are dependencies of the extensions and are loaded
# by the same loader, so they belong in the same directory.  libomp is the
# OpenMP runtime the extensions link against; without it beside them, dyld
# cannot resolve `@rpath/libomp.so` and every import fails.
cp "$DEPS/lib/libcint.so" "$DEPS/lib/libxc.so" "$DEPS/lib/libomp.so" "$STAGE/pyscf/lib/"
for f in "$DEPS/lib/"libcint.*.so "$DEPS/lib/"libxc.*.so; do
  [[ -e "$f" ]] && cp "$f" "$STAGE/pyscf/lib/"
done

# config.h records the compile-time feature flags; pyscf reads it at runtime.
if [[ -f "$SRC/pyscf/lib/config.h" ]]; then
  cp "$SRC/pyscf/lib/config.h" "$STAGE/pyscf/lib/"
fi

# ---------------------------------------------------------------------------
# The app's own Python package
# ---------------------------------------------------------------------------
# pyscf_mobile (engine/bridge/geometry/elements) and its vendored scipy/h5py
# stand-ins ship alongside PySCF in the same tree.  The vendor package is pure
# Python, so it is copied verbatim.
echo ">> staging pyscf_mobile"
rm -rf "$STAGE/pyscf_mobile"
mkdir -p "$STAGE/pyscf_mobile"
( cd "$ROOT/src/pyscf_mobile" && find . \
    -name '__pycache__' -prune -o \
    -type f -name '*.py' -print ) | while read -r f; do
  mkdir -p "$STAGE/pyscf_mobile/$(dirname "$f")"
  cp "$ROOT/src/pyscf_mobile/$f" "$STAGE/pyscf_mobile/$f"
done
# The native accelerator, if it has been built.
if [[ -f "$OUT/_pyscf_mobile_accel.cpython-313-iphoneos.so" ]]; then
  cp "$OUT/_pyscf_mobile_accel.cpython-313-iphoneos.so" "$STAGE/pyscf_mobile/"
fi

echo ">> extension modules built:"
ls "$STAGE/pyscf/lib/"*.so 2>/dev/null | sed 's/^/   /' || echo "   (none)"

tar -C "$STAGE" -czf "$OUT/pyscf-$PYSCF_VERSION-ios-arm64.tar.gz" pyscf pyscf_mobile
echo ">> packaged: $OUT/pyscf-$PYSCF_VERSION-ios-arm64.tar.gz"
