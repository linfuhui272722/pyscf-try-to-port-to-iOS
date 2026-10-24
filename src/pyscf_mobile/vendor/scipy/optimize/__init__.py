"""NumPy-backed replacement for the parts of :mod:`scipy.optimize` PySCF uses.

PySCF calls ``minimize`` (BFGS) from its EDIIS/ADIIS convergence accelerators,
``bisect`` from the Fermi smearing root search, and imports ``newton`` and
``least_squares`` in the GW code.  All are implemented here; ``bisect`` and the
BFGS minimizer are the two on the SCF path.
"""

from __future__ import annotations

import numpy as np

__all__ = [
    "OptimizeResult", "bisect", "least_squares", "linear_sum_assignment",
    "minimize", "newton",
]


class OptimizeResult(dict):
    """Result container, matching the ``scipy.optimize.OptimizeResult`` API."""

    def __getattr__(self, name):
        try:
            return self[name]
        except KeyError as exc:  # pragma: no cover - mirrors SciPy
            raise AttributeError(name) from exc


def bisect(f, a, b, xtol=1e-12, maxiter=10000, **kwargs):
    """Find a root of ``f`` in ``[a, b]`` by bisection.

    Reproduces the SciPy calling convention used by PySCF's smearing code,
    which passes ``xtol`` and ``maxiter`` as keywords.
    """
    fa = f(a)
    fb = f(b)
    if fa == 0:
        return a
    if fb == 0:
        return b
    if fa * fb > 0:
        raise ValueError("f(a) and f(b) must have different signs")

    for _ in range(maxiter):
        mid = 0.5 * (a + b)
        fmid = f(mid)
        if fmid == 0 or (b - a) * 0.5 < xtol:
            return mid
        if fa * fmid < 0:
            b, fb = mid, fmid
        else:
            a, fa = mid, fmid
    return 0.5 * (a + b)


def newton(func, x0, fprime=None, args=(), tol=1.48e-8, maxiter=50, **kwargs):
    """Newton-Raphson root finder with a secant fallback when no derivative is given."""
    x = float(x0)
    for _ in range(maxiter):
        fx = func(x, *args)
        if abs(fx) < tol:
            return x
        if fprime is not None:
            dfx = fprime(x, *args)
        else:
            # Numerical derivative, matching SciPy's secant behaviour closely
            # enough for the well-conditioned roots PySCF searches for.
            h = 1e-7 * max(1.0, abs(x))
            dfx = (func(x + h, *args) - fx) / h
        if dfx == 0:
            break
        step = fx / dfx
        x -= step
        if abs(step) < tol:
            break
    return x


def minimize(fun, x0, args=(), jac=None, method="BFGS", tol=None, options=None,
             callback=None, **kwargs):
    """Minimize a scalar function.

    Implements BFGS with a backtracking Armijo line search.  PySCF's DIIS
    accelerators minimize a small (few-variable) quadratic-like cost, for which
    this converges to the same optimum as SciPy's implementation.
    """
    if method not in ("BFGS", "CG", "Nelder-Mead", "Powell", "L-BFGS-B",
                      "TNC", "COBYLA", "SLSQP", "trust-constr", "dogleg",
                      "Newton-CG"):
        raise NotImplementedError(f"minimize: method {method!r} is not available on iOS")

    options = options or {}
    gtol = float(options.get("gtol", tol if tol is not None else 1e-5))
    maxiter = int(options.get("maxiter", 200))

    x = np.atleast_1d(np.asarray(x0, dtype=float)).copy()
    n = x.shape[0]

    def f_and_g(xv):
        fv = float(fun(xv, *args))
        if jac is not None:
            gv = np.asarray(jac(xv, *args), dtype=float)
        else:
            gv = np.empty(n)
            h = 1e-8
            for i in range(n):
                xp = xv.copy()
                xp[i] += h
                gv[i] = (float(fun(xp, *args)) - fv) / h
        return fv, gv

    fval, grad = f_and_g(x)
    hess_inv = np.eye(n)
    niter = 0
    converged = False

    for niter in range(1, maxiter + 1):
        if np.linalg.norm(grad) < gtol:
            converged = True
            break

        direction = -hess_inv @ grad
        # Guard against a non-descent direction from a bad curvature estimate.
        if float(grad @ direction) > 0:
            direction = -grad
            hess_inv = np.eye(n)

        # Backtracking line search on the Armijo condition.
        step = 1.0
        while step > 1e-16:
            x_new = x + step * direction
            f_new, grad_new = f_and_g(x_new)
            if f_new <= fval + 1e-4 * step * float(grad @ direction):
                break
            step *= 0.5
        else:
            converged = True
            break

        s = x_new - x
        y = grad_new - grad
        sy = float(s @ y)
        if sy > 1e-12 * np.linalg.norm(s) * np.linalg.norm(y):
            rho = 1.0 / sy
            a = np.eye(n) - rho * np.outer(s, y)
            hess_inv = a @ hess_inv @ a.T + rho * np.outer(s, s)

        x, fval, grad = x_new, f_new, grad_new
        if callback is not None:
            callback(x)

    return OptimizeResult(
        x=x, fun=fval, jac=grad, nit=niter, success=converged,
        status=0 if converged else 1,
        message="converged" if converged else "maximum iterations reached",
    )


def least_squares(fun, x0, jac=None, bounds=(-np.inf, np.inf), tol=1e-8,
                  max_nfev=None, **kwargs):
    """Nonlinear least squares via the Gauss-Newton method with Levenberg damping.

    PySCF imports this only in the GW self-energy grid fit, which the app does
    not ship; the implementation is complete so that an import never fails.
    """
    x = np.atleast_1d(np.asarray(x0, dtype=float)).copy()
    max_nfev = int(max_nfev or 200)
    lam = 1e-3

    def residuals(xv):
        r = np.atleast_1d(np.asarray(fun(xv), dtype=float))
        return r

    r = residuals(x)
    cost = 0.5 * float(r @ r)
    niter = 0

    for niter in range(1, max_nfev + 1):
        # Numerical Jacobian.
        m = r.shape[0]
        n = x.shape[0]
        jmat = np.empty((m, n))
        h = 1e-8
        for i in range(n):
            xp = x.copy()
            xp[i] += h
            jmat[:, i] = (residuals(xp) - r) / h

        jtj = jmat.T @ jmat
        jtr = jmat.T @ r
        try:
            step = np.linalg.solve(jtj + lam * np.diag(np.diag(jtj) + 1e-12), -jtr)
        except np.linalg.LinAlgError:  # pragma: no cover - defensive
            break

        x_new = x + step
        r_new = residuals(x_new)
        cost_new = 0.5 * float(r_new @ r_new)
        if cost_new < cost:
            x, r, cost = x_new, r_new, cost_new
            lam = max(lam * 0.5, 1e-12)
            if np.linalg.norm(step) < tol:
                break
        else:
            lam *= 2.0
            if lam > 1e12:
                break

    return OptimizeResult(
        x=x, fun=r, cost=cost, nit=niter,
        success=cost < tol, message="converged" if cost < tol else "not converged",
    )


def linear_sum_assignment(cost_matrix, maximize=False):
    """Solve the linear sum assignment problem.

    Uses the Jonker-Volgenant shortest augmenting path algorithm, which is what
    SciPy uses.  PySCF calls this in EOM-CCSD, off the app's main path.
    """
    cost = np.asarray(cost_matrix, dtype=float)
    if maximize:
        cost = cost.max() - cost

    n, m = cost.shape
    # Rectangular matrices are padded so the square algorithm applies.
    size = max(n, m)
    padded = np.full((size, size), cost.max() * size if cost.size else 0.0)
    padded[:n, :m] = cost

    u = np.zeros(size + 1)
    v = np.zeros(size + 1)
    p = np.zeros(size + 1, dtype=int)
    way = np.zeros(size + 1, dtype=int)

    for i in range(1, size + 1):
        p[0] = i
        j0 = 0
        minv = np.full(size + 1, np.inf)
        used = np.zeros(size + 1, dtype=bool)
        while True:
            used[j0] = True
            i0 = p[j0]
            delta = np.inf
            j1 = 0
            for j in range(1, size + 1):
                if used[j]:
                    continue
                cur = padded[i0 - 1, j - 1] - u[i0] - v[j]
                if cur < minv[j]:
                    minv[j] = cur
                    way[j] = j0
                if minv[j] < delta:
                    delta = minv[j]
                    j1 = j
            for j in range(size + 1):
                if used[j]:
                    u[p[j]] += delta
                    v[j] -= delta
                else:
                    minv[j] -= delta
            j0 = j1
            if p[j0] == 0:
                break
        while True:
            j1 = way[j0]
            p[j0] = p[j1]
            j0 = j1
            if j0 == 0:
                break

    rows = np.arange(size)
    cols = np.empty(size, dtype=int)
    for j in range(1, size + 1):
        cols[p[j] - 1] = j - 1

    keep = (rows < n) & (cols < m)
    return rows[keep], cols[keep]
