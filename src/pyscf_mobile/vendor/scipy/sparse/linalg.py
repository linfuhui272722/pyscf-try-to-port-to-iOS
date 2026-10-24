"""Matrix-free linear solvers replacing :mod:`scipy.sparse.linalg`.

Provides the ``LinearOperator`` container, a preconditioned conjugate-gradient
solver (``cg``) and a restarted GMRES solver (``gmres``).  PySCF uses ``cg`` in
its gradient Lagrange multiplier solve and ``gmres`` in a general linear solver
helper.
"""

from __future__ import annotations

import numpy as np

__all__ = ["LinearOperator", "aslinearoperator", "cg", "gmres"]


class LinearOperator:
    """Matrix-free linear operator, mirroring ``scipy.sparse.linalg.LinearOperator``.

    Either ``matvec`` (and optionally ``rmatvec``) or a dense ``dtype`` plus
    ``shape`` must be supplied.  ``matmat`` falls back to column-wise ``matvec``.
    """

    def __init__(self, shape, matvec=None, rmatvec=None, matmat=None, dtype=None,
                 **kwargs):
        if matvec is None and rmatvec is None and matmat is None:
            raise ValueError("LinearOperator needs at least one of matvec/rmatvec/matmat")
        self.shape = tuple(shape)
        self._matvec = matvec
        self._rmatvec = rmatvec
        self._matmat = matmat
        self.dtype = np.dtype(dtype) if dtype is not None else np.dtype(float)

    def matvec(self, x):
        if self._matvec is not None:
            return self._matvec(x)
        if self._matmat is not None:
            return self._matmat(np.asarray(x).reshape(-1, 1)).ravel()
        raise NotImplementedError("matvec is not defined for this operator")

    def rmatvec(self, x):
        if self._rmatvec is not None:
            return self._rmatvec(x)
        # Fall back to the adjoint via the transpose of the matvec.
        return self._adjoint_matvec(x)

    def matmat(self, x):
        x = np.asarray(x)
        if self._matmat is not None:
            return self._matmat(x)
        if x.ndim == 1:
            return self.matvec(x)
        return np.column_stack([self.matvec(x[:, j]) for j in range(x.shape[1])])

    def _adjoint_matvec(self, x):
        n = self.shape[0]
        cols = []
        for j in range(n):
            e = np.zeros(n, dtype=complex)
            e[j] = 1.0
            cols.append(np.vdot(self.matvec(e), x))
        return np.asarray(cols)

    def __matmul__(self, x):
        return self.matvec(x)

    def dot(self, x):
        x = np.asarray(x)
        return self.matmat(x) if x.ndim == 2 else self.matvec(x)


def aslinearoperator(a):
    if isinstance(a, LinearOperator):
        return a
    a = np.asarray(a)
    return LinearOperator(a.shape, matvec=lambda x: a @ x, rmatvec=lambda x: a.conj().T @ x,
                          matmat=lambda x: a @ x, dtype=a.dtype)


def cg(A, b, x0=None, tol=1e-5, maxiter=None, M=None, callback=None,
       atol=0.0, rtol=None):
    """Preconditioned conjugate gradient.

    Accepts both the modern ``rtol``/``atol`` keywords and the legacy ``tol``,
    so PySCF's version-dependent call site works unchanged.
    """
    A = aslinearoperator(A)
    b = np.asarray(b, dtype=complex if np.iscomplexobj(b) else float).ravel()
    n = b.shape[0]

    if rtol is None:
        rtol = tol
    if maxiter is None:
        maxiter = 10 * n

    x = np.zeros(n, dtype=b.dtype) if x0 is None else np.asarray(x0).ravel().astype(b.dtype)
    r = b - A.matvec(x)
    if M is not None:
        z = M.matvec(r) if isinstance(M, LinearOperator) else np.asarray(M) @ r
    else:
        z = r.copy()

    p = z.copy()
    rz = np.vdot(r, z)
    bnorm = np.linalg.norm(b)
    threshold = max(atol, rtol * bnorm)

    info = 0
    for _ in range(maxiter):
        if np.linalg.norm(r) <= threshold:
            break
        Ap = A.matvec(p)
        pAp = np.vdot(p, Ap)
        if pAp == 0:
            info = 1
            break
        alpha = rz / pAp
        x = x + alpha * p
        r = r - alpha * Ap
        if M is not None:
            z = M.matvec(r) if isinstance(M, LinearOperator) else np.asarray(M) @ r
        else:
            z = r.copy()
        rz_new = np.vdot(r, z)
        beta = rz_new / rz
        p = z + beta * p
        rz = rz_new
        if callback is not None:
            callback(x)
    else:
        info = 1

    if np.linalg.norm(r) <= threshold:
        info = 0

    return x, info


def gmres(A, b, x0=None, tol=1e-5, maxiter=None, M=None, callback=None,
          atol=0.0, restart=None, rtol=None):
    """Restarted GMRES.

    Returns ``(x, info)`` like SciPy.  ``restart`` defaults to ``min(n, 20)``.
    """
    A = aslinearoperator(A)
    b = np.asarray(b, dtype=complex if np.iscomplexobj(b) else float).ravel()
    n = b.shape[0]

    if rtol is None:
        rtol = tol
    if maxiter is None:
        maxiter = 10 * n
    if restart is None or restart <= 0:
        restart = min(n, 20)

    x = np.zeros(n, dtype=b.dtype) if x0 is None else np.asarray(x0).ravel().astype(b.dtype)

    def apply_m(v):
        if M is None:
            return v
        return M.matvec(v) if isinstance(M, LinearOperator) else np.asarray(M) @ v

    bnorm = np.linalg.norm(b)
    threshold = max(atol, rtol * bnorm)
    info = 0
    iters = 0

    while iters < maxiter:
        r = apply_m(b - A.matvec(x))
        beta = np.linalg.norm(r)
        if beta <= threshold:
            break

        # Arnoldi basis.
        v = [r / beta]
        h = np.zeros((restart + 1, restart), dtype=complex)
        cs = np.zeros(restart, dtype=complex)
        sn = np.zeros(restart, dtype=complex)
        g = np.zeros(restart + 1, dtype=complex)
        g[0] = beta

        k = 0
        for k in range(restart):
            iters += 1
            w = apply_m(A.matvec(v[k]))
            for j in range(k + 1):
                h[j, k] = np.vdot(v[j], w)
                w = w - h[j, k] * v[j]
            h[k + 1, k] = np.linalg.norm(w)
            if h[k + 1, k] > 1e-14:
                v.append(w / h[k + 1, k])

            # Apply previous Givens rotations, then compute a new one.
            for j in range(k):
                temp = cs[j] * h[j, k] + sn[j] * h[j + 1, k]
                h[j + 1, k] = -np.conj(sn[j]) * h[j, k] + cs[j] * h[j + 1, k]
                h[j, k] = temp
            denom = np.hypot(abs(h[k, k]), abs(h[k + 1, k]))
            if denom == 0:
                cs[k], sn[k] = 1.0, 0.0
            else:
                cs[k] = h[k, k] / denom
                sn[k] = h[k + 1, k] / denom
            h[k, k] = cs[k] * h[k, k] + sn[k] * h[k + 1, k]
            h[k + 1, k] = 0.0
            g[k + 1] = -np.conj(sn[k]) * g[k]
            g[k] = cs[k] * g[k]

            if abs(g[k + 1]) <= threshold:
                break

        # Back-substitution for the least-squares solution.
        y = np.zeros(k + 1, dtype=complex)
        for i in range(k, -1, -1):
            if h[i, i] == 0:
                y[i] = 0.0
                continue
            s = g[i] - sum(h[i, j] * y[j] for j in range(i + 1, k + 1))
            y[i] = s / h[i, i]

        for i in range(k + 1):
            x = x + y[i] * v[i]

        if abs(g[k + 1]) <= threshold:
            info = 0
            break
        if iters >= maxiter:
            info = 1
            break
        if callback is not None:
            callback(x)

    return x, info
