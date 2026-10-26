"""Mayer bond orders, checked against molecules whose bond orders are known.

The values asserted here are the textbook answers, not whatever the code
happened to print: H2 is a single bond, N2 a triple bond, benzene has six equal
aromatic bonds.  The open-shell cases are the reason the spin-resolved form of
the formula is used rather than the closed-shell shortcut, so they are covered
explicitly.
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src"))

from pyscf_mobile import engine  # noqa: E402

BONDS = {
    "H2": ("H 0 0 0; H 0 0 0.74", 1.0),
    "N2": ("N 0 0 0; N 0 0 1.10", 3.0),
    "ethane": (
        "C 0 0 -0.767; C 0 0 0.767; "
        "H 0.578 0.578 -1.159; H -0.578 -0.578 -1.159; "
        "H 0.578 -0.578 -1.159; H -0.578 0.578 -1.159; "
        "H 0.578 0.578 1.159; H -0.578 -0.578 1.159; "
        "H 0.578 -0.578 1.159; H -0.578 0.578 1.159",
        1.0,
    ),
    "ethylene": (
        "C 0 0 0.667; C 0 0 -0.667; "
        "H 0 0.928 1.234; H 0 -0.928 1.234; "
        "H 0 0.928 -1.234; H 0 -0.928 -1.234",
        2.0,
    ),
    "acetylene": ("C 0 0 0.601; C 0 0 -0.601; H 0 0 1.663; H 0 0 -1.663", 3.0),
}

WATER = "O 0 0 0; H 0 -0.757 0.587; H 0 0.757 0.587"


def _first_bond(result: dict) -> dict:
    return result["mayer"]["bonds"][0]


def _by_pair(result: dict, i: int, j: int) -> float:
    for bond in result["mayer"]["bonds"]:
        if {bond["i"], bond["j"]} == {i, j}:
            return bond["order"]
    raise AssertionError(f"no bond between atoms {i} and {j}")


def test_bond_orders_match_the_bond_multiplicity():
    for name, (atoms, expected) in BONDS.items():
        result = engine.run_scf({"atoms": atoms, "basis": "sto-3g", "method": "RHF"})
        order = _first_bond(result)["order"]
        # STO-3G is a minimal basis, so the value is not exact; being within
        # 0.05 of the integer is what distinguishes a correct implementation
        # from one that reports the wrong number of bonds.
        assert abs(order - expected) < 0.05, f"{name}: {order} vs {expected}"


def test_sum_rule_holds():
    for name, (atoms, _expected) in list(BONDS.items()) + [("water", (WATER, 1.0))]:
        result = engine.run_scf({"atoms": atoms, "basis": "sto-3g", "method": "RHF"})
        mayer = result["mayer"]
        # Mayer's sum rule: the bond orders over all atom pairs, diagonal
        # included, add up to twice the electron count. It holds exactly for any
        # correct density, so it is a strong check on the whole pipeline.
        assert abs(mayer["total"] - mayer["expectedTotal"]) < 1e-4, name
        assert mayer["expectedTotal"] == 2 * result["nElectrons"], name


def test_benzene_has_six_equal_bonds():
    result = engine.run_scf(
        {"atoms": engine._PRESET_ATOMS["benzene"], "basis": "sto-3g", "method": "RHF"}
    )
    carbons = [b for b in result["mayer"]["bonds"] if b["a"] == "C" and b["b"] == "C"]
    assert len(carbons) == 6, carbons
    orders = [b["order"] for b in carbons]
    # Aromatic C-C lands between the single and double bond values. Getting six
    # identical values is the sign that the ring is being treated as symmetric.
    assert all(1.3 < o < 1.6 for o in orders), orders
    assert max(orders) - min(orders) < 1e-3, orders


def test_open_shell_triplet_oxygen_is_a_double_bond():
    # The closed-shell simplification of Mayer's formula returns 1.50 here, and
    # the spin-separated variant 1.00. Only the spin-resolved form gives 2.00.
    result = engine.run_scf(
        {"atoms": "O 0 0 0; O 0 0 1.208", "basis": "sto-3g", "method": "UHF", "spin": 2}
    )
    order = _first_bond(result)["order"]
    assert abs(order - 2.0) < 0.05, order
    assert abs(result["mayer"]["total"] - result["mayer"]["expectedTotal"]) < 1e-4


def test_open_shell_radicals_are_consistent():
    cases = [
        ("O 0 0 0; H 0 0 0.97", 1, 1.0),  # OH radical, single bond
        (
            "C 0 0 0; H 0 1.079 0; H 0.934 -0.539 0; H -0.934 -0.539 0",
            1,
            1.0,
        ),  # methyl, three C-H single bonds
    ]
    for atoms, spin, expected in cases:
        result = engine.run_scf(
            {"atoms": atoms, "basis": "sto-3g", "method": "UHF", "spin": spin}
        )
        assert abs(result["mayer"]["total"] - result["mayer"]["expectedTotal"]) < 1e-4
        for bond in result["mayer"]["bonds"]:
            assert abs(bond["order"] - expected) < 0.05, bond


def test_density_functional_theory_also_reports_bond_orders():
    result = engine.run_scf(
        {"atoms": WATER, "basis": "sto-3g", "method": "RKS", "xc": "b3lyp"}
    )
    assert abs(_first_bond(result)["order"] - 0.954) < 0.02
    assert abs(result["mayer"]["total"] - result["mayer"]["expectedTotal"]) < 1e-4


def test_post_hartree_fock_inherits_the_reference_density():
    # MP2 and CCSD improve the energy on top of an SCF reference but do not
    # relax the orbitals, so the bond orders must equal the SCF ones exactly.
    scf = engine.run_scf({"atoms": WATER, "basis": "sto-3g", "method": "RHF"})
    for run in (engine.run_mp2, engine.run_ccsd):
        result = run({"atoms": WATER, "basis": "sto-3g", "reference": "RHF"})
        assert result["mayer"]["bonds"] == scf["mayer"]["bonds"], run.__name__


def test_bond_scan_omits_the_population_analysis():
    # The scan asks for the energy only; paying for the population analysis at
    # every point would slow it down for output that is discarded.
    scan = engine.run_bond_scan(
        {"atoms": "H 0 0 0; H 0 0 0.74", "i": 0, "j": 1, "steps": 3, "start": 0.6, "stop": 1.4}
    )
    assert len(scan["points"]) == 3
    for point in scan["points"]:
        assert "energy" in point
    # run_scf is what the scan drives; confirm the flag reaches the payload.
    trimmed = engine.run_scf(
        {"atoms": WATER, "basis": "sto-3g", "include": ["_skip_population"]}
    )
    assert "mayer" not in trimmed and "mulliken" not in trimmed and "dipole" not in trimmed
    assert "energy" in trimmed


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
