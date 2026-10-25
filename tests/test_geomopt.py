"""Tests for the Cartesian geometry optimiser.

The optimiser replaces PySCF's ``geomopt`` solvers, which cannot be
cross-compiled for iOS because they depend on the ``berny`` and ``geometric``
packages.  These tests pin the behaviour that matters: the projection that
removes rigid-body drift, convergence on a real PES, and agreement with
PySCF's own optimiser when it is installed.

Run with ``python -m pytest tests -v`` or ``python tests/run_tests.py``.
"""

from __future__ import annotations

import json
import math
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src"))

import numpy as np  # noqa: E402

from pyscf_mobile import engine, geomopt  # noqa: E402


def _water_stretched() -> str:
    """Water with the O-H bonds stretched to 1.30 A and a bent H-O-H."""
    return "O 0 0 0; H 0 0 1.30; H 0 1.10 -0.30"


def _internals(coords):
    """Return (O-H1, O-H2, H-O-H) for a three-atom water geometry."""
    coords = np.asarray(coords, dtype=float)
    distance = lambda i, j: float(np.linalg.norm(coords[i] - coords[j]))
    v1, v2 = coords[1] - coords[0], coords[2] - coords[0]
    angle = math.degrees(
        math.acos(float(v1 @ v2) / (np.linalg.norm(v1) * np.linalg.norm(v2)))
    )
    return distance(0, 1), distance(0, 2), angle


# --------------------------------------------------------------------------
# geomopt: the pure-NumPy core
# --------------------------------------------------------------------------


def test_max_abs_and_rms():
    assert geomopt.max_abs([3.0, -4.0, 1.0]) == 4.0
    assert geomopt.rms([3.0, -4.0]) == math.sqrt(12.5)
    assert geomopt.max_abs([]) == 0.0


def test_rigid_body_basis_has_expected_dimension():
    """A non-linear molecule has 3 translations and 3 rotations."""
    water = np.array([[0.0, 0.0, 0.0], [0.0, 0.0, 1.8], [0.0, 1.7, -0.5]])
    assert geomopt.rigid_body_basis(water).shape == (9, 6)


def test_rigid_body_basis_of_single_atom_is_translation_only():
    assert geomopt.rigid_body_basis(np.zeros((1, 3))).shape == (3, 3)


def test_rigid_body_basis_of_linear_molecule_is_five():
    """A linear molecule has only two independent rotations."""
    linear = np.array([[0.0, 0.0, 0.0], [0.0, 0.0, 1.2], [0.0, 0.0, 2.4]])
    assert geomopt.rigid_body_basis(linear).shape == (9, 5)


def test_projection_removes_translation_from_a_gradient():
    """A constant force on every atom is pure translation and must vanish."""
    coords = np.array([[0.0, 0.0, 0.0], [0.0, 0.0, 1.8], [0.0, 1.7, -0.5]])
    basis = geomopt.rigid_body_basis(coords)
    translation = np.tile(np.array([0.0, 0.0, 0.7]), 3)
    projected = translation - basis @ (basis.T @ translation)
    assert geomopt.max_abs(projected) < 1e-12


def test_minimise_converges_on_a_bond_stretch():
    """The optimiser must drive a bond to its target length.

    The energy depends only on the distance between the two atoms, so the
    minimum is reachable even though the projector removes overall translation
    and rotation.  The centroid must not move.
    """
    target_length = 2.0

    def energy_and_grad(x):
        coords = x.reshape(-1, 3)
        delta = coords[0] - coords[1]
        distance = float(np.linalg.norm(delta))
        energy = (distance - target_length) ** 2
        unit = delta / distance
        gradient = np.zeros_like(coords)
        gradient[0] = 2.0 * (distance - target_length) * unit
        gradient[1] = -gradient[0]
        return energy, gradient.ravel()

    start = np.array([0.0, 0.0, 0.0, 0.0, 0.0, 1.0])
    outcome = geomopt.minimise(start, energy_and_grad, max_steps=60)
    assert outcome["converged"], outcome["message"]
    final = outcome["x"].reshape(-1, 3)
    assert abs(float(np.linalg.norm(final[0] - final[1])) - target_length) < 1e-6
    assert float(np.linalg.norm(final.mean(axis=0) - start.reshape(-1, 3).mean(axis=0))) < 1e-9


def test_minimise_rejects_empty_coordinates():
    try:
        geomopt.minimise([], lambda x: (0.0, np.zeros(0)))
    except ValueError:
        return
    raise AssertionError("empty coordinates should be rejected")


# --------------------------------------------------------------------------
# engine: the optimise endpoint
# --------------------------------------------------------------------------


def test_optimise_water_relaxes_the_bonds():
    """Stretched O-H bonds must contract towards the equilibrium length."""
    result = engine.run_geometry_optimisation(
        {"atoms": _water_stretched(), "method": "RKS", "xc": "b3lyp",
         "basis": "sto-3g", "maxSteps": 30}
    )
    assert result["ok"]
    assert result["converged"], result["message"]
    oh1, oh2, angle = _internals([a["xyz"] for a in result["atoms"]])
    # Equilibrium B3LYP/STO-3G water: O-H about 1.03 A, H-O-H about 97 degrees.
    assert 0.95 < oh1 < 1.10, oh1
    assert 0.95 < oh2 < 1.10, oh2
    assert 90.0 < angle < 105.0, angle


def test_optimise_lowers_the_energy():
    """Relaxation must not raise the energy above the starting structure."""
    stretched = _water_stretched()
    single = engine.run_scf(
        {"atoms": stretched, "method": "RKS", "xc": "b3lyp", "basis": "sto-3g"}
    )
    relaxed = engine.run_geometry_optimisation(
        {"atoms": stretched, "method": "RKS", "xc": "b3lyp",
         "basis": "sto-3g", "maxSteps": 30}
    )
    assert relaxed["energy"] < single["energy"]
    assert relaxed["maxGradient"] < 3e-4


def test_optimise_reports_a_decreasing_trajectory():
    result = engine.run_geometry_optimisation(
        {"atoms": _water_stretched(), "method": "RKS", "xc": "b3lyp",
         "basis": "sto-3g", "maxSteps": 30}
    )
    energies = [point["energy"] for point in result["trajectory"]]
    assert len(energies) >= 2
    assert energies == sorted(energies, reverse=True), energies
    assert result["trajectory"][0]["step"] == 0


def test_optimise_returns_parseable_coordinates():
    """The copy button ships this string, so it must round-trip."""
    from pyscf_mobile import geometry

    result = engine.run_geometry_optimisation(
        {"atoms": _water_stretched(), "method": "RKS", "xc": "b3lyp",
         "basis": "sto-3g", "maxSteps": 30}
    )
    reparsed = geometry.parse_atom_spec(result["optimisedAtoms"])
    assert [a["element"] for a in reparsed] == ["O", "H", "H"]
    # The re-parsed coordinates must match the structured form.
    for atom, expected in zip(reparsed, result["atoms"]):
        assert max(abs(a - b) for a, b in zip(atom["xyz"], expected["xyz"])) < 1e-6


def test_optimise_geometry_block_uses_angstrom():
    """The reported bond length must be in Angstrom, matching the single point."""
    result = engine.run_geometry_optimisation(
        {"atoms": _water_stretched(), "method": "RKS", "xc": "b3lyp",
         "basis": "sto-3g", "maxSteps": 30}
    )
    reported = sorted(b["length"] for b in result["geometry"]["bonds"])
    measured = sorted(_internals([a["xyz"] for a in result["atoms"]])[:2])
    assert max(abs(a - b) for a, b in zip(reported, measured)) < 1e-3


def test_optimise_works_for_every_basis_set():
    """The user asked for all basis sets; the gradient driver must support each."""
    for basis in engine.BASIS_SETS:
        result = engine.run_geometry_optimisation(
            {"atoms": _water_stretched(), "method": "RKS", "xc": "b3lyp",
             "basis": basis, "maxSteps": 40}
        )
        assert result["converged"], f"{basis}: {result['message']}"
        oh1, oh2, _ = _internals([a["xyz"] for a in result["atoms"]])
        # Every basis should relax towards the same physical bond length.
        assert 0.90 < oh1 < 1.15, (basis, oh1)
        assert 0.90 < oh2 < 1.15, (basis, oh2)


def test_optimise_supports_hartree_fock_reference():
    result = engine.run_geometry_optimisation(
        {"atoms": _water_stretched(), "method": "RHF", "basis": "sto-3g",
         "maxSteps": 30}
    )
    assert result["converged"], result["message"]
    assert result["functional"] is None
    oh1, _, _ = _internals([a["xyz"] for a in result["atoms"]])
    assert 0.90 < oh1 < 1.10, oh1


def test_optimise_does_not_drift():
    """Rigid-body projection must leave the molecular centroid exactly fixed.

    Without it the molecule slowly translates along the residual force on each
    atom, which shows up as coordinates that wander even though the energy is
    already converged.
    """
    from pyscf_mobile import geometry

    result = engine.run_geometry_optimisation(
        {"atoms": _water_stretched(), "method": "RKS", "xc": "b3lyp",
         "basis": "sto-3g", "maxSteps": 30}
    )
    start = np.array([a["xyz"] for a in geometry.parse_atom_spec(result["initialAtoms"])])
    end = np.array([a["xyz"] for a in result["atoms"]])
    assert float(np.linalg.norm(end.mean(axis=0) - start.mean(axis=0))) < 1e-6


def test_optimise_matches_pyscf_reference_optimiser():
    """When PySCF's own optimiser is installed, both must reach the same point."""
    try:
        from pyscf import dft, gto
        from pyscf.geomopt.geometric_solver import optimize
    except Exception:
        return  # the dependency is optional; skip when absent

    stretched = _water_stretched()
    reference_mf = dft.RKS(gto.M(atom=stretched, basis="sto-3g", verbose=0))
    reference_mf.xc = "b3lyp"
    # geometric_solver returns a Mole carrying the optimised geometry; its
    # energy is not attached, so a single point on that geometry is the
    # reference the energy comparison uses.
    relaxed = optimize(reference_mf, maxsteps=30)
    reference_coords = np.asarray(relaxed.atom_coords())
    check = dft.RKS(gto.M(
        atom=[("O", reference_coords[0]), ("H", reference_coords[1]),
              ("H", reference_coords[2])],
        basis="sto-3g", unit="Bohr", verbose=0))
    check.xc = "b3lyp"
    check.kernel()
    reference_energy = float(check.e_tot)

    angstrom = 0.52917721092
    reference = reference_coords * angstrom
    result = engine.run_geometry_optimisation(
        {"atoms": stretched, "method": "RKS", "xc": "b3lyp",
         "basis": "sto-3g", "maxSteps": 30}
    )
    mine = np.array([a["xyz"] for a in result["atoms"]])

    # Both must land on the same minimum.  The energy and the bond lengths are
    # stiff coordinates and have to agree tightly; the H-O-H angle is a very
    # flat mode, so it is allowed a looser tolerance.
    assert abs(result["energy"] - reference_energy) < 1e-5, (
        result["energy"], reference_energy)
    for got, expected in zip(_internals(mine)[:2], _internals(reference)[:2]):
        assert abs(got - expected) < 5e-3, (got, expected)
    assert abs(_internals(mine)[2] - _internals(reference)[2]) < 0.2


def test_optimise_is_reachable_through_the_bridge():
    from pyscf_mobile import bridge

    request = {
        "jsonrpc": "2.0", "id": 11, "method": "optimise",
        "params": {"atoms": _water_stretched(), "method": "RKS", "xc": "b3lyp",
                   "basis": "sto-3g", "maxSteps": 30},
    }
    reply = json.loads(bridge.handle_json(json.dumps(request)))
    assert reply["id"] == 11
    assert "error" not in reply, reply.get("error")
    assert reply["result"]["converged"]
    assert reply["result"]["optimisedAtoms"]

    caps = json.loads(bridge.handle_json(json.dumps({"id": 1, "method": "capabilities"})))
    assert "optimise" in caps["result"]["methods"]


TESTS = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]


def run_all() -> int:
    failures = 0
    for fn in TESTS:
        try:
            fn()
            print(f"  ok   {fn.__name__}")
        except Exception as exc:
            failures += 1
            print(f"  FAIL {fn.__name__}: {type(exc).__name__}: {exc}")
    print(f"\n{len(TESTS) - failures}/{len(TESTS)} passed")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(run_all())


def test_relaxation_grid_does_not_change_the_minimum():
    """The cheap relaxation grid must land on the production-grid minimum.

    The XC quadrature dominates a Kohn-Sham relaxation, so the engine relaxes on
    a coarse grid and re-evaluates the final structure on the production grid.
    This asserts that shortcut is free: same energy, same geometry.
    """
    params = {"atoms": _water_stretched(), "method": "RKS", "xc": "b3lyp",
              "basis": "sto-3g", "maxSteps": 30}
    cheap = engine.run_geometry_optimisation(params)
    full = engine.run_geometry_optimisation({**params, "relaxGridLevel": 3,
                                             "gridLevel": 3})
    assert cheap["converged"] and full["converged"]
    assert abs(cheap["energy"] - full["energy"]) < 1e-6, (
        cheap["energy"], full["energy"])
    cheap_xyz = np.array([a["xyz"] for a in cheap["atoms"]])
    full_xyz = np.array([a["xyz"] for a in full["atoms"]])
    assert float(np.abs(cheap_xyz - full_xyz).max()) < 1e-3


def test_relaxation_grid_is_reported_and_bounded():
    """The payload names both grids so the UI can say which one it used."""
    result = engine.run_geometry_optimisation(
        {"atoms": _water_stretched(), "method": "RKS", "xc": "b3lyp",
         "basis": "sto-3g", "maxSteps": 30}
    )
    assert result["gridLevel"] is not None
    assert result["relaxGridLevel"] is not None
    assert result["relaxGridLevel"] <= result["gridLevel"]

    # Hartree-Fock has no quadrature, so neither grid is reported.
    hf = engine.run_geometry_optimisation(
        {"atoms": _water_stretched(), "method": "RHF", "basis": "sto-3g",
         "maxSteps": 30}
    )
    assert hf["gridLevel"] is None
    assert hf["relaxGridLevel"] is None


def test_reported_energy_uses_the_production_grid():
    """The energy the user sees must not be the coarse one.

    Relaxing on a coarse grid changes the energy by several kcal/mol, so a
    payload that reported the cheap number would be visibly wrong.  Comparing
    against an explicit production-grid single point catches that.
    """
    from pyscf import dft, gto

    result = engine.run_geometry_optimisation(
        {"atoms": _water_stretched(), "method": "RKS", "xc": "b3lyp",
         "basis": "sto-3g", "maxSteps": 30}
    )
    coords = np.array([a["xyz"] for a in result["atoms"]])
    check = dft.RKS(gto.M(
        atom=[("O", coords[0]), ("H", coords[1]), ("H", coords[2])],
        basis="sto-3g", verbose=0))
    check.xc = "b3lyp"
    check.kernel()
    assert abs(result["energy"] - float(check.e_tot)) < 1e-7, (
        result["energy"], float(check.e_tot))
