"""NumPy-backed replacement for :mod:`scipy.fft`.

PySCF uses only ``fftn``/``ifftn`` (in the periodic-DFT tools) and always with an
explicit ``axes`` and ``workers`` argument.  ``workers`` is accepted and ignored:
iOS has no process pool worth spinning up for this, and the transforms are
already multithreaded inside Accelerate's vDSP.
"""

from __future__ import annotations

import numpy as np

__all__ = ["fft", "fft2", "fftn", "ifft", "ifft2", "ifftn", "rfft", "irfft"]


def fft(a, n=None, axis=-1, norm=None, workers=None, **kwargs):
    return np.fft.fft(a, n=n, axis=axis, norm=norm)


def ifft(a, n=None, axis=-1, norm=None, workers=None, **kwargs):
    return np.fft.ifft(a, n=n, axis=axis, norm=norm)


def fft2(a, s=None, axes=(-2, -1), norm=None, workers=None, **kwargs):
    return np.fft.fft2(a, s=s, axes=axes, norm=norm)


def ifft2(a, s=None, axes=(-2, -1), norm=None, workers=None, **kwargs):
    return np.fft.ifft2(a, s=s, axes=axes, norm=norm)


def fftn(a, s=None, axes=None, norm=None, workers=None, **kwargs):
    return np.fft.fftn(a, s=s, axes=axes, norm=norm)


def ifftn(a, s=None, axes=None, norm=None, workers=None, **kwargs):
    return np.fft.ifftn(a, s=s, axes=axes, norm=norm)


def rfft(a, n=None, axis=-1, norm=None, workers=None, **kwargs):
    return np.fft.rfft(a, n=n, axis=axis, norm=norm)


def irfft(a, n=None, axis=-1, norm=None, workers=None, **kwargs):
    return np.fft.irfft(a, n=n, axis=axis, norm=norm)
