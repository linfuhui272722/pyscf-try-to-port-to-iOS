# Build-time configuration for PySCF's C extensions on arm64 iOS.
#
# Included automatically by pyscf/lib/CMakeLists.txt when present (line ~67),
# which is the supported hook for overriding dependency discovery, BLAS and
# OpenMP.  PySCF's own CMakeLists files are left untouched.
#
# The pre-built dependencies live in the deps prefix installed by
# scripts/build-pyscf-ios.sh.

get_filename_component(_ios_root "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
if(NOT DEFINED IOS_DEPS_PREFIX)
  set(IOS_DEPS_PREFIX "${_ios_root}/build/products/ios-arm64/deps")
endif()

# ---------------------------------------------------------------------------
# BLAS / LAPACK
# ---------------------------------------------------------------------------
# find_package(BLAS) cannot work while cross-compiling: it decides by linking a
# *runnable* probe.  Apple's Accelerate framework already exports the reference
# symbols PySCF uses (dgemm_, zungqr_, cblas_dgemm), so linking the framework is
# enough.  PySCF interpolates these into target_link_libraries().
set(BLAS_LIBRARIES "-framework Accelerate" CACHE STRING "" FORCE)
set(LAPACK_LIBRARIES "-framework Accelerate" CACHE STRING "" FORCE)

# ---------------------------------------------------------------------------
# OpenMP
# ---------------------------------------------------------------------------
# PySCF enables OpenMP whenever find_package(OpenMP) succeeds, but that module
# decides by compiling and *running* a probe program, which cannot work while
# cross-compiling.  The probe is skipped when the result variables are already
# defined, so the answers are supplied here directly: -fopenmp for the compiler,
# and the libomp built by scripts/build-libomp-ios.sh for the link.
#
# Both languages need answering.  The project enables C and CXX, and
# find_package(OpenMP) reports OpenMP_FOUND only when *every* loaded language
# was found, so supplying the C variables alone leaves OpenMP_FOUND false and
# PySCF silently builds serial code.
#
# OpenMP_C_INCLUDE_DIR matters as much as the library: clang's own resource
# directory has no omp.h, so `#include <omp.h>` only resolves through the -I
# this adds.
if(EXISTS "${IOS_DEPS_PREFIX}/lib/libomp.so")
  foreach(_omp_lang C CXX)
    set(OpenMP_${_omp_lang}_FLAGS "-fopenmp" CACHE STRING "" FORCE)
    set(OpenMP_${_omp_lang}_LIB_NAMES "omp" CACHE STRING "" FORCE)
    set(OpenMP_omp_LIBRARY "${IOS_DEPS_PREFIX}/lib/libomp.so" CACHE FILEPATH "" FORCE)
    set(OpenMP_${_omp_lang}_INCLUDE_DIR "${IOS_DEPS_PREFIX}/include" CACHE PATH "" FORCE)
  endforeach()
  set(ENABLE_OPENMP ON CACHE BOOL "" FORCE)
  # PySCF's subdirectories add their own include_directories() when they are
  # processed, which come *before* the ones this file sets, so omp.h has to be
  # registered here rather than relying on the OpenMP target's interface.
  include_directories("${IOS_DEPS_PREFIX}/include")
else()
  set(ENABLE_OPENMP OFF CACHE BOOL "" FORCE)
endif()

# ---------------------------------------------------------------------------
# Pre-built libcint / libxc
# ---------------------------------------------------------------------------
# PySCF links these by bare name (`target_link_libraries(cgto cint ...)`,
# `target_link_libraries(xc_itrf xc ...)`).  Defining IMPORTED targets with the
# same names makes CMake use our iOS builds, and -- importantly -- records the
# absolute path in the link line, so no -L/-l search happens.
add_library(cint SHARED IMPORTED GLOBAL)
set_target_properties(cint PROPERTIES
  IMPORTED_LOCATION "${IOS_DEPS_PREFIX}/lib/libcint.so"
  INTERFACE_INCLUDE_DIRECTORIES "${IOS_DEPS_PREFIX}/include")

add_library(xc SHARED IMPORTED GLOBAL)
set_target_properties(xc PROPERTIES
  IMPORTED_LOCATION "${IOS_DEPS_PREFIX}/lib/libxc.so"
  INTERFACE_INCLUDE_DIRECTORIES "${IOS_DEPS_PREFIX}/include")

# The ExternalProject_Add() blocks must not run: they download sources and
# configure a *nested* build that would target the Linux host instead of iOS.
set(BUILD_LIBCINT OFF CACHE BOOL "" FORCE)
set(ENABLE_LIBXC ON CACHE BOOL "" FORCE)
set(BUILD_LIBXC OFF CACHE BOOL "" FORCE)
set(ENABLE_XCFUN OFF CACHE BOOL "" FORCE)
set(BUILD_XCFUN OFF CACHE BOOL "" FORCE)
set(ENABLE_LIBXSMM OFF CACHE BOOL "" FORCE)
set(BUILD_LIBXSMM OFF CACHE BOOL "" FORCE)
set(ENABLE_FFTW OFF CACHE BOOL "" FORCE)
set(BUILD_FFTW OFF CACHE BOOL "" FORCE)
