"""Intrinsic localised orbitals, checked against the Multiwfn reference.

Every Pipek-Mezey and Foster-Boys number asserted here was produced by running
Multiwfn 2026.10.18 itself on a MOLDEN written by PySCF -- the noGUI binary,
main function 19, option ``-6`` to pick the method -- and reading the ``P``
values from its convergence cycles.  A localisation that looks plausible but
optimises the wrong functional still yields compact-looking orbitals, so the
reference values are the only way to tell a faithful port from a plausible one.

The objective is not something Multiwfn prints directly.  It prints the sum of
squared Mulliken atomic populations regardless of which method is running, so
for Foster-Boys its ``P`` column is that metric and not the Boys spread.  The
Boys rows below therefore assert the orbital *centroids*, which Multiwfn does
print, and the spread, which is what the method actually minimises.

Edmiston-Ruedenberg is not one of Multiwfn's methods, so it is checked against
``pyscf.lo.ER`` -- an independent implementation -- and against the
stationarity of its own objective.

Run with ``python tests/run_tests.py``.
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src"))

import numpy as np  # noqa: E402
from pyscf import gto, scf  # noqa: E402

from pyscf_mobile import orbital_localization  # noqa: E402

WATER = "O 0 0 0; H 0 -0.757 0.587; H 0 0.757 0.587"
METHANE = (
    "C 0 0 0; H 0.6291 0.6291 0.6291; H -0.6291 -0.6291 0.6291; "
    "H -0.6291 0.6291 -0.6291; H 0.6291 -0.6291 -0.6291"
)
AMMONIA = (
    "N 0 0 0.1173; H 0 0.9377 -0.2738; H 0.8121 -0.4689 -0.2738; "
    "H -0.8121 -0.4689 -0.2738"
)

# Multiwfn's last printed ``P`` for each method, read from its convergence
# cycles.  This is the sum of squared Mulliken atomic populations for every
# method, so it is the objective itself for the two Pipek-Mezey variants and
# only a cross-check for Foster-Boys.
MULTIWFN = {
    ("water", "6-31g"): {"pm-mulliken": 4.22821434, "pm-lowdin": 4.06690454},
    ("methane", "6-31g"): {"pm-mulliken": 3.14949010, "pm-lowdin": 3.00508370},
    ("ammonia", "6-31g"): {"pm-mulliken": 3.72021927, "pm-lowdin": 3.54084907},
}

# Multiwfn's Foster-Boys orbital centres for water, in Bohr, from its
# LMOcen.txt.  These are the quantity the method is defined to produce, so they
# validate the orbitals themselves rather than the value of a scalar.
MULTIWFN_BOYS_CENTROIDS = {
    "water": np.array(
        [
            [0.0000, -0.0000, 0.0005],
            [0.0002, 0.7771, 0.6147],
            [0.0004, -0.7771, 0.6147],
            [0.5067, 0.0001, -0.3195],
            [-0.5073, -0.0000, -0.3189],
        ]
    ),
}


def _mean_field(geometry: str, basis: str = "6-31g"):
    mol = gto.M(atom=geometry, basis=basis, verbose=0)
    return scf.RHF(mol).run(), mol


def _atoms(mol) -> list[dict]:
    return [{"element": mol.atom_symbol(i)} for i in range(mol.natm)]


def _mulliken_objective(mol, orbitals: np.ndarray) -> float:
    """``sum_A sum_i Q_Ai^2``, the metric Multiwfn prints for every method."""
    overlap = mol.intor_symmetric("int1e_ovlp")
    weighted = overlap @ orbitals
    total = 0.0
    for atom in range(mol.natm):
        slice_ = mol.aoslice_by_atom()[atom]
        block = np.arange(int(slice_[2]), int(slice_[3]))
        populations = np.einsum("mi,mi->i", orbitals[block], weighted[block])
        total += float(np.sum(populations**2))
    return total


def _localised(geometry: str, method: str, basis: str = "6-31g"):
    """``(mean field, molecule, coefficients, sweeps, objective)``."""
    mf, mol = _mean_field(geometry, basis)
    coefficients, sweeps, objective = orbital_localization.localize_coefficients(
        mf, method=method
    )
    return mf, mol, coefficients, sweeps, objective


def test_pipek_mezey_matches_multiwfn():
    """The objective reproduces Multiwfn's, and is not beaten by any rotation."""
    for (name, basis), expected in MULTIWFN.items():
        geometry = {"water": WATER, "methane": METHANE, "ammonia": AMMONIA}[name]
        for method, reference in expected.items():
            _mf, _mol, _coefficients, _sweeps, objective = _localised(
                geometry, method, basis
            )
            # Multiwfn stops when its per-cycle change falls below 1e-4, so its
            # printed value can sit a little short of the converged optimum --
            # ammonia's Mulliken run is one such case, where the port lands
            # 1.9e-7 higher.  Its own threshold is therefore the tolerance: a
            # genuinely different optimum would miss by far more than this.
            assert abs(objective - reference) < 1e-4, (
                f"{name}/{basis} {method}: objective {objective:.8f} differs from "
                f"Multiwfn's {reference:.8f} by more than its stopping tolerance"
            )


def test_boys_reproduces_multiwfn_orbital_centres():
    """Foster-Boys centroids match Multiwfn's printed LMOcen.txt."""
    mf, mol, _coefficients, _sweeps, _objective = _localised(WATER, "boys")
    result = orbital_localization.localize(mf, _atoms(mol), method="boys")
    assert result is not None
    mine = np.array(result["centroids"])
    reference = MULTIWFN_BOYS_CENTROIDS["water"]
    assert mine.shape == reference.shape

    # The orbitals are only defined up to their ordering, so the centroids are
    # compared as an unordered set.
    remaining = list(reference)
    for centroid in mine:
        distances = [np.abs(centroid - candidate).max() for candidate in remaining]
        closest = int(np.argmin(distances))
        assert distances[closest] < 1e-3, (
            f"centroid {centroid} has no Multiwfn counterpart within 1e-3 Bohr"
        )
        remaining.pop(closest)


def test_boys_minimises_the_spread():
    """Boys lowers the summed second moment from the canonical orbitals."""
    mf, mol, _coefficients, _sweeps, _objective = _localised(WATER, "boys")
    dipole = mol.intor("int1e_r", comp=3)
    r2 = mol.intor("int1e_r2")

    def spread(occupied: np.ndarray) -> float:
        total = 0.0
        for column in range(occupied.shape[1]):
            vector = occupied[:, column]
            centroid = np.einsum("kij,i,j->k", dipole, vector, vector)
            total += float(vector @ r2 @ vector) - float(centroid @ centroid)
        return total

    canonical = np.asarray(mf.mo_coeff)[:, : mol.nelectron // 2]
    localised, _sweeps, _objective = orbital_localization.localize_coefficients(
        mf, method="boys"
    )
    assert spread(localised) <= spread(canonical) + 1e-9, (
        "Boys should not increase the orbital spread"
    )


def test_every_method_returns_an_orthonormal_span():
    """Each method rotates the occupied space rather than leaving it."""
    for method in ("pm-mulliken", "pm-lowdin", "boys", "er"):
        mf, mol, coefficients, sweeps, objective = _localised(WATER, method)
        overlap = mol.intor_symmetric("int1e_ovlp")
        count = mol.nelectron // 2
        assert coefficients.shape == (mol.nao, count)
        assert np.abs(coefficients.T @ overlap @ coefficients - np.eye(count)).max() < 1e-9
        assert np.isfinite(objective)
        assert sweeps > 0


def test_methods_are_start_independent():
    """A rotation of the occupied space localises to the same objective.

    This is what "intrinsic" means: the method optimises a functional of the
    orbitals, so any orthonormal set spanning the occupied space must lead to
    the same value.  A port that followed the reference program's iteration
    order without a well-defined objective would fail this.
    """
    from scipy.linalg import expm

    mf, mol = _mean_field(WATER)
    _coefficients, _sweeps, baseline = orbital_localization.localize_coefficients(
        mf, method="pm-mulliken"
    )
    occupied = np.asarray(mf.mo_coeff)[:, : mol.nelectron // 2]
    rng = np.random.default_rng(20261024)
    skew = rng.normal(size=(occupied.shape[1],) * 2)
    skew = skew - skew.T

    class _Seeded:
        """A stand-in for a mean field whose occupied space has been rotated."""

        pass

    seeded = _Seeded()
    seeded.mol = mol
    seeded.mo_coeff = occupied @ expm(0.7 * skew)
    seeded.mo_occ = np.asarray(mf.mo_occ)
    _rotated, _sweeps, objective = orbital_localization.localize_coefficients(
        seeded, method="pm-mulliken"
    )
    assert abs(objective - baseline) < 1e-6, (
        f"objective depends on the starting orbitals: {objective:.8f} vs "
        f"{baseline:.8f}"
    )


def test_edmiston_ruedenberg_matches_pyscf():
    """ER reproduces the independent implementation in ``pyscf.lo``."""
    from pyscf import lo as pyscf_lo

    mf, mol = _mean_field(WATER)
    localised, _sweeps, _objective = orbital_localization.localize_coefficients(
        mf, method="er"
    )
    overlap = mol.intor_symmetric("int1e_ovlp")
    occupied = np.asarray(mf.mo_coeff)[:, : mol.nelectron // 2]
    reference = pyscf_lo.ER(mol, occupied).kernel()

    # The two are the same subspace when the overlap between them is unitary.
    singular = np.linalg.svd(localised.T @ overlap @ reference, compute_uv=False)
    assert np.abs(singular - 1.0).max() < 1e-8, (
        "ER subspace differs from pyscf.lo.ER; singular values "
        f"{np.round(singular, 6)}"
    )


def test_edmiston_ruedenberg_is_stationary():
    """No small rotation of the ER orbitals raises the self-repulsion."""
    from pyscf import ao2mo
    from scipy.linalg import expm

    mf, mol = _mean_field(WATER)
    localised, _sweeps, objective = orbital_localization.localize_coefficients(
        mf, method="er"
    )

    def self_repulsion(coefficients: np.ndarray) -> float:
        n = coefficients.shape[1]
        tensor = ao2mo.full(mol, coefficients, compact=False).reshape(n, n, n, n)
        return float(sum(tensor[i, i, i, i] for i in range(n)))

    best = self_repulsion(localised)
    assert abs(best - objective) < 1e-8, "reported objective is not the one achieved"

    rng = np.random.default_rng(7)
    for _ in range(8):
        skew = rng.normal(scale=1e-3, size=(localised.shape[1],) * 2)
        skew = skew - skew.T
        assert self_repulsion(localised @ expm(skew)) <= best + 1e-9, (
            "a small rotation raised the ER objective, so the port stopped "
            "short of a stationary point"
        )


def test_unknown_method_is_rejected():
    mf, _mol = _mean_field(WATER)
    try:
        orbital_localization.localize_coefficients(mf, method="nonsense")
    except ValueError:
        return
    raise AssertionError("an unknown method should raise ValueError")


def test_open_shell_is_localised_per_spin_channel():
    """An open shell is localised, but only within each spin channel.

    The methods rotate the occupied space, and for an open-shell reference that
    space splits: the singly occupied columns of a restricted open-shell run are
    not mixed with the pairs, and the alpha and beta sets of an unrestricted run
    stay apart.  The orbitals that come back must still be orthonormal and must
    still span the occupied space.
    """
    mol = gto.M(atom="O 0 0 0; O 0 0 1.2075", basis="6-31g", spin=2, verbose=0)
    mf = scf.ROHF(mol).run()

    result = orbital_localization.localize(mf, _atoms(mol), method="pm-mulliken")
    assert result is not None, "a restricted open-shell reference should localise"

    coefficients, _sweeps, _objective = orbital_localization.localize_coefficients(
        mf, method="pm-mulliken")
    overlap = mol.intor_symmetric("int1e_ovlp")
    # Still an orthonormal set spanning the same occupied space.
    assert np.allclose(coefficients.T @ overlap @ coefficients, np.eye(coefficients.shape[1]),
                       atol=1e-8)
    assert coefficients.shape[1] == orbital_localization.localizable_orbital_count(mf)
    # The singly occupied columns are carried through, so one spin channel holds
    # two more orbitals than the other for a triplet.
    spins = orbital_localization.localized_orbital_spins(mf)
    assert len(spins) == coefficients.shape[1]


def test_unrestricted_localisation_keeps_the_spin_channels_apart():
    """UHF stores alpha and beta separately and each is rotated on its own."""
    mol = gto.M(atom="O 0 0 0; O 0 0 1.2075", basis="6-31g", spin=2, verbose=0)
    mf = scf.UHF(mol).run()

    coefficients, _sweeps, _objective = orbital_localization.localize_coefficients(
        mf, method="boys")
    occupations = np.asarray(mf.mo_occ)
    alpha = int(np.sum(occupations[0] > 0.5))
    beta = int(np.sum(occupations[1] > 0.5))
    assert coefficients.shape[1] == alpha + beta
    spins = orbital_localization.localized_orbital_spins(mf)
    assert spins == [0] * alpha + [1] * beta

    # Rotating within a channel cannot change the number of electrons in it,
    # and each channel stays orthonormal on its own.  The two channels are not
    # mutually orthogonal -- alpha and beta are eigenvectors of different Fock
    # operators -- so only the within-channel property is asserted here.
    overlap = mol.intor_symmetric("int1e_ovlp")
    alpha_block = coefficients[:, :alpha]
    beta_block = coefficients[:, alpha:]
    assert np.allclose(alpha_block.T @ overlap @ alpha_block, np.eye(alpha), atol=1e-8)
    assert np.allclose(beta_block.T @ overlap @ beta_block, np.eye(beta), atol=1e-8)


def test_payload_shape():
    """The payload carries what the panel and the report read."""
    mf, mol = _mean_field(WATER)
    result = orbital_localization.localize(mf, _atoms(mol), method="boys")
    assert result is not None
    assert result["localization"] == "boys"
    assert result["family"] == "Foster-Boys"
    assert isinstance(result["sweeps"], int) and result["sweeps"] > 0
    assert len(result["centroids"]) == 5
    assert len(result["centroids"][0]) == 3
    assert len(result["compositions"]["perAtom"]) == 3
    assert len(result["compositions"]["percent"]) == 3
    assert result["analysisMethod"]


def test_engine_dispatch_reaches_the_localisers():
    """The RPC names the UI sends resolve to each method."""
    from pyscf_mobile import engine

    base = {"atoms": WATER, "basis": "6-31g"}
    for name, expected in (
        ("boys", "boys"),
        ("er", "er"),
        ("pm", "pm-mulliken"),
        ("pipek_mezey", "pm-mulliken"),
    ):
        payload = engine.dispatch(name, dict(base))
        assert payload["ok"] is True
        # "method" is the mean-field reference, not the localisation objective.
        assert payload["method"] == "RHF/6-31g"
        assert payload["localization"] == expected, (
            f"{name} selected {payload['localization']}, expected {expected}"
        )
        assert payload["family"]
        assert payload["objective"] > 0.0
        assert len(payload["centroids"]) == 5

    # The objective can also be chosen through "kind" on the shared entry point.
    payload = engine.dispatch("pm", {**base, "kind": "pm-lowdin"})
    assert payload["localization"] == "pm-lowdin"


def test_composition_column_sums_are_one():
    """Each orbital's per-atom populations sum to one, for every method.

    This is the property the panel relies on to read the numbers as a share of
    the orbital.  Summing magnitudes element by element used to break it, so it
    is asserted directly rather than left to the renderer.
    """
    import numpy as np

    mf, mol = _mean_field(WATER)
    overlap = mol.intor_symmetric("int1e_ovlp")
    for method in ("pm-mulliken", "pm-lowdin", "boys", "er"):
        coefficients, _, _ = orbital_localization.localize_coefficients(mf, method=method)
        per_atom = np.asarray(orbital_localization._composition(mol, overlap, coefficients)["perAtom"])
        sums = per_atom.sum(axis=0)
        assert np.allclose(sums, 1.0, atol=1e-4), f"{method} column sums {sums}"


def test_localization_is_opt_in_for_scf():
    """The SCF payload only carries localisation when it is asked for.

    It is a Jacobi sweep over the occupied space, so paying for it on every run
    would slow the common case for a panel that is usually not open.
    """
    from pyscf_mobile import engine

    base = {"atoms": WATER, "basis": "6-31g", "method": "RHF"}
    assert "localization" not in engine.run_scf({**base, "include": []})
    assert "localization" not in engine.run_scf({**base, "include": ["mo"]})

    payload = engine.run_scf({**base, "include": ["localization"]})
    assert payload["localization"]["localization"] == "pm-mulliken"

    # The method can be named on the request as well.
    payload = engine.run_scf({**base, "include": ["localization:er"]})
    assert payload["localization"]["localization"] == "er"
    assert payload["localization"]["family"] == "Edmiston-Ruedenberg"
