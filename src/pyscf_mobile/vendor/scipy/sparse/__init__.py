"""NumPy-backed replacement for the parts of :mod:`scipy.sparse` PySCF uses.

PySCF's ``pyscf/grad/lagrange.py`` imports ``LinearOperator`` and ``cg`` from
``scipy.sparse.linalg``.  Both are provided: ``LinearOperator`` is a thin
matrix-free wrapper, and ``cg`` is a real preconditioned conjugate-gradient
solver.  ``gmres`` is also present because ``pyscf/lib/linalg_helper.py``
imports it inside a function.
"""

from __future__ import annotations

import numpy as np

from . import linalg  # noqa: F401  (re-exported as scipy.sparse.linalg)

__all__ = ["linalg"]
