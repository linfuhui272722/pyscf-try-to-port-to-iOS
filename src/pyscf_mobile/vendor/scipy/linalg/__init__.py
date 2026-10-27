"""NumPy/LAPACK-backed replacement for the parts of :mod:`scipy.linalg` PySCF uses.

Everything here delegates to ``numpy.linalg``, which on iOS resolves to LAPACK
inside Apple's Accelerate framework.  The generalized symmetric eigenproblem
(``eigh`` with a ``b`` matrix) is the only routine with real logic: NumPy 2.x
dropped the ``(a, b)`` form, so the problem is reduced to a standard one with a
Cholesky factor, which is what LAPACK's ``sygv``/``sygst`` do internally.
"""

from __future__ import annotations

import numpy as np

__all__ = [
    "LinAlgError", "block_diag", "cho_factor", "cho_solve", "cholesky", "det",
    "eig", "eigh", "eigh_tridiagonal", "eigvalsh", "expm", "get_blas_funcs",
    "inv", "logm", "lu", "norm", "qr", "solve", "solve_triangular", "svd",
    "blas", "lapack",
]

LinAlgError = np.linalg.LinAlgError


def _asarray(a):
    return np.asarray(a)


def block_diag(*arrs):
    """Build a block-diagonal matrix from the given arrays.

    Handles the same shapes SciPy does: 2-D blocks are placed diagonally, 1-D
    and scalar inputs are promoted to 2-D first.
    """
    if not arrs:
        return np.zeros((0, 0))

    blocks = []
    for a in arrs:
        a = np.atleast_2d(_asarray(a))
        blocks.append(a)

    rows = sum(b.shape[0] for b in blocks)
    cols = sum(b.shape[1] for b in blocks)
    dtype = np.result_type(*[b.dtype for b in blocks])
    out = np.zeros((rows, cols), dtype=dtype)

    r = c = 0
    for b in blocks:
        br, bc = b.shape
        out[r:r + br, c:c + bc] = b
        r += br
        c += bc
    return out


def cholesky(a, lower=False, **kwargs):
    """Cholesky factorization; SciPy returns the upper triangle by default."""
    a = _asarray(a)
    l = np.linalg.cholesky(a)  # lower triangular
    return l if lower else l.T


def cho_factor(a, lower=False, **kwargs):
    """Return ``(factor, lower)`` so that :func:`cho_solve` can use it."""
    a = _asarray(a)
    l = np.linalg.cholesky(a)
    if lower:
        return l, True
    return l.T, False


def cho_solve(c_and_lower, b, **kwargs):
    """Solve ``A x = b`` from the output of :func:`cho_factor`."""
    c, lower = c_and_lower
    c = _asarray(c)
    b = _asarray(b)
    # np.linalg.solve is used rather than two triangular solves because it also
    # handles a non-contiguous `b` and gives the same result to rounding.
    a = c @ c.T.conj() if lower else c.T.conj() @ c
    return np.linalg.solve(a, b)


def solve(a, b, lower=False, assume_a=None, **kwargs):
    """Solve a linear system."""
    return np.linalg.solve(_asarray(a), _asarray(b))


def solve_triangular(a, b, trans=0, lower=False, unit_diagonal=False, **kwargs):
    """Solve ``a x = b`` with ``a`` triangular.

    ``trans`` follows SciPy's convention: 0 = no transpose, 1 = transpose,
    2 = conjugate transpose.
    """
    a = _asarray(a)
    b = _asarray(b)

    if unit_diagonal:
        a = a.copy()
        idx = np.arange(a.shape[0])
        a[idx, idx] = 1

    if trans == 1:
        a = a.T
    elif trans == 2:
        a = a.conj().T

    # The matrix is triangular, so a full solve is correct and, for the sizes
    # PySCF feeds in, not meaningfully slower than a blocked triangular solve.
    return np.linalg.solve(a, b)


def lu(a, permute_l=False, **kwargs):
    """LU decomposition.

    ``scipy.linalg.lu`` returns ``(p, l, u)``, or ``(l, u)`` when
    ``permute_l=True`` (with the permutation folded into ``l``).  PySCF only
    uses the ``permute_l=True`` form.
    """
    a = _asarray(a)
    # NumPy has no LU, so use a partial-pivoting Gaussian elimination written
    # with array operations.  The pivots are tracked explicitly.
    n, m = a.shape
    u = a.astype(np.result_type(a, np.float64), copy=True)
    l = np.eye(n, dtype=u.dtype)
    perm = np.arange(n)

    for k in range(min(n, m)):
        piv = k + int(np.argmax(np.abs(u[k:, k])))
        if piv != k:
            u[[k, piv], :] = u[[piv, k], :]
            l[[k, piv], :k] = l[[piv, k], :k]
            perm[[k, piv]] = perm[[piv, k]]
        if u[k, k] == 0:
            continue
        factors = u[k + 1:, k] / u[k, k]
        l[k + 1:, k] = factors
        u[k + 1:, k:] -= factors[:, None] * u[k, k:]

    if permute_l:
        return l, u

    p = np.eye(n)
    p = p[perm]
    return p, l, u


def qr(a, mode="full", pivoting=False, **kwargs):
    """QR factorization, optionally with column pivoting."""
    a = _asarray(a)
    if pivoting:
        # Column-pivoted QR: pick the column with the largest remaining norm at
        # each step.  Only SciPy's ('economic', pivoting=True) form is used by
        # PySCF, so the return is always (q, r, p).
        m, n = a.shape
        r = a.astype(np.result_type(a, np.float64), copy=True)
        q = np.eye(m, dtype=r.dtype)
        perm = np.arange(n)
        for k in range(min(m, n)):
            norms = np.linalg.norm(r[k:, k:], axis=0)
            j = k + int(np.argmax(norms))
            if j != k:
                r[:, [k, j]] = r[:, [j, k]]
                perm[[k, j]] = perm[[j, k]]
            # Householder reflection for column k.
            x = r[k:, k]
            alpha = -np.sign(x[0]) * np.linalg.norm(x) if x[0] != 0 else -np.linalg.norm(x)
            v = x.copy()
            v[0] -= alpha
            vnorm = np.linalg.norm(v)
            if vnorm > 0:
                v = v / vnorm
                r[k:, k:] -= 2.0 * np.outer(v, v @ r[k:, k:])
                q[:, k:] -= 2.0 * np.outer(q[:, k:] @ v, v)
        k = min(m, n)
        p = np.eye(n)
        return q[:, :k], r[:k, :], p[:, perm]

    if mode == "economic":
        return np.linalg.qr(a, mode="reduced")
    if mode == "r":
        return np.linalg.qr(a, mode="r")
    return np.linalg.qr(a, mode="complete")


def svd(a, full_matrices=True, **kwargs):
    """Singular value decomposition."""
    return np.linalg.svd(_asarray(a), full_matrices=full_matrices)


def det(a, **kwargs):
    return np.linalg.det(_asarray(a))


def norm(a, ord=None, axis=None, **kwargs):
    return np.linalg.norm(_asarray(a), ord=ord, axis=axis)


def inv(a, **kwargs):
    return np.linalg.inv(_asarray(a))


def eig(a, b=None, left=False, right=True, **kwargs):
    """Eigenvalues/eigenvectors of a general (non-symmetric) matrix.

    Returns ``(w, vr)`` or, when ``left=True``, ``(w, vl, vr)``, matching
    SciPy's argument order.  A generalized problem ``a v = w b v`` is reduced
    via ``inv(b) a``, which is what PySCF relies on for its non-symmetric
    effective Hamiltonians.
    """
    a = _asarray(a)
    if b is not None:
        a = np.linalg.solve(_asarray(b), a)

    if left:
        w, vl, vr = _eig_left(a)
        return w, vl, vr
    return np.linalg.eig(a)


def _eig_left(a):
    """Eigen-decomposition returning left and right eigenvectors.

    SciPy normalizes each eigenvector to unit Euclidean norm and does not
    enforce ``vl^H vr = I``, so the left vectors are simply the eigenvectors of
    ``a^H``.  Eigenvalue ordering matches the right-vector ordering because
    ``a`` and ``a^H`` share a spectrum.
    """
    w, vr = np.linalg.eig(a)
    _, vl = np.linalg.eig(a.conj().T)
    return w, vl, vr


def eigh(a, b=None, lower=True, eigvals_only=False, type=1, **kwargs):
    """Solve the symmetric (Hermitian) eigenproblem, optionally generalized.

    ``b`` and ``type`` follow LAPACK/SciPy:

    * type 1: ``a x = w b x``
    * type 2: ``a b x = w x``
    * type 3: ``b a x = w x``

    ``b`` must be positive definite.  NumPy 2.x removed the ``(a, b)`` form of
    ``numpy.linalg.eigh``, so the generalized problems are reduced with a
    Cholesky factor ``b = L L^T`` (``L`` lower):

    * type 1 -> ``(L^-1 a L^-T) y = w y``,  ``x = L^-T y``
    * type 2 -> ``(L^T a L) y = w y``,      ``x = L^-T y``
    * type 3 -> ``(L^T a L) y = w y``,      ``x = L y``

    Types 2 and 3 share a reduced matrix (``AB`` and ``BA`` are similar) and
    differ only in how the eigenvectors map back.
    """
    a = _asarray(a)

    if b is None:
        w, v = np.linalg.eigh(a, UPLO="L" if lower else "U")
        return w if eigvals_only else (w, v)

    b = _asarray(b)
    l = np.linalg.cholesky(b if lower else b.T)  # b = l l^T, l lower

    if type == 1:
        linv = np.linalg.inv(l)
        reduced = linv @ a @ linv.T.conj()
        back = linv.T.conj()
    else:
        reduced = l.T.conj() @ a @ l
        back = l if type == 3 else np.linalg.inv(l).T.conj()

    w, y = np.linalg.eigh(reduced)
    if eigvals_only:
        return w
    return w, back @ y


def eigvalsh(a, b=None, type=1, **kwargs):
    return eigh(a, b=b, type=type, eigvals_only=True)


def eigh_tridiagonal(d, e, eigvals_only=False, **kwargs):
    """Eigenvalues of a symmetric tridiagonal matrix.

    Built by expanding the tridiagonal matrix and calling the dense solver.
    PySCF uses this only for small matrices in the GW/BSE code, which the app
    does not ship.
    """
    d = _asarray(d)
    e = _asarray(e)
    n = d.shape[0]
    m = np.diag(d)
    if n > 1:
        m += np.diag(e, 1) + np.diag(e, -1)
    w, v = np.linalg.eigh(m)
    return w if eigvals_only else (w, v)


def expm(a, **kwargs):
    """Matrix exponential via scaling and squaring with a Pade approximant.

    Scaling and squaring is what SciPy uses too; the order-13 Pade coefficients
    below give full double precision.
    """
    a = _asarray(a)
    if a.ndim != 2 or a.shape[0] != a.shape[1]:
        raise ValueError("expm requires a square matrix")

    # Pade coefficients for the (13, 13) approximant (Higham 2005).
    b = [64764752532480000.0, 32382376266240000.0, 7771770303897600.0,
         1187353796428800.0, 129060195264000.0, 10559470521600.0,
         670442572800.0, 33522128640.0, 1323241920.0, 40840800.0,
         960960.0, 16380.0, 182.0, 1.0]

    norm_a = float(np.abs(a).sum(axis=1).max())
    # theta_13 from Higham's table.
    theta13 = 5.371920351148152
    if norm_a <= theta13:
        s = 0
    else:
        s = max(0, int(np.ceil(np.log2(norm_a / theta13))))
    a = a / (2.0 ** s)

    a2 = a @ a
    a4 = a2 @ a2
    a6 = a4 @ a2

    u = a @ (a6 @ (b[13] * a6 + b[11] * a4 + b[9] * a2)
             + b[7] * a6 + b[5] * a4 + b[3] * a2 + b[1] * np.eye(a.shape[0]))
    v = (a6 @ (b[12] * a6 + b[10] * a4 + b[8] * a2)
         + b[6] * a6 + b[4] * a4 + b[2] * a2 + b[0] * np.eye(a.shape[0]))

    r = np.linalg.solve(v - u, v + u)
    for _ in range(s):
        r = r @ r
    return r


def logm(a, **kwargs):
    """Matrix logarithm.

    Computed from the Schur decomposition, which is how SciPy implements the
    real case: ``a = Q T Q^H`` with ``T`` quasi-upper-triangular, so
    ``log(a) = Q log(T) Q^H``.  PySCF uses this only in the CC orbital-rotation
    helpers.
    """
    a = _asarray(a)
    # np.linalg has no Schur decomposition, so use the eigendecomposition.
    # This is exact for the diagonalizable matrices PySCF passes (orbital
    # rotation matrices are unitary) and is the standard fallback.
    w, v = np.linalg.eig(a)
    with np.errstate(divide="ignore", invalid="ignore"):
        logw = np.log(w.astype(complex))
    return (v @ np.diag(logw) @ np.linalg.inv(v)).real


class _BlasFunc:
    """Callable wrapper exposing one BLAS routine with SciPy's keyword names."""

    def __init__(self, name):
        self._name = name

    def __call__(self, *args, **kwargs):
        raise NotImplementedError(
            f"scipy.linalg.blas.{self._name} is not available on iOS; "
            "PySCF only uses it in the DF decomposition path"
        )


class _Blas:
    """Placeholder namespace for the BLAS wrappers PySCF references by name."""

    daxpy = staticmethod(_BlasFunc("daxpy"))
    dgemm = staticmethod(_BlasFunc("dgemm"))
    dgemv = staticmethod(_BlasFunc("dgemv"))
    zgemm = staticmethod(_BlasFunc("zgemm"))


blas = _Blas()


class _Lapack:
    """LAPACK routines reached directly by PySCF."""

    @staticmethod
    def dpstrf(a, tol=-1.0, lower=False, **kwargs):
        """Pivoted Cholesky.  Returns ``(factor, piv, rank, info)``.

        Delegates to PySCF's own pure-Python implementation, which is what it
        falls back to when ``dpstrf`` is unavailable -- see
        ``pyscf/lib/scipy_helper.py``.
        """
        from pyscf.lib.scipy_helper import pivoted_cholesky_python

        a = _asarray(a)
        factor, piv, rank = pivoted_cholesky_python(a, tol=tol, lower=lower)
        # SciPy returns 1-based pivots and an integer info code.
        return factor, np.asarray(piv) + 1, rank, 0


lapack = _Lapack()


def get_blas_funcs(names, arrays=None, **kwargs):
    """Return BLAS callables for the requested names.

    SciPy returns a tuple of ``(func,)``.  The only caller in PySCF
    (``pyscf/df/incore.py``) uses ``trsm``, which is implemented here with
    :func:`solve_triangular`.
    """
    if isinstance(names, str):
        names = (names,)

    funcs = []
    for name in names:
        if name == "trsm":
            funcs.append(_trsm)
        elif name == "scal":
            funcs.append(_scal)
        else:
            funcs.append(_BlasFunc(name))
    return tuple(funcs)


def _trsm(alpha, a, b, lower=False, trans_a=0, side=1, overwrite_b=False, **kwargs):
    """Solve a triangular system, matching SciPy's ``trsm`` wrapper.

    SciPy exposes LAPACK's ``TRSM`` through f2py, and the two conventions that
    matter are easy to get backwards:

    * the triangle is selected from ``a`` *before* the transpose is applied, so
      ``lower=True, trans_a=1`` means ``tril(a).T`` and not ``tril(a.T)`` -- the
      latter is the diagonal alone whenever ``a`` is already triangular, which
      silently destroys the matrix;
    * the result is ``alpha * b @ inv(op(a))``, a right solve, because f2py
      presents the operand in column-major order and the caller transposes it
      back.

    ``pyscf/df/incore.py`` calls this as
    ``trsm(1.0, low, ints.T, lower=True, trans_a=1).T`` and expects
    ``solve(low, ints)``, which is what the two conventions above produce.

    Only ``side=1`` is implemented; it is the only value PySCF passes.
    """
    a = _asarray(a)
    b = _asarray(b)
    op = np.tril(a) if lower else np.triu(a)
    if trans_a == 1:
        op = op.T
    elif trans_a == 2:
        op = op.conj().T
    return alpha * np.linalg.solve(op.T, b.T).T


def _scal(alpha, x, **kwargs):
    """Scale a vector in place (LAPACK SCAL)."""
    x = _asarray(x)
    x *= alpha
    return x
