"""Natural population analysis (NPA).

NPA is the population half of Weinhold's natural bond orbital method: the
density is transformed into natural atomic orbitals (NAOs), which are the
eigenvectors of the atomic blocks of the density matrix, and the atomic
populations are read off their occupancies.  Because the NAOs are the
*intrinsic* orbitals of the density rather than a fixed basis, the resulting
charges are far less basis-set sensitive than Mulliken's -- water's oxygen
comes out near -0.95 in 6-31G, 6-31G* and cc-pVDZ alike, where Mulliken moves
by more than half an electron over the same three bases.

Ref: A. E. Reed, R. B. Weinstock, F. Weinhold, J. Chem. Phys. 83 (1985) 735.

Scope
-----
This module implements the NAO/NPA part of the method and stops there.  It does
not build NBOs, and it does not compute the second-order perturbation energies
E(2) that the NBO program reports.  That is a deliberate omission rather than a
gap to be filled in later: the NBO step is an iterative sequence of 2x2 density
rotations whose precise pairing rules are the substance of the published
algorithm, and the reference implementation (NBO6/NBO7) is licensed software.
Two shortcuts were tried and both give demonstrably wrong answers -- a full
diagonalization of the density returns natural orbitals, in which the Fock
matrix is diagonal and every E(2) is identically zero, and a one-shot
construction from the natural hybrid orbitals gives bond occupancies near 1.6
instead of 2.0 and E(2) values an order of magnitude too large.  Since a wrong
E(2) is worse than no E(2), only the part that can be checked against the
literature is reported here.

The charges are validated against published NPA values in tests/test_nbo.py.
"""

from __future__ import annotations

from typing import Any

import numpy as np


def natural_population_analysis(mf, atoms: list[dict]) -> dict[str, Any] | None:
    """NAO occupations, natural charges and natural electron configuration.

    ``atoms`` is the engine's normalised atom list (``element``, ``z``, ``xyz``);
    only its length is used, as a consistency check against the molecule.
    Returns ``None`` when the analysis cannot run, so a caller can leave the
    field out rather than fail a calculation that is otherwise fine.
    """
    try:
        from pyscf.lo import nao as nao_mod

        mol = mf.mol
        overlap = mol.intor_symmetric("int1e_ovlp")
        density = mf.make_rdm1()
        if np.asarray(density).ndim == 3:
            # ROHF and UHF both hand back one matrix per spin; the NAO
            # transformation needs the total density.
            density = density[0] + density[1]
        density = np.asarray(density, dtype=float)

        # The NAO transform is a per-atom generalized eigenproblem of the
        # density in the overlap metric, followed by the core/valence/Rydberg
        # orthogonalisation that gives the orbitals their natural character.
        coefficients = np.asarray(nao_mod.nao(mol, mf), dtype=float)

        # In the orthonormal NAO basis the population of an orbital is just its
        # density-matrix diagonal, so the transform is the whole analysis.
        p_nao = coefficients.T @ overlap @ density @ overlap @ coefficients
        occupations = np.real(np.diag(p_nao))
    except Exception:
        return None

    if occupations.shape[0] != coefficients.shape[1] or len(atoms) != mol.natm:
        return None

    labels = _ao_labels(mol)
    shells_by_nao = _natural_shells(mol)
    ao_slice = mol.aoslice_by_atom()

    per_atom = []
    for index in range(mol.natm):
        _, _, first, last = ao_slice[index]
        shells: dict[str, float] = {}
        orbitals = []
        for nao_index in range(first, last):
            occupation = float(occupations[nao_index])
            shell = shells_by_nao.get(nao_index, "")
            shells[shell] = shells.get(shell, 0.0) + occupation
            orbitals.append(
                {
                    "label": f"{shell}{_subscript(len(orbitals) + 1)}",
                    "shell": shell,
                    "occupation": round(occupation, 6),
                    "character": labels[nao_index] if nao_index < len(labels) else "",
                }
            )
        population = float(occupations[first:last].sum())
        per_atom.append(
            {
                "index": index,
                "element": mol.atom_symbol(index),
                "population": round(population, 6),
                "charge": round(float(mol.atom_charge(index)) - population, 6),
                "configuration": {k: round(v, 6) for k, v in sorted(shells.items(), key=_shell_key)},
                "orbitals": orbitals,
            }
        )

    totals: dict[str, float] = {}
    for entry in per_atom:
        totals[entry["element"]] = totals.get(entry["element"], 0.0) + entry["charge"]

    total_population = float(occupations.sum())
    return {
        "perAtom": per_atom,
        "perElement": {k: round(v, 6) for k, v in sorted(totals.items())},
        "nElectrons": int(mol.nelectron),
        "totalPopulation": round(total_population, 6),
        # The occupations must add up to the electron count. A mismatch means
        # the transform or the density is wrong, so the UI shows it as a
        # self-check rather than presenting the numbers as trustworthy.
        "sumRuleOk": abs(total_population - mol.nelectron) < 1e-6,
        "analysisMethod": "NAO/NPA",
    }


def _natural_shells(mol) -> dict[int, str]:
    """Give each NAO the (n, l) shell label NBO would print.

    The label PySCF attaches to a basis function is the contraction's name in
    the basis set, which is not the orbital's natural shell: the valence s NAO
    of 6-31G oxygen carries the basis label "3s" but is reported by NBO as 2s.

    Distinct basis labels are therefore renumbered per atom and angular
    momentum, in order of first appearance: the first s contraction is 1s, the
    second 2s, the first p contraction is 2p.  Grouping by the label string
    rather than by AO position keeps this correct when a shell holds several
    contractions (cc-pVDZ packs 1s and 2s into one shell, and counting shells
    would merge the core with the valence) and when the ordering within a shell
    is contraction-major rather than component-major.
    """
    shells: dict[int, str] = {}
    seen: dict[tuple[int, int], dict[str, str]] = {}
    for index, (atom, _symbol, label) in enumerate(_ao_entries(mol)):
        angular = _angular(label)
        table = seen.setdefault((int(atom), angular), {})
        if label not in table:
            table[label] = f"{angular + 1 + len(table)}{'spdfgh'[angular]}"
        shells[index] = table[label]
    return shells


def _ao_entries(mol) -> list[tuple]:
    """``(atom_index, atom_symbol, basis_label)`` for every AO."""
    try:
        return [(e[0], e[1], str(e[2])) for e in mol.ao_labels(fmt=None)]
    except Exception:
        entries = []
        for entry in mol.ao_labels():
            parts = str(entry).split()
            entries.append((int(parts[0]), parts[1], parts[-1]))
        return entries


def _angular(label: str) -> int:
    """Angular momentum of a basis-function label such as ``2pz`` or ``1s``."""
    letters = "spdfgh"
    for char in label:
        lowered = char.lower()
        if lowered in letters:
            return letters.index(lowered)
    return 0


def _ao_labels(mol) -> list[str]:
    """Per-AO labels such as ``2pz``, with the atom index stripped."""
    return [label for _atom, _symbol, label in _ao_entries(mol)]


def _shell_key(item: tuple[str, float]):
    """Sort shells by principal quantum number then angular momentum."""
    shell = item[0]
    digits = "".join(c for c in shell if c.isdigit())
    letters = "".join(c for c in shell if c.isalpha())
    return (int(digits) if digits else 99, letters)


def _subscript(number: int) -> str:
    table = str.maketrans("0123456789", "₀₁₂₃₄₅₆₇₈₉")
    return str(number).translate(table)
