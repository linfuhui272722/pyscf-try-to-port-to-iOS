"""Build script for the _pyscf_mobile_accel C extension.

When run inside the arm64-iphoneos cross environment the compiler is already
iOS clang, so a plain ``pip install .`` produces an iOS dylib.  On a desktop
machine the same command produces a native module, which is what the test-suite
uses.
"""

from setuptools import Extension, setup

setup(
    ext_modules=[
        Extension(
            "_pyscf_mobile_accel",
            sources=["_pyscf_mobile_accel.c"],
            extra_compile_args=["-O2", "-fPIC"],
        )
    ]
)
