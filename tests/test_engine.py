"""Tests for the PySCF-mobile compute core.

Run with ``python -m pytest tests -v`` or, without pytest installed,
``python tests/run_tests.py``.
"""

from __future__ import annotations

import json
import math
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src"))

from pyscf_mobile import bridge, engine, geometry  # noqa: E402

HARTREE_TO_KCAL = 627.5094740631


# --------------------------------------------------------------------------
# elements
# --------------------------------------------------------------------------


def test_element_lookup():
    from pyscf_mobile.elements import resolve

    assert resolve("H").z == 1
    assert resolve("h").symbol == "H"
    assert resolve(8).symbol == "O"
    assert resolve("6").symbol == "C"
    try:
        resolve("Xx")
    except KeyError:
        pass
    else:  # pragma: no cover
        raise AssertionError("unknown element should raise")


def test_element_table_is_complete_and_ordered():
    from pyscf_mobile.elements import ELEMENTS

    assert len(ELEMENTS) == 86
    assert [e.z for e in ELEMENTS] == list(range(1, 87))
    assert all(e.color.startswith("#") and len(e.color) == 7 for e in ELEMENTS)
    assert all(e.mass > 0 for e in ELEMENTS)
    assert all(e.covalent_radius > 0 for e in ELEMENTS)


# --------------------------------------------------------------------------
# geometry
# --------------------------------------------------------------------------


def test_parse_atom_spec_forms():
    a = geometry.parse_atom_spec("O 0 0 0; H 0 0 0.96")
    assert [x["element"] for x in a] == ["O", "H"]
    b = geometry.parse_atom_spec("O 0 0 0\nH 0 0 0.96\n\n# comment")
    assert len(b) == 2
    c = geometry.parse_atom_spec("O,0,0,0;H,0,0,0.96")
    assert len(c) == 2


def test_parse_atom_spec_rejects_garbage():
    for bad in ("", "   ", "O 0 0", "Qq 0 0 0"):
        try:
            geometry.parse_atom_spec(bad)
        except ValueError:
            pass
        else:  # pragma: no cover
            raise AssertionError(f"{bad!r} should have raised")


def test_formula_and_mass():
    atoms = geometry.parse_atom_spec(engine._PRESET_ATOMS["ethanol"])
    assert geometry.formula(atoms) == "C2H6O"
    assert abs(geometry.molecular_mass(atoms) - 46.069) < 0.05


def test_water_bonds_and_angle():
    atoms = geometry.parse_atom_spec(engine._PRESET_ATOMS["water"])
    bonds = geometry.bond_lengths(atoms)
    assert len(bonds) == 2
    angles = geometry.bond_angles(atoms)
    assert len(angles) == 1
    assert abs(angles[0]["angle"] - 104.5) < 2.0, angles[0]


def test_methane_is_tetrahedral():
    atoms = geometry.parse_atom_spec(engine._PRESET_ATOMS["methane"])
    angles = [a["angle"] for a in geometry.bond_angles(atoms)]
    assert len(angles) == 6
    assert all(abs(a - 109.471) < 0.01 for a in angles), angles


def test_bond_scan_target_is_not_self_bonded():
    atoms = geometry.parse_atom_spec("H 0 0 0; H 0 0 0.74; O 0 0 3.0")
    pairs = [(i, j) for i, j, _ in geometry.perceive_bonds(atoms)]
    assert (0, 1) in pairs
    assert (1, 2) not in pairs


def test_inertia_of_linear_molecule():
    atoms = geometry.parse_atom_spec("N 0 0 0; N 0 0 1.0977")
    inertia = geometry.moments_of_inertia(atoms)
    moments = inertia["moments"]
    assert moments[0] < 1e-6, moments  # rotation about the molecular axis
    assert abs(moments[1] - moments[2]) < 1e-6


# --------------------------------------------------------------------------
# engine
# --------------------------------------------------------------------------


def _pyscf_ready() -> bool:
    return bool(engine.engine_status()["available"])


def test_engine_status_reports_libraries():
    status = engine.engine_status()
    if not status["available"]:
        print(f"    (PySCF unavailable: {status['error']})")
        return
    assert status["libraries"]["libcgto"] is True
    assert status["libraries"]["libdft"] is True


def test_rhf_water_energy():
    if not _pyscf_ready():
        return
    res = engine.run_scf(
        {"atoms": engine._PRESET_ATOMS["water"], "basis": "sto-3g", "method": "RHF"}
    )
    assert res["ok"] and res["converged"]
    assert abs(res["energy"] - (-74.9627)) < 0.01, res["energy"]
    assert res["nElectrons"] == 10
    assert res["nBasis"] == 7
    assert res["homo"] is not None and res["lumo"] is not None
    assert res["gap"] > 0


def test_hf_dissociation_is_sane():
    if not _pyscf_ready():
        return
    res = engine.run_scf({"atoms": "H 0 0 0; H 0 0 0.7414", "basis": "sto-3g"})
    assert abs(res["energy"] - (-1.116759)) < 1e-4, res["energy"]


def test_dft_b3lyp_water_is_below_hf():
    if not _pyscf_ready():
        return
    hf = engine.run_scf({"atoms": engine._PRESET_ATOMS["water"], "basis": "sto-3g", "method": "RHF"})
    dft_res = engine.run_scf(
        {"atoms": engine._PRESET_ATOMS["water"], "basis": "sto-3g", "method": "RKS", "xc": "b3lyp"}
    )
    assert dft_res["converged"]
    assert dft_res["energy"] < hf["energy"], (dft_res["energy"], hf["energy"])
    # B3LYP/STO-3G water is about -75.31 Ha
    assert abs(dft_res["energy"] - (-75.31)) < 0.05, dft_res["energy"]


def test_dft_pbe_and_functional_label():
    if not _pyscf_ready():
        return
    res = engine.run_scf(
        {"atoms": "H 0 0 0; F 0 0 0.9171", "basis": "sto-3g", "method": "RKS", "xc": "pbe"}
    )
    assert res["method"] == "RKS/sto-3g"
    # PBE/STO-3G hydrogen fluoride is about -98.82 Ha
    assert abs(res["energy"] - (-98.82)) < 0.05, res["energy"]


def test_open_shell_oxygen_uhf():
    if not _pyscf_ready():
        return
    res = engine.run_scf(
        {"atoms": engine._PRESET_ATOMS["oxygen"], "basis": "sto-3g", "method": "UHF", "spin": 2}
    )
    assert res["converged"]
    assert res["nAlpha"] == 9 and res["nBeta"] == 7
    assert abs(res["energy"] - (-147.6)) < 1.0, res["energy"]


def test_mp2_correlation_is_negative():
    if not _pyscf_ready():
        return
    res = engine.run_mp2({"atoms": engine._PRESET_ATOMS["water"], "basis": "sto-3g"})
    assert res["correlationEnergy"] < 0
    assert abs(res["energy"] - (res["scfEnergy"] + res["correlationEnergy"])) < 1e-9


def test_ccsd_water():
    if not _pyscf_ready():
        return
    res = engine.run_ccsd({"atoms": engine._PRESET_ATOMS["water"], "basis": "sto-3g"})
    assert res["correlationEnergy"] < 0
    assert abs(res["energy"] - (-75.0124)) < 0.02, res["energy"]


def test_mulliken_charges_sum_to_total_charge():
    if not _pyscf_ready():
        return
    res = engine.run_scf(
        {"atoms": engine._PRESET_ATOMS["water"], "basis": "sto-3g", "include": []}
    )
    assert res["mulliken"] is not None
    total = sum(e["charge"] for e in res["mulliken"]["perAtom"])
    assert abs(total) < 1e-6, total
    assert res["mulliken"]["perElement"]["O"] < 0


def test_dipole_of_water():
    if not _pyscf_ready():
        return
    res = engine.run_scf({"atoms": engine._PRESET_ATOMS["water"], "basis": "sto-3g"})
    assert res["dipole"] is not None
    # STO-3G water: ~1.7 D along the C2 axis
    assert 1.0 < res["dipole"]["magnitude"] < 2.5, res["dipole"]


def test_orbital_payloads_are_json_serialisable():
    if not _pyscf_ready():
        return
    res = engine.run_scf(
        {
            "atoms": engine._PRESET_ATOMS["water"],
            "basis": "sto-3g",
            "include": ["mo", "overlap", "grid"],
        }
    )
    text = json.dumps(res)
    assert len(text) > 1000
    assert len(res["moCoefficients"]) == res["nBasis"]
    assert len(res["overlap"]) == res["nBasis"]
    assert len(res["grid"]["values"]) == 22 ** 3


def test_bond_scan_finds_minimum_near_experimental_length():
    if not _pyscf_ready():
        return
    res = engine.run_bond_scan(
        {
            "atoms": "H 0 0 0; F 0 0 1.2",
            "basis": "sto-3g",
            "i": 0,
            "j": 1,
            "start": 0.6,
            "stop": 2.2,
            "steps": 17,
        }
    )
    assert res["ok"]
    assert res["minimum"] is not None
    # HF/STO-3G H-F equilibrium bond length is ~0.95 A
    assert 0.85 < res["minimum"]["r"] < 1.10, res["minimum"]


def test_geometry_method():
    res = engine.dispatch("geometry", {"atoms": engine._PRESET_ATOMS["benzene"]})
    assert res["formula"] == "C6H6"
    assert len(res["bonds"]) == 12


def test_charge_is_honoured():
    if not _pyscf_ready():
        return
    neutral = engine.run_scf({"atoms": "He 0 0 0", "basis": "sto-3g"})
    cation = engine.run_scf({"atoms": "He 0 0 0", "basis": "sto-3g", "charge": 1, "spin": 1, "method": "UHF"})
    assert neutral["nElectrons"] == 2
    assert cation["nElectrons"] == 1
    assert cation["energy"] > neutral["energy"]


# --------------------------------------------------------------------------
# bridge / protocol
# --------------------------------------------------------------------------


def test_handle_json_success_envelope():
    reply = json.loads(
        bridge.handle_json(json.dumps({"jsonrpc": "2.0", "id": 7, "method": "elements"}))
    )
    assert reply["id"] == 7
    assert reply["result"]["ok"] is True
    assert len(reply["result"]["elements"]) == 86


def test_handle_json_error_envelope_for_unknown_method():
    reply = json.loads(
        bridge.handle_json(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "nope"}))
    )
    assert reply["error"]["code"] == -32000
    assert "unknown method" in reply["error"]["message"]


def test_handle_json_parse_error():
    reply = json.loads(bridge.handle_json("{not json"))
    assert reply["error"]["code"] == -32700
    assert reply["id"] is None


def test_handle_json_never_raises_on_bad_params():
    reply = json.loads(
        bridge.handle_json(json.dumps({"id": 2, "method": "scf", "params": {"atoms": 42}}))
    )
    assert "error" in reply
    assert reply["id"] == 2


def test_capabilities_payload():
    caps = bridge.capabilities()
    assert caps["protocolVersion"] == bridge.PROTOCOL_VERSION
    assert "scf" in caps["methods"]
    assert "sto-3g" in caps["basisSets"]
    assert "b3lyp" in caps["functionals"]


def test_presets_are_valid_and_parseable():
    for preset in engine.presets():
        atoms = geometry.parse_atom_spec(preset["atoms"])
        assert len(atoms) >= 2
        assert preset["formula"] == geometry.formula(atoms)


def test_presets_have_no_overlapping_atoms():
    for preset in engine.presets():
        atoms = geometry.parse_atom_spec(preset["atoms"])
        coords = geometry.atoms_to_coords(atoms)
        for i in range(len(atoms)):
            for j in range(i + 1, len(atoms)):
                d = float(((coords[i] - coords[j]) ** 2).sum() ** 0.5)
                assert d > 0.4, f"{preset['id']}: atoms {i},{j} overlap (d={d})"


def test_unknown_method_reports_unavailable_or_error():
    reply = json.loads(bridge.handle_json(json.dumps({"id": 3, "method": "scf", "params": {"atoms": "H 0 0 0; H 0 0 0.7"}})))
    if not _pyscf_ready():
        assert reply["error"]["code"] == -32001
    else:
        assert reply["result"]["ok"]


TESTS = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]


def run_all() -> int:
    if not _pyscf_ready():
        print(f"!! PySCF engine unavailable: {engine.engine_status()['error']}")
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
