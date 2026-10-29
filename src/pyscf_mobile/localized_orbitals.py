"""Localised property-optimised orbitals: JANPA's LPO and CLPO.

A port of the ``CLPO`` package of JANPA 2.02.  The natural atomic orbitals
delocalise the density; these orbitals undo that, by rotating each atom's NAOs
into hybrids and pairing the hybrids of neighbouring atoms into bonds.  The two
variants differ in what they optimise:

``LPO``
    maximise the sum of the squared occupations, ``tr(D^2)``.  This is the
    Pipek-Mezey-style criterion and gives the most compact orbitals.
``CLPO``
    maximise the squared occupations of the two-centre bonding and one-centre
    lone-pair orbitals only.  This is the "chemist's" criterion: it keeps the
    lone pairs on the atom that owns them instead of splitting them into bent
    bonds, which is what makes the result read as a Lewis structure.

Both come out of the same loop.  Each pass re-pairs the hybrids -- a maximum
weight matching on the inter-atomic coupling -- and then relaxes the hybrids
themselves by a gradient step on the target function, until the function stops
improving.

The reference program is the oracle for every number reported here, and the
matching is a port of the same weighted-matching algorithm JANPA carries.
"""

from __future__ import annotations

from typing import Any

import numpy as np

from ._matching import maximum_weight_matching
from .natural_orbitals import _BasisLayout, _NaoBasis, _build_naos, _density_matrices

# JANPA's convergence threshold and iteration cap for the hybrid relaxation.
_TARGET_FUNCTION_THRESHOLD = 1.0e-5
_MAX_ITERATIONS = 1000
# A two-centre orbital is only treated as a bond in CLPO mode when its ionic
# character clears 1 and the anti-bonding partner stays below it, with the
# hybridisation angle below the ionicity cutoff (JANPA's
# -maximumBondIonicity default).
_MIN_BOND_OCCUPATION = 1.0
_MAX_BOND_IONICITY = 0.9


# ---------------------------------------------------------------------------
# maximum weight matching
# ---------------------------------------------------------------------------
#
# JANPA scores each candidate pair and asks for the matching of greatest total
# weight, preferring more bonds when the weights tie.  That is the maximum
# weight matching of Edmonds' blossom algorithm; ``_matching`` holds a vendored
# implementation.


def _maximum_weight_matching(edges: list[tuple[int, int, float]]) -> dict[int, int]:
    """The matching as a partner map over the matched vertices."""
    if not edges:
        return {}
    pairs = maximum_weight_matching(edges, maxcardinality=False)
    partner: dict[int, int] = {}
    for a, b in pairs:
        partner[a] = b
        partner[b] = a
    return partner


# ---------------------------------------------------------------------------
# hybrid orbitals
# ---------------------------------------------------------------------------


class _AtomicHybrids:
    """The hybrid orbitals of one atom, as a rotation of its NAOs.

    ``u`` is ``n_nao x n_nao`` with one hybrid per column.  ``friend_atom`` and
    ``friend_hybrid`` record the partner each hybrid is bonded to, or ``-1`` for
    a lone pair or Rydberg orbital.
    """

    def __init__(self, nao_indices: np.ndarray) -> None:
        n = len(nao_indices)
        self.nao_indices = nao_indices
        self.u = np.eye(n)
        self.n_valid = 0
        self.friend_atom = np.full(n, -1, dtype=int)
        self.friend_hybrid = np.full(n, -1, dtype=int)
        self._u_saved: np.ndarray | None = None
        self._friends_saved: tuple[np.ndarray, np.ndarray] | None = None

    def backup(self) -> None:
        self._u_saved = self.u.copy()

    def restore(self) -> None:
        if self._u_saved is not None:
            self.u = self._u_saved.copy()

    def backup_bonding(self) -> None:
        self._friends_saved = (self.friend_atom.copy(), self.friend_hybrid.copy())

    def restore_bonding(self) -> None:
        if self._friends_saved is not None:
            self.friend_atom = self._friends_saved[0].copy()
            self.friend_hybrid = self._friends_saved[1].copy()

    def symmetrise(self) -> None:
        if self.n_valid <= 1:
            return
        block = self.u[:, : self.n_valid]
        self.u[:, : self.n_valid] = _symmetric_orthogonalisation(block)


def _symmetric_orthogonalisation(matrix: np.ndarray) -> np.ndarray:
    """The nearest orthogonal matrix, ``U . V^T`` from the SVD of ``matrix``.

    This is JANPA's ``EigenEngine.symmetrOrth``, and it is what keeps the hybrid
    rotation orthonormal after a gradient step.  The SVD form is used rather
    than ``matrix . (matrix^T matrix)^(-1/2)`` because the two agree only while
    the matrix has full rank, and a gradient step can make it singular.
    """
    u, _values, vt = np.linalg.svd(matrix)
    return u @ vt


def _rotate_pair(matrix: np.ndarray, i: int, j: int, cosine: float, sine: float) -> None:
    """Apply a plane rotation to rows and columns ``i`` and ``j``, in place."""
    n = matrix.shape[0]
    for k in range(n):
        if k == i or k == j:
            continue
        a = matrix[i, k]
        b = matrix[j, k]
        matrix[i, k] = cosine * a + sine * b
        matrix[j, k] = -sine * a + cosine * b
        a = matrix[k, i]
        b = matrix[k, j]
        matrix[k, i] = cosine * a + sine * b
        matrix[k, j] = -sine * a + cosine * b
    a = matrix[i, i]
    b = matrix[j, j]
    c = matrix[i, j]
    d = matrix[j, i]
    matrix[i, i] = cosine * cosine * a + sine * sine * b + cosine * sine * (c + d)
    matrix[j, j] = cosine * cosine * b + sine * sine * a - cosine * sine * (c + d)
    matrix[i, j] = cosine * cosine * c - sine * sine * d + cosine * sine * (b - a)
    matrix[j, i] = cosine * cosine * d - sine * sine * c + cosine * sine * (b - a)


def _simultaneous_diagonalisation(
    matrices: list[np.ndarray], initial: np.ndarray | None = None
) -> np.ndarray:
    """Rotate so every symmetric matrix in ``matrices`` is as diagonal as possible.

    The Jacobi sweep of JANPA's ``CS96_SimultDiag``: each off-diagonal pair is
    rotated by the angle that zeroes the summed ``(i, j)`` element over all the
    matrices at once, and sweeps repeat until no rotation moves anything.
    """
    n = matrices[0].shape[0]
    rotation = np.eye(n) if initial is None else initial.T.copy()
    for _ in range(100):
        largest = 0.0
        for i in range(n):
            for j in range(i + 1, n):
                difference = 0.0
                cross = 0.0
                for matrix in matrices:
                    difference += (matrix[i, i] - matrix[j, j]) ** 2 - (
                        matrix[i, j] + matrix[j, i]
                    ) ** 2
                    cross += (matrix[i, i] - matrix[j, j]) * (matrix[i, j] + matrix[j, i])
                angle = np.arctan2(2.0 * cross, difference) / 4.0
                cosine = np.cos(angle)
                sine = np.sin(angle)
                largest = max(largest, abs(sine))
                for matrix in matrices:
                    _rotate_pair(matrix, i, j, cosine, sine)
                for k in range(n):
                    a = rotation[i, k]
                    rotation[i, k] = cosine * a + sine * rotation[j, k]
                    rotation[j, k] = -sine * a + cosine * rotation[j, k]
        if largest <= 1.0e-7:
            break
    return rotation.T


# ---------------------------------------------------------------------------
# the optimisation loop
# ---------------------------------------------------------------------------


def localized_orbitals(
    mf, atoms: list[dict], *, kind: str = "clpo"
) -> dict[str, Any] | None:
    """Localised property-optimised orbitals for a converged wavefunction.

    ``kind`` selects the target: ``"clpo"`` for the chemist's orbitals, ``"lpo"``
    for the plain property-optimised ones.  Returns ``None`` when the analysis
    cannot run, matching the other analyses.
    """
    try:
        mol = mf.mol
        layout = _BasisLayout(mol)
        overlap, _density, sds = _density_matrices(mf)
        basis = _build_naos(mol, overlap, sds, layout)
    except Exception:
        return None

    if len(atoms) != mol.natm:
        return None

    return _optimise(mf, layout, basis, basis.sds_nao, kind == "clpo")


def _optimise(
    mf, layout: _BasisLayout, basis: _NaoBasis, sds_nao: np.ndarray, lewis_mode: bool
) -> dict[str, Any]:
    """Run the LPO/CLPO loop and describe the resulting orbitals."""
    n_atoms = layout.n_atoms
    n_naos = sds_nao.shape[0]
    nao_at_centre = [np.where(layout.atom == centre)[0] for centre in range(n_atoms)]

    hybrids = [_AtomicHybrids(indices) for indices in nao_at_centre]
    dab = [[None] * n_atoms for _ in range(n_atoms)]
    for i in range(n_atoms):
        for j in range(i + 1):
            dab[i][j] = sds_nao[np.ix_(nao_at_centre[i], nao_at_centre[j])]

    _initial_guess(hybrids, nao_at_centre, dab, n_atoms)
    global_indices = _global_hybrid_indices(hybrids, n_atoms)

    target = 0.0
    for iteration in range(_MAX_ITERATIONS):
        sds_hybrid = _sds_in_hybrid_basis(hybrids, dab, nao_at_centre, n_atoms)
        reconnect = _reconnect(
            hybrids, sds_hybrid, global_indices, lewis_mode, n_naos, n_atoms
        )
        if iteration > 0 and abs(target - reconnect) < _TARGET_FUNCTION_THRESHOLD:
            break
        target = _optimise_hybrids(
            hybrids, dab, nao_at_centre, n_atoms, lewis_mode, n_naos
        )

    sds_hybrid = _sds_in_hybrid_basis(hybrids, dab, nao_at_centre, n_atoms)
    return _describe(hybrids, sds_hybrid, global_indices, layout, mf, n_atoms, lewis_mode)


def _initial_guess(hybrids, nao_at_centre, dab, n_atoms) -> None:
    """JANPA's ``CS_Guess``: diagonalise the coupling to every neighbour at once."""
    for centre in range(n_atoms):
        matrices = []
        for other in range(n_atoms):
            if other <= centre:
                block = dab[centre][other]
                matrices.append(block @ block.T)
            else:
                block = dab[other][centre]
                matrices.append(block.T @ block)
        hybrids[centre].u = _simultaneous_diagonalisation(matrices)
        hybrids[centre].n_valid = len(nao_at_centre[centre])


def _global_hybrid_indices(hybrids, n_atoms) -> list[np.ndarray]:
    """Number the valid hybrids globally, centre by centre."""
    result = []
    counter = 0
    for centre in range(n_atoms):
        indices = np.zeros(len(hybrids[centre].nao_indices), dtype=int)
        for j in range(hybrids[centre].n_valid):
            indices[j] = counter
            counter += 1
        result.append(indices)
    return result


def _sds_in_hybrid_basis(hybrids, dab, nao_at_centre, n_atoms) -> np.ndarray:
    """S.D.S transformed into the hybrid basis, made symmetric."""
    n = sum(hybrids[i].n_valid for i in range(n_atoms))
    matrix = np.zeros((n, n))
    for i in range(n_atoms):
        indices_i = nao_at_centre[i]
        u_i = hybrids[i].u[:, : hybrids[i].n_valid]
        matrix[np.ix_(indices_i, indices_i)] = 0.5 * (u_i.T @ dab[i][i] @ u_i)
        for j in range(i):
            indices_j = nao_at_centre[j]
            u_j = hybrids[j].u[:, : hybrids[j].n_valid]
            matrix[np.ix_(indices_i, indices_j)] = u_i.T @ dab[i][j] @ u_j
    return matrix + matrix.T


def _dab_dot_h(hybrids, dab, nao_at_centre, centre, other, hybrid) -> np.ndarray:
    """The ``(centre, other)`` block of S.D.S contracted with one hybrid column."""
    u = hybrids[other].u
    if other <= centre:
        return dab[centre][other] @ u[:, hybrid]
    return dab[other][centre].T @ u[:, hybrid]


def _hybrid_scalar(hybrids, centre, hybrid, vector) -> float:
    return float(hybrids[centre].u[:, hybrid] @ vector)


def _reconnect(hybrids, sds_hybrid, global_indices, lewis_mode, n_naos, n_atoms) -> float:
    """Re-pair the hybrids by maximum weight matching, then score the pairing."""
    owner: dict[int, tuple[int, int]] = {}
    edges: list[tuple[int, int, float]] = []
    for centre in range(n_atoms):
        for j in range(hybrids[centre].n_valid):
            owner[global_indices[centre][j]] = (centre, j)

    for centre in range(n_atoms):
        for j in range(hybrids[centre].n_valid):
            hybrids[centre].friend_atom[j] = -1
            hybrids[centre].friend_hybrid[j] = -1
            index = global_indices[centre][j]
            diagonal = sds_hybrid[index, index]
            if lewis_mode:
                edges.append((index, n_naos + index, diagonal * diagonal))
            for other in range(n_atoms):
                if other == centre:
                    continue
                for k in range(hybrids[other].n_valid):
                    other_index = global_indices[other][k]
                    if other_index > index:
                        continue
                    other_diagonal = sds_hybrid[other_index, other_index]
                    coupling = sds_hybrid[index, other_index]
                    root = np.sqrt(
                        (diagonal - other_diagonal) ** 2 + 4.0 * coupling * coupling
                    )
                    ionic = 0.5 * (diagonal + other_diagonal + root)
                    anti = diagonal + other_diagonal - ionic
                    cosine = np.cos(
                        np.arctan2(2.0 * coupling, abs(diagonal - other_diagonal))
                    )
                    bondable = (
                        ionic > _MIN_BOND_OCCUPATION
                        and anti < _MIN_BOND_OCCUPATION
                        and cosine < _MAX_BOND_IONICITY
                    )
                    # CLPO only bonds hybrids that clear the ionicity test; LPO
                    # scores every pair, bond or not.
                    if lewis_mode and not bondable:
                        continue
                    weight = ionic * ionic if lewis_mode else coupling * coupling
                    edges.append((index, other_index, weight))

    if not edges:
        return 0.0

    partner = _maximum_weight_matching(edges)

    target = 0.0
    for index, mate in partner.items():
        if index >= n_naos:
            # The virtual vertex CLPO adds for a one-centre orbital.
            continue
        if mate < 0 or mate >= n_naos:
            target += sds_hybrid[index, index] ** 2
            continue
        if index >= mate:
            continue
        centre, j = owner[index]
        other_centre, k = owner[mate]
        hybrids[centre].friend_atom[j] = other_centre
        hybrids[centre].friend_hybrid[j] = k
        hybrids[other_centre].friend_atom[k] = centre
        hybrids[other_centre].friend_hybrid[k] = j
        diagonal = sds_hybrid[index, index]
        other_diagonal = sds_hybrid[mate, mate]
        coupling = sds_hybrid[index, mate]
        ionic = 0.5 * (
            diagonal
            + other_diagonal
            + np.sqrt((diagonal - other_diagonal) ** 2 + 4.0 * coupling * coupling)
        )
        if lewis_mode:
            target += ionic * ionic
        else:
            target += diagonal**2 + 2.0 * coupling**2 + other_diagonal**2

    return float(target)


def _gradient(hybrids, dab, nao_at_centre, centre, lewis_mode):
    """The derivative of the target function with respect to one atom's hybrids."""
    u = hybrids[centre].u
    gradient = np.zeros_like(u)
    value = 0.0
    for j in range(u.shape[1]):
        own = _dab_dot_h(hybrids, dab, nao_at_centre, centre, centre, j)
        diagonal = _hybrid_scalar(hybrids, centre, j, own)
        friend = hybrids[centre].friend_atom[j]
        if friend == -1:
            gradient[:, j] += own * diagonal
            value += diagonal * diagonal
            continue
        friend_hybrid = hybrids[centre].friend_hybrid[j]
        coupling_vector = _dab_dot_h(
            hybrids, dab, nao_at_centre, centre, friend, friend_hybrid
        )
        coupling = _hybrid_scalar(hybrids, centre, j, coupling_vector)
        if not lewis_mode:
            gradient[:, j] += own * diagonal + coupling_vector * coupling
            value += diagonal * diagonal + coupling * coupling
            continue
        # CLPO: the bonding and anti-bonding occupations are the eigenvalues of
        # the 2x2 block, and the gradient follows their derivatives.
        friend_own = _dab_dot_h(hybrids, dab, nao_at_centre, friend, friend, friend_hybrid)
        friend_diagonal = _hybrid_scalar(hybrids, friend, friend_hybrid, friend_own)
        root = np.sqrt((diagonal - friend_diagonal) ** 2 + 4.0 * coupling * coupling)
        bonding = 0.5 * (diagonal + friend_diagonal + root)
        d_bonding = 0.5 * bonding * (1.0 + (diagonal - friend_diagonal) / root)
        d_coupling = bonding * coupling / root
        gradient[:, j] += own * d_bonding + coupling_vector * d_coupling
        value += bonding * bonding / 2.0
    return gradient, value


def _optimise_hybrids(hybrids, dab, nao_at_centre, n_atoms, lewis_mode, n_naos) -> float:
    """Relax the hybrids by a gradient step until the target function settles.

    The step length is JANPA's: the mean absolute trace of ``gradient^T . U``,
    scaled by ``1e-16``, doubling whenever a step fails to improve the target.
    """
    for hybrid in hybrids:
        hybrid.backup()
    target = -1.0
    step = 0.0
    took_step = True
    for _iteration in range(_MAX_ITERATIONS):
        gradients = []
        value = 0.0
        step_scale = 0.0
        for centre in range(n_atoms):
            gradient, centre_value = _gradient(
                hybrids, dab, nao_at_centre, centre, lewis_mode
            )
            gradients.append(gradient)
            value += centre_value
            step_scale += abs(float(np.trace(gradient.T @ hybrids[centre].u)))
        step_scale /= n_naos
        if value > target:
            step = 1.0e-16 * step_scale
            took_step = True
            for hybrid in hybrids:
                hybrid.backup()
            if value - target < _TARGET_FUNCTION_THRESHOLD:
                return float(value)
            target = value
        else:
            for hybrid in hybrids:
                hybrid.restore()
            if target - value < _TARGET_FUNCTION_THRESHOLD:
                return float(target)
            step = step_scale if took_step else step * 2.0
            took_step = False
        for centre in range(n_atoms):
            hybrids[centre].u = _symmetric_orthogonalisation(
                gradients[centre] + hybrids[centre].u * step
            )
    for hybrid in hybrids:
        hybrid.restore()
    return float(target)


# ---------------------------------------------------------------------------
# reporting
# ---------------------------------------------------------------------------


def _describe(
    hybrids, sds_hybrid, global_indices, layout, mf, n_atoms, lewis_mode
) -> dict[str, Any]:
    """Turn the optimised hybrids into the reported orbitals."""
    orbitals: list[dict[str, Any]] = []
    summary = {"bonding": 0.0, "antiBonding": 0.0, "lonePairs": 0.0, "rydberg": 0.0}
    counts = {"bonding": 0, "antiBonding": 0, "lonePairs": 0, "rydberg": 0}
    # The valence is how many of an atom's hybrids went into a bond, which is
    # counted per atom rather than per reported orbital.
    valences = [
        int(np.count_nonzero(hybrids[centre].friend_atom[: hybrids[centre].n_valid] != -1))
        for centre in range(n_atoms)
    ]

    for centre in range(n_atoms):
        element = mf.mol.atom_symbol(centre)
        for j in range(hybrids[centre].n_valid):
            index = global_indices[centre][j]
            friend = int(hybrids[centre].friend_atom[j])
            if friend == -1:
                occupancy = float(sds_hybrid[index, index])
                kind = "lonePairs" if occupancy > 1.0 else "rydberg"
                summary[kind] += occupancy
                counts[kind] += 1
                orbitals.append(
                    {
                        "type": kind,
                        "occupancy": round(occupancy, 5),
                        "centres": [centre],
                        "elements": [element],
                        "label": f"{element}{centre + 1}",
                        "composition": [
                            {"centre": centre, "element": element, "hybrid": j + 1,
                             "coefficient": 1.0}
                        ],
                    }
                )
                continue
            friend_hybrid = int(hybrids[centre].friend_hybrid[j])
            partner = int(global_indices[friend][friend_hybrid])
            if partner <= index:
                continue
            block = np.array(
                [
                    [sds_hybrid[index, index], sds_hybrid[index, partner]],
                    [sds_hybrid[index, partner], sds_hybrid[partner, partner]],
                ]
            )
            values, vectors = np.linalg.eigh(block)
            order = np.argsort(values)[::-1]
            values = values[order]
            vectors = vectors[:, order]
            other_element = mf.mol.atom_symbol(friend)
            label = f"{element}{centre + 1}-{other_element}{friend + 1}"
            ionic = float(
                np.cos(
                    np.arctan2(
                        2.0 * sds_hybrid[index, partner],
                        abs(sds_hybrid[index, index] - sds_hybrid[partner, partner]),
                    )
                )
            )
            summary["bonding"] += float(values[0])
            summary["antiBonding"] += float(values[1])
            counts["bonding"] += 1
            counts["antiBonding"] += 1
            orbitals.append(
                {
                    "type": "bonding",
                    "occupancy": round(float(values[0]), 5),
                    "centres": [centre, friend],
                    "elements": [element, other_element],
                    "label": label,
                    "ionicCharacter": round(ionic, 4),
                    "composition": [
                        {"centre": centre, "element": element, "hybrid": j + 1,
                         "coefficient": round(float(vectors[0, 0]), 4)},
                        {"centre": friend, "element": other_element,
                         "hybrid": friend_hybrid + 1, "coefficient": round(float(vectors[1, 0]), 4)},
                    ],
                }
            )
            orbitals.append(
                {
                    "type": "antiBonding",
                    "occupancy": round(float(values[1]), 5),
                    "centres": [centre, friend],
                    "elements": [element, other_element],
                    "label": label,
                    "composition": [
                        {"centre": centre, "element": element, "hybrid": j + 1,
                         "coefficient": round(float(vectors[0, 1]), 4)},
                        {"centre": friend, "element": other_element,
                         "hybrid": friend_hybrid + 1, "coefficient": round(float(vectors[1, 1]), 4)},
                    ],
                }
            )

    return {
        "kind": "CLPO" if lewis_mode else "LPO",
        "orbitals": orbitals,
        "valences": valences,
        "occupancySummary": {k: round(v, 5) for k, v in summary.items()},
        "counts": counts,
        "analysisMethod": "LPO/CLPO (JANPA 2.02 port)",
    }
