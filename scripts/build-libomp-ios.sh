#!/usr/bin/env bash
# Cross-compile the LLVM OpenMP runtime (libomp) for arm64 iOS.
#
# The iOS SDK ships no OpenMP runtime, so find_package(OpenMP) fails and PySCF
# falls back to serial loops.  On a desktop that is a performance question; on
# a phone the difference between one core and all of them is the difference
# between a usable app and a stalled one, so the runtime is built here.
#
# The version is pinned to the LLVM release that matches the cross-toolchain
# (clang 11.1.0): libomp and the compiler must agree on the ABI the compiler
# emits for `#pragma omp`, so a newer runtime is not an option.
#
# Two upstream files need a patch to build for iOS; both are carried inline
# below rather than as a separate .patch file, so the script stays self
# contained.
#
# Prerequisites (produced by the other scripts in this directory):
#   build/toolchain                     scripts/setup-ios-toolchain.sh
#   build/sdk/iPhoneOS15.6.sdk          scripts/setup-ios-toolchain.sh
#
# Output:
#   build/products/ios-arm64/deps/lib/libomp.so       the runtime
#   build/products/ios-arm64/deps/include/omp.h       its header
#
# It is a `.so` and not a `.dylib` because ios-cmake-project-include.cmake sets
# CMAKE_SHARED_LIBRARY_SUFFIX for every target; see AGENTS.md.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC="${LIBOMP_SRC:-$ROOT/build/src/llvm-openmp-11.1.0}"
BUILD="$ROOT/build/libomp-ios"
DEPS="$ROOT/build/products/ios-arm64/deps"
LOG="$ROOT/build/logs"

# The exact release the cross-toolchain's clang was built from.
LIBOMP_REPO="${LIBOMP_REPO:-https://github.com/llvm/llvm-project.git}"
LIBOMP_TAG="${LIBOMP_TAG:-llvmorg-11.1.0}"
LIBOMP_COMMIT="${LIBOMP_COMMIT:-1fdec59bffc11ae37eb51a1b9869f0696bfd5312}"

export PATH="$HOME/.local/bin:$PATH"

for tool in cmake ninja git; do
  command -v "$tool" >/dev/null || {
    echo ">> $tool not found on PATH" >&2
    exit 1
  }
done
for dir in "$ROOT/build/toolchain" "$ROOT/build/sdk/iPhoneOS15.6.sdk"; do
  [[ -d "$dir" ]] || {
    echo ">> missing $dir - run scripts/setup-ios-toolchain.sh first" >&2
    exit 1
  }
done

mkdir -p "$LOG" "$DEPS/lib" "$DEPS/include"

# ---------------------------------------------------------------------------
# Source
# ---------------------------------------------------------------------------
# Only openmp/ and compiler-rt/lib/builtins/ are needed; a full checkout is
# ~2 GB of mostly irrelevant history.  A blobless partial clone plus sparse
# checkout fetches a few tens of MB.
if [[ ! -d "$SRC/openmp/runtime/src" ]]; then
  echo ">> fetching llvm-project $LIBOMP_TAG (sparse: openmp, compiler-rt/lib/builtins)"
  rm -rf "$SRC"
  mkdir -p "$(dirname "$SRC")"
  git clone --filter=blob:none --no-checkout "$LIBOMP_REPO" "$SRC"
  git -C "$SRC" sparse-checkout init --cone
  git -C "$SRC" sparse-checkout set openmp compiler-rt/lib/builtins
  git -C "$SRC" checkout "$LIBOMP_COMMIT"
fi

ACTUAL=$(git -C "$SRC" rev-parse HEAD)
if [[ "$ACTUAL" != "$LIBOMP_COMMIT" ]]; then
  echo ">> $SRC is at $ACTUAL, expected $LIBOMP_COMMIT" >&2
  echo "   remove it and re-run to fetch the pinned revision" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Patches
# ---------------------------------------------------------------------------
# 1. z_Linux_asm.S
#
#    The AARCH64 `__kmp_unnamed_critical_addr` block emits `.size`, which is an
#    ELF directive; the Mach-O assembler rejects it ("unknown directive"), so
#    the whole library fails to assemble.  LLVM's main branch fixed this by
#    giving Darwin its own branch, which is what is applied here: the Darwin
#    symbol takes the underscore prefix and no `.size`.
ASM="$SRC/openmp/runtime/src/z_Linux_asm.S"
echo ">> patching z_Linux_asm.S for Mach-O"
python3 - "$ASM" <<'PY'
import sys

path = sys.argv[1]
with open(path) as handle:
    text = handle.read()

old = """#if KMP_ARCH_PPC64 || KMP_ARCH_AARCH64 || KMP_ARCH_MIPS64 || KMP_ARCH_RISCV64
    .data
    .comm .gomp_critical_user_,32,8
    .data
    .align 8
    .global __kmp_unnamed_critical_addr
__kmp_unnamed_critical_addr:
    .8byte .gomp_critical_user_
    .size __kmp_unnamed_critical_addr,8
#endif /* KMP_ARCH_PPC64 || KMP_ARCH_AARCH64 || KMP_ARCH_MIPS64 ||
          KMP_ARCH_RISCV64 */"""

new = """#if KMP_ARCH_PPC64 || KMP_ARCH_AARCH64 || KMP_ARCH_MIPS64 || KMP_ARCH_RISCV64
# if KMP_OS_DARWIN
    .data
    .comm .gomp_critical_user_,32
    .data
    .align 8
    .globl ___kmp_unnamed_critical_addr
___kmp_unnamed_critical_addr:
    .quad .gomp_critical_user_
# else /* Linux* OS */
    .data
    .comm .gomp_critical_user_,32,8
    .data
    .align 8
    .global __kmp_unnamed_critical_addr
__kmp_unnamed_critical_addr:
    .8byte .gomp_critical_user_
    .size __kmp_unnamed_critical_addr,8
# endif /* KMP_OS_DARWIN */
#endif /* KMP_ARCH_PPC64 || KMP_ARCH_AARCH64 || KMP_ARCH_MIPS64 ||
          KMP_ARCH_RISCV64 */"""

if new in text:
    sys.exit(0)  # already patched
if old not in text:
    sys.exit("z_Linux_asm.S does not match the expected 11.1.0 content")
with open(path, "w") as handle:
    handle.write(text.replace(old, new, 1))
PY

# 2. runtime/src/CMakeLists.txt
#
#    kmp_atomic.cpp calls __divdc3/__divsc3 for complex division.  On Apple
#    platforms those live in compiler-rt, which is not part of the iOS SDK, and
#    ld64.lld will not pull them out of libSystem's .tbd stub even though it
#    lists them.  Compiling the two canonical implementations into libomp
#    resolves the link without depending on a runtime that iOS does not ship.
OMP_CMAKE="$SRC/openmp/runtime/src/CMakeLists.txt"
if ! grep -q "pyscf-ios: complex-division builtins" "$OMP_CMAKE"; then
  echo ">> patching runtime/src/CMakeLists.txt for the missing builtins"
  python3 - "$OMP_CMAKE" <<'PY'
import sys

path = sys.argv[1]
with open(path) as handle:
    text = handle.read()

anchor = """  libomp_append(LIBOMP_CXXFILES kmp_taskdeps.cpp)
  libomp_append(LIBOMP_CXXFILES kmp_cancel.cpp)
endif()"""

addition = """  libomp_append(LIBOMP_CXXFILES kmp_taskdeps.cpp)
  libomp_append(LIBOMP_CXXFILES kmp_cancel.cpp)
  # pyscf-ios: complex-division builtins
  # iOS has no compiler-rt: libSystem declares these builtins but ld64.lld will
  # not resolve them out of the SDK stub, so bring the two the atomic
  # implementation needs into the library itself.
  if(APPLE)
    set(LIBOMP_IOS_BUILTINS_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../compiler-rt/lib/builtins)
    if(EXISTS ${LIBOMP_IOS_BUILTINS_DIR}/divdc3.c)
      include_directories(${LIBOMP_IOS_BUILTINS_DIR})
      set(LIBOMP_IOS_BUILTIN_SRCS
          ${LIBOMP_IOS_BUILTINS_DIR}/divdc3.c
          ${LIBOMP_IOS_BUILTINS_DIR}/divsc3.c)
    endif()
  endif()
endif()"""

if anchor not in text:
    sys.exit("runtime/src/CMakeLists.txt does not match the expected 11.1.0 content")
text = text.replace(anchor, addition, 1)

sources = "set(LIBOMP_SOURCE_FILES ${LIBOMP_CXXFILES} ${LIBOMP_ASMFILES})"
if sources not in text:
    sys.exit("could not find LIBOMP_SOURCE_FILES in runtime/src/CMakeLists.txt")
text = text.replace(
    sources,
    "set(LIBOMP_SOURCE_FILES ${LIBOMP_CXXFILES} ${LIBOMP_ASMFILES} ${LIBOMP_IOS_BUILTIN_SRCS})",
    1,
)

with open(path, "w") as handle:
    handle.write(text)
PY
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
# CMake 4 removed compatibility with the `cmake_minimum_required(VERSION 2.8)`
# that LLVM 11 declares; the policy floor lets it configure anyway.
rm -rf "$BUILD"
echo ">> configuring libomp for arm64-ios"
cmake -S "$SRC/openmp" -B "$BUILD" -G Ninja \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_TOOLCHAIN_FILE="$ROOT/scripts/ios-cmake-toolchain.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DLIBOMP_ARCH=aarch64 \
  -DLIBOMP_ENABLE_SHARED=ON \
  -DLIBOMP_OMPT_SUPPORT=OFF \
  -DLIBOMP_USE_HWLOC=OFF \
  -DLIBOMP_FORTRAN_MODULES=OFF \
  2>&1 | tee "$LOG/libomp-configure.log"

echo ">> building libomp"
cmake --build "$BUILD" --parallel "${JOBS:-4}" \
  2>&1 | tee "$LOG/libomp-build.log"

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
# The library keeps the name and @rpath install name CMake gave it, which is
# `libomp.so`: the project-include file overrides the shared-library suffix for
# every target so the Python loaders find extension modules on `sys.platform ==
# 'ios'`.  PySCF links it by absolute path (the OpenMP target carries the path,
# not `-lomp`), and the extension modules already have an @loader_path rpath, so
# dropping it beside them is enough to resolve.
cp "$BUILD/runtime/src/libomp.so" "$DEPS/lib/libomp.so"
cp "$BUILD/runtime/src/omp.h" "$DEPS/include/omp.h"

echo ">> installed:"
ls -la "$DEPS/lib/libomp.so" "$DEPS/include/omp.h"
