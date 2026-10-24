# CMake toolchain file for cross-compiling to arm64 iOS from a Linux host.
#
# CMake has first-class iOS support via CMAKE_SYSTEM_NAME=iOS, but it normally
# leans on Apple's `xcrun` to locate the SDK and the compiler.  Both are
# replaced here with explicit paths, and the compiler itself is our
# arm64-apple-ios-clang wrapper, so nothing Apple-only is required.
#
# Usage:
#   cmake -S <src> -B <build> \
#     -DCMAKE_TOOLCHAIN_FILE=scripts/ios-cmake-toolchain.cmake \
#     -DCMAKE_INSTALL_PREFIX=<prefix>

set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR arm64)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_DEPLOYMENT_TARGET "15.6" CACHE STRING "")

# Resolve the repository root from this file's location (scripts/).
get_filename_component(_ios_root "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)

if(NOT DEFINED IOS_SDK_PATH)
  set(IOS_SDK_PATH "${_ios_root}/build/sdk/iPhoneOS15.6.sdk")
endif()
if(NOT DEFINED IOS_LLVM_TOOLCHAIN)
  set(IOS_LLVM_TOOLCHAIN "${_ios_root}/build/toolchain")
endif()
if(NOT DEFINED IOS_TOOLCHAIN_BIN)
  set(IOS_TOOLCHAIN_BIN "${_ios_root}/scripts/ios-toolchain/bin")
endif()

set(CMAKE_OSX_SYSROOT "${IOS_SDK_PATH}" CACHE PATH "")

# CMake wants to run `xcrun` to inspect the SDK; we already know everything it
# would report.
set(CMAKE_OSX_SYSROOT_LOCAL "${IOS_SDK_PATH}")
set(CMAKE_OSX_ARCHITECTURES "arm64")

set(CMAKE_C_COMPILER   "${IOS_TOOLCHAIN_BIN}/arm64-apple-ios-clang")
set(CMAKE_CXX_COMPILER "${IOS_TOOLCHAIN_BIN}/arm64-apple-ios-clang++")
set(CMAKE_AR           "${IOS_TOOLCHAIN_BIN}/arm64-apple-ios-ar")
set(CMAKE_RANLIB       "${IOS_TOOLCHAIN_BIN}/arm64-apple-ios-ranlib")
set(CMAKE_INSTALL_NAME_TOOL "${IOS_LLVM_TOOLCHAIN}/bin/llvm-install-name-tool" CACHE FILEPATH "")

# The build host cannot execute arm64 iOS binaries.
set(CMAKE_CROSSCOMPILING_EMULATOR "")
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# CMake's Darwin.cmake turns every executable into a .app bundle by default.
# The helper binaries these libraries build (xc-info, etc.) are build-time
# tools, not apps, and bundling makes `install(TARGETS ...)` demand a BUNDLE
# DESTINATION.
set(CMAKE_MACOSX_BUNDLE OFF CACHE BOOL "" FORCE)

# CPython on iOS reports sys.platform == 'ios', so NumPy's and PySCF's ctypes
# loaders probe for `<name>.so` rather than `<name>.dylib` (they only
# special-case 'darwin').  The suffix is overridden in a project-include file
# because CMake's Darwin.cmake sets it after this file is read.
set(CMAKE_PROJECT_INCLUDE "${CMAKE_CURRENT_LIST_DIR}/ios-cmake-project-include.cmake")

# Only look inside the SDK for headers and libraries; never fall back to the
# Linux host's /usr/include.
set(CMAKE_FIND_ROOT_PATH "${IOS_SDK_PATH}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# Make the wrapper's environment assumptions explicit for child builds
# (ExternalProject passes CMAKE_ARGS, not the ambient environment).
set(ENV{IOS_SDK_PATH} "${IOS_SDK_PATH}")
set(ENV{IOS_LLVM_TOOLCHAIN} "${IOS_LLVM_TOOLCHAIN}")
set(ENV{IOS_DEPLOYMENT_TARGET} "15.6")
set(ENV{PATH} "${IOS_TOOLCHAIN_BIN}:$ENV{PATH}")
