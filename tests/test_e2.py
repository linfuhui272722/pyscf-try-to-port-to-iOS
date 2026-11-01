"""E(2) second-order perturbation energies.

The numbers asserted here are checked two ways.  The *ranges* come from the
chemistry: water's largest donor-acceptor interaction is a lone pair pushing
into an O-H antibond, worth a few kcal/mol, and the total over all pairs is of
the same order.  A value of zero means the analysis found no interaction; a
value in the hundreds means it is measuring the overlap of two orbital spaces
rather than an interaction between orbitals.  Both are asserted against
explicitly, because both are what a plausible-looking wrong implementation
produces.

The structural checks are the load-bearing ones: the Lewis orbital set must be
globally orthonormal, and the donor and acceptor spaces must be orthogonal to
each other.  Everything about the magnitude of the result follows from those
two properties, so they are tested directly rather than inferred from an energy.

Reproducibility is tested directly as well.  The Lewis orbitals are only defined
up to a rotation inside each degenerate set, so the total is only meaningful if
the analysis fixes that rotation itself; the test reruns the SCF and requires
the same total, which a per-orbital sum over an arbitrary rotation does not give.

Run with ``python tests/run_tests.py``.
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src"))

import numpy as np  # noqa: E402
from pyscf import gto, scf  # noqa: E402

from pyscf_mobile import e2, engine, localized_orbitals  # noqa: E402

WATER = "O 0 0 0; H 0 -0.757 0.587; H 0 0.757 0.587"
AMMONIA = "N 0 0 0; H 0 -0.9377 0.3816; H 0.8123 0.4689 0.3816; H -0.8123 0.4689 0.3816"


def _water(basis="6-31g", method="RHF"):
    mol = gto.M(atom=WATER, basis=basis, verbose=0)
    mf = (scf.RHF if method == "RHF" else scf.UHF)(mol)
    mf.kernel()
    atoms = [
        {"element": mol.atom_symbol(i), "z": mol.atom_charge(i), "xyz": list(mol.atom_coords()[i])}
        for i in range(mol.natm)
    ]
    return mf, atoms


# --------------------------------------------------------------------------
# the structural properties the numbers depend on
# --------------------------------------------------------------------------


def test_lewis_orbitals_are_globally_orthonormal():
    """The whole E(2) formulation rests on this.

    The orbitals are assembled from per-atom hybrids, and each hybrid belongs to
    exactly one bond or lone pair, so the set is orthonormal across the molecule
    rather than only within an atom.
    """
    mf, atoms = _water()
    orbitals = localized_orbitals.lewis_orbitals(mf, atoms)
    assert orbitals is not None
    overlap = np.asarray(mf.mol.intor_symmetric("int1e_ovlp"), dtype=float)
    coefficients = orbitals["coefficients"]
    gram = coefficients.T @ overlap @ coefficients
    error = np.abs(gram - np.eye(gram.shape[0])).max()
    assert error < 1e-10, f"Lewis orbitals are not orthonormal: max error {error:.3e}"


def test_donor_and_acceptor_spaces_are_mutually_orthogonal():
    """The property that separates a real interaction from an overlap artefact.

    Canonical occupied and virtual orbitals are each orthonormal but the two
    spaces are not orthogonal to each other, so a Fock element between them
    carries the space overlap as well as the coupling.  The Lewis orbitals have no
    such overlap, and this is what makes the reported E(2) a coupling.
    """
    mf, atoms = _water()
    orbitals = localized_orbitals.lewis_orbitals(mf, atoms)
    overlap = np.asarray(mf.mol.intor_symmetric("int1e_ovlp"), dtype=float)
    coefficients = orbitals["coefficients"]
    types = orbitals["types"]
    donors = coefficients[:, [i for i, t in enumerate(types) if t in ("bonding", "lonePair")]]
    acceptors = coefficients[:, [i for i, t in enumerate(types) if t in ("antiBonding", "rydberg")]]
    mixing = np.abs(donors.T @ overlap @ acceptors).max()
    assert mixing < 1e-10, f"donor and acceptor spaces overlap: {mixing:.3e}"


def test_canonical_coupling_vanishes_by_brillouin():
    """The discriminating test for the choice of orbitals.

    A canonical reference cannot be used for this analysis, and the reason is
    Brillouin's theorem rather than an overlap artefact: for a converged SCF the
    Fock matrix is diagonal, so the occupied-virtual block is zero and a
    canonical E(2) would report essentially nothing.  The Lewis coupling over the
    same molecule is orders of magnitude larger, so a change that switched the
    donors or acceptors to canonical orbitals would fail here rather than quietly
    reporting a near-zero stabilisation.
    """
    mf, atoms = _water()
    fock = np.asarray(mf.get_fock(), dtype=float)
    coefficients = np.asarray(mf.mo_coeff, dtype=float)
    occupancy = np.asarray(mf.mo_occ, dtype=float)
    occupied = coefficients[:, occupancy > 0]
    virtual = coefficients[:, occupancy == 0]
    canonical_coupling = np.abs(occupied.T @ fock @ virtual).max()
    assert canonical_coupling < 1e-5, (
        f"Brillouin's theorem should zero the canonical coupling, got "
        f"{canonical_coupling:.3e}"
    )

    # The Lewis coupling is real and much larger, so the two choices are not
    # interchangeable.
    orbitals = localized_orbitals.lewis_orbitals(mf, atoms)
    lewis = np.asarray(orbitals["coefficients"], dtype=float)
    types = list(orbitals["types"])
    donors = [i for i, t in enumerate(types) if t in ("bonding", "lonePair")]
    acceptors = [i for i, t in enumerate(types) if t in ("antiBonding", "rydberg")]
    lewis_coupling = np.abs(lewis[:, donors].T @ fock @ lewis[:, acceptors]).max()
    assert lewis_coupling > 1e-2, f"expected a real Lewis coupling, got {lewis_coupling:.3e}"
    assert lewis_coupling > 100 * canonical_coupling


# --------------------------------------------------------------------------
# magnitudes
# --------------------------------------------------------------------------


def test_water_sto3g_total_is_a_few_kcal():
    """STO-3G water: two O-H antibonds, total about -2.4 kcal/mol."""
    mf, atoms = _water("sto-3g")
    result = e2.compute(mf, atoms)
    total = result["totalStabilizationKcal"]
    assert -10.0 < total < -0.5, total
    assert result["donorCount"] == 5
    assert result["acceptorCount"] == 2


def test_water_631g_total_is_a_few_kcal():
    """6-31G water: total about -4.3 kcal/mol."""
    mf, atoms = _water("6-31g")
    result = e2.compute(mf, atoms)
    total = result["totalStabilizationKcal"]
    assert -10.0 < total < -0.5, total


def test_every_listed_interaction_stabilises():
    """E(2) is a stabilisation, so no term may be positive."""
    mf, atoms = _water("6-31g")
    result = e2.compute(mf, atoms)
    assert result["interactionCount"] > 0
    for interaction in result["interactions"]:
        assert interaction["energyKcal"] <= 1e-9, interaction
        assert interaction["energyKcal"] > -50.0, interaction


def test_no_interaction_exceeds_a_chemical_magnitude():
    """Rejects the overlap artefact directly.

    A naive calculation that pairs canonical occupied orbitals with canonical
    virtuals gives -367 kcal/mol for the largest term on this molecule, because
    the two spaces overlap.  Nothing in a molecule's Lewis structure is worth
    that, so the bound is set well below it and well above the real value.
    """
    mf, atoms = _water("sto-3g")
    result = e2.compute(mf, atoms)
    largest = min(i["energyKcal"] for i in result["interactions"])
    assert largest > -30.0, (
        f"largest interaction {largest:.3f} kcal/mol is not chemically plausible; "
        f"this is the signature of a non-orthogonal donor/acceptor pair"
    )


def test_threshold_is_in_kcal_per_mol():
    """The listing threshold is compared in the unit it is documented in."""
    mf, atoms = _water("6-31g")
    coarse = e2.compute(mf, atoms, threshold_kcal=1.0)
    fine = e2.compute(mf, atoms, threshold_kcal=0.0)
    assert fine["interactionCount"] >= coarse["interactionCount"]
    # A threshold of 1 kcal/mol keeps only terms at least that large.
    for interaction in coarse["interactions"]:
        assert abs(interaction["energyKcal"]) >= 1.0, interaction


def test_total_covers_interactions_below_the_threshold():
    """The total is over every pair, not only the listed ones."""
    mf, atoms = _water("6-31g")
    coarse = e2.compute(mf, atoms, threshold_kcal=1.0)
    fine = e2.compute(mf, atoms, threshold_kcal=0.0)
    assert coarse["interactionCount"] < fine["interactionCount"]
    assert abs(coarse["totalStabilizationKcal"] - fine["totalStabilizationKcal"]) < 1e-9


def test_labels_name_the_orbitals():
    """A donor is a bond or a lone pair, an acceptor an antibond or Rydberg."""
    mf, atoms = _water("6-31g")
    result = e2.compute(mf, atoms)
    assert result["interactionCount"] > 0
    for interaction in result["interactions"]:
        assert interaction["donorType"] in ("bonding", "lonePair"), interaction
        assert interaction["acceptorType"] in ("antiBonding", "rydberg"), interaction
        assert interaction["donorLabel"], interaction
        assert interaction["acceptorLabel"], interaction
    # The strongest term on water is a lone pair feeding an antibond.
    strongest = result["interactions"][0]
    assert strongest["acceptorType"] in ("antiBonding", "rydberg"), strongest


def test_lone_pair_to_antibond_is_the_largest_term():
    """Chemistry check: on ammonia the lone pair dominates the stabilisation."""
    mol = gto.M(atom=AMMONIA, basis="6-31g", verbose=0)
    mf = scf.RHF(mol)
    mf.kernel()
    atoms = [
        {"element": mol.atom_symbol(i), "z": mol.atom_charge(i), "xyz": list(mol.atom_coords()[i])}
        for i in range(mol.natm)
    ]
    result = e2.compute(mf, atoms)
    assert result["totalStabilizationKcal"] < -0.5
    strongest = result["interactions"][0]
    assert strongest["donorType"] == "lonePair", strongest
    assert strongest["donorLabel"].startswith("N"), strongest


# --------------------------------------------------------------------------
# references the analysis declines
# --------------------------------------------------------------------------


def test_unrestricted_reference_is_refused():
    """One Fock matrix per spin cannot be paired with total-density orbitals."""
    mol = gto.M(atom="O 0 0 0; H 0 -0.757 0.587; H 0 0.757 0.587", basis="6-31g",
                spin=2, charge=0, verbose=0)
    mf = scf.UHF(mol)
    mf.kernel()
    atoms = [
        {"element": mol.atom_symbol(i), "z": mol.atom_charge(i), "xyz": list(mol.atom_coords()[i])}
        for i in range(mol.natm)
    ]
    try:
        e2.compute(mf, atoms)
    except ValueError as exc:
        assert "closed-shell" in str(exc), exc
    else:
        raise AssertionError("an unrestricted reference should be refused")


# --------------------------------------------------------------------------
# through the engine
# --------------------------------------------------------------------------


def test_total_is_reproducible_across_scf_runs():
    """The total must not depend on an arbitrary rotation inside a degenerate set.

    Water's two lone pairs are equivalent and its Rydberg orbitals are near-free,
    so the orbital builder is free to return either rotated by anything; a fresh
    SCF reproduces the energy and density to 1e-13 but not those vectors.  If the
    analysis summed per-orbital terms over whatever rotation it was handed, the
    total would move by 0.1 to 0.25 kcal/mol between runs.  It must not.
    """
    totals = []
    for _ in range(3):
        mf, atoms = _water()
        totals.append(e2.compute(mf, atoms)["totalStabilizationKcal"])
    assert max(totals) - min(totals) < 1e-6, totals


def test_dispatch_e2_and_alias():
    params = {"atoms": WATER, "basis": "6-31g", "method": "RHF"}
    direct = engine.dispatch("e2", params)
    alias = engine.dispatch("perturbation", params)
    assert direct["ok"] and alias["ok"]
    assert direct["kind"] == alias["kind"]
    assert direct["donorCount"] == alias["donorCount"]
    assert direct["acceptorCount"] == alias["acceptorCount"]
    assert direct["interactionCount"] == alias["interactionCount"]
    # Each dispatch runs its own SCF, so this compares two independent solves.
    # The two agree because the analysis fixes its own intra-manifold rotation;
    # see test_total_is_reproducible_across_scf_runs.
    assert direct["totalStabilizationKcal"] == alias["totalStabilizationKcal"]
    assert direct["totalStabilizationKcal"] < 0


def test_dispatch_e2_rejects_a_periodic_cell():
    params = {
        "atoms": WATER,
        "basis": "sto-3g",
        "method": "RHF",
        "lattice": [[8.0, 0, 0], [0, 8.0, 0], [0, 0, 8.0]],
        "dimension": 3,
    }
    try:
        engine.dispatch("e2", params)
    except ValueError as exc:
        assert "periodic" in str(exc), exc
    else:
        raise AssertionError("E(2) should be refused for a periodic cell")


def test_capabilities_advertise_e2():
    from pyscf_mobile import bridge

    capabilities = bridge.capabilities()
    methods = capabilities.get("methods", [])
    assert "e2" in methods
    assert "perturbation" in methods
