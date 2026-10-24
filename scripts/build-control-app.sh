#!/usr/bin/env bash
# Build a minimal control app for diagnosing the TrollStore 181 failure.
#
# PySCF.app fails to install with "Unable to register" (exit 181), and every
# layer that can be inspected from the build host checks out: the Info.plist
# matches TrollStore's own working app, all 109 binaries are arm64/iOS with
# valid ad-hoc signatures, and the icons are well formed. What cannot be
# checked from here is the payload, because the payload is the only unusual
# thing about this bundle - a nested Python framework, a 36 MB stdlib tree and
# 100+ re-signed .so files.
#
# This script builds the same app with the same toolchain, SDK, Info.plist keys
# and signing, but with none of that payload. Installing it separates the two
# possibilities:
#
#   control installs, PySCF does not  -> the payload is at fault
#   both fail                         -> the plist or the signing is at fault
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SDK="${IOS_SDK_PATH:-$ROOT/build/sdk/iPhoneOS15.6.sdk}"
SWIFT="${IOS_SWIFT:-$ROOT/build/swift/usr/bin/swiftc}"
SWIFT_RESOURCE_DIR="${IOS_SWIFT_RESOURCE_DIR:-$ROOT/build/swift-resource}"
LINKER="${IOS_LD64:-$ROOT/build/swift/usr/bin/ld64.lld}"

DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-15.6}"
# Same identifier as PySCF.app on purpose. The failing install and this control
# then differ in exactly one respect - the payload - so the result isolates it.
# A fresh identifier here would change two variables at once and leave the
# outcome ambiguous.
BUNDLE_ID="${IOS_BUNDLE_ID:-dev.pyscf.mobile}"
APP_NAME="PySCFControl"
PRODUCT="$ROOT/build/products/ios-arm64/$APP_NAME.app"
EXECUTABLE="$PRODUCT/$APP_NAME"

for path in "$SDK" "$SWIFT" "$LINKER"; do
  if [ ! -e "$path" ]; then
    echo "!! missing $path" >&2
    exit 1
  fi
done

rm -rf "$PRODUCT"
mkdir -p "$PRODUCT"

LDSHIM="$(mktemp -d)"
SWIFTLIBS="$(mktemp -d)"
SRCDIR="$(mktemp -d)"
trap 'rm -rf "$LDSHIM" "$SWIFTLIBS" "$SRCDIR"' EXIT

printf '#!/bin/sh\nexec %s "$@"\n' "$LINKER" > "$LDSHIM/ld"
chmod +x "$LDSHIM/ld"

for lib in libncursesw.so.6 libtinfo.so.6; do
  for candidate in /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu /usr/lib64 /usr/lib; do
    if [ -e "$candidate/$lib" ] && [ ! -e "$SWIFTLIBS/$lib" ]; then
      ln -s "$candidate/$lib" "$SWIFTLIBS/$lib"
    fi
  done
done
if [ ! -e "$SWIFTLIBS/libncurses.so.6" ] && [ -e "$SWIFTLIBS/libncursesw.so.6" ]; then
  ln -s libncursesw.so.6 "$SWIFTLIBS/libncurses.so.6"
fi

cat > "$SRCDIR/main.swift" <<'SWIFT'
import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let window = UIWindow(frame: UIScreen.main.bounds)
    let controller = UIViewController()
    controller.view.backgroundColor = .systemBackground
    window.rootViewController = controller
    window.makeKeyAndVisible()
    self.window = window
    return true
  }
}
SWIFT

echo ">> compiling control app"
PATH="$LDSHIM:$PATH" LD_LIBRARY_PATH="$SWIFTLIBS:${LD_LIBRARY_PATH:-}" \
  "$SWIFT" \
  -target "arm64-apple-ios$DEPLOYMENT_TARGET" \
  -sdk "$SDK" \
  -resource-dir "$SWIFT_RESOURCE_DIR" \
  -parse-as-library \
  -swift-version 5 \
  -O \
  -Xfrontend -suppress-warnings \
  -o "$EXECUTABLE" "$SRCDIR/main.swift"

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
    <key>CFBundleName</key><string>PySCF Control</string>
    <key>CFBundleDisplayName</key><string>PySCF Ctrl</string>
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
</dict>
</plist>
PLIST

printf 'APPL????' > "$PRODUCT/PkgInfo"

if [ -x "$ROOT/build/toolchain/bin/ldid" ]; then
  echo ">> ad-hoc signing"
  "$ROOT/build/toolchain/bin/ldid" -S "$EXECUTABLE"
fi

echo
echo ">> built $PRODUCT"
du -sh "$PRODUCT"
