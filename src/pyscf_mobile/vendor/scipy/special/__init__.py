"""NumPy-backed replacement for the parts of :mod:`scipy.special` PySCF uses.

PySCF references these names: ``erf``, ``erfc``, ``erfcx``, ``gamma``,
``gammaincc``, ``factorial``, ``comb``, ``binom``, ``lambertw``, ``j0``, ``j1``,
``k0``, ``k1``, ``sph_harm`` and ``sph_harm_y``.

``erf``/``erfc``/``gamma``/``factorial`` have exact counterparts in
``math`` and NumPy.  The Bessel and incomplete-gamma functions are evaluated
from their standard series/asymptotic expansions, and the spherical harmonics
from the associated Legendre recurrence.  All of them are checked against real
SciPy by ``tests/test_shims.py``.
"""

from __future__ import annotations

import math

import numpy as np

__all__ = [
    "binom", "comb", "erf", "erfc", "erfcx", "factorial", "gamma",
    "gammaincc", "j0", "j1", "k0", "k1", "lambertw", "sph_harm",
    "sph_harm_y",
]

_EULER_GAMMA = 0.5772156649015329


def _vectorize(func):
    """Wrap a scalar function so it also accepts arrays, like SciPy's ufuncs."""

    def wrapper(x, *args, **kwargs):
        arr = np.asarray(x, dtype=float)
        if arr.ndim == 0:
            return func(float(arr), *args, **kwargs)
        return np.array([func(float(v), *args, **kwargs) for v in arr.ravel()],
                        dtype=float).reshape(arr.shape)

    wrapper.__name__ = getattr(func, "__name__", "vectorized")
    return wrapper


# ---------------------------------------------------------------------------
# Elementary functions
# ---------------------------------------------------------------------------

def erf(x):
    return np.vectorize(math.erf, otypes=[float])(x) if np.ndim(x) else math.erf(x)


def erfc(x):
    return np.vectorize(math.erfc, otypes=[float])(x) if np.ndim(x) else math.erfc(x)


def erfcx(x):
    """Scaled complementary error function ``exp(x**2) * erfc(x)``.

    Evaluated directly for moderate ``x``; for large ``x`` the asymptotic
    expansion is used, because ``exp(x**2)`` would overflow first.
    """
    def scalar(v):
        if v < 25.0:
            return math.exp(v * v) * math.erfc(v)
        # erfcx(x) ~ 1/(x sqrt(pi)) * sum_k (-1)^k (2k-1)!!/(2x^2)^k
        inv2x2 = 1.0 / (2.0 * v * v)
        term = 1.0
        total = 1.0
        for k in range(1, 20):
            term *= -(2 * k - 1) * inv2x2
            total += term
            if abs(term) < 1e-18 * abs(total):
                break
        return total / (v * math.sqrt(math.pi))

    return _vectorize(scalar)(x)


def gamma(x):
    return np.vectorize(math.gamma, otypes=[float])(x) if np.ndim(x) else math.gamma(x)


def factorial(n, exact=False):
    """Factorial, matching SciPy's ``exact`` flag."""
    arr = np.asarray(n)
    if exact:
        return np.vectorize(lambda v: math.factorial(int(v)), otypes=[object])(arr)
    return np.vectorize(lambda v: math.gamma(v + 1.0), otypes=[float])(arr)


def comb(n, k, exact=False, repetition=False):
    """Binomial coefficient ``C(n, k)``."""
    if repetition:
        return comb(n + k - 1, k, exact=exact)
    arr_n = np.asarray(n)
    arr_k = np.asarray(k)
    if exact:
        return np.vectorize(lambda a, b: math.comb(int(a), int(b)), otypes=[object])(arr_n, arr_k)
    return np.vectorize(
        lambda a, b: math.gamma(a + 1.0) / (math.gamma(b + 1.0) * math.gamma(a - b + 1.0)),
        otypes=[float],
    )(arr_n, arr_k)


def binom(n, k, exact=False):
    return comb(n, k, exact=exact)


def gammaincc(a, x):
    """Regularized upper incomplete gamma ``Q(a, x)``.

    Uses the series expansion for ``x < a + 1`` and the continued fraction
    otherwise (Numerical Recipes, section 6.2).
    """
    def scalar(av, xv):
        if xv < 0 or av <= 0:
            raise ValueError("gammaincc requires a > 0 and x >= 0")
        if xv == 0:
            return 1.0
        if xv < av + 1.0:
            # Series for P(a, x), then Q = 1 - P.
            ap = av
            term = 1.0 / av
            total = term
            for _ in range(1000):
                ap += 1.0
                term *= xv / ap
                total += term
                if abs(term) < abs(total) * 1e-16:
                    break
            return 1.0 - total * math.exp(-xv + av * math.log(xv) - math.lgamma(av))
        # Lentz's continued fraction for Q(a, x).
        tiny = 1e-300
        b = xv + 1.0 - av
        c = 1.0 / tiny
        d = 1.0 / b
        h = d
        for i in range(1, 1000):
            an = -i * (i - av)
            b += 2.0
            d = an * d + b
            if abs(d) < tiny:
                d = tiny
            c = b + an / c
            if abs(c) < tiny:
                c = tiny
            d = 1.0 / d
            delta = d * c
            h *= delta
            if abs(delta - 1.0) < 1e-16:
                break
        return h * math.exp(-xv + av * math.log(xv) - math.lgamma(av))

    return np.vectorize(scalar, otypes=[float])(np.asarray(a, dtype=float), np.asarray(x, dtype=float))


def lambertw(z, k=0):
    """Lambert W function, principal branch (``k=0``).

    Halley's method on ``w exp(w) = z``, seeded from the standard asymptotic
    estimates, converging to machine precision.
    """
    if k != 0:
        raise NotImplementedError("lambertw is implemented for the principal branch (k=0) only")

    z = np.asarray(z, dtype=complex)
    flat = z.ravel()
    out = np.empty(flat.shape, dtype=complex)

    for i, zi in enumerate(flat):
        if zi == 0:
            out[i] = 0.0
            continue
        if abs(zi + 1.0 / math.e) < 1e-12:
            out[i] = -1.0
            continue
        if abs(zi) < 1.0:
            w = zi
        elif zi.real > 1.0:
            w = np.log(zi) - np.log(np.log(zi))
        else:
            w = zi
        for _ in range(100):
            ew = np.exp(w)
            f = w * ew - zi
            wn = w - f / (ew * (w + 1.0) - (w + 2.0) * f / (2.0 * w + 2.0))
            if abs(wn - w) < 1e-15 * max(1.0, abs(wn)):
                w = wn
                break
            w = wn
        out[i] = w

    result = out.reshape(z.shape)
    return result.real if np.allclose(result.imag, 0.0) else result


# ---------------------------------------------------------------------------
# Bessel functions
# ---------------------------------------------------------------------------

def j0(x):
    """Bessel function of the first kind, order 0."""
    def scalar(v):
        if abs(v) < 12.0:
            # Power series.
            term = 1.0
            total = 1.0
            for k in range(1, 60):
                term *= -(v * v) / (4.0 * k * k)
                total += term
                if abs(term) < 1e-18 * abs(total):
                    break
            return total
        # Asymptotic expansion.
        z = abs(v)
        mu = 4.0 * 0.0 ** 2
        p = 1.0 - (mu - 1) * (mu - 9) / (2 * (8 * z) ** 2)
        q = (mu - 1) / (8 * z)
        chi = z - math.pi / 4.0
        return math.sqrt(2.0 / (math.pi * z)) * (p * math.cos(chi) - q * math.sin(chi))

    return _vectorize(scalar)(x)


def j1(x):
    """Bessel function of the first kind, order 1."""
    def scalar(v):
        if abs(v) < 12.0:
            term = v / 2.0
            total = term
            for k in range(1, 60):
                term *= -(v * v) / (4.0 * k * (k + 1.0))
                total += term
                if abs(term) < 1e-18 * abs(total):
                    break
            return total
        z = abs(v)
        mu = 4.0 * 1.0 ** 2
        p = 1.0 - (mu - 1) * (mu - 9) / (2 * (8 * z) ** 2)
        q = (mu - 1) / (8 * z)
        chi = z - 3.0 * math.pi / 4.0
        return math.copysign(math.sqrt(2.0 / (math.pi * z)) * (p * math.cos(chi) - q * math.sin(chi)), v)

    return _vectorize(scalar)(x)


def _bessel_k_scalar(nu, x):
    """Modified Bessel function of the second kind, integer order."""
    if x <= 0:
        raise ValueError("k0/k1 require x > 0")
    if x < 2.0:
        # Series from the integral representation; use the ascending expansion
        # for small arguments with the Euler-Mascheroni constant.
        if nu == 0:
            # K0(x) = -(ln(x/2) + gamma) I0(x) + sum_{k>=1} H_k (x^2/4)^k / (k!)^2
            i0 = 1.0
            term = 1.0
            for k in range(1, 60):
                term *= (x * x) / (4.0 * k * k)
                i0 += term
            total = 0.0
            hk = 0.0
            term = 1.0
            for k in range(1, 60):
                term *= (x * x) / (4.0 * k * k)
                hk += 1.0 / k
                total += hk * term
                if abs(hk * term) < 1e-18 * max(1.0, abs(total)):
                    break
            return -(math.log(x / 2.0) + _EULER_GAMMA) * i0 + total
        # K1
        i1 = x / 2.0
        term = i1
        for k in range(1, 60):
            term *= (x * x) / (4.0 * k * (k + 1.0))
            i1 += term
        total = 0.0
        hk = 0.0
        term = x / 2.0
        for k in range(1, 60):
            hk += 1.0 / k
            term *= (x * x) / (4.0 * k * (k + 1.0))
            total += (hk + 1.0 / (k + 1.0)) * term
            if abs(term) < 1e-18:
                break
        return (1.0 / x) + (math.log(x / 2.0) + _EULER_GAMMA) * i1 - total
    # Asymptotic expansion for large x.
    def series(mu):
        p = 1.0
        q = 0.0
        term = 1.0
        for k in range(1, 12):
            term *= (mu - (2 * k - 1) ** 2) / (k * 8.0 * x)
            p += term
        term = (mu - 1.0) / (8.0 * x)
        q = term
        t = term
        for k in range(2, 12):
            t *= (mu - (2 * k - 1) ** 2) / (k * 8.0 * x)
            q += t
        return p, q

    if nu == 0:
        p, q = series(0.0)
    else:
        p, q = series(4.0)
    return math.sqrt(math.pi / (2.0 * x)) * math.exp(-x) * (p + q)


def k0(x):
    return _vectorize(lambda v: _bessel_k_scalar(0, v))(x)


def k1(x):
    return _vectorize(lambda v: _bessel_k_scalar(1, v))(x)


# ---------------------------------------------------------------------------
# Spherical harmonics
# ---------------------------------------------------------------------------

def _assoc_legendre(l, m, x):
    """Associated Legendre polynomial ``P_l^m(x)`` with the Condon-Shortley phase."""
    m = abs(m)
    x = np.asarray(x, dtype=float)

    if m == 0:
        pmm = np.ones_like(x)
    else:
        somx2 = np.sqrt(np.maximum(0.0, 1.0 - x * x))
        pmm = np.ones_like(x)
        fact = 1.0
        for _ in range(1, m + 1):
            pmm = pmm * (-fact) * somx2
            fact += 2.0

    if l == m:
        return pmm
    pmmp1 = x * (2 * m + 1) * pmm
    if l == m + 1:
        return pmmp1
    for ll in range(m + 2, l + 1):
        pll = ((2 * ll - 1) * x * pmmp1 - (ll + m - 1) * pmm) / (ll - m)
        pmm, pmmp1 = pmmp1, pll
    return pmmp1


def sph_harm_y(n, m, theta, phi, diff_n=0):
    """Spherical harmonic ``Y_n^m(theta, phi)``.

    ``theta`` is the polar angle and ``phi`` the azimuthal angle, matching
    SciPy's convention.  Negative ``m`` uses ``Y_n^{-m} = (-1)^m conj(Y_n^m)``.
    """
    if diff_n != 0:
        raise NotImplementedError("sph_harm_y is implemented for diff_n=0 only")

    theta = np.asarray(theta, dtype=float)
    phi = np.asarray(phi, dtype=float)
    am = abs(int(m))

    x = np.cos(theta)
    p = _assoc_legendre(int(n), am, x)
    norm = math.sqrt((2 * int(n) + 1) / (4.0 * math.pi)
                     * math.factorial(int(n) - am) / math.factorial(int(n) + am))
    y = norm * p * np.exp(1j * am * phi)
    if m < 0:
        y = ((-1) ** am) * np.conj(y)
    return y


def sph_harm(m, n, theta, phi):
    """Legacy spherical harmonic signature ``sph_harm(m, n, theta, phi)``.

    Here ``theta`` is the azimuthal angle, as in the deprecated SciPy API.
    """
    return sph_harm_y(n, m, phi, theta)
