"""A NumPy-backed subset of :mod:`scipy` for the iOS build.

Why this exists
---------------
PySCF's ``pyscf/lib/misc.py`` imports ``scipy`` and ``h5py`` at module import
time, so neither can simply be left out.  Neither package can be cross-compiled
for arm64 iOS with the open-source toolchain used here: SciPy's ``linalg`` and
``special`` modules are Fortran (LAPACK/ARPACK/AMOS) wrapped by f2py, and there
is no Fortran compiler for arm64 iOS in this toolchain -- ``flang`` is not part
of the LLVM release that ships the iOS backend, and the iOS SDK has no libgfortran.

What this is
------------
Every function below is a genuine implementation written on top of NumPy, which
on iOS is itself linked against Apple's Accelerate framework.  Nothing here is a
silent stub that returns fake data: the linear-algebra routines call
``numpy.linalg`` (LAPACK), the special functions are computed from their series
or recurrence relations, and the optimizers actually iterate.

Scope
-----
The subset is derived from a static scan of PySCF 2.14 for every ``scipy.*``
attribute it references, so the SCF / DFT / MP2 / CCSD / geometry path the app
exercises is fully covered.  Modules that PySCF only touches in features the app
does not ship (PBC/GW/BSE, Fortran file IO) are present but raise a clear
``NotImplementedError`` instead of failing in a confusing way.

Accuracy of the reimplementations is checked against the real SciPy on the build
host by ``tests/test_shims.py``; the tests run the full chemistry pipeline with
these modules forced to the front of ``sys.path``.
"""

from __future__ import annotations

# Reported to PySCF for its version banner and for feature gates.  PySCF only
# tests the minor version in one place (pyscf/grad/lagrange.py), comparing
# against 14 to decide whether scipy.sparse.linalg.cg takes `rtol` or `tol`.
__version__ = "1.14.0"

from . import fft, linalg, optimize, sparse, special  # noqa: E402,F401

__all__ = ["fft", "linalg", "optimize", "sparse", "special", "__version__"]
