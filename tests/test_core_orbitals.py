"""Which orbitals count as core, and what the viewer's valence option hides.

The filter is a statement about chemistry, so the tests check it against the
chemistry rather than against the implementation: water has one core orbital
(the oxygen 1s), benzene has six (one per carbon), hydrogen sulfide has five
(the sulfur 1s, 2s and 2p).  A test that only compared the mask with the table
would pass while the table was misread.

Run with ``python tests/run_tests.py``.
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src"))

import numpy as np  # noqa: E402
from pyscf import gto, scf  # noqa: E402

from pyscf_mobile import core_orbitals, engine  # noqa: E402

WATER = "O 0 0 0; H 0 0 0.9584; H 0 0.9267 -0.2421"
BENZENE = (
    "C 1.3965 0 0; C 0.69825 1.2095 0; C -0.69825 1.2095 0; C -1.3965 0 0; "
    "C -0.69825 -1.2095 0; C 0.69825 -1.2095 0; H 2.4793 0 0; H 1.23965 2.1472 0; "
    "H -1.23965 2.1472 0; H -2.4793 0 0; H -1.23965 -2.1472 0; H 1.23965 -2.1472 0"
)
HYDROGEN_SULFIDE = "S 0 0 0; H 0 0 1.34; H 0 0.93 -0.42"
NITROGEN = "N 0 0 0; N 0 0 1.10"


def _mean_field(atoms: str, basis: str, method: str = "RHF"):
    mol = gto.M(atom=atoms, basis=basis, verbose=0)
    return scf.RHF(mol).run(verbose=0)


def test_oxygen_has_one_core_function():
    """Water's core is the oxygen 1s: one function, on the oxygen.

    A valence orbital must not be counted with it.  The 6-31G oxygen has three
    s shells and two p shells, of which only the first s is core.
    """
    mol = gto.M(atom=WATER, basis="6-31g", verbose=0)
    mask = core_orbitals.core_ao_mask(mol)
    assert mask.sum() == 1, f"expected one core function, got {int(mask.sum())}"
    labels = mol.ao_labels()
    assert labels[int(np.argmax(mask))].strip().endswith("1s"), (
        f"the core function is {labels[int(np.argmax(mask))]!r}")
    # The p functions are all valence: oxygen's 2p is occupied in the atom.
    assert not any(mask[i] for i, label in enumerate(labels) if " p" in label)


def test_carbon_and_hydrogen_in_benzene():
    """Six carbons contribute one core function each; hydrogen contributes none."""
    mol = gto.M(atom=BENZENE, basis="sto-3g", verbose=0)
    mask = core_orbitals.core_ao_mask(mol)
    assert mask.sum() == 6, f"expected six core functions, got {int(mask.sum())}"
    labels = mol.ao_labels()
    for index in np.where(mask)[0]:
        assert labels[index].strip().endswith("1s"), labels[index]
        assert " C " in labels[index], labels[index]


def test_sulfur_core_is_a_1s_2s_and_2p():
    """Sulfur's core is five functions: a 1s, a 2s and three 2p.

    This is the case that separates "core" from "the lowest shell".  Sulfur's
    2s and 2p hold the n = 2 electrons, which are core for a third-row element
    but valence for oxygen, so a table indexed wrongly would put them on the
    wrong side.  PySCF's spec for sulfur is ``'2s1p0d0f'`` -- two s shells and
    one p shell, that is 1s and 2s plus the three 2p -- which is five functions
    and five core orbitals for hydrogen sulfide.
    """
    mol = gto.M(atom=HYDROGEN_SULFIDE, basis="6-31g", verbose=0)
    mask = core_orbitals.core_ao_mask(mol)
    assert mask.sum() == 5, f"expected five core functions, got {int(mask.sum())}"
    labels = [mol.ao_labels()[i].strip() for i in np.where(mask)[0]]
    assert sum(label.endswith("1s") for label in labels) == 1, labels
    assert sum(label.endswith("2s") for label in labels) == 1, labels
    assert sum("2p" in label for label in labels) == 3, labels


def test_generally_contracted_basis_keeps_the_second_s_valence():
    """cc-pVDZ stores nitrogen's 1s and 2s in one shell row with two contractions.

    Counting the row as one shell would read both contractions as core and hide
    a valence lone pair, so the row is counted by its contraction count.  The
    check is that the mask has exactly one function per nitrogen.
    """
    mol = gto.M(atom=NITROGEN, basis="cc-pvdz", verbose=0)
    mask = core_orbitals.core_ao_mask(mol)
    assert mask.sum() == 2, f"expected two core functions, got {int(mask.sum())}"
    labels = [mol.ao_labels()[i].strip() for i in np.where(mask)[0]]
    assert all(label.endswith("1s") for label in labels), labels


def test_core_populations_separate_core_from_valence():
    """The core orbital puts nearly all of itself on the core functions.

    The mask alone cannot make this statement -- a core and a valence orbital
    can share basis functions -- so the population is what the filter acts on,
    and the gap between the two has to be wide for a threshold to be safe.
    """
    mf = _mean_field(WATER, "6-31g")
    populations = core_orbitals.core_populations(mf, np.asarray(mf.mo_coeff))
    core = float(populations.max())
    others = float(np.sort(populations)[-2])
    assert core > 0.99, f"the core orbital only reaches {core:.4f}"
    assert others < 0.01, f"a valence orbital reaches {others:.4f}"


def test_only_occupied_orbitals_are_called_core():
    """A virtual cannot be a core orbital, however it is composed.

    cc-pVDZ has virtuals with a large core population -- a core-correlating
    function of the basis -- and calling one core would hide a virtual from the
    valence list on the strength of it.
    """
    mf = _mean_field(NITROGEN, "cc-pvdz")
    coefficients = np.asarray(mf.mo_coeff, dtype=float)
    occupations = np.asarray(mf.mo_occ, dtype=float)
    flags = core_orbitals.core_flags(mf, coefficients, occupations)
    for index, is_core in enumerate(flags):
        if is_core:
            assert occupations[index] > 0.5, (
                f"orbital {index} is unoccupied but classified core")
    # Nitrogen's two 1s orbitals are the core, and both are occupied.
    assert sum(flags) == 2, f"expected two core orbitals, got {sum(flags)}"


def test_payload_valence_list_is_the_complement_of_the_core_list():
    """The two lists partition the ladder, and the flags agree with both.

    The viewer builds its buttons from ``valenceOrbitals`` and reads
    ``isCore`` to label them, so a disagreement between the two would put a
    core orbital in the valence list while marking it core.
    """
    payload = engine.run_scf({"atoms": WATER, "basis": "6-31g", "method": "RHF"})
    compositions = payload["orbitalCompositions"]
    orbitals = compositions["orbitals"]
    core = compositions["coreOrbitals"]
    valence = compositions["valenceOrbitals"]

    assert sorted(core + valence) == list(range(len(orbitals)))
    assert len(core) == 1, f"water has one core orbital, got {core}"
    for index, entry in enumerate(orbitals):
        assert entry["isCore"] == (index in core), f"orbital {index} disagrees"


def test_localised_orbitals_are_classified_too():
    """A localised core orbital is still core, and is hidden as one.

    Localisation rotates the occupied space, so the core orbital stays a core
    orbital -- it has nothing to mix with -- and the viewer has to hide the
    same number of columns for every method rather than only for canonical MOs.
    """
    payload = engine.run_scf(
        {"atoms": WATER, "basis": "6-31g", "method": "RHF", "include": ["localization"]})
    localization = payload["localization"]
    valence = localization["valenceOrbitals"]
    n_columns = len(localization["compositions"]["perAtom"][0])

    assert len(valence) == n_columns - 1, (
        f"expected {n_columns - 1} valence columns, got {len(valence)}")
    assert 0 not in valence, "the core column is in the valence list"


def test_surface_reports_the_valence_list_for_its_own_source():
    """The viewer can build a localised button list from the surface it drew.

    The run payload describes the canonical orbitals, so a localised list cannot
    come from there; the classification rides with the surface instead.  The
    indices address the localised columns, which is what the buttons will use.
    """
    for source in ("pm-mulliken", "boys", "er"):
        payload = engine.run_orbital_surface({
            "atoms": WATER, "basis": "6-31g", "method": "RHF",
            "source": source, "index": 0, "pointsPerAxis": 10,
        })
        valence = payload["valenceOrbitals"]
        assert len(valence) == 4, f"{source}: expected four valence columns, got {valence}"
        assert 0 not in valence, f"{source}: the core column is in the valence list"
        assert payload["isCore"] is True, f"{source}: column 0 is the core orbital"


def test_canonical_surface_valence_list_matches_the_run():
    """A canonical surface classifies the ladder, not the drawn orbital.

    Drawing one MO must not change which orbitals the viewer offers, or the
    list would depend on what was clicked last.
    """
    payload = engine.run_orbital_surface({
        "atoms": WATER, "basis": "6-31g", "method": "RHF",
        "source": "mo", "index": 0, "pointsPerAxis": 10,
    })
    run = engine.run_scf({"atoms": WATER, "basis": "6-31g", "method": "RHF"})
    assert payload["valenceOrbitals"] == run["orbitalCompositions"]["valenceOrbitals"]
    assert payload["isCore"] is True, "MO 1 of water is the oxygen 1s"


def test_filtering_never_empties_the_list():
    """Even a molecule whose core is everything keeps a valence orbital.

    A filter that could return nothing would leave the viewer with no buttons at
    all, which reads as a broken run rather than as a filter.  Helium's 1s is
    both its core and its only occupied orbital, and the hydrogen molecule has
    no core, so the two ends of the range are checked.
    """
    for atoms, basis in (("He 0 0 0", "sto-3g"), ("H 0 0 0; H 0 0 0.7414", "sto-3g")):
        payload = engine.run_scf({"atoms": atoms, "basis": basis, "method": "RHF"})
        valence = payload["orbitalCompositions"]["valenceOrbitals"]
        assert len(valence) >= 1, f"{atoms}: no valence orbital survived"
