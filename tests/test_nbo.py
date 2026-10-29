"""Natural orbital analysis, checked against the JANPA reference program.

The charges and bond orders asserted here are not what this port happens to
print: every number was produced by running JANPA 2.02 itself on the same
wavefunction and reading its output.  The Java sources were compiled with
``javac`` and driven with ``java -cp <classes> onpa.Main -i <molden>
-npacharges <file> -WibergBondOrders_File <file>``, with the MOLDEN input
written by PySCF.  Asserting the reference program's own output is the only
way to tell a faithful port from a plausible-looking one, because both NPA and
the Wiberg indices are basis-set stable: a wrong transform still produces
charges of the right size.

Run with ``python tests/run_tests.py``.
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src"))

from pyscf import gto, scf  # noqa: E402

from pyscf_mobile import natural_orbitals  # noqa: E402

WATER = "O 0 0 0; H 0 -0.757 0.587; H 0 0.757 0.587"
METHANE = (
    "C 0 0 0; H 0.629 0.629 0.629; H -0.629 -0.629 0.629; "
    "H -0.629 0.629 -0.629; H 0.629 -0.629 -0.629"
)
AMMONIA = "N 0 0 0; H 0 -0.9377 0.3816; H 0.8123 0.4689 0.3816; H -0.8123 0.4689 0.3816"


def _analyse(spec, basis, spin=0, charge=0):
    mol = gto.M(atom=spec, basis=basis, spin=spin, charge=charge, verbose=0)
    mf = scf.RHF(mol) if mol.spin == 0 else scf.ROHF(mol)
    mf.kernel()
    atoms = [
        {"element": mol.atom_symbol(i), "z": mol.atom_charge(i), "xyz": list(mol.atom_coords()[i])}
        for i in range(mol.natm)
    ]
    return mf, natural_orbitals.natural_orbitals(mf, atoms)


def _charges(result, element):
    return [a["charge"] for a in result["perAtom"] if a["element"] == element]


# --------------------------------------------------------------------------
# charges
# --------------------------------------------------------------------------


def test_water_npa_charges():
    """Water in 6-31G: JANPA gives O -0.9515202488, H +0.4757601244."""
    _mf, result = _analyse(WATER, "6-31g")
    assert result is not None
    assert abs(result["perAtom"][0]["charge"] - (-0.9515202488)) < 1e-6, result["perAtom"][0]["charge"]
    for charge in _charges(result, "H"):
        assert abs(charge - 0.4757601244) < 1e-6, charge


def test_water_npa_is_basis_stable():
    """The point of NPA: the charge barely moves across four different bases.

    Mulliken on the same bases spans far more than this, which is the
    behaviour NPA exists to avoid.  Asserting both keeps the test from passing
    on a wrong value that merely happens to be flat.  The expected numbers are
    JANPA's, basis set by basis set.
    """
    oxygen, mulliken = [], []
    for basis, expected in (
        ("6-31g", -0.9515202488),
        ("6-31g*", -0.9561246950),
        ("cc-pvdz", -0.9136076944),
        ("6-311g", -0.8777747398),
    ):
        mf, result = _analyse(WATER, basis)
        oxygen.append(result["perAtom"][0]["charge"])
        _pop, charges = mf.mulliken_pop(verbose=0)
        mulliken.append(float(charges[0]))
        assert abs(oxygen[-1] - expected) < 1e-6, (basis, oxygen[-1], expected)

    assert max(oxygen) - min(oxygen) < 0.09, oxygen
    assert max(mulliken) - min(mulliken) > 0.3, mulliken


def test_methane_and_ammonia_npa_charges():
    _mf, methane = _analyse(METHANE, "6-31g")
    assert abs(methane["perAtom"][0]["charge"] - (-0.9246902942)) < 1e-6
    for charge in _charges(methane, "H"):
        assert abs(charge - 0.2311725736) < 1e-6, charge

    _mf, ammonia = _analyse(AMMONIA, "6-31g")
    assert abs(ammonia["perAtom"][0]["charge"] - (-1.1311835789)) < 1e-6
    # The three hydrogens are not equivalent by symmetry, so each keeps its own
    # reference value rather than a shared one.
    assert abs(ammonia["perAtom"][1]["charge"] - 0.3770428917) < 1e-6
    assert abs(ammonia["perAtom"][2]["charge"] - 0.3770703436) < 1e-6
    assert abs(ammonia["perAtom"][3]["charge"] - 0.3770703436) < 1e-6


def test_total_charge_is_recovered():
    """A cation's charges must still sum to the molecular charge."""
    _mf, result = _analyse(AMMONIA + "; H 0 0 -1.0", "6-31g", charge=1)
    total = sum(a["charge"] for a in result["perAtom"])
    assert abs(total - 1.0) < 1e-4, total
    # JANPA's own ammonium charge on nitrogen.
    assert abs(result["perAtom"][0]["charge"] - (-0.9926729940)) < 1e-6


def test_per_element_totals_match_per_atom():
    _mf, _result = _analyse(WATER, "6-31g")
    per_element = natural_orbitals.natural_population_analysis(_mf, [])
    assert abs(per_element["perElement"]["O"] - (-0.9515202488)) < 1e-5
    assert abs(per_element["perElement"]["H"] - 2 * 0.4757601244) < 1e-5


# --------------------------------------------------------------------------
# occupancies and angular breakdown
# --------------------------------------------------------------------------


def test_occupations_sum_to_electron_count():
    """The NAO occupations are a partition of the density, so they sum to N.

    This is the self-check that catches a wrong density or a wrong transform:
    neither can leave the sum intact.
    """
    for spec, basis in ((WATER, "6-31g"), (METHANE, "cc-pvdz"), (AMMONIA, "6-31g*")):
        _mf, result = _analyse(spec, basis)
        assert result["sumRuleOk"] is True, (spec, basis)
        assert abs(result["totalPopulation"] - result["nElectrons"]) < 1e-6


def test_naos_come_out_orthonormal():
    """The final NAO overlap must be the unit matrix to machine precision.

    JANPA prints ``SQRT{SUM[(NaoOverlap_ij - delta_ij)^2]} = 9.59e-15`` for
    water; anything much larger means a step of the construction is wrong.
    """
    for spec, basis in ((WATER, "6-31g"), (WATER, "cc-pvdz"), (AMMONIA, "6-31g*")):
        _mf, result = _analyse(spec, basis)
        assert result["orthogonalityError"] < 1e-10, (spec, basis, result["orthogonalityError"])


def test_nmb_nrb_split_matches_the_reference():
    """Water in 6-31G splits into 7 NMB and 6 NRB functions.

    The split is driven by JANPA's ground-state configuration table, so it is
    worth pinning: a wrong table would still give orthogonal orbitals and
    sensible-looking occupancies.
    """
    _mf, result = _analyse(WATER, "6-31g")
    assert result["nmbFunctions"] == 7, result["nmbFunctions"]
    assert result["nrbFunctions"] == 6, result["nrbFunctions"]
    # JANPA's oxygen occupancies, in its own order.
    assert abs(result["orbitals"][2]["occupancy"] - 1.9998766) < 1e-5
    assert abs(result["orbitals"][6]["occupancy"] - 1.9995334) < 1e-5


def test_angular_populations():
    """Oxygen's population splits into 3.7648 in s and 5.1867 in p."""
    _mf, result = _analyse(WATER, "6-31g")
    oxygen = result["angularPopulations"][0]
    assert abs(oxygen["s"] - 3.7648437) < 1e-5, oxygen
    assert abs(oxygen["p"] - 5.1866766) < 1e-5, oxygen
    assert abs(sum(oxygen.values()) - result["perAtom"][0]["population"]) < 1e-6


# --------------------------------------------------------------------------
# Wiberg bond orders
# --------------------------------------------------------------------------


def test_wiberg_water():
    """Water: O-H bond orders 0.77427, O valence 1.54855, H-H 0.00084."""
    mf, _result = _analyse(WATER, "6-31g")
    wiberg = natural_orbitals.wiberg_bond_orders(mf, [])
    assert abs(wiberg["matrix"][0][0] - 1.54855) < 1e-5, wiberg["matrix"]
    assert abs(wiberg["matrix"][0][1] - 0.77427) < 1e-5, wiberg["matrix"]
    assert abs(wiberg["matrix"][1][2] - 0.00084) < 1e-5, wiberg["matrix"]


def test_wiberg_methane_and_ammonia():
    mf, _ = _analyse(METHANE, "6-31g")
    wiberg = natural_orbitals.wiberg_bond_orders(mf, [])
    assert abs(wiberg["matrix"][0][0] - 3.78168) < 1e-5, wiberg["matrix"]
    assert abs(wiberg["matrix"][0][1] - 0.94542) < 1e-5, wiberg["matrix"]
    assert abs(wiberg["matrix"][1][1] - 0.94744) < 1e-5, wiberg["matrix"]

    mf, _ = _analyse(AMMONIA, "6-31g")
    wiberg = natural_orbitals.wiberg_bond_orders(mf, [])
    # Every N-H bond order, from the reference run.
    assert abs(wiberg["matrix"][0][0] - 2.57409) < 1e-5, wiberg["matrix"]
    assert abs(wiberg["matrix"][0][1] - 0.85804) < 1e-5, wiberg["matrix"]
    assert abs(wiberg["matrix"][0][2] - 0.85802) < 1e-5, wiberg["matrix"]


def test_wiberg_diagonal_is_the_valence():
    """The diagonal is the sum of the row's bond orders, not the self term."""
    mf, _ = _analyse(WATER, "6-31g")
    wiberg = natural_orbitals.wiberg_bond_orders(mf, [])
    row = sum(wiberg["matrix"][0][b] for b in range(1, 3))
    # The matrix is reported to five decimals, so the two roundings may differ
    # by up to that much.
    assert abs(wiberg["matrix"][0][0] - row) < 2e-5


# --------------------------------------------------------------------------
# open shells and failure modes
# --------------------------------------------------------------------------


def test_open_shell_oh_radical():
    """An unrestricted density is a spin-summed pair of matrices; NAO needs both."""
    _mf, result = _analyse("O 0 0 0; H 0 -0.757 0.587", "6-31g", spin=1)
    assert result is not None
    assert result["sumRuleOk"] is True
    assert result["nElectrons"] == 9
    assert result["perAtom"][0]["charge"] < 0


def test_analysis_reports_none_rather_than_raising():
    """A caller must be able to leave the field out instead of failing."""

    class Broken:
        mol = None

    assert natural_orbitals.natural_population_analysis(Broken(), [{"element": "H"}]) is None
    assert natural_orbitals.natural_orbitals(Broken(), [{"element": "H"}]) is None
    assert natural_orbitals.wiberg_bond_orders(Broken(), [{"element": "H"}]) is None


def test_analyze_returns_all_three_views():
    """One call yields the charges, the orbital detail and the bond orders."""
    mf, _ = _analyse(WATER, "6-31g")
    analysis = natural_orbitals.analyze(mf, [])
    assert analysis["npa"] is not None
    assert analysis["naturalOrbitals"] is not None
    assert analysis["wiberg"] is not None
    assert "orbitals" in analysis["naturalOrbitals"]
    assert "matrix" in analysis["wiberg"]
    # The compact NPA view is the projection of the full one.
    assert (
        analysis["npa"]["perAtom"][0]["charge"]
        == analysis["naturalOrbitals"]["perAtom"][0]["charge"]
    )


# --------------------------------------------------------------------------
# engine and bridge wiring
# --------------------------------------------------------------------------


def test_engine_exposes_npa_alongside_the_other_populations():
    """The SCF payload carries NPA next to Mulliken and Mayer."""
    from pyscf_mobile import engine

    result = engine.run_scf(
        {
            "atoms": [
                {"element": "O", "xyz": [0.0, 0.0, 0.0]},
                {"element": "H", "xyz": [0.0, -0.757, 0.587]},
                {"element": "H", "xyz": [0.0, 0.757, 0.587]},
            ],
            "basis": "6-31g",
            "method": "RHF",
        }
    )
    assert result["npa"]["sumRuleOk"] is True
    assert abs(result["npa"]["perAtom"][0]["charge"] - (-0.9515202488)) < 1e-6
    assert result["naturalOrbitals"]["nmbFunctions"] == 7
    assert abs(result["wiberg"]["matrix"][0][0] - 1.54855) < 1e-5
    # Mulliken is present too, and disagrees, which is the reason both are shown.
    assert result["mulliken"] is not None
    assert result["npa"]["perAtom"][0]["charge"] != result["mulliken"]["perAtom"][0]["charge"]


def test_nbo_method_is_reachable_over_the_bridge():
    """The standalone ``nbo`` RPC method returns the same numbers."""
    import json

    from pyscf_mobile import bridge

    request = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "nbo",
        "params": {
            "atoms": [
                {"element": "O", "xyz": [0.0, 0.0, 0.0]},
                {"element": "H", "xyz": [0.0, -0.757, 0.587]},
                {"element": "H", "xyz": [0.0, 0.757, 0.587]},
            ],
            "basis": "6-31g",
            "method": "RHF",
        },
    }
    response = json.loads(bridge.handle_json(json.dumps(request)))
    assert "error" not in response, response
    result = response["result"]
    assert result["npa"]["analysisMethod"] == "NAO/NPA (JANPA 2.02 port)"
    assert result["method"] == "RHF/6-31g"
    assert result["npa"]["sumRuleOk"] is True
    assert abs(result["npa"]["perAtom"][0]["charge"] - (-0.9515202488)) < 1e-6
    assert result["wiberg"]["matrix"][0][1] == 0.77427


def test_wiberg_method_is_reachable_over_the_bridge():
    """The standalone ``wiberg`` RPC method returns the bond-order matrix."""
    import json

    from pyscf_mobile import bridge

    request = {
        "jsonrpc": "2.0",
        "id": 2,
        "method": "wiberg",
        "params": {
            "atoms": [
                {"element": "O", "xyz": [0.0, 0.0, 0.0]},
                {"element": "H", "xyz": [0.0, -0.757, 0.587]},
                {"element": "H", "xyz": [0.0, 0.757, 0.587]},
            ],
            "basis": "6-31g",
            "method": "RHF",
        },
    }
    response = json.loads(bridge.handle_json(json.dumps(request)))
    assert "error" not in response, response
    result = response["result"]
    assert result["analysisMethod"] == "Wiberg-Mayer (NAO basis)"
    assert abs(result["matrix"][0][0] - 1.54855) < 1e-5
    assert abs(result["valences"][0] - 1.54855) < 1e-5
