"""Tests for the vendored scipy/h5py replacements.

Two kinds of check live here:

* the reimplemented routines are compared against the real SciPy, when it is
  importable, so a change that silently breaks the maths is caught on the build
  host rather than on a device,
* the full chemistry pipeline is run with the shims forced to the front of
  ``sys.path``, which is what actually happens on iOS.

Run with ``python -m pytest tests -v`` or ``python tests/run_tests.py``.
"""

from __future__ import annotations

import importlib
import os
import sys
import tempfile

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src"))

from pyscf_mobile import vendor  # noqa: E402


def _vendored():
    """Import the vendored modules with the shims definitely in place."""
    vendor.install(force=True)
    scipy = importlib.import_module("scipy")
    assert os.path.dirname(os.path.dirname(scipy.__file__)) == vendor.VENDOR_DIR
    return scipy


def _real_scipy():
    """Import the platform SciPy, or return None if there is none."""
    saved = list(sys.path)
    sys.path[:] = [p for p in sys.path if p != vendor.VENDOR_DIR]
    for name in [m for m in sys.modules if m == "scipy" or m.startswith("scipy.")]:
        del sys.modules[name]
    try:
        import scipy as real
    except Exception:
        return None
    finally:
        sys.path[:] = saved
    return None if "vendor" in real.__file__ else real


# --------------------------------------------------------------------------
# install
# --------------------------------------------------------------------------


def test_install_puts_vendored_modules_first():
    scipy = _vendored()
    assert "vendor" in scipy.__file__
    assert vendor.is_installed()


def test_install_is_idempotent():
    _vendored()
    assert vendor.install(force=True)
    assert sys.path.count(vendor.VENDOR_DIR) == 1


def test_vendor_dir_is_removed_from_path_before_reinsert():
    """Repeated installs must not accumulate duplicate path entries."""
    vendor.install(force=True)
    vendor.install(force=True)
    vendor.install(force=True)
    assert sys.path.count(vendor.VENDOR_DIR) == 1
    assert vendor.is_installed()


# --------------------------------------------------------------------------
# linalg against real SciPy
# --------------------------------------------------------------------------


def _rng(n=6, seed=11):
    rng = np.random.default_rng(seed)
    a = rng.standard_normal((n, n))
    spd = rng.standard_normal((n, n))
    spd = spd @ spd.T + n * np.eye(n)
    return a, spd


def test_linalg_matches_scipy():
    real = _real_scipy()
    if real is None:
        return  # nothing to compare against on a device
    my = _vendored().linalg
    a, spd = _rng()
    sym = a + a.T

    for t in (1, 2, 3):
        assert np.allclose(real.linalg.eigh(sym, spd, type=t)[0],
                           my.eigh(sym, spd, type=t)[0])
    assert np.allclose(real.linalg.eigvalsh(sym, spd), my.eigvalsh(sym, spd))
    assert np.allclose(real.linalg.eigh(sym)[0], my.eigh(sym)[0])
    assert np.allclose(real.linalg.cholesky(spd, lower=True), my.cholesky(spd, lower=True))
    assert np.allclose(real.linalg.det(spd), my.det(spd))
    assert np.allclose(real.linalg.norm(a), my.norm(a))
    assert np.allclose(real.linalg.expm(0.01 * a), my.expm(0.01 * a))
    assert np.allclose(real.linalg.block_diag(np.eye(2), np.ones((2, 3))),
                       my.block_diag(np.eye(2), np.ones((2, 3))))

    cf, low = real.linalg.cho_factor(spd)
    cm, lowm = my.cho_factor(spd)
    assert np.allclose(real.linalg.cho_solve((cf, low), np.ones(6)),
                       my.cho_solve((cm, lowm), np.ones(6)))

    tri = np.tril(a) + 3 * np.eye(6)
    for trans in (0, 1, 2):
        assert np.allclose(
            real.linalg.solve_triangular(tri, np.ones(6), lower=True, trans=trans),
            my.solve_triangular(tri, np.ones(6), lower=True, trans=trans),
        )

    p, l, u = real.linalg.lu(a)
    pm, lm, um = my.lu(a)
    assert np.allclose(p @ l @ u, pm @ lm @ um)

    assert np.allclose(np.sort_complex(real.linalg.eig(a)[0]),
                       np.sort_complex(my.eig(a)[0]))
    wl, vll, vrl = real.linalg.eig(a, left=True)
    wlm, vllm, vrlm = my.eig(a, left=True)
    assert np.allclose(np.sort_complex(wl), np.sort_complex(wlm))
    # SciPy leaves left eigenvectors unit-norm; check we do too.
    assert np.allclose(np.linalg.norm(vllm, axis=0), 1.0)


def test_eigh_eigenvectors_satisfy_the_defining_equations():
    my = _vendored().linalg
    a, spd = _rng()
    sym = a + a.T

    w, v = my.eigh(sym, spd, type=1)
    assert np.abs(sym @ v - spd @ v * w).max() < 1e-10

    w, v = my.eigh(sym, spd, type=2)
    assert np.abs(sym @ spd @ v - v * w).max() < 1e-9

    w, v = my.eigh(sym, spd, type=3)
    assert np.abs(spd @ sym @ v - v * w).max() < 1e-9


# --------------------------------------------------------------------------
# special against real SciPy
# --------------------------------------------------------------------------


def test_special_matches_scipy():
    real = _real_scipy()
    if real is None:
        return
    my = _vendored().special

    x = np.array([0.1, 0.5, 1.0, 2.0, 3.7, 10.0])
    assert np.allclose(real.special.erf(x), my.erf(x))
    assert np.allclose(real.special.erfc(x), my.erfc(x))
    assert np.allclose(real.special.erfcx(x), my.erfcx(x))
    assert np.allclose(real.special.erfcx(np.array([5.0, 20.0, 50.0])),
                       my.erfcx(np.array([5.0, 20.0, 50.0])))
    assert np.allclose(real.special.gamma(x), my.gamma(x))
    assert np.allclose(real.special.factorial(x), my.factorial(x))
    assert np.allclose(real.special.gammaincc(x, x * 0.7), my.gammaincc(x, x * 0.7))
    assert np.allclose(real.special.lambertw(x).real, my.lambertw(x))
    for name in ("j0", "j1", "k0", "k1"):
        assert np.allclose(getattr(real.special, name)(x), getattr(my, name)(x))


def test_spherical_harmonics_match_scipy():
    real = _real_scipy()
    if real is None:
        return
    my = _vendored().special

    theta = np.array([0.3, 1.2, 2.5])
    phi = np.array([0.4, -1.0, 2.0])
    for n in range(0, 7):
        for m in range(-n, n + 1):
            assert np.allclose(real.special.sph_harm_y(n, m, theta, phi),
                               my.sph_harm_y(n, m, theta, phi)), (n, m)


def test_sph_harm_y_returns_scalars_for_scalar_input():
    my = _vendored().special
    value = my.sph_harm_y(2, 1, 0.5, 0.2)
    assert np.ndim(value) == 0


# --------------------------------------------------------------------------
# optimize against real SciPy
# --------------------------------------------------------------------------


def test_optimize_matches_scipy():
    real = _real_scipy()
    if real is None:
        return
    my = _vendored().optimize

    f = lambda t: np.cos(t) - t  # noqa: E731
    assert abs(real.optimize.bisect(f, 0, 1) - my.bisect(f, 0, 1)) < 1e-10

    mat = np.array([[4.0, 1.0, 0.0], [1.0, 3.0, 1.0], [0.0, 1.0, 2.0]])
    target = np.array([1.0, 2.0, 3.0])
    cost = lambda t: float(t @ mat @ t - 2 * target @ t)  # noqa: E731
    grad = lambda t: 2 * mat @ t - 2 * target  # noqa: E731

    r = real.optimize.minimize(cost, np.ones(3), jac=grad, method="BFGS", tol=1e-12)
    m = my.minimize(cost, np.ones(3), jac=grad, method="BFGS", tol=1e-12)
    assert abs(r.fun - m.fun) < 1e-9
    assert np.allclose(r.x, m.x, atol=1e-6)

    c = np.array([[4.0, 1.0, 3.0], [2.0, 0.0, 5.0], [3.0, 2.0, 2.0]])
    assert np.array_equal(real.optimize.linear_sum_assignment(c)[1],
                          my.linear_sum_assignment(c)[1])


def test_minimize_without_jacobian_reaches_the_same_minimum():
    my = _vendored().optimize
    mat = np.array([[4.0, 1.0, 0.0], [1.0, 3.0, 1.0], [0.0, 1.0, 2.0]])
    target = np.array([1.0, 2.0, 3.0])
    cost = lambda t: float(t @ mat @ t - 2 * target @ t)  # noqa: E731
    m = my.minimize(cost, np.ones(3), method="BFGS", tol=1e-10)
    assert np.allclose(m.x, np.linalg.solve(mat, target), atol=1e-6)


# --------------------------------------------------------------------------
# sparse
# --------------------------------------------------------------------------


def test_sparse_cg_solves_a_spd_system():
    my = _vendored().sparse
    rng = np.random.default_rng(5)
    a = rng.standard_normal((12, 12))
    a = a @ a.T + 12 * np.eye(12)
    b = rng.standard_normal(12)

    x, info = my.linalg.cg(a, b, rtol=1e-12)
    assert info == 0
    assert np.allclose(a @ x, b, atol=1e-6)


def test_sparse_gmres_solves_a_nonsymmetric_system():
    my = _vendored().sparse
    rng = np.random.default_rng(6)
    a = rng.standard_normal((10, 10)) + 10 * np.eye(10)
    b = rng.standard_normal(10)

    x, info = my.linalg.gmres(a, b, rtol=1e-10)
    assert np.allclose(a @ x, b, atol=1e-6)


def test_linear_operator_matvec_and_dot():
    my = _vendored().sparse
    a = np.arange(9.0).reshape(3, 3)
    op = my.linalg.LinearOperator((3, 3), matvec=lambda x: a @ x)
    v = np.array([1.0, 2.0, 3.0])
    assert np.allclose(op @ v, a @ v)
    assert np.allclose(op.dot(np.eye(3)), a)


# --------------------------------------------------------------------------
# h5py store
# --------------------------------------------------------------------------


def test_h5py_store_round_trips_across_reopen():
    _vendored()
    import h5py

    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "data.chk")
        assert not h5py.is_hdf5(path)

        with h5py.File(path, "w") as fh:
            fh["scf/e_tot"] = np.float64(-76.02)
            fh["scf/mo_energy"] = np.array([-1.0, -0.5, 0.2])
            fh.create_group("symm")["Ci/op"] = np.array(["E", "i"])

        assert h5py.is_hdf5(path)

        with h5py.File(path, "r") as fh:
            assert fh["scf/e_tot"][()] == -76.02
            assert np.allclose(fh["scf/mo_energy"][()], [-1.0, -0.5, 0.2])
            assert list(fh["symm/Ci/op"][()]) == [b"E", b"i"]
            assert "scf" in fh and "symm/Ci" in fh and "missing" not in fh
            assert isinstance(fh["scf"], h5py.Group)
            assert isinstance(fh["scf/e_tot"], h5py.Dataset)


def test_h5py_store_append_and_delete():
    _vendored()
    import h5py

    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "data.chk")
        with h5py.File(path, "w") as fh:
            fh["a"] = np.arange(3)
        with h5py.File(path, "a") as fh:
            fh["b"] = np.arange(4)
        with h5py.File(path, "r") as fh:
            assert sorted(fh.keys()) == ["a", "b"]
        with h5py.File(path, "r+") as fh:
            del fh["b"]
        with h5py.File(path, "r") as fh:
            assert list(fh.keys()) == ["a"]


def test_h5py_low_level_create_dataset_is_zero_filled_and_writable():
    _vendored()
    import h5py

    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "scratch.h5")
        with h5py.File(path, "w") as fh:
            # The signature PySCF's CCSD uses.
            ds = fh.create_dataset("block", (2, 3, 4), "f8")
            assert ds.shape == (2, 3, 4)
            assert np.all(ds[()] == 0.0)
            ds[0] = 1.0
            ds[1, :, 2] += 5.0

        with h5py.File(path, "r") as fh:
            got = fh["block"][()]
            assert np.all(got[0] == 1.0)
            assert np.all(got[1, :, 2] == 5.0)
            assert np.all(got[1, :, 0] == 0.0)


def test_h5py_dataset_exposes_the_metadata_pyscf_reads():
    """The dataset attributes PySCF's out-of-core loader branches on.

    ``ao2mo/outcore._load_from_h5g`` reads ``dat.ndim`` to tell a two-index
    store from a multi-component one, and reads each block with ``read_direct``
    rather than ``ds[...]``.  Both were missing, so Edmiston-Ruedenberg failed
    on iOS only, with an AttributeError that never appears on the build host.
    """
    _vendored()
    import h5py

    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "ints.h5")
        with h5py.File(path, "w") as fh:
            ds = fh.create_dataset("eri", (2, 3, 4), "f8")
            ds[0] = 1.0
            ds[1, :, 2] = 7.0

        with h5py.File(path, "r") as fh:
            ds = fh["eri"]
            assert ds.ndim == 3
            assert ds.size == 24
            assert ds.maxshape == (2, 3, 4)
            assert ds.fillvalue is None
            assert ds.chunks is None
            # read_direct with and without explicit selections.
            whole = np.zeros((2, 3, 4))
            ds.read_direct(whole)
            assert whole[0].sum() == 12.0
            assert np.all(whole[1, :, 2] == 7.0)
            block = np.zeros((3, 4))
            ds.read_direct(block, np.s_[1], np.s_[:])
            assert np.all(block[:, 2] == 7.0)
            assert ds.astype("f4").dtype == np.float32
            # Attribute-style metadata, which PySCF writes on checkpoints.
            ds.attrs["mol"] = "water"
            assert ds.attrs["mol"] == "water"


def test_h5py_is_hdf5_accepts_an_open_file():
    _vendored()
    import h5py

    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "data.chk")
        with h5py.File(path, "w") as fh:
            assert h5py.is_hdf5(fh)


# --------------------------------------------------------------------------
# the real thing: the chemistry pipeline on the shims
# --------------------------------------------------------------------------


def test_scf_runs_on_the_shims_and_matches_the_reference_energy():
    _vendored()
    from pyscf_mobile import engine

    result = engine.run_scf({
        "atoms": "O 0 0 0; H 0 0 0.96; H 0 0.9 0",
        "basis": "sto-3g",
        "method": "RHF",
    })
    # Reference value from PySCF on Linux with the real SciPy.
    assert abs(result["energy"] - (-74.9474159374)) < 1e-8


def test_dft_runs_on_the_shims():
    _vendored()
    from pyscf_mobile import engine

    result = engine.run_scf({
        "atoms": "O 0 0 0; H 0 0 0.96; H 0 0.9 0",
        "basis": "sto-3g",
        "method": "RKS",
        "xc": "b3lyp",
    })
    assert abs(result["energy"] - (-75.2959883784)) < 1e-8


def test_ccsd_runs_on_the_shims_and_exercises_the_h5py_temp_files():
    """CCSD is the path that writes into h5py datasets, so it must work."""
    _vendored()
    from pyscf_mobile import engine

    result = engine.run_ccsd({
        "atoms": "O 0 0 0; H 0 0 0.96; H 0 0.9 0",
        "basis": "sto-3g",
        "reference": "RHF",
    })
    assert abs(result["correlationEnergy"] - (-0.0488641187)) < 1e-8


def test_trsm_matches_scipy():
    """``get_blas_funcs(('trsm',))`` is the DF path's linear solve.

    SciPy's wrapper is f2py-generated, so its conventions do not match a naive
    reading: the triangle is taken from ``a`` *before* the transpose, and the
    result is a right solve.  Getting either backwards still returns an array
    of the right shape for a square operand, so only a non-square ``b`` -- which
    is what a blocked integral build produces -- exposes it.
    """
    real = _real_scipy()
    if real is None:
        return  # nothing to compare against on a device
    my = _vendored().linalg
    rng = np.random.default_rng(1234)

    for naux in (1, 2, 4, 7, 13):
        for nrow in (1, 3, naux, 2 * naux + 1):
            a = rng.random((naux, naux))
            low = np.linalg.cholesky(a @ a.T + np.eye(naux) * 5)
            for lower in (True, False):
                operand = low if lower else low.T
                for trans_a in (0, 1):
                    b = rng.random((nrow, naux))
                    want, = real.linalg.get_blas_funcs(("trsm",), (operand, b))
                    got, = my.get_blas_funcs(("trsm",), (operand, b))
                    # overwrite_b is destructive, so both sides get a copy.
                    expected = want(1.0, operand, b.copy(), lower=lower,
                                    trans_a=trans_a, side=1, overwrite_b=True)
                    result = got(1.0, operand, b.copy(), lower=lower,
                                 trans_a=trans_a, side=1, overwrite_b=True)
                    assert np.allclose(expected, result), (
                        naux, nrow, lower, trans_a)


def test_trsm_agrees_with_solve_triangular_on_the_pyscf_call():
    """The two branches of PySCF's blocked build must agree.

    ``pyscf/df/incore.py`` picks ``trsm`` for C-contiguous blocks and
    ``solve_triangular`` otherwise.  If they disagree the result depends on
    memory layout, which is how the transposed-triangle bug reached a device.
    """
    my = _vendored().linalg
    rng = np.random.default_rng(7)

    for naux, nrow in ((13, 40), (60, 200), (348, 1485)):
        a = rng.random((naux, naux))
        low = np.linalg.cholesky(a @ a.T + np.eye(naux) * 5)
        ints = rng.random((naux, nrow))

        trsm, = my.get_blas_funcs(("trsm",), (low, ints))
        via_trsm = trsm(1.0, low, ints.T, lower=True, trans_a=1,
                        side=1, overwrite_b=True).T
        via_solve = my.solve_triangular(low, ints, lower=True,
                                        check_finite=False)
        assert via_trsm.shape == via_solve.shape
        assert np.allclose(via_trsm, via_solve)


def test_density_fitting_runs_on_the_shims():
    """Density fitting must work with the vendored SciPy, not just the host's.

    This is the case that failed on device: the DF builder is the only caller
    of ``trsm``, and every other shim test uses routines the host SciPy also
    provides, so a broken ``trsm`` passed the whole suite.
    """
    _vendored()
    from pyscf_mobile import engine

    result = engine.run_geometry_optimisation({
        "atoms": "O 0 0 0; H 0 0 1.30; H 0 1.10 -0.30",
        "method": "RHF",
        "basis": "6-31g",
        "maxSteps": 20,
        "densityFit": True,
    })
    assert result["converged"]
    # Reference from the host SciPy with the same request.
    assert abs(result["energy"] - (-75.985355)) < 1e-5


def test_orbital_localisation_runs_on_the_shims():
    """Every localisation method must work with the vendored SciPy.

    This is the device path: ``vendor.install(force=True)`` puts the shims first
    and PySCF's ``lo`` helpers reach for ``scipy.linalg``, so a method that
    works on the host can still fail on device.  Edmiston-Ruedenberg is the one
    that used to, through ``h5py``'s dataset interface.
    """
    _vendored()
    from pyscf_mobile import engine

    for method in ("pm-mulliken", "pm-lowdin", "boys", "er"):
        payload = engine.dispatch("scf", {
            "atoms": "O 0 0 0; H 0 0 0.96; H 0 0.9 0",
            "basis": "sto-3g",
            "method": "RHF",
            "include": [f"localization:{method}"],
        })
        assert payload["ok"] is True, f"{method} failed: {payload.get('error')}"
        assert payload["localization"]["localization"] == method
        assert len(payload["localization"]["centroids"]) == 5


def test_localised_orbital_surface_runs_on_the_shims():
    """The viewer's own request, for each method, on the device stack."""
    _vendored()
    from pyscf_mobile import engine

    for method in ("pm-mulliken", "boys", "er"):
        payload = engine.dispatch("orbital_surface", {
            "atoms": "O 0 0 0; H 0 0 0.96; H 0 0.9 0",
            "basis": "sto-3g",
            "method": "RHF",
            "source": method,
            "index": 1,
            "pointsPerAxis": 24,
        })
        assert payload["ok"] is True, f"{method} failed: {payload.get('error')}"
        assert payload["label"] == "LMO 2"
        assert payload["occupation"] == 2.0
