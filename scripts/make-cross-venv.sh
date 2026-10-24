#!/usr/bin/env bash
# Create a cross-compiling virtual environment that targets arm64 iOS.
#
# The trick (borrowed from Python-Apple-support's own tooling) is that we do not
# cross-compile pip itself.  Instead we build a *normal* host virtual environment
# and then patch it so that, from Python's point of view, it is running on
# `arm64-iphoneos`.  pip then happily accepts sdists, and the compiler it
# invokes is our iOS clang wrapper, so the produced extension modules are real
# Mach-O arm64 dylibs.
#
# Result: build/cross-venv/bin/python, with `sys.platform == "ios"`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XC="$ROOT/build/python-ios/Python.xcframework/ios-arm64"
PLATFORM_CONFIG="$XC/platform-config/arm64-iphoneos"
VENV="${1:-$ROOT/build/cross-venv}"
HOST_PYTHON="${HOST_PYTHON:-python3}"

if [ ! -d "$PLATFORM_CONFIG" ]; then
  echo "!! platform config missing: $PLATFORM_CONFIG" >&2
  echo "   run scripts/setup-ios-toolchain.sh first" >&2
  exit 1
fi

# The sysconfigdata records the deployment target the framework was built with.
HOST_VERSION="$("$HOST_PYTHON" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
FRAMEWORK_VERSION="$(basename "$(dirname "$(dirname "$XC")")" | sed 's/.*python//;s/\././')"
echo ">> host python $HOST_VERSION, target framework $FRAMEWORK_VERSION"
if [ "$HOST_VERSION" != "3.13" ]; then
  echo "!! the iOS framework in build/python-ios is CPython 3.13;" >&2
  echo "   point HOST_PYTHON at a 3.13 interpreter." >&2
  exit 1
fi

if [ ! -x "$VENV/bin/python3" ]; then
  echo ">> creating virtual environment at $VENV"
  "$HOST_PYTHON" -m venv "$VENV"
fi

echo ">> installing pip/setuptools/wheel into the venv"
"$VENV/bin/python3" -m pip install --quiet --upgrade pip setuptools wheel

echo ">> cross-patching the environment for arm64-iphoneos"
"$VENV/bin/python3" "$PLATFORM_CONFIG/make_cross_venv.py" "$VENV" "$PLATFORM_CONFIG"

# Make the iOS compiler wrappers reachable for every build.
cat > "$VENV/bin/ios-build-env.sh" <<EOF
# Source this before invoking pip builds for iOS.
export PATH="$ROOT/scripts/ios-toolchain/bin:\$PATH"
export IOS_LLVM_TOOLCHAIN="$ROOT/build/toolchain"
export IOS_SDK_PATH="$ROOT/build/sdk/iPhoneOS15.6.sdk"
export IOS_DEPLOYMENT_TARGET=15.6
export _PYTHON_HOST_PLATFORM=ios-15.6-arm64-iphoneos
export ARCHFLAGS="-arch arm64"
export CC=arm64-apple-ios-clang
export CXX=arm64-apple-ios-clang++
export AR=arm64-apple-ios-ar
export RANLIB=arm64-apple-ios-ranlib
# pkg-config must not pick up host libraries.
export PKG_CONFIG_PATH=
EOF

echo
echo "cross environment ready:"
"$VENV/bin/python3" -c 'import sys, sysconfig; print("  sys.platform      :", sys.platform); print("  multiarch         :", sys.implementation._multiarch); print("  SOABI             :", sysconfig.get_config_var("SOABI")); print("  CC                :", sysconfig.get_config_var("CC"))'
echo
echo "Usage:"
echo "  source $VENV/bin/ios-build-env.sh"
echo "  $VENV/bin/pip install <package>"
