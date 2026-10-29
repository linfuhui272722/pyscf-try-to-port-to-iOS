"""Natural orbital analysis: NAO/NPA, Wiberg bond orders and CLPOs.

This is a faithful port of the JANPA package (version 2.02) of
T. Yu. Nikolaienko, L. A. Bulavin and D. M. Hovorun, which is an independent
open-source implementation of Weinhold's natural population analysis.  JANPA
is distributed under a BSD-style licence that permits redistribution provided
the copyright notice, the list of conditions and the following acknowledgement
travel with the code:

    This product includes components from JANPA package of programs
    ( http://janpa.sourceforge.net/ ) developed by Tymofii Nikolaienko

JANPA is written in Java and reads MOLDEN files.  This module performs the
same algebra directly on the PySCF objects the engine already has, so no
MOLDEN round-trip and no Java runtime are needed.  Everything is expressed in
numpy against PySCF's AO basis, which is already contraction-major: within one
shell PySCF lists the first contraction of every component before the second
contraction of the first component, exactly the layout JANPA calls a "radial
part".

References
----------
* A. E. Reed, R. B. Weinstock, F. Weinhold, J. Chem. Phys. 83 (1985) 735.
* K. Wiberg, Tetrahedron 24 (1968) 1083.
* I. Mayer, Int. J. Quantum Chem. 29 (1986) 477.
* T. Y. Nikolaienko, L. A. Bulavin, Int. J. Quantum Chem. 119 (2019) e25798.
* T. Y. Nikolaienko, L. A. Bulavin, D. M. Hovorun, Comput. Theor. Chem.
  1050 (2014) 15.

The implementation reproduces JANPA's seven-step NAO construction literally,
including its idiosyncrasies, because the point of the port is to agree with
the reference program to the last digit:

1. intra-centre naturalization of the atomic basis functions into PNAOs,
2. splitting the PNAOs into the natural minimal basis (NMB) and the natural
   Rydberg basis (NRB) by occupancy and the ground-state configuration table,
3. occupancy-weighted orthogonalization of the NMB,
4. Schmidt orthogonalization of the NRB against the new NMB,
5. intra-centre naturalization of the NRB,
6. occupancy-weighted orthogonalization of the naturalized NRB (heavy
   functions by the weighted square root, light ones by Schmidt plus Loewdin),
7. a final intra-centre naturalization over the whole set.

The NPA charges and the Wiberg bond orders are then read off the S.D.S matrix
in the resulting NAO basis.
"""

from __future__ import annotations

from typing import Any

import numpy as np

__all__ = [
    "natural_orbitals",
    "wiberg_bond_orders",
    "natural_population_analysis",
]

# JANPA's ground-state table: for each angular momentum and nuclear charge, the
# number of functions that belong to the natural minimal basis.  Rows are
# s, p, d, f, g; columns are Z = 1..86.  Copied from NPA.java so that the NMB /
# NRB split matches the reference program exactly.
_NMB_PER_ATOM = (
    # s
    (1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4,
     4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5, 5, 5, 5, 5, 5, 4, 5, 5,
     5, 5, 5, 5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
     6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6),
    # p
    (0, 0, 0, 0, 3, 3, 3, 3, 3, 3, 3, 3, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
     6, 6, 6, 6, 6, 6, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
     12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
     12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 15, 15,
     15, 15),
    # d
    (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 5, 5, 5,
     5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 10, 10, 10, 10, 10, 10, 10,
     10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 15, 15, 10, 10, 10,
     10, 10, 15, 10, 10, 10, 10, 10, 10, 15, 15, 15, 15, 15, 15, 15, 15, 15,
     15, 15, 15, 15, 15),
    # f
    (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
     7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7),
    # g
    (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
)

# JANPA keeps only the functions heavier than this occupancy in the "heavy" NRB
# set during step 6; everything lighter goes through Schmidt + Loewdin.
_HEAVY_NRB_THRESHOLD = 1.0e-4

_SHELL_LETTERS = "spdfgh"


def _matrix_sqrt(matrix: np.ndarray, inverse: bool = False) -> np.ndarray:
    """Symmetric square root (or inverse square root) of a symmetric matrix.

    ``EigenEngine.Matrix_SQRT`` in JANPA.  ``numpy.linalg.eigh`` returns
    eigenvalues in ascending order, the same order JAMA uses, so no explicit
    sort is needed to stay in step with the reference.  Eigenvalues that a
    positive-semidefinite matrix produces as tiny negatives through round-off
    are clipped before the root is taken.
    """
    matrix = np.asarray(matrix, dtype=float)
    values, vectors = np.linalg.eigh(matrix)
    values = np.where(values < 0.0, 0.0, values)
    roots = 1.0 / np.sqrt(values) if inverse else np.sqrt(values)
    # vecs[i, k] * roots[k] * vecs[j, k] summed over k, i.e. V.diag(roots).V^T
    return (vectors * roots) @ vectors.T


def _generalized_evd_symmetric(
    matrix: np.ndarray, overlap: np.ndarray
) -> tuple[np.ndarray, np.ndarray]:
    """Solve ``A x = lambda S x`` for symmetric ``A`` and positive ``S``.

    ``EigenEngine.Generalized_EVD_SymmMatr``.  Returns ``(values, vectors)``
    where the columns of ``vectors`` are the ``S``-orthonormal eigenvectors.
    """
    overlap_sqrt = _matrix_sqrt(overlap, inverse=False)
    overlap_sqrt_inv = np.linalg.inv(overlap_sqrt)
    transformed = overlap_sqrt_inv @ matrix @ overlap_sqrt_inv
    values, vectors = np.linalg.eigh(transformed)
    return values, overlap_sqrt_inv @ vectors


class _BasisLayout:
    """Per-AO bookkeeping of the atomic basis, in JANPA's radial-part terms.

    PySCF numbers the functions of a shell contraction-major, which is exactly
    the layout JANPA's MOLDEN reader produces.  ``radial`` is the index of the
    contracted function and ``component`` its magnetic index within the
    ``2l+1`` functions of that contraction.
    """

    def __init__(self, mol) -> None:
        atom: list[int] = []
        angular: list[int] = []
        radial: list[int] = []
        component: list[int] = []
        radial_id = 0
        for shell in mol._bas:
            shell_atom = int(shell[0])
            shell_angular = int(shell[1])
            contractions = int(shell[3])
            for _contraction in range(contractions):
                for magnetic in range(2 * shell_angular + 1):
                    atom.append(shell_atom)
                    angular.append(shell_angular)
                    radial.append(radial_id)
                    component.append(magnetic)
                radial_id += 1
        self.atom = np.asarray(atom)
        self.angular = np.asarray(angular)
        self.radial = np.asarray(radial)
        self.component = np.asarray(component)
        self.n_atoms = mol.natm
        self.n_basis = len(atom)

    @classmethod
    def subset(cls, layout: "_BasisLayout", indices: np.ndarray) -> "_BasisLayout":
        """The same bookkeeping restricted to a subset of the functions."""
        subset = cls.__new__(cls)
        subset.atom = layout.atom[indices]
        subset.angular = layout.angular[indices]
        subset.radial = layout.radial[indices]
        subset.component = layout.component[indices]
        subset.n_atoms = layout.n_atoms
        subset.n_basis = int(indices.size)
        return subset


def _intracenter_naturalization(
    overlap: np.ndarray,
    sds: np.ndarray,
    layout: _BasisLayout,
) -> tuple[np.ndarray, np.ndarray]:
    """Intra-centre naturalization of a set of functions.

    ``NPA.IntracenterBasisOrthogonalization``.  For every centre and every
    angular momentum the radial parts are collected, an averaged local overlap
    and S.D.S matrix is built by summing over pairs of functions that carry the
    same magnetic component, and the generalized eigenproblem
    ``SDS x = lambda S x`` is solved.  The eigenvectors are the new functions
    and the eigenvalues their occupancies (the "weights").

    Returns ``(coefficients, weights)`` with ``coefficients[i, j]`` the
    expansion of new function ``i`` over old function ``j``.  One new function
    comes out per input function and in the same order, carrying that
    function's centre, angular momentum, magnetic component and radial part,
    which is what the caller relies on to keep its bookkeeping aligned.
    """
    n_basis = overlap.shape[0]
    coefficients = np.zeros((n_basis, n_basis))
    weights = np.zeros(n_basis)

    centre_order = [np.where(layout.atom == centre)[0] for centre in range(layout.n_atoms)]

    new_index = 0
    for centre in range(layout.n_atoms):
        functions_here = centre_order[centre]
        if functions_here.size == 0:
            continue
        angular_here = layout.angular[functions_here]

        for angular in range(int(angular_here.max()) + 1):
            this_l = functions_here[angular_here == angular]
            if this_l.size == 0:
                continue

            # The distinct radial parts among them, in order of appearance.
            radial_ids: list[int] = []
            for function in this_l:
                identifier = int(layout.radial[function])
                if identifier not in radial_ids:
                    radial_ids.append(identifier)
            radial_slot = {identifier: slot for slot, identifier in enumerate(radial_ids)}
            n_radial = len(radial_ids)

            # Local overlap and S.D.S, summed over pairs of functions that share
            # a magnetic component and connect the two radial parts.
            local_overlap = np.zeros((n_radial, n_radial))
            local_sds = np.zeros((n_radial, n_radial))
            for first in range(n_radial):
                for second in range(first, n_radial):
                    count = 0
                    for i in this_l:
                        for j in this_l:
                            if layout.component[i] != layout.component[j]:
                                continue
                            i_first = radial_slot[int(layout.radial[i])] == first
                            i_second = radial_slot[int(layout.radial[i])] == second
                            j_first = radial_slot[int(layout.radial[j])] == first
                            j_second = radial_slot[int(layout.radial[j])] == second
                            if (i_first and j_second) or (i_second and j_first):
                                count += 1
                                local_overlap[first, second] += overlap[i, j]
                                local_sds[first, second] += sds[i, j]
                    if count > 0:
                        local_overlap[first, second] /= count
                        local_sds[first, second] /= count
                    local_overlap[second, first] = local_overlap[first, second]
                    local_sds[second, first] = local_sds[first, second]

            values, vectors = _generalized_evd_symmetric(local_sds, local_overlap)

            # One new function per input function, in input order.  Its weight
            # is the eigenvalue of the radial part it came from, and it takes
            # coefficients from every radial part of this (centre, L) that
            # carries the same magnetic component.
            for source in this_l:
                source_radial = radial_slot[int(layout.radial[source])]
                weights[new_index] = values[source_radial]
                for target in this_l:
                    if layout.component[target] != layout.component[source]:
                        continue
                    target_radial = radial_slot[int(layout.radial[target])]
                    coefficients[new_index, target] = vectors[target_radial, source_radial]
                new_index += 1

    return coefficients, weights


def _nmb_count(angular: int, charge: int) -> int:
    """Number of natural-minimal-basis functions of this angular momentum."""
    if angular >= len(_NMB_PER_ATOM):
        return 0
    row = _NMB_PER_ATOM[angular]
    if charge <= 0 or charge > len(row):
        return 0
    return int(row[charge - 1])


class _NaoBasis:
    """The natural atomic orbitals of one molecule, with their occupancies."""

    def __init__(
        self,
        mol,
        layout: _BasisLayout,
        nao_to_ao: np.ndarray,
        occupancies: np.ndarray,
        is_rydberg: np.ndarray,
        sds_nao: np.ndarray,
        overlap_nao: np.ndarray,
    ) -> None:
        self.mol = mol
        self.layout = layout
        self.nao_to_ao = nao_to_ao
        self.occupancies = occupancies
        self.is_rydberg = is_rydberg
        self.sds_nao = sds_nao
        self.overlap_nao = overlap_nao

    @property
    def n_basis(self) -> int:
        return int(self.nao_to_ao.shape[0])


def _build_naos(mol, overlap: np.ndarray, sds: np.ndarray, layout: _BasisLayout) -> _NaoBasis:
    """Run JANPA's seven-step NAO construction and return the resulting basis."""
    n_basis = overlap.shape[0]
    n_atoms = layout.n_atoms

    # Step 1: intra-centre naturalization of the atomic basis -> PNAOs.
    pnao_to_ao, pnao_weights = _intracenter_naturalization(overlap, sds, layout)

    # Step 2: sort the PNAOs by descending occupancy and label each one NMB or
    # NRB by comparing its rank within (centre, angular momentum) with the
    # ground-state table.
    order = np.argsort(-pnao_weights, kind="stable")
    is_rydberg = np.zeros(n_basis, dtype=bool)
    for centre in range(n_atoms):
        used = {angular: 0 for angular in range(len(_SHELL_LETTERS))}
        allowed_cache: dict[int, int] = {}
        for index in order:
            if layout.atom[index] != centre:
                continue
            angular = int(layout.angular[index])
            used[angular] += 1
            if angular not in allowed_cache:
                allowed_cache[angular] = _nmb_count(angular, int(mol.atom_charge(centre)))
            if used[angular] > allowed_cache[angular]:
                is_rydberg[index] = True

    nmb_numbers = np.where(~is_rydberg)[0]
    nrb_numbers = np.where(is_rydberg)[0]
    n_nmb = nmb_numbers.size
    n_nrb = nrb_numbers.size

    pnao_overlap = pnao_to_ao @ overlap @ pnao_to_ao.T
    pnao_sds = pnao_to_ao @ sds @ pnao_to_ao.T

    # Step 3: occupancy-weighted orthogonalization of the NMB.
    ow1 = np.zeros((n_basis, n_basis))
    ow1[nrb_numbers, nrb_numbers] = 1.0
    if n_nmb:
        weights = pnao_weights[nmb_numbers]
        weighted = (pnao_overlap[np.ix_(nmb_numbers, nmb_numbers)] * weights).T * weights
        weighted = 0.5 * (weighted + weighted.T)
        # OW = W . (W.S.W)^(-1/2), transposed on insertion.
        ow1[np.ix_(nmb_numbers, nmb_numbers)] = (
            np.diag(weights) @ _matrix_sqrt(weighted, inverse=True)
        ).T

    overlap_new = ow1 @ pnao_overlap @ ow1.T
    sds_new = ow1 @ pnao_sds @ ow1.T

    # Step 4: Schmidt orthogonalization of the NRB against the new NMB.
    os1 = np.zeros((n_basis, n_basis))
    if n_nrb:
        nrb_to_pnao = np.zeros((n_nrb, n_basis))
        nrb_to_pnao[np.arange(n_nrb), nrb_numbers] = 1.0
        if n_nmb:
            nrb_to_pnao[:, nmb_numbers] -= overlap_new[np.ix_(nmb_numbers, nrb_numbers)].T
        os1[nrb_numbers] = nrb_to_pnao
    os1[nmb_numbers, nmb_numbers] = 1.0
    overlap_new = os1 @ overlap_new @ os1.T
    sds_new = os1 @ sds_new @ os1.T

    # Step 5: intra-centre naturalization of the NRB.
    on2 = np.zeros((n_basis, n_basis))
    on2[nmb_numbers, nmb_numbers] = 1.0
    if n_nrb:
        nrb_coefficients, nrb_weights = _intracenter_naturalization(
            overlap_new[np.ix_(nrb_numbers, nrb_numbers)],
            sds_new[np.ix_(nrb_numbers, nrb_numbers)],
            _BasisLayout.subset(layout, nrb_numbers),
        )
        on2[np.ix_(nrb_numbers, nrb_numbers)] = nrb_coefficients
    else:
        nrb_weights = np.zeros(0)
    overlap_new = on2 @ overlap_new @ on2.T
    sds_new = on2 @ sds_new @ on2.T

    # Step 6: occupancy-weighted orthogonalization of the naturalized NRB.
    ow2 = np.zeros((n_basis, n_basis))
    ow2[nmb_numbers, nmb_numbers] = 1.0
    if n_nrb:
        nrb_overlap_new = overlap_new[np.ix_(nrb_numbers, nrb_numbers)]
        heavy = np.where(nrb_weights > _HEAVY_NRB_THRESHOLD)[0]
        light = np.where(nrb_weights <= _HEAVY_NRB_THRESHOLD)[0]
        nrb_transform = np.eye(n_nrb)
        if heavy.size:
            heavy_weights = nrb_weights[heavy]
            weighted = (nrb_overlap_new[np.ix_(heavy, heavy)] * heavy_weights).T * heavy_weights
            weighted = 0.5 * (weighted + weighted.T)
            nrb_transform[np.ix_(heavy, heavy)] = (
                np.diag(heavy_weights) @ _matrix_sqrt(weighted, inverse=True)
            )
            # The full transform is OW . OS^T, where OS carries the Schmidt
            # projections of the light functions onto the heavy ones.  JANPA
            # measures every intermediate overlap as OW^T . S . OW.
            updated = nrb_transform.T @ nrb_overlap_new @ nrb_transform
            schmidt = np.eye(n_nrb)
            schmidt[np.ix_(light, heavy)] -= updated[np.ix_(light, heavy)]
            nrb_transform = nrb_transform @ schmidt.T
            updated = nrb_transform.T @ nrb_overlap_new @ nrb_transform
            if light.size:
                lowdin = np.eye(n_nrb)
                lowdin[np.ix_(light, light)] = _matrix_sqrt(
                    updated[np.ix_(light, light)], inverse=True
                )
                nrb_transform = nrb_transform @ lowdin.T
        else:
            # No heavy functions: Loewdin-orthogonalize the whole NRB set.
            nrb_transform = _matrix_sqrt(nrb_overlap_new, inverse=True)
        ow2[np.ix_(nrb_numbers, nrb_numbers)] = nrb_transform.T

    overlap_new = ow2 @ overlap_new @ ow2.T
    sds_new = ow2 @ sds_new @ ow2.T

    # Step 7: final intra-centre naturalization over the whole set.
    nao_coefficients, _ = _intracenter_naturalization(overlap_new, sds_new, layout)
    nao_to_ao = nao_coefficients @ ow2 @ on2 @ os1 @ ow1 @ pnao_to_ao

    overlap_nao = nao_to_ao @ overlap @ nao_to_ao.T
    sds_nao = nao_to_ao @ sds @ nao_to_ao.T

    return _NaoBasis(
        mol=mol,
        layout=layout,
        nao_to_ao=nao_to_ao,
        # Occupancies are the diagonal of S.D.S in the NAO basis.
        occupancies=np.diag(sds_nao),
        is_rydberg=is_rydberg,
        sds_nao=sds_nao,
        overlap_nao=overlap_nao,
    )


def _density_matrices(mf) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """``(overlap, density, S.D.S)`` for a mean-field object, total density."""
    mol = mf.mol
    overlap = np.asarray(mol.intor_symmetric("int1e_ovlp"), dtype=float)
    density = np.asarray(mf.make_rdm1(), dtype=float)
    if density.ndim == 3:
        # ROHF and UHF hand back one matrix per spin; NAO theory needs the total.
        density = density[0] + density[1]
    density = 0.5 * (density + density.T)
    return overlap, density, overlap @ density @ overlap


def _natural_configuration(layout: _BasisLayout, basis: "_NaoBasis", centre: int) -> dict[str, float]:
    """The natural electron configuration of one centre.

    NAOs are grouped by radial part -- the components of one contracted
    function share a shell -- and the groups are ranked by their summed
    occupancy, which is what fixes the principal quantum number: the most
    occupied s group is 1s, the next 2s, and so on.  Ranking by occupancy
    rather than by the basis set's own contraction order keeps the labels
    chemical: JANPA's step 7 can hand the 2.0-occupancy NAO of oxygen to the
    third radial part, and reading the basis label through unchanged would call
    the core shell "3s".
    """
    configuration: dict[str, float] = {}
    for angular in range(len(_SHELL_LETTERS)):
        mask = (layout.atom == centre) & (layout.angular == angular)
        if not mask.any():
            continue
        radial_ids = np.unique(layout.radial[mask])
        groups = [
            float(basis.occupancies[mask & (layout.radial == radial_id)].sum())
            for radial_id in radial_ids
        ]
        groups.sort(reverse=True)
        for rank, occupancy in enumerate(groups, start=1):
            shell = f"{angular + rank}{_SHELL_LETTERS[angular]}"
            configuration[shell] = round(occupancy, 7)
    return configuration


def _npa_from_basis(mf, layout: _BasisLayout, basis: _NaoBasis) -> dict[str, Any]:
    """The NPA half of the analysis, read off an already-built NAO basis."""
    mol = mf.mol
    occupancies = basis.occupancies
    n_basis = basis.n_basis

    per_atom = []
    for centre in range(layout.n_atoms):
        on_centre = layout.atom == centre
        population = float(occupancies[on_centre].sum())
        nmb_population = float(occupancies[on_centre & ~basis.is_rydberg].sum())
        per_atom.append(
            {
                "index": centre,
                "element": mol.atom_symbol(centre),
                "nuclearCharge": float(mol.atom_charge(centre)),
                "population": round(population, 7),
                "minimalBasisPopulation": round(nmb_population, 7),
                "charge": round(float(mol.atom_charge(centre)) - population, 7),
                "configuration": _natural_configuration(layout, basis, centre),
            }
        )

    angular_populations = []
    for centre in range(layout.n_atoms):
        contributions = {}
        for angular in range(len(_SHELL_LETTERS)):
            mask = (layout.atom == centre) & (layout.angular == angular)
            if not mask.any():
                continue
            contributions[_SHELL_LETTERS[angular]] = round(float(occupancies[mask].sum()), 7)
        angular_populations.append(contributions)

    orbitals = []
    for index in range(n_basis):
        leading = int(np.argmax(np.abs(basis.nao_to_ao[index])))
        orbitals.append(
            {
                "index": index + 1,
                "atom": int(layout.atom[index]),
                "element": mol.atom_symbol(int(layout.atom[index])),
                "angular": _SHELL_LETTERS[int(layout.angular[index])],
                "occupancy": round(float(occupancies[index]), 7),
                "rydberg": bool(basis.is_rydberg[index]),
                "leadingAo": int(leading),
                "leadingCoefficient": round(float(basis.nao_to_ao[index, leading]), 6),
            }
        )

    # The NAO overlap should be the unit matrix; report how far off it is so the
    # UI can show the transform as self-checked.
    orthogonality_error = float(
        np.sqrt(np.sum((basis.overlap_nao - np.eye(n_basis)) ** 2))
    )

    return {
        "perAtom": per_atom,
        "angularPopulations": angular_populations,
        "orbitals": orbitals,
        "nElectrons": int(mol.nelectron),
        "totalPopulation": round(float(occupancies.sum()), 7),
        "nmbFunctions": int(np.count_nonzero(~basis.is_rydberg)),
        "nrbFunctions": int(np.count_nonzero(basis.is_rydberg)),
        "orthogonalityError": orthogonality_error,
        "sumRuleOk": abs(float(occupancies.sum()) - mol.nelectron) < 1e-6,
        "analysisMethod": "NAO/NPA (JANPA 2.02 port)",
    }


def _wiberg_from_basis(mf, layout: _BasisLayout, basis: _NaoBasis) -> dict[str, Any]:
    """Wiberg-Mayer bond orders, read off an already-built NAO basis."""
    mol = mf.mol
    product = basis.sds_nao * basis.sds_nao.T
    bonds = np.zeros((layout.n_atoms, layout.n_atoms))
    for i in range(basis.n_basis):
        for j in range(i + 1, basis.n_basis):
            bonds[layout.atom[i], layout.atom[j]] += product[i, j]
    bonds = bonds + bonds.T
    # JANPA reports the diagonal as the atomic valence, the sum of that atom's
    # bond orders to *other* atoms, so same-centre NAO pairs are dropped rather
    # than folded into the diagonal.
    np.fill_diagonal(bonds, 0.0)
    valence = bonds.sum(axis=1)

    matrix = []
    for a in range(layout.n_atoms):
        row = []
        for b in range(layout.n_atoms):
            value = valence[a] if a == b else bonds[a, b]
            row.append(round(float(value), 5))
        matrix.append(row)

    bond_list = []
    for a in range(layout.n_atoms):
        for b in range(a + 1, layout.n_atoms):
            distance = float(np.linalg.norm(mol.atom_coord(a) - mol.atom_coord(b)))
            bond_list.append(
                {
                    "i": a,
                    "j": b,
                    "elements": [mol.atom_symbol(a), mol.atom_symbol(b)],
                    "order": round(float(bonds[a, b]), 5),
                    "distance": round(distance, 5),
                }
            )

    return {
        "matrix": matrix,
        "atoms": [mol.atom_symbol(i) for i in range(layout.n_atoms)],
        "valences": [round(float(v), 5) for v in valence],
        "bonds": bond_list,
        "analysisMethod": "Wiberg-Mayer (NAO basis)",
    }


def analyze(mf, atoms: list[dict]) -> dict[str, Any]:
    """Every NAO-based analysis of one wavefunction, from a single transform.

    Building the NAO basis is the expensive part, so the NPA charges, the
    orbital detail and the Wiberg bond orders are all derived from one build
    rather than repeating the seven steps three times.  ``npa`` is the compact
    charge summary the engine has always stored; ``naturalOrbitals`` is the
    full payload, orbitals included.
    """
    result: dict[str, Any] = {"npa": None, "naturalOrbitals": None, "wiberg": None}
    try:
        layout = _BasisLayout(mf.mol)
        overlap, _density, sds = _density_matrices(mf)
        basis = _build_naos(mf.mol, overlap, sds, layout)
        full = _npa_from_basis(mf, layout, basis)
        result["naturalOrbitals"] = full
        result["npa"] = _compact_npa(full)
        result["wiberg"] = _wiberg_from_basis(mf, layout, basis)
    except Exception:
        return result
    return result


def _compact_npa(full: dict[str, Any]) -> dict[str, Any]:
    """Project the full NAO payload down to the historical ``npa`` shape."""
    per_atom = [
        {
            "index": entry["index"],
            "element": entry["element"],
            "population": entry["population"],
            "charge": entry["charge"],
            # The electron configuration and the per-atom index travel with the
            # charges: the panel labels each row by index and prints the
            # configuration underneath, and rebuilding either from the element
            # would mislabel repeated atoms.
            "configuration": entry["configuration"],
        }
        for entry in full["perAtom"]
    ]
    totals: dict[str, float] = {}
    for entry in per_atom:
        totals[entry["element"]] = totals.get(entry["element"], 0.0) + entry["charge"]
    return {
        "perAtom": per_atom,
        "perElement": {k: round(v, 6) for k, v in sorted(totals.items())},
        "nElectrons": full["nElectrons"],
        "totalPopulation": full["totalPopulation"],
        "sumRuleOk": full["sumRuleOk"],
        "analysisMethod": full["analysisMethod"],
    }


def natural_orbitals(mf, atoms: list[dict]) -> dict[str, Any] | None:
    """Full NAO/NPA analysis of a converged mean-field object.

    ``mf`` is any PySCF SCF object whose ``mol`` carries the basis set.
    Returns ``None`` when the analysis cannot run so a caller can leave the
    field out rather than fail an otherwise fine calculation.
    """
    try:
        layout = _BasisLayout(mf.mol)
        overlap, _density, sds = _density_matrices(mf)
        basis = _build_naos(mf.mol, overlap, sds, layout)
        return _npa_from_basis(mf, layout, basis)
    except Exception:
        return None


def wiberg_bond_orders(mf, atoms: list[dict]) -> dict[str, Any] | None:
    """Wiberg-Mayer bond orders in the NAO basis.

    Uses Mayer's spin-resolved definition ``B_AB = sum (S.D.S)_ij (S.D.S)_ji``
    over NAOs on A and B.  JANPA reads these off the S.D.S matrix in the NAO
    basis; the diagonal is the atomic valence, the sum of that atom's bond
    orders.
    """
    try:
        layout = _BasisLayout(mf.mol)
        overlap, _density, sds = _density_matrices(mf)
        basis = _build_naos(mf.mol, overlap, sds, layout)
        return _wiberg_from_basis(mf, layout, basis)
    except Exception:
        return None


def natural_population_analysis(mf, atoms: list[dict]) -> dict[str, Any] | None:
    """Compatibility wrapper returning the NPA charges in the historical shape.

    ``engine`` has always stored the result under the ``npa`` key with this
    layout, and the Swift models and the saved history depend on it, so the
    richer ``natural_orbitals`` payload is projected back down here.
    """
    analysis = natural_orbitals(mf, atoms)
    if analysis is None:
        return None
    return _compact_npa(analysis)
