"""Vendored stand-ins for the third-party packages PySCF needs but iOS cannot build.

PySCF imports ``scipy`` and ``h5py`` unconditionally.  On iOS neither can be
cross-compiled with the open-source toolchain this project uses (SciPy's core is
Fortran wrapped by f2py, and h5py needs libhdf5), so this directory contains
NumPy-backed reimplementations of the subset PySCF actually touches.

Call :func:`install` before importing PySCF to put these modules in front of any
system copies.  ``pyscf_mobile`` does this automatically on iOS.
"""

from __future__ import annotations

import importlib
import os
import sys

__all__ = ["install", "is_installed", "VENDOR_DIR"]

VENDOR_DIR = os.path.dirname(os.path.abspath(__file__))

# Set to "0" to keep the platform's own scipy/h5py even on iOS.
_ENV_FLAG = "PYSCF_MOBILE_VENDOR"


def is_installed() -> bool:
    """Report whether the vendored modules are currently the ones importable."""
    try:
        for name in ("scipy", "h5py"):
            mod = sys.modules.get(name)
            if mod is None:
                return False
            path = getattr(mod, "__file__", "") or ""
            if os.path.dirname(os.path.dirname(path)) != VENDOR_DIR:
                return False
        return True
    except Exception:  # pragma: no cover - defensive
        return False


def install(force: bool = False) -> bool:
    """Make the vendored ``scipy`` and ``h5py`` importable.

    Returns True if the vendored copies are in place afterwards.  The modules are
    placed at the front of ``sys.path`` and any already-imported system copies are
    dropped, so the replacement takes effect even if something imported them
    earlier.

    The shims are installed when any of these hold:

    * ``force=True``,
    * the interpreter reports ``sys.platform == "ios"``,
    * ``scipy`` or ``h5py`` cannot be imported from the existing path.
    """
    if os.environ.get(_ENV_FLAG) == "0":
        return is_installed()

    if not (force or sys.platform == "ios"):
        if _importable("scipy") and _importable("h5py"):
            return False

    if VENDOR_DIR in sys.path:
        sys.path.remove(VENDOR_DIR)
    sys.path.insert(0, VENDOR_DIR)

    # Anything already loaded would shadow the vendored copies.
    for name in ("scipy", "h5py"):
        for mod in [m for m in sys.modules if m == name or m.startswith(name + ".")]:
            del sys.modules[mod]

    importlib.invalidate_caches()

    # Import both to confirm the vendored copies are the ones that resolve, and
    # so callers can rely on the modules being ready.
    try:
        importlib.import_module("scipy")
        importlib.import_module("h5py")
    except Exception:
        return False
    return is_installed()


def _importable(name: str) -> bool:
    try:
        importlib.import_module(name)
        return True
    except Exception:
        for mod in [m for m in sys.modules if m == name or m.startswith(name + ".")]:
            del sys.modules[mod]
        return False
