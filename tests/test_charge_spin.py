"""Charge and spin actually reach the calculation.

These two settings are easy to lose on the way from the UI to the engine: they
are read from separate steppers, they are not part of the molecule, and a
method that ignores them still returns a plausible energy.  The tests below
assert on observables that can only be right if the settings were applied -- the
electron count, the alpha/beta split, and the Mulliken total -- rather than on
the request payload, which a wrong implementation can still build correctly.
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src"))

from pyscf_mobile import engine  # noqa: E402

WATER = "O 0 0 0; H 0 -0.757 0.587; H 0 0.757 0.587"
OXYGEN = "O 0 0 0; O 0 0 1.2075"


def _electron_count(atoms: str, charge: int) -> int:
    from pyscf_mobile.elements import resolve

    return sum(resolve(part.split()[0]).z for part in atoms.split(";")) - charge


def _expect_value_error(call, *fragments):
    """Assert ``call`` raises ValueError mentioning every fragment."""
    try:
        call()
    except ValueError as exc:
        message = str(exc)
        for fragment in fragments:
            assert fragment in message, f"{fragment!r} missing from: {message}"
        return message
    raise AssertionError("expected ValueError")


def test_charge_changes_the_electron_count_and_the_energy():
    neutral = engine.run_scf({"atoms": WATER, "basis": "sto-3g", "method": "RHF", "charge": 0})
    dication = engine.run_scf({"atoms": WATER, "basis": "sto-3g", "method": "RHF", "charge": 2})
    assert neutral["nElectrons"] == 10
    assert dication["nElectrons"] == 8
    assert dication["energy"] > neutral["energy"]


def test_charge_reaches_the_mulliken_totals():
    # The Mulliken charges must add up to the molecular charge. This is the
    # observable that catches a charge the engine accepted but did not use.
    for charge in (-1, 0, 1, 2):
        spin = 1 if (10 - charge) % 2 else 0
        result = engine.run_scf({
            "atoms": WATER, "basis": "sto-3g", "charge": charge, "spin": spin,
            "method": "ROHF" if spin else "RHF",
        })
        total = sum(entry["charge"] for entry in result["mulliken"]["perAtom"])
        assert abs(total - charge) < 1e-6, (charge, total)


def test_spin_splits_the_alpha_and_beta_electrons():
    for spin in (0, 2, 4):
        result = engine.run_scf({
            "atoms": OXYGEN, "basis": "sto-3g", "method": "UHF", "spin": spin,
        })
        assert result["nAlpha"] - result["nBeta"] == spin, spin
        assert result["nAlpha"] + result["nBeta"] == 16, spin


def test_charge_and_spin_reach_the_post_hartree_fock_references():
    # MP2 and CCSD run on top of an SCF reference. If the reference is built
    # without the charge and spin, the electron count comes back as the neutral
    # one and the energy belongs to a different molecule.
    for run in (engine.run_mp2, engine.run_ccsd):
        neutral = run({"atoms": WATER, "basis": "sto-3g", "reference": "RHF"})
        cation = run({
            "atoms": WATER, "basis": "sto-3g", "reference": "ROHF",
            "charge": 1, "spin": 1,
        })
        assert neutral["nElectrons"] == 10, run.__name__
        assert cation["nElectrons"] == 9, run.__name__
        assert cation["energy"] != neutral["energy"], run.__name__


def test_charge_reaches_the_optimiser():
    # The optimiser builds its own molecule from the same parameters, so the
    # charge has to survive that path too. A dication cannot relax to the same
    # geometry as the neutral molecule.
    neutral = engine.run_geometry_optimisation({
        "atoms": WATER, "basis": "sto-3g", "method": "RHF", "charge": 0, "maxSteps": 3,
    })
    dication = engine.run_geometry_optimisation({
        "atoms": WATER, "basis": "sto-3g", "method": "RHF", "charge": 2, "maxSteps": 3,
    })
    assert dication["energy"] != neutral["energy"]


def test_charge_reaches_the_bond_scan():
    scan = engine.run_bond_scan({
        "atoms": "H 0 0 0; H 0 0 0.74", "i": 0, "j": 1, "steps": 3,
        "charge": 1, "spin": 1, "method": "ROHF",
    })
    # H2+ has one electron, so every point must converge; if the charge were
    # dropped the scan would run the neutral two-electron molecule instead.
    assert all(point["energy"] is not None for point in scan["points"])


def test_impossible_charge_spin_pairs_are_rejected_with_both_numbers():
    for charge, spin in [(1, 0), (0, 1), (0, 3), (2, 1), (-1, 0)]:
        electrons = _electron_count(WATER, charge)
        # The message has to name the electron count and the spin, because the
        # two live in separate controls and the user needs to know which one to
        # move.
        _expect_value_error(
            lambda c=charge, s=spin: engine.run_scf(
                {"atoms": WATER, "basis": "sto-3g", "charge": c, "spin": s}
            ),
            str(electrons),
            f"2S = {spin}",
        )


def test_charge_beyond_the_electrons_is_rejected():
    _expect_value_error(
        lambda: engine.run_scf({"atoms": "H 0 0 0; H 0 0 0.74", "basis": "sto-3g", "charge": 3}),
        "more electrons",
    )


def test_valid_open_shell_combinations_still_run():
    for atoms, charge, spin, method in [
        (WATER, 1, 1, "ROHF"),
        (WATER, -1, 1, "ROHF"),
        (WATER, 2, 0, "RHF"),
        (OXYGEN, 0, 2, "UHF"),
    ]:
        result = engine.run_scf({
            "atoms": atoms, "basis": "sto-3g", "charge": charge, "spin": spin, "method": method,
        })
        assert result["converged"], (charge, spin)


def test_unrestricted_driver_is_what_makes_a_spin_polarised_dft_run():
    # A restricted Kohn-Sham driver has no spin to polarise, so a nonzero spin
    # has to be sent to the unrestricted one. The two agree only by accident.
    restricted = engine.run_scf({
        "atoms": OXYGEN, "basis": "sto-3g", "method": "RKS", "xc": "b3lyp", "spin": 2,
    })
    unrestricted = engine.run_scf({
        "atoms": OXYGEN, "basis": "sto-3g", "method": "UKS", "xc": "b3lyp", "spin": 2,
    })
    assert unrestricted["nAlpha"] - unrestricted["nBeta"] == 2
    assert unrestricted["energy"] != restricted["energy"]


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
