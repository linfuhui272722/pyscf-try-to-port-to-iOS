"""Periodic (cell) calculations.

Two things are checked here that a molecular test would not catch, and both are
conventions rather than physics:

* a slab is written with a **vacuum vector**, not a row of zeros — a zero row
  makes the lattice singular and PySCF fails while building its real-space grid;
* the periodicity is stated with ``dimension``, because the lattice matrix alone
  cannot express it — the same vacuum vector describes a slab or a crystal.

The energies are checked for the properties that distinguish a real periodic
calculation from a molecular one: the energy of a crystal changes when the
k-point sampling is refined, and a molecule in a box converges to the molecular
answer as the box grows.  The second is the strongest available check, because
it ties the periodic path to a number the molecular path already produces.

Cells here are deliberately small and Γ-only.  A periodic SCF allocates a
real-space grid and is far heavier than the molecular calculations in this
suite; the cheap settings are enough to exercise every code path.

Run with ``python tests/run_tests.py``.
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src"))

import numpy as np  # noqa: E402

from pyscf_mobile import engine, periodic  # noqa: E402

#: A hydrogen molecule inside a box.  Hydrogen needs no pseudopotential, which
#: keeps the cell small enough to build quickly.
H2 = "H 0 0 0; H 0 0 0.74"

#: A silicon crystal at the experimental lattice constant.
SI = "Si 0 0 0; Si 0.25 0.25 0.25"
SI_LATTICE = [[5.43, 0.0, 0.0], [0.0, 5.43, 0.0], [0.0, 0.0, 5.43]]


def _box(size: float) -> list[list[float]]:
    return [[size, 0.0, 0.0], [0.0, size, 0.0], [0.0, 0.0, size]]


# --------------------------------------------------------------------------
# request handling, without running a calculation
# --------------------------------------------------------------------------


def test_no_lattice_is_not_periodic():
    assert periodic.lattice_from_params({"atoms": H2}) is None
    assert periodic.cell_dimensions({"atoms": H2}) is None
    assert not periodic.is_periodic({"atoms": H2})


def test_lattice_is_converted_from_angstrom_to_bohr():
    lattice = periodic.lattice_from_params({"lattice": _box(10.0)})
    assert lattice is not None
    # 10 Å is 18.897 Bohr.
    assert abs(np.linalg.norm(lattice[0]) - 10.0 * periodic.ANGSTROM_TO_BOHR) < 1e-9


def test_lattice_unit_can_be_stated():
    bohr = periodic.lattice_from_params({"lattice": _box(10.0), "latticeUnit": "Bohr"})
    assert abs(np.linalg.norm(bohr[0]) - 10.0) < 1e-12


def test_lattice_dict_form_is_accepted():
    lattice = periodic.lattice_from_params(
        {"lattice": {"a": [4, 0, 0], "b": [0, 4, 0], "c": [0, 0, 4]}}
    )
    assert lattice.shape == (3, 3)


def test_zero_lattice_row_is_refused_with_an_explanation():
    """The natural but wrong way to write a slab, caught with a usable message."""
    try:
        periodic.cell_dimensions({"lattice": [[6, 0, 0], [0, 6, 0], [0, 0, 0]], "dimension": 2})
    except ValueError as exc:
        assert "zero" in str(exc), exc
        assert "vacuum" in str(exc), exc
    else:
        raise AssertionError("a singular lattice should be refused")


def test_rank_deficient_lattice_is_refused():
    try:
        periodic.cell_dimensions({"lattice": [[1, 0, 0], [2, 0, 0], [0, 0, 1]]})
    except ValueError as exc:
        assert "dependent" in str(exc), exc
    else:
        raise AssertionError("a rank-deficient lattice should be refused")


def test_one_dimension_is_refused_with_the_reason():
    """PySCF's cell builder has no uniform grid for dimension=1."""
    try:
        periodic.cell_dimensions({"lattice": _box(10.0), "dimension": 1})
    except ValueError as exc:
        assert "one-dimensional" in str(exc), exc
        assert "dimension=1" in str(exc), exc
    else:
        raise AssertionError("dimension=1 should be refused")


def test_dimension_defaults_to_three_and_says_so():
    lattice = _box(10.0)
    assert periodic.cell_dimensions({"lattice": lattice}) == 3
    assert periodic.dimension_was_stated({"lattice": lattice}) is False
    assert periodic.dimension_was_stated({"lattice": lattice, "dimension": 2}) is True


def test_unsupported_dimension_is_refused():
    try:
        periodic.cell_dimensions({"lattice": _box(10.0), "dimension": 4})
    except ValueError as exc:
        assert "dimension must be" in str(exc), exc
    else:
        raise AssertionError("dimension=4 should be refused")


def test_kmesh_defaults_to_gamma():
    assert periodic.kmesh_from_params({}) == [1, 1, 1]
    assert not periodic.uses_kpoints({})


def test_kmesh_can_be_stated_three_ways():
    assert periodic.kmesh_from_params({"kmesh": [2, 2, 2]}) == [2, 2, 2]
    assert periodic.kmesh_from_params({"kmesh": 3}) == [3, 3, 3]
    assert periodic.kmesh_from_params({"kPoints": [2, 1, 1]}) == [2, 1, 1]
    assert periodic.uses_kpoints({"kmesh": [2, 1, 1]})


def test_bad_kmesh_is_refused():
    for bad in ([2, 2], [0, 1, 1], [-1, 1, 1]):
        try:
            periodic.kmesh_from_params({"kmesh": bad})
        except ValueError:
            pass
        else:
            raise AssertionError(f"kmesh {bad} should be refused")


def test_pseudopotential_is_added_for_heavy_elements_only():
    """Hydrogen and helium have no core to replace; everything else needs one."""
    assert periodic.pseudopotential_for([{"element": "H"}, {"element": "H"}]) is None
    assert periodic.pseudopotential_for([{"element": "He"}]) is None
    assert periodic.pseudopotential_for([{"element": "Si"}]) is not None
    assert periodic.pseudopotential_for([{"element": "O"}, {"element": "H"}]) is not None


def test_pseudopotential_can_be_overridden_and_disabled():
    assert periodic.pseudopotential_for([{"element": "Si"}], "gth-pade") == "gth-pade"
    assert periodic.pseudopotential_for([{"element": "Si"}], "none") is None


def test_lattice_summary_reports_cell_parameters():
    lattice = periodic.lattice_from_params({"lattice": _box(10.0)})
    summary = periodic.lattice_summary(lattice, 3)
    assert abs(summary["a"] - 10.0) < 1e-8
    assert abs(summary["b"] - 10.0) < 1e-8
    assert abs(summary["c"] - 10.0) < 1e-8
    for angle in ("alpha", "beta", "gamma"):
        assert abs(summary[angle] - 90.0) < 1e-6
    assert abs(summary["volume"] - 1000.0) < 1e-6


# --------------------------------------------------------------------------
# running a calculation
# --------------------------------------------------------------------------


def test_gamma_cell_scf_runs_and_reports_the_cell():
    result = engine.dispatch(
        "scf",
        {"atoms": SI, "lattice": SI_LATTICE, "dimension": 3, "method": "RHF"},
    )
    assert result["ok"]
    assert result["converged"]
    assert result["periodic"] is True
    cell = result["cell"]
    assert cell["dimension"] == 3
    assert abs(cell["a"] - 5.43) < 1e-8
    assert cell["dimensionStated"] is True
    assert cell["kmesh"] == [1, 1, 1]
    assert cell["nKpts"] == 1
    # A silicon crystal's valence energy is a few hartree, not the -578 of a free
    # atom pair, because the pseudopotential has removed the core electrons.
    assert -20.0 < result["energy"] < 20.0, result["energy"]


def test_periodic_payload_leaves_out_molecular_analyses():
    """Said rather than left as a silent gap in the payload."""
    result = engine.dispatch(
        "scf", {"atoms": SI, "lattice": SI_LATTICE, "dimension": 3, "method": "RHF"}
    )
    assert "populationUnavailable" in result
    assert result["nLocalizedOrbitals"] is None
    assert result.get("mulliken") is None
    assert result.get("naturalOrbitals") is None


def test_slab_runs_with_a_vacuum_vector():
    """The slab convention: a non-zero vacuum vector and dimension=2."""
    lattice = [[6.0, 0.0, 0.0], [0.0, 6.0, 0.0], [0.0, 0.0, 15.0]]
    result = engine.dispatch(
        "scf",
        {"atoms": H2, "lattice": lattice, "dimension": 2, "method": "RHF",
         "basis": "sto-3g"},
    )
    assert result["ok"]
    assert result["cell"]["dimension"] == 2
    assert abs(result["cell"]["c"] - 15.0) < 1e-8


def test_slab_and_crystal_differ_for_the_same_lattice():
    """The discriminating test for ``dimension``.

    The lattice is identical; only the periodicity differs.  If ``dimension``
    were ignored, the two energies would be equal.  They are not, because in the
    crystal the periodic images along c interact and in the slab they do not.
    """
    lattice = [[6.0, 0.0, 0.0], [0.0, 6.0, 0.0], [0.0, 0.0, 3.0]]
    common = {"atoms": H2, "lattice": lattice, "method": "RHF", "basis": "sto-3g"}
    slab = engine.dispatch("scf", {**common, "dimension": 2})
    crystal = engine.dispatch("scf", {**common, "dimension": 3})
    assert slab["cell"]["dimension"] == 2
    assert crystal["cell"]["dimension"] == 3
    assert abs(slab["energy"] - crystal["energy"]) > 1e-6, (
        "dimension had no effect on the energy, so it is not reaching the cell"
    )


def test_kpoint_sampling_changes_the_crystal_energy():
    """The discriminating test for the k-point path.

    A Γ-only and a sampled calculation of the same crystal must differ; if the
    sampling were dropped the two would agree exactly.  Sampled points are also
    reported, so the count is checked too.
    """
    common = {"atoms": SI, "lattice": SI_LATTICE, "dimension": 3, "method": "RHF"}
    gamma = engine.dispatch("scf", common)
    sampled = engine.dispatch("scf", {**common, "kmesh": [2, 1, 1]})
    assert gamma["cell"]["nKpts"] == 1
    assert sampled["cell"]["nKpts"] == 2
    assert abs(gamma["energy"] - sampled["energy"]) > 1e-6, (
        "the k-point sampling had no effect on the energy"
    )


def test_molecule_in_a_large_box_approaches_the_molecular_energy():
    """The strongest check available: the periodic path against the molecular one.

    A hydrogen molecule in a box large enough that its images do not interact is
    just a hydrogen molecule.  This ties the two code paths to the same number,
    so a systematic error in the periodic setup cannot pass unnoticed.

    The box is 6 Å rather than larger because the real-space grid scales with the
    volume: a 12 Å box costs about 6.8 GB to reach the same 1e-3 agreement a 6 Å
    box reaches in 1.1 GB, and the suite has to run on a phone-sized machine.
    """
    molecular = engine.dispatch("scf", {"atoms": H2, "basis": "sto-3g", "method": "RHF"})
    boxed = engine.dispatch(
        "scf",
        {"atoms": H2, "lattice": _box(6.0), "dimension": 3, "method": "RHF",
         "basis": "sto-3g"},
    )
    assert boxed["periodic"] is True
    difference = abs(molecular["energy"] - boxed["energy"])
    assert difference < 5e-3, (
        f"a molecule in a 6 Å box should reproduce the molecular energy; "
        f"got {boxed['energy']:.6f} against {molecular['energy']:.6f}"
    )


def test_dft_runs_for_a_cell():
    """A periodic DFT run must produce the PBE energy, not the Hartree-Fock one.

    The energy is *positive*, which looks wrong and is not: the Goedecker-
    Teter-Hutter pseudopotentials reference the energy to a free-electron-like
    zero, so a silicon crystal comes out around +4.5 hartree in this convention.
    The discriminating check is therefore against a periodic Hartree-Fock run of
    the same cell, which must differ because the exchange-correlation functional
    is actually applied.
    """
    common = {"atoms": SI, "lattice": SI_LATTICE, "dimension": 3, "method": "RKS",
              "xc": "pbe", "gridLevel": 1}
    result = engine.dispatch("dft", common)
    assert result["ok"]
    assert result["periodic"] is True
    assert np.isfinite(result["energy"])

    hartree_fock = engine.dispatch(
        "scf", {"atoms": SI, "lattice": SI_LATTICE, "dimension": 3, "method": "RHF"}
    )
    assert abs(result["energy"] - hartree_fock["energy"]) > 1e-3, (
        "the PBE energy equals the Hartree-Fock energy, so the functional is not "
        "reaching the calculation"
    )


def test_geometry_optimisation_uses_a_numerical_gradient_for_a_cell():
    """The analytic lattice gradient is wrong, so the optimiser must not use it.

    A hydrogen molecule in a box, placed at the experimental bond length, has no
    force along the bond once it is relaxed, so the run converges immediately;
    what is being checked is the reported provenance of the gradient, which is
    what tells the user how the number was obtained.  A single hydrogen atom
    would not do: one electron cannot form a singlet, so it is refused before the
    optimiser runs.
    """
    result = engine.dispatch(
        "optimise",
        {"atoms": H2, "lattice": _box(8.0), "dimension": 3, "method": "RHF",
         "basis": "sto-3g", "maxSteps": 2},
    )
    assert result["periodic"] is True
    assert result["gradientMethod"].startswith("numerical")
    assert result["cell"]["latticeFixed"] is True


def test_molecular_geometry_optimisation_still_reports_an_analytic_gradient():
    """The periodic branch must not leak into the molecular path."""
    result = engine.dispatch(
        "optimise",
        {"atoms": H2, "basis": "sto-3g", "method": "RHF", "maxSteps": 2},
    )
    assert result["periodic"] is False
    assert result["gradientMethod"] == "analytic"
    assert "cell" not in result
