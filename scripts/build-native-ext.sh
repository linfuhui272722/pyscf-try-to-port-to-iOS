#!/usr/bin/env bash
# Build the _pyscf_mobile_accel C extension for arm64 iOS.
#
# The extension is linked against the CPython framework shipped in
# build/python-ios/Python.xcframework, using exactly the flags that
# Python-Apple-support recorded in its sysconfigdata (SOABI cpython-313-iphoneos,
# -F <framework dir> -framework Python).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLCHAIN_BIN="$ROOT/scripts/ios-toolchain/bin"
XC="$ROOT/build/python-ios/Python.xcframework/ios-arm64"
FRAMEWORK_DIR="$XC/Python.framework"
OUT="$ROOT/build/products/ios-arm64"

SDK="${IOS_SDK_PATH:-$ROOT/build/sdk/iPhoneOS15.6.sdk}"
export IOS_LLVM_TOOLCHAIN="${IOS_LLVM_TOOLCHAIN:-$ROOT/build/toolchain}"
export IOS_SDK_PATH="$SDK"
export PATH="$TOOLCHAIN_BIN:$PATH"

if [ ! -d "$FRAMEWORK_DIR" ]; then
  echo "!! CPython framework missing at $FRAMEWORK_DIR" >&2
  echo "   run scripts/setup-ios-toolchain.sh" >&2
  exit 1
fi

mkdir -p "$OUT"

CFLAGS=(
  -O2 -fPIC -fno-common -Wall
  -I"$XC/include/python3.13"
  -I"$FRAMEWORK_DIR/Headers"
)
LDFLAGS=(
  -dynamiclib
  -F "$(dirname "$FRAMEWORK_DIR")"
  -framework Python
  -Wl,-install_name,@rpath/_pyscf_mobile_accel.so
)

echo ">> compiling _pyscf_mobile_accel.c for arm64-ios"
arm64-apple-ios-clang "${CFLAGS[@]}" \
  "$ROOT/ios/native/_pyscf_mobile_accel.c" \
  -o "$OUT/_pyscf_mobile_accel.cpython-313-iphoneos.so" \
  "${LDFLAGS[@]}" \
  -L"$XC/lib"

echo ">> result"
ls -la "$OUT"
python3 - "$OUT/_pyscf_mobile_accel.cpython-313-iphoneos.so" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read()
magic = data[:4]
cputype = struct.unpack("<I", data[4:8])[0]
print(f"   mach-o magic : {magic.hex()}")
print(f"   cputype      : {hex(cputype)} (0x100000c = arm64)")
assert magic == bytes.fromhex("cffaedfe"), "not a 64-bit little-endian Mach-O"
assert cputype == 0x0100000C, "not arm64"
print("   OK: arm64 iOS dylib")
PY
