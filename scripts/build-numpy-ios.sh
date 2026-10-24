#!/usr/bin/env bash
# Cross-compile NumPy for arm64 iOS.
#
# NumPy is the hard dependency: PySCF's Python layer is written against it, and
# no iOS wheel exists on PyPI, so it has to be built from source.  NumPy >= 1.26
# uses Meson, which supports cross-compilation through a cross file, so the plan
# is:
#
#   1. install the pure-Python build backends into the cross venv,
#   2. hand Meson a cross file describing the iOS compiler and host machine,
#   3. tell NumPy to use Apple's Accelerate framework for BLAS/LAPACK, which
#      ships on iOS and avoids cross-compiling OpenBLAS.
#
# Usage: scripts/build-numpy-ios.sh [numpy-version]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$ROOT/build/cross-venv"
XC="$ROOT/build/python-ios/Python.xcframework/ios-arm64"
OUT="$ROOT/build/products/ios-arm64"
NUMPY_VERSION="${1:-2.1.3}"
CROSS_FILE="$ROOT/build/ios-cross-file.ini"

if [ ! -x "$VENV/bin/python3" ]; then
  echo "!! cross venv missing; run scripts/make-cross-venv.sh" >&2
  exit 1
fi

# --------------------------------------------------------------------------
# Meson cross file
# --------------------------------------------------------------------------
cat > "$CROSS_FILE" <<EOF
[binaries]
c = '$ROOT/scripts/ios-toolchain/bin/arm64-apple-ios-clang'
cpp = '$ROOT/scripts/ios-toolchain/bin/arm64-apple-ios-clang++'
ar = '$ROOT/scripts/ios-toolchain/bin/arm64-apple-ios-ar'
ranlib = '$ROOT/scripts/ios-toolchain/bin/arm64-apple-ios-ranlib'
strip = 'strip'
exe_wrapper = '$ROOT/scripts/ios-exe-wrapper.sh'

[host_machine]
system = 'darwin'
subsystem = 'ios'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[properties]
# We cannot execute arm64 binaries on the Linux build host, so Meson must fall
# back to the values NumPy supplies for the known-good Apple configurations.
needs_exe_wrapper = true
EOF

# --------------------------------------------------------------------------
# pkg-config for the iOS SDK
# --------------------------------------------------------------------------
# NumPy asks Meson for BLAS and LAPACK.  The dedicated `accelerate` detector is
# unusable here (it requires macOS + xcrun), but the generic `blas`/`lapack`
# detectors go through pkg-config and only *link* their probe programs, which
# works when cross-compiling.  Apple's Accelerate framework lives in the iOS SDK
# and exports dgemm_/cblas_dgemm/zungqr_, so we describe it as both.
mkdir -p "$ROOT/build/pkgconfig"
SDK_DIR="$ROOT/build/sdk/iPhoneOS15.6.sdk"
for name in blas lapack; do
  sed -e "s|__SDK__|$SDK_DIR|" -e "s|__NAME__|$name|" \
      "$ROOT/scripts/ios-frameworks/accelerate-blas.pc.in" \
      > "$ROOT/build/pkgconfig/$name.pc"
done

export PKG_CONFIG="$ROOT/scripts/ios-pkg-config"
export PKG_CONFIG_PATH="$ROOT/build/pkgconfig"
export PKG_CONFIG_LIBDIR="$ROOT/build/pkgconfig"

echo ">> blas.pc    -> $("$ROOT/scripts/ios-pkg-config" --libs blas)"
echo ">> lapack.pc  -> $("$ROOT/scripts/ios-pkg-config" --libs lapack)"

# --------------------------------------------------------------------------
# Build backends
# --------------------------------------------------------------------------
source "$VENV/bin/ios-build-env.sh"

# ios-build-env.sh clears PKG_CONFIG_PATH to keep host libraries out; restore
# the SDK-only path afterwards.
export PKG_CONFIG="$ROOT/scripts/ios-pkg-config"
export PKG_CONFIG_PATH="$ROOT/build/pkgconfig"
export PKG_CONFIG_LIBDIR="$ROOT/build/pkgconfig"

echo ">> installing pure-Python build backends into the cross venv"
"$VENV/bin/pip" install --quiet --upgrade \
  "meson-python>=0.16" "meson>=1.3" "Cython>=3.0" "pyproject-metadata" "packaging"

# Meson looks for `cython` and `ninja` as executables, so both the cross venv
# and the host tool directory must be on PATH.
export PATH="$VENV/bin:$HOME/.local/bin:$PATH"
command -v cython >/dev/null || { echo "!! cython not found on PATH" >&2; exit 1; }
command -v ninja >/dev/null || { echo "!! ninja not found on PATH" >&2; exit 1; }

mkdir -p "$OUT" "$ROOT/build/downloads"

echo ">> building numpy $NUMPY_VERSION for arm64-ios (this takes a while)"
cd "$ROOT/build"
"$VENV/bin/pip" wheel "numpy==$NUMPY_VERSION" \
  --no-build-isolation --no-deps \
  --config-settings="setup-args=--cross-file=$CROSS_FILE" \
  --config-settings="setup-args=-Dblas=blas" \
  --config-settings="setup-args=-Dlapack=lapack" \
  --config-settings="setup-args=-Dallow-noblas=false" \
  -w "$OUT" 2>&1 | tee "$ROOT/build/logs/numpy-build.log"

echo
echo ">> numpy wheels produced:"
ls -la "$OUT"/*numpy*.whl 2>/dev/null || echo "   (none - see build/logs/numpy-build.log)"
