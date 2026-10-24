# Included automatically at the end of every project() call while cross
# compiling for iOS (wired up through CMAKE_PROJECT_INCLUDE in the toolchain
# file).
#
# Why this exists
# ---------------
# CMake's Modules/Platform/Darwin.cmake hard-codes
#
#     set(CMAKE_SHARED_LIBRARY_SUFFIX ".dylib")
#
# and it is loaded *after* the toolchain file, so setting the suffix there has
# no effect.  CMAKE_PROJECT_INCLUDE is processed after project() has finished
# enabling languages, which makes it the earliest point where an override
# sticks.
#
# The override is needed because CPython on iOS reports sys.platform == 'ios',
# not 'darwin'.  NumPy's and PySCF's ctypes loaders only special-case 'darwin'
# when guessing the extension, so for 'ios' they look for `<name>.so`.  Mach-O
# shared libraries are identified by their header, not their extension, so
# naming them .so is purely a loader-convenience choice.
set(CMAKE_SHARED_LIBRARY_SUFFIX ".so")
set(CMAKE_SHARED_LIBRARY_SUFFIX_CACHE ".so" CACHE STRING "" FORCE)
