#!/usr/bin/env bash
# Fetch the iOS SDK and the Darwin cross-toolchain used to build for iOS from a
# Linux host.
#
# Apple's toolchain cannot run on Linux, so this installs the two pieces the
# open-source route needs:
#
#   * theos/sdks       -- the iPhoneOS 15.6 SDK (headers, stubs, .tbd files)
#   * L1ghtmann's LLVM -- clang/ld64.lld and the Darwin utilities (ld,
#                         install_name_tool, ...) built for Linux
#
# Everything lands under build/ and is skipped if already present, so re-running
# is cheap.  Override IOS_SDK_VERSION to target a different SDK; 15.6 is what
# the app is built and validated against.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOWNLOAD_DIR="$ROOT/toolchain-dl"
SDK_ROOT="$ROOT/build/sdk"
TOOLCHAIN="$ROOT/build/toolchain"

SDK_VERSION="${IOS_SDK_VERSION:-15.6}"
SDK_URL="${IOS_SDK_URL:-https://github.com/theos/sdks/releases/download/master-146e41f/iPhoneOS${SDK_VERSION}.sdk.tar.xz}"
SDK_SHA256="${IOS_SDK_SHA256:-c4a02f5cac1101d1e5e506a1d117de38fd23714a6f535d50c64265bc7351f623}"

# The toolchain is x86_64 or aarch64 depending on the build host, and the
# release tag is pinned rather than "latest" so the checksums below stay valid.
case "$(uname -m)" in
  aarch64|arm64)
    TOOLCHAIN_ASSET="iOSToolchain-aarch64.tar.xz"
    TOOLCHAIN_SHA256="${IOS_TOOLCHAIN_SHA256:-}"
    ;;
  *)
    TOOLCHAIN_ASSET="iOSToolchain-x86_64.tar.xz"
    TOOLCHAIN_SHA256="${IOS_TOOLCHAIN_SHA256:-a72a7a577e2fbe2838b6b5e9c72034fa7d114af96f0e1d4b016f18730ce4056e}"
    ;;
esac

TOOLCHAIN_TAG="${IOS_TOOLCHAIN_TAG:-test-210562a}"
TOOLCHAIN_URL="${IOS_TOOLCHAIN_URL:-https://github.com/L1ghtmann/llvm-project/releases/download/${TOOLCHAIN_TAG}/${TOOLCHAIN_ASSET}}"

mkdir -p "$DOWNLOAD_DIR"

download() {
  local url="$1" dest="$2" sha="$3"
  if [ -f "$dest" ]; then
    if [ -z "$sha" ] || [ "$(sha256sum "$dest" | cut -d' ' -f1)" = "$sha" ]; then
      echo "   cached $(basename "$dest")"
      return
    fi
  fi
  echo "   downloading $(basename "$dest")"
  curl -L --fail --retry 3 -o "$dest.part" "$url"
  if [ -n "$sha" ]; then
    local actual
    actual="$(sha256sum "$dest.part" | cut -d' ' -f1)"
    if [ "$actual" != "$sha" ]; then
      echo "!! checksum mismatch for $(basename "$dest")" >&2
      echo "   expected $sha" >&2
      echo "   actual   $actual" >&2
      rm -f "$dest.part"
      exit 1
    fi
  fi
  mv "$dest.part" "$dest"
}

# ---------------------------------------------------------------------------
# 1. iOS SDK
# ---------------------------------------------------------------------------
if [ -d "$SDK_ROOT/iPhoneOS${SDK_VERSION}.sdk" ]; then
  echo ">> SDK iPhoneOS${SDK_VERSION} already installed"
else
  echo ">> fetching iPhoneOS${SDK_VERSION} SDK"
  archive="$DOWNLOAD_DIR/iPhoneOS${SDK_VERSION}.sdk.tar.xz"
  download "$SDK_URL" "$archive" "$SDK_SHA256"
  mkdir -p "$SDK_ROOT"
  tar -xJf "$archive" -C "$SDK_ROOT"
  [ -d "$SDK_ROOT/iPhoneOS${SDK_VERSION}.sdk" ] || {
    echo "!! SDK extracted but iPhoneOS${SDK_VERSION}.sdk is missing" >&2
    exit 1
  }
fi

# ---------------------------------------------------------------------------
# 2. Darwin cross-toolchain
#
# The release unpacks to linux/iphone/, which is the layout theos expects.
# Symlinking it to build/toolchain keeps the scripts independent of theos.
# ---------------------------------------------------------------------------
if [ -x "$TOOLCHAIN/bin/clang" ]; then
  echo ">> cross-toolchain already installed"
else
  echo ">> fetching Darwin cross-toolchain"
  archive="$DOWNLOAD_DIR/iOSToolchain-x86_64.tar.xz"
  download "$TOOLCHAIN_URL" "$archive" "$TOOLCHAIN_SHA256"

  staging="$(mktemp -d)"
  trap 'rm -rf "$staging"' EXIT
  tar -xJf "$archive" -C "$staging"
  [ -d "$staging/linux/iphone/bin" ] || {
    echo "!! toolchain archive did not contain linux/iphone/bin" >&2
    exit 1
  }
  rm -rf "$TOOLCHAIN"
  mv "$staging/linux/iphone" "$TOOLCHAIN"
fi

for tool in clang ld; do
  [ -e "$TOOLCHAIN/bin/$tool" ] || {
    echo "!! cross-toolchain is missing bin/$tool" >&2
    exit 1
  }
done

echo
echo ">> SDK:       $SDK_ROOT/iPhoneOS${SDK_VERSION}.sdk"
echo ">> toolchain: $TOOLCHAIN"
echo "   clang:     $("$TOOLCHAIN/bin/clang" --version | head -1)"
