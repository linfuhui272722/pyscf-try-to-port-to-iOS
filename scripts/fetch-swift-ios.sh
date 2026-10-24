#!/usr/bin/env bash
# Fetch the Swift toolchain used to compile the app's SwiftUI layer for iOS.
#
# Linux Swift releases ship a full LLVM toolchain, including clang and ld64.lld.
# The app needs Swift 5.6 specifically: its bundled ld64.lld is LLD 13, the last
# version that accepts `-platform_version ios`.  Newer LLD refuses to link for
# iOS outright (see AGENTS.md).
#
# The toolchain is installed under build/ rather than /tmp so it survives a
# reboot and so a fresh clone can rebuild with the documented pipeline.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOWNLOAD_DIR="$ROOT/toolchain-dl"
PREFIX="${IOS_SWIFT_PREFIX:-$ROOT/build/swift}"

SWIFT_VERSION="${IOS_SWIFT_VERSION:-5.6}"
SWIFT_URL="${IOS_SWIFT_URL:-https://download.swift.org/swift-${SWIFT_VERSION}-release/ubuntu2004/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE-ubuntu20.04.tar.gz}"
# Set IOS_SWIFT_SHA256 to enforce a checksum; left empty by default because the
# swift.org release is republished in place for some older versions, which would
# make a pinned hash fail spuriously on an otherwise good download.
SWIFT_SHA256="${IOS_SWIFT_SHA256:-}"

mkdir -p "$DOWNLOAD_DIR"

if [ -x "$PREFIX/usr/bin/swiftc" ]; then
  echo ">> Swift toolchain already installed at $PREFIX"
else
  echo ">> fetching Swift ${SWIFT_VERSION} for Linux"
  archive="$DOWNLOAD_DIR/swift-${SWIFT_VERSION}-RELEASE-ubuntu20.04.tar.gz"
  if [ ! -f "$archive" ]; then
    curl -L --fail --retry 3 -o "$archive.part" "$SWIFT_URL"
    if [ -n "$SWIFT_SHA256" ]; then
      actual="$(sha256sum "$archive.part" | cut -d' ' -f1)"
      if [ "$actual" != "$SWIFT_SHA256" ]; then
        echo "!! checksum mismatch: expected $SWIFT_SHA256, got $actual" >&2
        rm -f "$archive.part"
        exit 1
      fi
    fi
    mv "$archive.part" "$archive"
  fi

  staging="$(mktemp -d)"
  trap 'rm -rf "$staging"' EXIT
  tar -xzf "$archive" -C "$staging"
  # The tarball contains a single swift-<version>-RELEASE-ubuntu20.04/ directory.
  extracted="$(find "$staging" -maxdepth 1 -mindepth 1 -type d | head -1)"
  [ -n "$extracted" ] || {
    echo "!! could not find the extracted toolchain directory" >&2
    exit 1
  }
  rm -rf "$PREFIX"
  mv "$extracted" "$PREFIX"
fi

# Swift 5.6 links against ncurses6/tinfo6, which newer distributions only ship
# under the wide-character names.  build-ios-app.sh supplies those aliases via
# LD_LIBRARY_PATH at compile time; check here so the failure is reported up
# front rather than midway through a build.
if ! "$PREFIX/usr/bin/swiftc" --version >/dev/null 2>&1; then
  echo "!! swiftc cannot run; it probably needs libncursesw.so.6 / libtinfo.so.6" >&2
  exit 1
fi

echo
echo ">> Swift: $PREFIX/usr/bin/swiftc"
"$PREFIX/usr/bin/swiftc" --version | head -2
echo ">> LLD:   $("$PREFIX/usr/bin/ld64.lld" --version | head -1)"
