"""Intrinsic localised molecular orbitals: Pipek-Mezey, Foster-Boys and ER.

The LPO/CLPO orbitals in ``localized_orbitals`` are JANPA's, and they are built
on top of natural atomic orbitals: each atom's NAOs are rotated into hybrids
first, and only then are the hybrids paired into bonds.  That construction
reads well as chemistry, but it never optimises a property of the *canonical*
orbitals directly.

These are the classical intrinsic methods, which take the converged occupied
canonical orbitals and rotate them among themselves so that some functional of
the resulting orbitals is stationary.  They are all the same shape of problem
-- a sequence of two-orbital Jacobi rotations -- so they share the loop below
and differ only in the objective.

``Pipek-Mezey`` (J. Chem. Phys. 90, 4916 (1989))
    Maximise the sum of the squared atomic populations, ``sum_A sum_i Q_Ai^2``.
    Two population definitions are offered because they do not agree on
    systems with diffuse functions: Mulliken and Loewdin.
``Foster-Boys`` (Rev. Mod. Phys. 32, 300 (1960))
    Minimise the summed second moment, equivalently maximise the summed
    squared orbital centroid.  Well behaved with diffuse functions.
``Edmiston-Ruedenberg`` (Rev. Mod. Phys. 35, 457 (1963))
    Maximise the summed self-repulsion ``sum_i (ii|ii)``.  The most expensive
    of the three, because the two-electron integrals have to be carried along
    as the orbitals rotate; this port keeps the transformed tensor in memory
    and co-rotates it, which is what makes it affordable on a phone.

Each pair's optimal angle is obtained in closed form rather than by search.
For all three methods the objective, as a function of the rotation angle, has
only a constant and a fourth harmonic: the ``cos 4g``/``sin 4g`` form.  Two
coefficients therefore determine it, and the maximum is at
``atan2(b, -a) / 4``.  Solving it exactly is not an optimisation -- a searched
angle is rounded, and the residual error leaves the orbitals at a point that is
not quite stationary, which shows up as the objective drifting between runs.

The reported orbital centroids are the Foster-Boys centres, the quantity
Multiwfn prints, so they are what the tests compare against.

The reference program for the first two is Multiwfn 2026.10.18, whose
``orbloc`` module was read line by line for the working equations; the tests
reproduce its printed objective values.  Edmiston-Ruedenberg is not one of
Multiwfn's methods, so it is checked against ``pyscf.lo.ER`` -- an independent
implementation -- and against the stationarity of its own objective.
"""

from __future__ import annotations

from typing import Any

import numpy as np

from . import core_orbitals

# The Jacobi sweep stops when no pair rotation can improve the objective by
# more than this.  The gain each engine reports is the exact improvement the
# best rotation would give, so the test is a stationarity test rather than a
# change-per-cycle heuristic.
_CONVERGENCE = 1.0e-12
_MAX_CYCLES = 500

_METHODS = {
    "pm-mulliken": ("Pipek-Mezey", "Mulliken"),
    "pm-lowdin": ("Pipek-Mezey", "Lowdin"),
    "boys": ("Foster-Boys", ""),
    "er": ("Edmiston-Ruedenberg", ""),
}

#: The intrinsic localisation methods, for callers that need to validate a name
#: or offer the list in a UI.
METHODS = tuple(_METHODS)


def _atom_blocks(mol) -> list[np.ndarray]:
    """The basis functions of each atom, as index arrays into the AO basis.

    This is Multiwfn's ``basstart``/``basend``: its basis functions are
    contiguous per atom, and PySCF's ``aoslice_by_atom`` gives the same
    contiguous slice, so the two programs sum over exactly the same functions.
    """
    slices = mol.aoslice_by_atom()
    return [np.arange(int(start), int(stop)) for _sh, _sl, start, stop in slices]


def _rotation_angle(a: float, b: float) -> tuple[float, float]:
    """The rotation maximising ``a cos 4g + b sin 4g``, and its gain.

    The maximum of that expression is ``hypot(a, b)``, reached at
    ``atan2(b, -a) / 4`` -- Multiwfn's ``sign(b) * acos(-a / hypot(a, b)) / 4``
    without the sign case.  The gain over leaving the pair alone is
    ``a + hypot(a, b)``, which is non-negative everywhere and zero exactly when
    ``b = 0`` and ``a <= 0``, the stationarity condition.

    Returns ``(angle, gain)``.
    """
    magnitude = float(np.hypot(a, b))
    return float(np.arctan2(b, -a) / 4.0), float(a + magnitude)


def _rotate_columns(matrix: np.ndarray, i: int, j: int, cosine: float, sine: float) -> None:
    """Mix columns ``i`` and ``j`` of a coefficient-like matrix, in place."""
    left = matrix[:, i].copy()
    right = matrix[:, j].copy()
    matrix[:, i] = cosine * left + sine * right
    matrix[:, j] = -sine * left + cosine * right


def _co_rotate_tensor(tensor: np.ndarray, i: int, j: int, cosine: float, sine: float) -> None:
    """Apply one orbital rotation to every axis of a two-electron tensor.

    The integrals are held in the *localised* basis and updated in step with the
    orbitals, so no integral transformation is repeated inside the loop.  That
    is what makes Edmiston-Ruedenberg affordable: the alternative,
    re-transforming ``(ij|kl)`` after every rotation, is ``O(N^5)`` per pair.
    """
    for axis in range(4):
        view = np.moveaxis(tensor, axis, 0)
        left = view[i].copy()
        right = view[j].copy()
        view[i] = cosine * left + sine * right
        view[j] = -sine * left + cosine * right


# ---------------------------------------------------------------------------
# the objectives
# ---------------------------------------------------------------------------


class _PipekMezey:
    """``sum_A sum_i Q_Ai^2`` for one of the population definitions."""

    def __init__(self, mol, overlap: np.ndarray, orbitals: np.ndarray, population: str):
        self.blocks = _atom_blocks(mol)
        self.population = population
        self.orbitals = orbitals
        self.root = None
        if population == "mulliken":
            # Multiwfn keeps S.C alongside C so each pair rotation costs O(N^2)
            # instead of O(N^3); the same trick is used here.
            self.weighted = overlap @ orbitals
        elif population == "lowdin":
            # Loewdin populations are Mulliken populations of the S^(1/2)
            # symmetric-orthogonalised orbitals: the rotation is applied in
            # that basis, where the overlap is the identity and drops out.
            values, vectors = np.linalg.eigh(overlap)
            self.root = vectors @ np.diag(np.sqrt(values)) @ vectors.T
            self.orbitals = self.root @ orbitals
            self.weighted = self.orbitals
        else:
            raise ValueError(f"unknown population: {population!r}")

    def value(self) -> float:
        total = 0.0
        for block in self.blocks:
            populations = np.einsum(
                "mi,mi->i", self.orbitals[block], self.weighted[block]
            )
            total += float(np.sum(populations**2))
        return total

    def angle(self, i: int, j: int) -> tuple[float, float]:
        a = 0.0
        b = 0.0
        for block in self.blocks:
            left = self.orbitals[block]
            right = self.weighted[block]
            qij = 0.5 * np.sum(left[:, j] * right[:, i] + left[:, i] * right[:, j])
            qii = np.sum(left[:, i] * right[:, i])
            qjj = np.sum(left[:, j] * right[:, j])
            a += float(qij**2 - (qii - qjj) ** 2 / 4.0)
            b += float(qij * (qii - qjj))
        return _rotation_angle(a, b)

    def apply(self, i: int, j: int, cosine: float, sine: float) -> None:
        _rotate_columns(self.orbitals, i, j, cosine, sine)
        if self.weighted is not self.orbitals:
            _rotate_columns(self.weighted, i, j, cosine, sine)

    def ao_coefficients(self) -> np.ndarray:
        """The localised orbitals back in the atomic-orbital basis."""
        if self.root is None:
            return self.orbitals
        # Undo the S^(1/2) transformation with S^(-1/2), its inverse.
        return np.linalg.inv(self.root) @ self.orbitals


class _Boys:
    """``sum_i |<i|r|i>|^2``, maximised.  Equivalent to minimising the spread."""

    def __init__(self, mol, orbitals: np.ndarray):
        self.orbitals = orbitals
        # <mu|r|nu> in three components; the loop contracts these into
        # orbital-basis centroids rather than carrying a 3N^2 matrix.
        self.dipole = np.asarray(mol.intor("int1e_r", comp=3), dtype=float)

    def _centroid(self, orbitals: np.ndarray, column: int) -> np.ndarray:
        vector = orbitals[:, column]
        return np.einsum("kij,i,j->k", self.dipole, vector, vector)

    def _cross(self, i: int, j: int) -> np.ndarray:
        """``<i|r|j>`` for a pair, contracted directly from the dipole blocks."""
        return np.einsum("kij,i,j->k", self.dipole, self.orbitals[:, i], self.orbitals[:, j])

    def value(self) -> float:
        total = 0.0
        for column in range(self.orbitals.shape[1]):
            centroid = self._centroid(self.orbitals, column)
            total += float(centroid @ centroid)
        return total

    def angle(self, i: int, j: int) -> tuple[float, float]:
        first = self._centroid(self.orbitals, i)
        second = self._centroid(self.orbitals, j)
        cross = self._cross(i, j)
        a = float(cross @ cross) - float(((first - second) ** 2).sum()) / 4.0
        b = float(cross @ (first - second))
        return _rotation_angle(a, b)

    def apply(self, i: int, j: int, cosine: float, sine: float) -> None:
        _rotate_columns(self.orbitals, i, j, cosine, sine)

    def ao_coefficients(self) -> np.ndarray:
        return self.orbitals


class _EdmistonRuedenberg:
    """``sum_i (ii|ii)``, maximised, with the integrals co-rotated."""

    def __init__(self, mol, orbitals: np.ndarray):
        from pyscf import ao2mo

        self.orbitals = orbitals
        n = orbitals.shape[1]
        self.n = n
        self.tensor = np.asarray(
            ao2mo.full(mol, orbitals, compact=False), dtype=float
        ).reshape(n, n, n, n)

    def value(self) -> float:
        return float(sum(self.tensor[i, i, i, i] for i in range(self.n)))

    def angle(self, i: int, j: int) -> tuple[float, float]:
        # Only this two-by-two block matters: the rotation mixes orbitals i and
        # j with each other and touches nothing else, so the change in the
        # total self-repulsion is confined to it.
        block = self.tensor[np.ix_([i, j], [i, j], [i, j], [i, j])]

        def pair(theta: float) -> float:
            cosine = np.cos(theta)
            sine = np.sin(theta)
            first = np.array([cosine, sine])
            second = np.array([-sine, cosine])
            return float(
                np.einsum("abcd,a,b,c,d", block, first, first, first, first)
                + np.einsum("abcd,a,b,c,d", block, second, second, second, second)
            )

        # As a function of the angle the pair objective is a constant plus a
        # fourth harmonic, ``c + A cos 4g + B sin 4g``, so three samples pin it
        # down exactly: the values at 0 and pi/4 give the constant and ``A``,
        # and the value at pi/8 -- where the cosine vanishes -- gives ``B``.
        #
        # ``_rotation_angle`` maximises ``-a cos 4g + b sin 4g``, so the
        # constant term is dropped and the cosine coefficient changes sign.
        at_zero = pair(0.0)
        at_quarter = pair(np.pi / 4.0)
        at_eighth = pair(np.pi / 8.0)
        constant = 0.5 * (at_zero + at_quarter)
        cosine_coefficient = 0.5 * (at_zero - at_quarter)
        sine_coefficient = at_eighth - constant
        return _rotation_angle(-cosine_coefficient, sine_coefficient)

    def apply(self, i: int, j: int, cosine: float, sine: float) -> None:
        _co_rotate_tensor(self.tensor, i, j, cosine, sine)
        _rotate_columns(self.orbitals, i, j, cosine, sine)

    def ao_coefficients(self) -> np.ndarray:
        return self.orbitals


# ---------------------------------------------------------------------------
# the loop
# ---------------------------------------------------------------------------


def _localise(engine, *, convergence: float = _CONVERGENCE, max_cycles: int = _MAX_CYCLES):
    """Sweep the orbital pairs until no rotation can improve the objective."""
    count = engine.orbitals.shape[1]
    sweeps = 0
    for sweep in range(1, max_cycles + 1):
        sweeps = sweep
        largest_gain = 0.0
        for i in range(count - 1):
            for j in range(i + 1, count):
                angle, gain = engine.angle(i, j)
                largest_gain = max(largest_gain, gain)
                engine.apply(i, j, np.cos(angle), np.sin(angle))
        if largest_gain <= convergence:
            break
    return sweeps, engine.value()


def _centroids(mol, orbitals: np.ndarray) -> list[list[float]]:
    """``<i|r|i>`` for every orbital, in Bohr."""
    dipole = np.asarray(mol.intor("int1e_r", comp=3), dtype=float)
    result = []
    for column in range(orbitals.shape[1]):
        vector = orbitals[:, column]
        centroid = np.einsum("kij,i,j->k", dipole, vector, vector)
        result.append([round(float(value), 5) for value in centroid])
    return result


def _composition(mol, overlap: np.ndarray, orbitals: np.ndarray) -> dict[str, Any]:
    """Per-atom Mulliken populations of each localised orbital.

    This is the composition the UI shows: for a lone pair one atom dominates,
    for a two-centre bond the population is shared.

    The contributions are summed over an atom's functions before the absolute
    value is taken.  Because ``C^T S C = I``, the signed sum over all atoms is
    exactly one per orbital, so summing magnitudes element by element would let
    a small negative off-diagonal term inflate the total past one and break
    that.  Taking the magnitude of the per-atom sum keeps the column sums at
    one, which is what makes the numbers readable as a share of the orbital.
    """
    weighted = overlap @ orbitals
    per_atom = []
    for block in _atom_blocks(mol):
        populations = np.einsum("mi,mi->i", orbitals[block], weighted[block])
        per_atom.append([round(float(value), 5) for value in populations])
    return {
        "perAtom": per_atom,
        "percent": [[round(100.0 * value, 1) for value in row] for row in per_atom],
    }


def _localisable_groups(mf) -> list[tuple[np.ndarray, int]]:
    """The occupied columns, grouped by the space each may be rotated within.

    Each group is ``(coefficients, spin)`` with coefficients shaped
    ``(nao, n)``.  A rotation has to stay inside a space the wavefunction is
    invariant over, and that space is not the whole occupied set once the
    reference is open shell:

    * an unrestricted reference stores alpha and beta separately and the two
      are eigenvectors of different Fock operators, so each occupied set is
      rotated on its own -- mixing them would change the spin density;
    * a restricted open-shell reference has one coefficient block, and only its
      doubly occupied columns may be rotated among themselves.  A singly
      occupied column is returned as a group of its own, which the loop leaves
      untouched because a single column has nothing to rotate with.

    A closed-shell reference gives the single group the earlier code assumed,
    so nothing changes for it.
    """
    occupations = np.asarray(mf.mo_occ, dtype=float)
    if occupations.ndim == 2:
        blocks = mf.mo_coeff
        if not isinstance(blocks, (tuple, list)):
            stacked = np.asarray(blocks, dtype=float)
            blocks = [stacked[spin] for spin in range(stacked.shape[0])]
        groups = []
        for spin, block in enumerate(blocks):
            occupied = np.where(occupations[spin] > 0.5)[0]
            groups.append((np.asarray(block, dtype=float)[:, occupied], spin))
        return groups

    block = np.asarray(mf.mo_coeff, dtype=float)
    paired = np.where(np.isclose(occupations, 2.0))[0]
    groups = [(block[:, paired], 0)]
    for column in np.where(np.isclose(occupations, 1.0))[0]:
        groups.append((block[:, [column]], 0))
    return groups


def localized_orbital_spins(mf) -> list[int]:
    """The spin channel of each column ``localize_coefficients`` returns.

    The viewer needs this to pick the right Fock matrix when it reports a
    localised orbital's energy, because an unrestricted reference has one Fock
    operator per spin.
    """
    spins: list[int] = []
    for block, spin in _localisable_groups(mf):
        spins.extend([spin] * block.shape[1])
    return spins


def localized_orbital_occupations(mf) -> list[float]:
    """The electron count of each column ``localize_coefficients`` returns.

    Two for a closed-shell pair or a restricted open-shell pair, one for a
    singly occupied column and for every column of an unrestricted reference,
    where the alpha and beta partners are separate orbitals.
    """
    occupations = np.asarray(mf.mo_occ, dtype=float)
    if occupations.ndim == 2:
        result: list[float] = []
        for spin, (coefficients, _spin) in enumerate(_localisable_groups(mf)):
            occupied = occupations[spin][occupations[spin] > 0.5]
            result.extend([float(occupied.mean())] * coefficients.shape[1])
        return result
    result = []
    for coefficients, _spin in _localisable_groups(mf):
        if coefficients.shape[1] == 1:
            result.append(1.0)
        else:
            result.extend([2.0] * coefficients.shape[1])
    return result


def localizable_orbital_count(mf) -> int:
    """How many localised orbitals a reference yields.

    Half the electron count only for a closed shell: an open-shell reference has
    one orbital per singly occupied column as well, so the viewer's button count
    cannot be derived from the electron count alone.
    """
    return sum(block.shape[1] for block, _spin in _localisable_groups(mf))


def localize_coefficients(
    mf, *, method: str = "pm-mulliken"
) -> tuple[np.ndarray, int, float]:
    """The localised occupied coefficients of a converged mean field.

    Returns ``(coefficients, sweeps, objective)``.  ``coefficients`` holds every
    occupied orbital, rotated within the spaces it is legal to rotate in (see
    ``_localisable_groups``); the columns are ordered alpha-occupied then
    beta-occupied for an unrestricted reference, and paired-then-singly-occupied
    for a restricted open-shell one.  Each channel is orthonormal on its own; the
    alpha and beta blocks of an unrestricted reference are not mutually
    orthogonal, because they are eigenvectors of different Fock operators and
    that is a property of the reference rather than of the localisation.  The
    orbital viewer and the tests both work from this rather than from the JSON.

    Raises ``ValueError`` for an unknown method.
    """
    key = str(method).lower()
    if key not in _METHODS:
        raise ValueError(f"unknown localization method: {method!r}")
    mol = mf.mol
    overlap = np.asarray(mol.intor_symmetric("int1e_ovlp"), dtype=float)
    population = _METHODS[key][1]

    columns: list[np.ndarray] = []
    sweeps = 0
    objective = 0.0
    for block, _spin in _localisable_groups(mf):
        if block.shape[1] < 2:
            # Nothing to mix a lone column with; carry it through unchanged.
            columns.append(block)
            continue
        orbitals = np.ascontiguousarray(block, dtype=float).copy()
        if key in ("pm-mulliken", "pm-lowdin"):
            engine = _PipekMezey(mol, overlap, orbitals, population.lower())
        elif key == "boys":
            engine = _Boys(mol, orbitals)
        else:
            engine = _EdmistonRuedenberg(mol, orbitals)
        group_sweeps, group_objective = _localise(engine)
        sweeps = max(sweeps, group_sweeps)
        objective += group_objective
        columns.append(engine.ao_coefficients())
    return np.concatenate(columns, axis=1), sweeps, objective


def localize(
    mf, atoms: list[dict], *, method: str = "pm-mulliken"
) -> dict[str, Any] | None:
    """Localise the occupied orbitals of a converged mean field.

    ``method`` is one of ``pm-mulliken``, ``pm-lowdin``, ``boys`` or ``er``.
    Returns ``None`` when the analysis cannot run, matching the other analyses,
    so a caller can leave the field out rather than fail a good calculation.
    """
    key = str(method).lower()
    if key not in _METHODS:
        raise ValueError(f"unknown localization method: {method!r}")
    try:
        mol = mf.mol
        if len(atoms) != mol.natm:
            return None
        localised, sweeps, objective = localize_coefficients(mf, method=key)
    except Exception:
        return None

    overlap = np.asarray(mol.intor_symmetric("int1e_ovlp"), dtype=float)
    family, population = _METHODS[key]
    return {
        # Named "localization" rather than "method" because the engine payload
        # already carries a "method" key holding the reference and basis.
        "localization": key,
        "family": family,
        "population": population,
        "sweeps": int(sweeps),
        "objective": round(float(objective), 10),
        "centroids": _centroids(mol, localised),
        "compositions": _composition(mol, overlap, localised),
        # Which of these columns are valence, for the viewer's "valence only"
        # option.  A core orbital is largely invariant under a localisation, so
        # the rotation leaves it on its own atom and it stays identifiable by
        # where its population sits.
        "valenceOrbitals": core_orbitals.valence_indices(
            mf, localised, localized_orbital_occupations(mf)),
        "analysisMethod": f"{family} localised orbitals (Multiwfn 2026.10.18 port)",
    }
