"""Natural population analysis, checked against published NPA values.

The charges asserted here are the standard NPA results for these molecules, not
whatever the code happens to print.  They are a usable oracle precisely because
NPA is basis-set stable: a mistake in the NAO transform or in the density
contraction shows up as a charge that is wrong by tenths, where Mulliken's own
values move by that much between bases for reasons that have nothing to do with
a bug.  The water test asserts both, so the contrast is part of the test.

Run with ``python tests/run_tests.py``.
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src"))

from pyscf import gto, scf  # noqa: E402

from pyscf_mobile import nbo  # noqa: E402

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
    return mf, nbo.natural_population_analysis(mf, atoms)


def _charges(result, element):
    return [a["charge"] for a in result["perAtom"] if a["element"] == element]


# --------------------------------------------------------------------------
# charges
# --------------------------------------------------------------------------


def test_water_npa_charges():
    """Water in 6-31G: NPA gives O -0.95, H +0.48."""
    _mf, result = _analyse(WATER, "6-31g")
    assert result is not None
    assert abs(result["perAtom"][0]["charge"] - (-0.9539)) < 2e-3, result["perAtom"][0]["charge"]
    for charge in _charges(result, "H"):
        assert abs(charge - 0.4770) < 2e-3, charge


def test_water_npa_is_basis_stable():
    """The point of NPA: the charge barely moves across three different bases.

    Mulliken on the same three bases spans more than half an electron, which is
    the behaviour NPA exists to avoid.  Asserting both keeps the test from
    passing on a wrong value that merely happens to be flat.
    """
    oxygen, mulliken = [], []
    for basis in ("6-31g", "6-31g*", "cc-pvdz"):
        mf, result = _analyse(WATER, basis)
        oxygen.append(result["perAtom"][0]["charge"])
        _pop, charges = mf.mulliken_pop(verbose=0)
        mulliken.append(float(charges[0]))

    for value, expected in zip(oxygen, (-0.9539, -0.9599, -0.9176)):
        assert abs(value - expected) < 3e-3, (value, expected)
    assert max(oxygen) - min(oxygen) < 0.05, oxygen
    assert max(mulliken) - min(mulliken) > 0.3, mulliken


def test_methane_and_ammonia_npa_charges():
    _mf, methane = _analyse(METHANE, "6-31g")
    assert abs(methane["perAtom"][0]["charge"] - (-0.9211)) < 3e-3
    for charge in _charges(methane, "H"):
        assert abs(charge - 0.2303) < 3e-3, charge

    _mf, ammonia = _analyse(AMMONIA, "6-31g")
    assert abs(ammonia["perAtom"][0]["charge"] - (-1.1340)) < 3e-3
    for charge in _charges(ammonia, "H"):
        assert abs(charge - 0.3780) < 3e-3, charge


def test_total_charge_is_recovered():
    """A cation's charges must still sum to the molecular charge."""
    _mf, result = _analyse(
        "N 0 0 0; H 0 -0.9377 0.3816; H 0.8123 0.4689 0.3816; "
        "H -0.8123 0.4689 0.3816; H 0 0 -1.0",
        "6-31g",
        charge=1,
    )
    total = sum(a["charge"] for a in result["perAtom"])
    assert abs(total - 1.0) < 1e-4, total


def test_per_element_totals_match_per_atom():
    _mf, result = _analyse(WATER, "6-31g")
    assert abs(result["perElement"]["O"] - (-0.9539)) < 2e-3
    assert abs(result["perElement"]["H"] - 2 * 0.4770) < 3e-3


# --------------------------------------------------------------------------
# occupancies and configuration
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


def test_natural_electron_configuration_of_oxygen():
    """Oxygen's valence s NAO is 2s, not the basis set's label for it.

    The 6-31G basis calls that contraction "3s"; NBO reports the natural shell
    as 2s.  Reading the basis label through unchanged would shift every valence
    shell up by one.
    """
    _mf, result = _analyse(WATER, "6-31g")
    configuration = result["perAtom"][0]["configuration"]
    assert set(configuration) == {"1s", "2s", "2p", "3s", "3p"}, configuration
    assert abs(configuration["1s"] - 2.0) < 1e-4, configuration["1s"]
    assert abs(configuration["2s"] - 1.7667) < 3e-3, configuration["2s"]
    assert abs(configuration["2p"] - 5.1841) < 3e-3, configuration["2p"]
    assert configuration["3s"] < 0.01, configuration["3s"]


def test_shell_labels_group_by_angular_momentum():
    """Every p NAO of an atom lands in one shell, not three.

    cc-pVDZ packs two s contractions into a single shell, so a walk indexed by
    shell merges the core with the valence and reports a 1s population near 4.
    """
    for basis in ("6-31g", "cc-pvdz", "6-311g"):
        _mf, result = _analyse(WATER, basis)
        configuration = result["perAtom"][0]["configuration"]
        assert abs(configuration["1s"] - 2.0) < 1e-3, (basis, configuration)
        assert configuration["2s"] < 2.0, (basis, configuration)


# --------------------------------------------------------------------------
# open shells and failure modes
# --------------------------------------------------------------------------


def test_open_shell_oh_radical():
    """An unrestricted density is a spin-summed pair of matrices; NPA needs both."""
    _mf, result = _analyse("O 0 0 0; H 0 -0.757 0.587", "6-31g", spin=1)
    assert result is not None
    assert result["sumRuleOk"] is True
    assert result["nElectrons"] == 9
    assert result["perAtom"][0]["charge"] < 0


def test_analysis_reports_none_rather_than_raising():
    """A caller must be able to leave the field out instead of failing."""

    class Broken:
        mol = None

    assert nbo.natural_population_analysis(Broken(), [{"element": "H"}]) is None


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
    assert abs(result["npa"]["perAtom"][0]["charge"] - (-0.9539)) < 2e-3
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
    assert result["analysisMethod"] == "NAO/NPA"
    assert result["method"] == "RHF/6-31g"
    assert result["sumRuleOk"] is True
    assert abs(result["perAtom"][0]["charge"] - (-0.9539)) < 2e-3
