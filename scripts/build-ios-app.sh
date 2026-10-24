#!/usr/bin/env bash
# Build the PySCF Mobile iOS app bundle from source.
#
# Runs on a Linux host with the open-source toolchain:
#   * clang/LLD from scripts/ios-toolchain   (replaces Apple's closed toolchain)
#   * theos iPhoneOS15.6.sdk                 (github.com/theos/sdks)
#   * Swift compiler                         (see scripts/fetch-swift-ios.sh)
#
# The Swift layer is compiled for arm64-apple-ios15.6 and linked with ld64.lld
# against the CPython framework built by scripts/build-pyscf-ios.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SDK="${IOS_SDK_PATH:-$ROOT/build/sdk/iPhoneOS15.6.sdk}"
SWIFT="${IOS_SWIFT:-$ROOT/build/swift/usr/bin/swiftc}"
SWIFT_RESOURCE_DIR="${IOS_SWIFT_RESOURCE_DIR:-$ROOT/build/swift-resource}"
LINKER="${IOS_LD64:-$ROOT/build/swift/usr/bin/ld64.lld}"

XCFRAMEWORK="$ROOT/build/python-ios/Python.xcframework"
FRAMEWORK="$XCFRAMEWORK/ios-arm64/Python.framework"
STDLIB="$XCFRAMEWORK/lib/python3.13"
DYNLOAD="$XCFRAMEWORK/ios-arm64/lib-arm64/python3.13/lib-dynload"
NUMPY_WHEEL="$(ls "$ROOT"/build/products/ios-arm64/numpy-*-ios_*_arm64_iphoneos.whl 2>/dev/null | head -1 || true)"
PAYLOAD="$ROOT/build/products/ios-arm64/pyscf-2.14.0-ios-arm64.tar.gz"

PRODUCT="$ROOT/build/products/ios-arm64/PySCF.app"
DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-15.6}"
BUNDLE_ID="${IOS_BUNDLE_ID:-dev.pyscf.mobile}"

APP_NAME="PySCF"
EXECUTABLE="$PRODUCT/$APP_NAME"

# ld64.lld has no notion of Apple's ld wrapper, so expose it under the name the
# Swift driver expects to find on PATH.
LDSHIM="$(mktemp -d)"
SWIFTLIBS="$(mktemp -d)"
trap 'rm -rf "$LDSHIM" "$SWIFTLIBS"' EXIT
printf '#!/bin/sh\nexec %s "$@"\n' "$LINKER" > "$LDSHIM/ld"
chmod +x "$LDSHIM/ld"

# The Linux Swift toolchain links against ncurses6, while newer distributions
# ship libncursesw only, so provide the names the loader looks for.
for lib in libncursesw.so.6 libtinfo.so.6; do
  for candidate in /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu /usr/lib64 /usr/lib; do
    if [ -e "$candidate/$lib" ] && [ ! -e "$SWIFTLIBS/$lib" ]; then
      ln -s "$candidate/$lib" "$SWIFTLIBS/$lib"
    fi
  done
done
# libncurses.so.6 is an alias for the wide-character build.
if [ ! -e "$SWIFTLIBS/libncurses.so.6" ] && [ -e "$SWIFTLIBS/libncursesw.so.6" ]; then
  ln -s libncursesw.so.6 "$SWIFTLIBS/libncurses.so.6"
fi

# Swift 5.6 emits a warning about the missing _StringProcessing module when it
# reads newer SDK interfaces; it is harmless but noisy.
QUIET='-Xfrontend -suppress-warnings'

# The Swift overlay modules shipped in the theos SDK assume Apple's apinotes.
# Without them DispatchQueue/Foundation overlay names fail to resolve, so the
# copies from swiftlang/swift are installed alongside the toolchain resources.
APINOTES="$ROOT/ios/toolchain/apinotes"

require() {
  local path="$1" hint="$2"
  if [ ! -e "$path" ]; then
    echo "!! missing $path" >&2
    echo "   $hint" >&2
    exit 1
  fi
}

require "$SDK" "run scripts/setup-ios-toolchain.sh"
require "$FRAMEWORK" "run scripts/build-pyscf-ios.sh"
require "$STDLIB" "run scripts/build-pyscf-ios.sh"
require "$SWIFT" "run scripts/fetch-swift-ios.sh"

if [ ! -d "$SWIFT_RESOURCE_DIR" ]; then
  echo ">> preparing Swift resource dir for the iOS SDK"
  mkdir -p "$SWIFT_RESOURCE_DIR/apinotes"
  for entry in "$SDK"/usr/lib/swift/*; do
    ln -sf "$entry" "$SWIFT_RESOURCE_DIR/$(basename "$entry")"
  done
  cp "$APINOTES"/*.apinotes "$SWIFT_RESOURCE_DIR/apinotes/" 2>/dev/null || true
  CLANG_DIR="$(ls -d "$(dirname "$(dirname "$SWIFT")")"/lib/clang/*/ 2>/dev/null | head -1)"
  [ -n "$CLANG_DIR" ] && ln -sfn "${CLANG_DIR%/}" "$SWIFT_RESOURCE_DIR/clang"
fi

# The Swift driver unconditionally adds <resource-dir>/iphoneos to the library
# search path, so create it to keep the link step free of -L warnings.
mkdir -p "$SWIFT_RESOURCE_DIR/iphoneos"

echo ">> cleaning $PRODUCT"
rm -rf "$PRODUCT"
mkdir -p "$PRODUCT/Frameworks"

# ---------------------------------------------------------------------------
# 1. Python payload: stdlib, extension modules, engine, NumPy
#
# Python-Apple-support lays the runtime out as
#   <home>/lib/python3.13/            pure-Python stdlib + site-packages
#   <home>/lib/python3.13/lib-dynload extension modules
# which is what Py_SetPythonHome() in PythonBridge.swift points at.
# ---------------------------------------------------------------------------
PYHOME="$PRODUCT/Resources/python"
mkdir -p "$PYHOME/lib"

echo ">> staging CPython standard library"
cp -R "$STDLIB" "$PYHOME/lib/python3.13"

echo ">> staging CPython extension modules"
cp -R "$DYNLOAD" "$PYHOME/lib/python3.13/lib-dynload"

SYSCONFIG="$(dirname "$DYNLOAD")/_sysconfigdata__ios_arm64-iphoneos.py"
if [ -f "$SYSCONFIG" ]; then
  cp "$SYSCONFIG" "$PYHOME/lib/python3.13/"
fi

echo ">> staging engine payload"
ENGINE_DIR="$PYHOME/lib/python3.13/site-packages"
mkdir -p "$ENGINE_DIR"
if [ -f "$PAYLOAD" ]; then
  tar -xzf "$PAYLOAD" -C "$ENGINE_DIR"
else
  echo "   payload tarball not found; copying from src/ instead"
  cp -R "$ROOT/src/pyscf_mobile" "$ENGINE_DIR/"
fi

if [ -n "$NUMPY_WHEEL" ]; then
  echo ">> staging NumPy from $(basename "$NUMPY_WHEEL")"
  python3 -c "
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
" "$NUMPY_WHEEL" "$ENGINE_DIR"
else
  echo "!! NumPy wheel not found; the engine will report numpy unavailable" >&2
fi

# The upstream wheels express versioned shared libraries as symlinks
# (libcint.so -> libcint.6.so -> libcint.6.1.3.so).  tar/cp materialise those as
# full copies, which triples the size of the largest libraries, so collapse
# byte-identical siblings back into symlinks.
echo ">> collapsing duplicate shared libraries"
python3 - "$ENGINE_DIR" <<'PY'
import hashlib, os, sys

root = sys.argv[1]
saved = 0
for directory, _, files in os.walk(root):
    by_size = {}
    for name in files:
        if not name.endswith((".so", ".dylib")):
            continue
        path = os.path.join(directory, name)
        if os.path.islink(path):
            continue
        by_size.setdefault(os.path.getsize(path), []).append(path)

    for paths in by_size.values():
        if len(paths) < 2:
            continue
        by_digest = {}
        for path in paths:
            with open(path, "rb") as handle:
                by_digest.setdefault(hashlib.md5(handle.read()).hexdigest(), []).append(path)

        for duplicates in by_digest.values():
            if len(duplicates) < 2:
                continue
            # Keep the most specific (longest) name as the real file.
            duplicates.sort(key=lambda p: len(os.path.basename(p)), reverse=True)
            keeper = duplicates[0]
            for path in duplicates[1:]:
                size = os.path.getsize(path)
                os.remove(path)
                os.symlink(os.path.basename(keeper), path)
                saved += size
print(f"   reclaimed {saved / 1e6:.1f} MB")
PY

# Byte-code caches and bundled test suites are dead weight on device.
echo ">> removing caches and test suites"
find "$ENGINE_DIR" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$ENGINE_DIR" -name 'tests' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$ENGINE_DIR" -name '*.pyc' -delete 2>/dev/null || true

# NumPy's generated __config__.py records the paths of the machine that built
# it.  That is pure diagnostics, and shipping the build host's layout is both
# useless and a (minor) information leak, so neutralise it.
echo ">> sanitising numpy build metadata"
python3 - "$ENGINE_DIR" "$ROOT" <<'PY'
import os, re, sys

engine, root = sys.argv[1], sys.argv[2]
target = os.path.join(engine, "numpy", "__config__.py")
if not os.path.isfile(target):
    sys.exit(0)

with open(target) as handle:
    text = handle.read()
# Collapse any absolute path under the build root to a neutral marker.
cleaned = re.sub(re.escape(root) + r"[^\"']*", "<build-host>", text)
if cleaned != text:
    with open(target, "w") as handle:
        handle.write(cleaned)
    print(f"   neutralised {os.path.relpath(target, engine)}")
PY

echo ">> staging CPython framework"
cp -R "$FRAMEWORK" "$PRODUCT/Frameworks/Python.framework"
chmod +x "$PRODUCT/Frameworks/Python.framework/Python"

# The framework's modulemap declares `link "Python"`, so Swift autolinking emits
# -lPython.  ld64 would fall back to Python.framework/Python, but LLD only
# searches -L paths, so expose the framework binary under that name.
LIBDIR="$ROOT/build/products/ios-arm64/lib"
mkdir -p "$LIBDIR"
ln -sf "$FRAMEWORK/Python" "$LIBDIR/libPython.dylib"

# ---------------------------------------------------------------------------
# 2. Compile the Swift sources
# ---------------------------------------------------------------------------
echo ">> compiling Swift sources"
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find "$ROOT/ios/PySCF" -name '*.swift' | sort)

SWIFT_FLAGS=(
  -target "arm64-apple-ios$DEPLOYMENT_TARGET"
  -sdk "$SDK"
  -resource-dir "$SWIFT_RESOURCE_DIR"
  -module-cache-path "$ROOT/build/swift-module-cache"
  -F "$XCFRAMEWORK/ios-arm64"
  -L "$LIBDIR"
  -Xcc -Wno-non-modular-include-in-framework-module
  -parse-as-library
  -swift-version 5
  -O
)

PATH="$LDSHIM:$PATH" LD_LIBRARY_PATH="$SWIFTLIBS:${LD_LIBRARY_PATH:-}" \
  "$SWIFT" "${SWIFT_FLAGS[@]}" $QUIET \
  -Xlinker -rpath -Xlinker @executable_path/Frameworks \
  -o "$EXECUTABLE" "${SOURCES[@]}"

# ---------------------------------------------------------------------------
# 3. Bundle metadata and code signature
# ---------------------------------------------------------------------------
# LaunchServices validates a bundle's declared platform and device family when
# it registers it. A plist without CFBundleSupportedPlatforms, UIDeviceFamily or
# any icon files is rejected outright, which TrollStore reports as
# "Failed to add app to icon cache" (exit 181) after signing has already
# succeeded - so these keys are required, not cosmetic.
echo ">> generating app icons"
python3 "$ROOT/scripts/make-app-icon.py" "$PRODUCT" >/dev/null

echo ">> writing Info.plist"
cat > "$PRODUCT/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>PySCF Mobile</string>
    <key>CFBundleDisplayName</key><string>PySCF</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleSignature</key><string>????</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
    <key>DTPlatformName</key><string>iphoneos</string>
    <key>DTSDKName</key><string>iphoneos$DEPLOYMENT_TARGET</string>
    <key>DTPlatformVersion</key><string>$DEPLOYMENT_TARGET</string>
    <key>DTCompiler</key><string>com.apple.compilers.llvm.clang.1_0</string>
    <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
    <key>LSRequiresIPhoneOS</key><true/>
    <key>UILaunchScreen</key><dict/>
    <key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>
    <key>CFBundleIcons</key>
    <dict>
        <key>CFBundlePrimaryIcon</key>
        <dict>
            <key>CFBundleIconFiles</key>
            <array>
                <string>AppIcon60x60</string>
                <string>AppIcon40x40</string>
                <string>AppIcon29x29</string>
            </array>
            <key>CFBundleIconName</key><string>AppIcon</string>
        </dict>
    </dict>
    <key>CFBundleIcons~ipad</key>
    <dict>
        <key>CFBundlePrimaryIcon</key>
        <dict>
            <key>CFBundleIconFiles</key>
            <array>
                <string>AppIcon60x60</string>
                <string>AppIcon76x76</string>
                <string>AppIcon83.5x83.5</string>
                <string>AppIcon40x40</string>
                <string>AppIcon29x29</string>
            </array>
        </dict>
    </dict>
    <key>UISupportedInterfaceOrientations</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
    <key>UISupportedInterfaceOrientations~ipad</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationPortraitUpsideDown</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
    <key>MinimumOSVersion</key><string>$DEPLOYMENT_TARGET</string>
</dict>
</plist>
PLIST

# Classic four-byte bundle type/signature stamp. LaunchServices tolerates its
# absence, but every Xcode-built app ships it.
printf 'APPL????' > "$PRODUCT/PkgInfo"

if [ -x "$ROOT/build/toolchain/bin/ldid" ]; then
  echo ">> ad-hoc signing"
  "$ROOT/build/toolchain/bin/ldid" -S "$EXECUTABLE" || echo "   ldid failed; sign later with codesign/ldid on a device host"
fi

echo
echo ">> built $PRODUCT"
du -sh "$PRODUCT"
echo "   executable: $(du -h "$EXECUTABLE" | cut -f1)"
