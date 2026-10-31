"""Which orbitals are core, so the viewer can show the valence ones alone.

"Valence" here means the orbitals built from the outermost occupied atomic
shells, which is the set a chemist means by "the valence orbitals": for water,
the oxygen 2s and 2p and the hydrogen 1s, and not the oxygen 1s.  The split is
the same one PySCF makes when it freezes a core, so it is taken from PySCF's own
table rather than re-derived from the basis: ``N_CORE_SHELLS`` gives, per
element, how many shells of each angular momentum are core, and ``chemcore``
turns that into a core-orbital count.

Two steps are involved and they answer different questions.

``core_ao_mask`` answers which *basis functions* are core, from the element and
the shell order.  PySCF writes an atom's shells grouped by angular momentum, so
the n-th s shell on oxygen is core when ``N_CORE_SHELLS`` says one s shell is,
and the remaining s and p shells are valence.

``core_populations`` answers which *orbitals* are core, by asking how much of
each orbital sits on those functions.  The basis alone cannot answer this: a
core and a valence orbital can share functions in a split-valence basis, and
only the converged coefficients say how the population is distributed.  The two
answers agree where they must -- a core orbital puts essentially all of itself
on the core functions -- and that agreement is what the tests check.
"""

from __future__ import annotations

import numpy as np

try:
    from pyscf.data import elements as _pyscf_elements
except Exception:  # pragma: no cover - PySCF missing, handled by the caller
    _pyscf_elements = None

# An orbital is core when this much of it sits on core functions.  The
# separation is not close: in the molecules the app runs, a core orbital puts
# more than 0.99 of itself there and the next orbital puts less than 0.01, so
# the exact cut only has to fall somewhere in the gap.  A half is chosen
# because it is the value that needs no explanation.
CORE_POPULATION_THRESHOLD = 0.5

_LETTERS = "spdfghik"


def _core_shells(element: str) -> dict[int, int]:
    """How many shells of each angular momentum are core, for one element.

    Read from PySCF's ``N_CORE_SHELLS``, whose entries look like ``'1s0p0d0f'``.
    An element past the end of the table -- or a PySCF without it -- has no core,
    which is the safe answer: the filter then hides nothing rather than hiding
    an orbital on a guess.
    """
    if _pyscf_elements is None:
        return {}
    try:
        charge = int(_pyscf_elements.charge(element))
        spec = _pyscf_elements.N_CORE_SHELLS[charge]
    except Exception:
        return {}
    counts: dict[int, int] = {}
    for position in range(0, len(spec) - 1, 2):
        letter = spec[position + 1]
        if letter not in _LETTERS:
            continue
        counts[_LETTERS.index(letter)] = int(spec[position])
    return counts


def core_ao_mask(mol) -> np.ndarray:
    """A boolean per basis function: True where the function is core.

    The shells of one atom are visited in the order PySCF stored them and
    counted per angular momentum, so the first s shell on oxygen is core and a
    later one is not.  That ordering is what makes the table's per-angular-
    momentum counts usable at all.

    A single ``_bas`` row can carry more than one contracted function of its
    angular momentum -- a generally contracted basis such as cc-pVDZ puts the
    1s and 2s of nitrogen in one row with two contractions.  The row is
    therefore counted by its contraction count, not as one shell, or the 2s
    would be read as part of the core and a valence lone pair would be hidden.
    """
    mask: list[bool] = []
    seen: dict[tuple[int, int], int] = {}
    for shell in mol._bas:
        atom = int(shell[0])
        angular = int(shell[1])
        contractions = int(shell[3])
        counts = _core_shells(mol.atom_symbol(atom))
        first = seen.get((atom, angular), 0)
        seen[(atom, angular)] = first + contractions
        n_core = counts.get(angular, 0)
        # The core shells of an angular momentum come first, so this row is core
        # up to the point the running count passes the table's number.
        core_here = max(0, min(contractions, n_core - first))
        mask.extend([True] * (core_here * (2 * angular + 1)))
        mask.extend([False] * ((contractions - core_here) * (2 * angular + 1)))
    return np.array(mask, dtype=bool)


def core_populations(mf, columns: np.ndarray) -> np.ndarray:
    """The share of each orbital that sits on the core basis functions.

    The Mulliken population of the core block, so it is a signed quantity in
    ``[0, 1]`` for a normalised orbital and reaches one when the orbital is a
    pure core function.  ``columns`` is ``(nao, n)``.
    """
    mol = mf.mol
    mask = core_ao_mask(mol)
    if mask.size != columns.shape[0]:
        raise ValueError(
            f"core mask has {mask.size} functions but the orbitals have {columns.shape[0]}")
    if not mask.any():
        return np.zeros(columns.shape[1])
    overlap = np.asarray(mf.get_ovlp(), dtype=float)
    weighted = overlap @ np.asarray(columns, dtype=float)
    return np.einsum("mi,mi->i", columns[mask], weighted[mask])


def core_flags(mf, columns: np.ndarray, occupations: np.ndarray | None = None,
               threshold: float = CORE_POPULATION_THRESHOLD) -> list[bool]:
    """Which of ``columns`` are core orbitals, in the order given.

    A core orbital is an *occupied* orbital that puts nearly all of itself on
    the core functions, and the occupation test is part of the definition rather
    than a guard.  A core orbital holds the core electrons, so an unoccupied
    column cannot be one however it is composed; a virtual with a large core
    population is a core-correlating function of the basis, not a core orbital.
    cc-pVDZ has such columns -- a nitrogen virtual reaches a core population of
    0.56 -- and without this test the viewer would hide a virtual from the
    valence list on the strength of it.
    """
    populations = core_populations(mf, columns)
    if occupations is None:
        return [bool(value > threshold) for value in populations]
    occupied = np.asarray(occupations, dtype=float).ravel()
    if occupied.size != len(populations):
        return [bool(value > threshold) for value in populations]
    return [bool(value > threshold and occupied[i] > 0.5)
            for i, value in enumerate(populations)]


def valence_indices(mf, columns: np.ndarray, occupations: np.ndarray | None = None,
                    threshold: float = CORE_POPULATION_THRESHOLD) -> list[int]:
    """The positions of the valence orbitals among ``columns``."""
    return [i for i, is_core in
            enumerate(core_flags(mf, columns, occupations, threshold)) if not is_core]


def n_core_orbitals(mol) -> int:
    """How many core orbitals a reference on ``mol`` has.

    ``chemcore`` counts core electron pairs from the atoms' configurations, so
    this is the number the core-space rotation leaves untouched and the count a
    localised list can hide from its front when the coefficients are not at
    hand.  Zero when PySCF cannot answer.
    """
    if _pyscf_elements is None:
        return 0
    try:
        return int(_pyscf_elements.chemcore(mol))
    except Exception:
        return 0
