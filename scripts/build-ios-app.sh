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

# MobileInstallation inspects a bundle by reading its Info.plist, and Apple's
# toolchain always emits that file in binary plist form. When inspection fails,
# the install log prints the file's first bytes - ours showed `<?xm`, i.e. XML
# text, which is the deviation. Rewrite plists as binary so the bundle matches
# what an Xcode build produces.
to_binary_plist() {
  python3 - "$1" <<'BPLIST'
import plistlib, sys

path = sys.argv[1]
with open(path, "rb") as handle:
    data = plistlib.load(handle)
with open(path, "wb") as handle:
    plistlib.dump(data, handle, fmt=plistlib.FMT_BINARY)
BPLIST
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
PYHOME="$PRODUCT/python"
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
  echo "   payload tarball not found; staging from src/ instead"
  mkdir -p "$ENGINE_DIR/pyscf_mobile"
fi

# Overlay the current engine sources on top of whatever was just unpacked.
#
# The tarball is a snapshot taken by build-pyscf-ios.sh, so a change to
# src/pyscf_mobile/ that was not followed by a full PySCF rebuild never reaches
# the app: the build succeeds and ships the previous revision. That is a silent
# failure — the edited module appears to run and behave as it did before — so the
# sources are copied in every time rather than trusted to the archive.
#
# The copy is `src/pyscf_mobile/.` into the existing package directory on
# purpose. `cp -R src/pyscf_mobile target/` where target/pyscf_mobile exists
# copies *into* it, producing pyscf_mobile/pyscf_mobile. The trailing `/.` copies
# the contents instead. Compiled modules such as
# _pyscf_mobile_accel.cpython-313-iphoneos.so are absent from src/ and are
# therefore left as the tarball supplied them.
echo "   overlaying current sources from src/pyscf_mobile"
rm -rf "$ENGINE_DIR/pyscf_mobile/__pycache__"
cp -R "$ROOT/src/pyscf_mobile/." "$ENGINE_DIR/pyscf_mobile/"

# A module deleted from src/ is still in the tarball, and copying over the top
# never removes it, so a removed module would keep shipping. Drop any .py the
# tarball supplied that src/ no longer has. Compiled modules are left alone:
# they are not in src/ at all.
python3 - "$ROOT/src/pyscf_mobile" "$ENGINE_DIR/pyscf_mobile" <<'PRUNE'
import os, sys
src, dst = sys.argv[1], sys.argv[2]
for root, _dirs, files in os.walk(dst):
    for name in files:
        if not name.endswith(".py"):
            continue
        rel = os.path.relpath(os.path.join(root, name), dst)
        if not os.path.exists(os.path.join(src, rel)):
            os.remove(os.path.join(root, name))
            print(f"   pruned stale module {rel}")
PRUNE

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

# Byte-code caches and bundled test suites are dead weight on device.  The
# stdlib ships a 36 MB `test` package plus `idlelib`/`tkinter` that no on-device
# code path can use, and the framework's C headers are useless without a
# compiler, so strip all of them.
echo ">> removing caches and test suites"
find "$PYHOME" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$PYHOME" -name '*.pyc' -delete 2>/dev/null || true
for junk in test idlelib tkinter turtledemo lib2to3; do
  rm -rf "$PYHOME/lib/python3.13/$junk"
done
find "$ENGINE_DIR" -name 'tests' -type d -prune -exec rm -rf {} + 2>/dev/null || true

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

# Apple's bundles use a fixed mode convention: directories 0755, regular files
# 0644, executables 0755. This build inherited 2755 (setgid) on directories and
# 0777 on three shared objects from the staging tree, which no shipped app has.
# Normalise so the payload matches what MobileInstallation expects to extract.
echo ">> normalising file modes"
find "$PRODUCT" -type d -exec chmod 755 {} +
find "$PRODUCT" -type f ! -perm -u+x -exec chmod 644 {} +
find "$PRODUCT" -type f -perm -u+x -exec chmod 755 {} +

# The xcframework's slice ships its executable as a single-architecture *fat*
# binary, because that is what `lipo -create` produces from one input. Apple's
# own bundles never look like this: Xcode runs `lipo -thin` while building, so
# every executable inside a shipped .app is a thin Mach-O. A fat executable in
# the payload is enough on its own to make MobileInstallation refuse the bundle,
# so thin anything fat here.
LIPO="$ROOT/build/toolchain/bin/llvm-lipo"
[ -x "$LIPO" ] || LIPO="$(command -v llvm-lipo || true)"
if [ -n "$LIPO" ]; then
  echo ">> thinning fat binaries"
  FAT_BINARIES="$(python3 "$ROOT/scripts/find-fat-binaries.py" "$PRODUCT")"
  if [ -n "$FAT_BINARIES" ]; then
    while IFS= read -r binary; do
      [ -n "$binary" ] || continue
      "$LIPO" -thin arm64 "$binary" -output "$binary.thin" && mv "$binary.thin" "$binary"
      chmod 755 "$binary"
      echo "   thinned ${binary#"$PRODUCT"/}"
    done <<< "$FAT_BINARIES"
  fi
fi

# The framework ships its plist as XML declaring version 0.9 with an external
# DTD reference, and it is a nested bundle that MobileInstallation also
# inspects, so normalise it to a binary plist like everything else.
to_binary_plist "$PRODUCT/Frameworks/Python.framework/Info.plist"

# C headers are dead weight in a shipped bundle: nothing on the device can
# compile against them, and they add ~270 files for LaunchServices to walk.
rm -rf "$PRODUCT/Frameworks/Python.framework/Headers"

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
# ---------------------------------------------------------------------------
# 2b. Localisations
# ---------------------------------------------------------------------------
# iOS reads localised resources from <bundle>/<lang>.lproj/Localizable.strings,
# and it only honours a *binary* plist there: a text .strings file is ignored
# and every lookup falls back to the development language, which looks like the
# translation was never wired up. Compile each .lproj in place, as Xcode does.
echo ">> staging localisations"
for lproj in "$ROOT"/ios/PySCF/Resources/*.lproj; do
  [ -d "$lproj" ] || continue
  # The source directory is already named "<lang>.lproj", so the destination is
  # the bundle name itself rather than that name plus another suffix.
  bundle="$(basename "$lproj")"
  mkdir -p "$PRODUCT/$bundle"
  cp "$lproj"/Localizable.strings "$PRODUCT/$bundle/Localizable.strings"
  python3 "$ROOT/scripts/compile-strings.py" \
    "$PRODUCT/$bundle/Localizable.strings"
done
if [ ! -d "$PRODUCT/en.lproj" ]; then
  echo "!! no localisations were staged; the UI will show raw keys" >&2
  exit 1
fi

echo ">> generating app icons"
python3 "$ROOT/scripts/make-app-icon.py" "$PRODUCT" >/dev/null

echo ">> writing Info.plist"
cat > "$PRODUCT/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>zh-Hans</string></array>
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
    <!-- Expose the container's Documents directory in the Files app, so the
         diagnostics log can be retrieved without a jailbroken-style install.
         The app writes to /var/mobile when it can and falls back to here. -->
    <key>UIFileSharingEnabled</key><true/>
    <key>LSSupportsOpeningDocumentsInPlace</key><true/>
</dict>
</plist>
PLIST

# Classic four-byte bundle type/signature stamp. LaunchServices tolerates its
# absence, but every Xcode-built app ships it.
printf 'APPL????' > "$PRODUCT/PkgInfo"

to_binary_plist "$PRODUCT/Info.plist"

if [ -x "$ROOT/build/toolchain/bin/ldid" ]; then
  # Every Mach-O in the bundle must carry a code signature. On arm64 iOS the
  # kernel refuses to map an unsigned image, so an unsigned .so fails at dlopen
  # with "code signature invalid" — which surfaces as an ImportError for the
  # module inside it. Signing only the main executable is not enough: the
  # framework and each extension module are loaded separately.
  #
  # Ad-hoc signatures do not cover nested content, so the order does not
  # matter; each image is signed independently.
  #
  # The entitlements are applied to the main executable only. They describe
  # process-level privileges — the memory ceiling in particular — which the
  # kernel reads from the main binary, and ldid rejects the plist on a nested
  # image that has no Info.plist to bind it to.
  ENTITLEMENTS="$ROOT/ios/PySCF.entitlements"
  MAIN_ENTITLEMENTS=""
  if [ -f "$ENTITLEMENTS" ]; then
    MAIN_ENTITLEMENTS="$ENTITLEMENTS"
    echo ">> embedding entitlements from ios/PySCF.entitlements"
  else
    echo "!! ios/PySCF.entitlements missing; signing without entitlements" >&2
  fi

  echo ">> ad-hoc signing bundled images"
  SIGNED=0
  while IFS= read -r -d '' candidate; do
    magic="$(head -c 4 "$candidate" | od -An -tx1 | tr -d ' \n')"
    case "$magic" in
      cffaedfe|cefaedfe|cafebabe|bebafeca|cafebabf|bfbafeca) ;;
      *) continue ;;
    esac
    if [ "$candidate" = "$EXECUTABLE" ] && [ -n "$MAIN_ENTITLEMENTS" ]; then
      if "$ROOT/build/toolchain/bin/ldid" -S"$MAIN_ENTITLEMENTS" "$candidate" 2>/dev/null; then
        SIGNED=$((SIGNED + 1))
      else
        echo "   could not sign $candidate with entitlements" >&2
      fi
    elif "$ROOT/build/toolchain/bin/ldid" -S "$candidate" 2>/dev/null; then
      SIGNED=$((SIGNED + 1))
    else
      echo "   could not sign $candidate" >&2
    fi
  done < <(find "$PRODUCT" -type f -print0)
  echo "   signed $SIGNED Mach-O images"
else
  echo "!! ldid not found; the bundle will not load its native modules on device" >&2
fi

echo
echo ">> built $PRODUCT"
du -sh "$PRODUCT"
echo "   executable: $(du -h "$EXECUTABLE" | cut -f1)"
