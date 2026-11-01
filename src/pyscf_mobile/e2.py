"""Second-order perturbation energies, E(2), on top of the Lewis orbitals.

E(2) is the stabilisation a filled orbital gains by mixing with a nearby empty
one.  It is the quantity an NBO analysis is usually quoted for, and it answers
"where does this molecule's extra stability come from" — the lone pair on an
oxygen pushing into an O-H antibond, and so on.

The expression is the standard second-order perturbation of the Fock matrix:

    E(2)_{i->j} = -n_i * |F_{ij}|^2 / (eps_j - eps_i)

with ``n_i`` the donor's occupancy.  What makes the numbers come out right is
which orbitals are used, and getting that wrong is easy in a way that is not
obvious from the result — see the note on ``localized_orbitals.lewis_orbitals``.
In short:

* The donors and acceptors are the **Lewis orbitals** — bonds, lone pairs and
  their antibond and Rydberg partners — not canonical molecular orbitals.  The
  two canonical spaces are individually orthonormal but not orthogonal to each
  other, and for a converged reference the coupling *within* them vanishes
  anyway: Brillouin's theorem makes the canonical occupied-virtual Fock block
  zero, so a canonical E(2) would report essentially nothing while the
  stabilisation it is meant to measure is real.  Measured on water in 6-31G the
  canonical block is 2e-7 against a Lewis coupling of 7e-2.
* The Lewis orbitals are orthonormal across the whole molecule, so the matrix
  element is the interaction and nothing else.  That is the property being
  relied on here.

The energy denominators are the diagonal Fock elements in the same orbital set.
For a localised orbital that diagonal is not an orbital energy a user would
recognise, and it is not meant to be: it is the expectation value of the Fock
operator in that orbital, which is what the perturbation series requires.

Both sets are rotated to diagonalise the Fock matrix within themselves before
the sum is formed; ``_fock_adapt`` explains why that is necessary and not
cosmetic.

Only closed-shell references are analysed.  An unrestricted reference has
separate alpha and beta Fock matrices and separate Lewis structures, and pairing
one spin's Fock matrix with the total-density orbitals would give a number that
looks plausible and is not; the analysis declines instead.
"""

from __future__ import annotations

import numpy as np

from . import localized_orbitals

__all__ = ["compute", "HARTREE_TO_KCAL"]

#: CODATA hartree, in kcal/mol.  NBO reports E(2) in kcal/mol, so that is the
#: unit the numbers are quoted in.
HARTREE_TO_KCAL = 627.5094740631

#: kcal/mol per electronvolt, for the electronvolt conversion below.
_KCAL_PER_EV = 23.060548867

#: Hartree per electronvolt, for the gap conversion below.
_EV_PER_HARTREE = 27.211386245988

#: Orbital kinds that can donate.  A bond and a lone pair both hold electrons.
_DONOR_TYPES = ("bonding", "lonePair")

#: Orbital kinds that can accept.  An antibond and a Rydberg orbital are both
#: empty or nearly so.
_ACCEPTOR_TYPES = ("antiBonding", "rydberg")

#: Interactions weaker than this are left out of the returned table; they are
#: still counted in the total.  The figure is in kcal/mol, which is the unit the
#: energies are quoted in, and it sits below NBO's own default listing threshold
#: of 0.5 kcal/mol so nothing a chemist would quote is dropped while the payload
#: stays small enough for a phone.
_DEFAULT_THRESHOLD_KCAL = 0.05

#: Cap on the number of interactions returned, largest first.
_DEFAULT_MAX_INTERACTIONS = 200


def _symmetrised_fock(mf) -> np.ndarray:
    """The Fock matrix, symmetrised.

    A converged SCF should give a symmetric Fock matrix, but the two triangles
    can differ by round-off and the perturbation expression reads a single
    element, so an asymmetric input would make ``E(2)`` depend on which triangle
    happened to be read.  Symmetrising removes that ambiguity.
    """
    fock = np.asarray(mf.get_fock(), dtype=float)
    if fock.ndim == 3:
        raise ValueError(
            "E(2) needs a closed-shell reference: an unrestricted wavefunction "
            "has one Fock matrix per spin, and pairing either with the "
            "total-density orbitals would not be meaningful"
        )
    return 0.5 * (fock + fock.T)


def _fock_adapt(fock: np.ndarray, coefficients: np.ndarray, indices: list[int]):
    """Rotate a block of orbitals to diagonalise the Fock matrix within it.

    The Lewis orbitals of a molecule contain degenerate sets — water's two
    equivalent lone pairs, and the Rydberg orbitals of a basis set, which are
    empty and nearly free — and the analysis is invariant to a rotation within
    such a set only if the rotation is made consistently.  It is not made
    consistently by the orbital builder: two SCF runs that agree to 1e-14 in
    energy and density produce Rydberg vectors differing by an arbitrary
    rotation inside the manifold.  That rotation leaves the *span* fixed (checked
    directly: the projector onto it agrees to 1e-14) but moves the individual
    vectors, and E(2) sums per-pair terms whose denominators differ within the
    set, so the total moves with it — by 0.1 to 0.25 kcal/mol on water in 6-31G,
    which is larger than the interactions being reported.

    Diagonalising the Fock matrix within the block removes the ambiguity: the
    rotation is then determined by the physics rather than by the builder's
    internal ordering, and the denominators become Fock eigenvalues in the block.
    Occupancies are unaffected, because a donor block is filled and an acceptor
    block empty, so the density restricted to either is already a multiple of the
    identity and every rotation preserves it.

    Returns the rotated coefficients and the resulting Fock eigenvalues.
    """
    if not indices:
        return coefficients, np.zeros(0)
    block = coefficients[:, indices]
    submatrix = block.T @ fock @ block
    submatrix = 0.5 * (submatrix + submatrix.T)
    values, vectors = np.linalg.eigh(submatrix)
    return block @ vectors, values


def compute(
    mf,
    atoms: list[dict],
    *,
    kind: str = "clpo",
    threshold_kcal: float = _DEFAULT_THRESHOLD_KCAL,
    max_interactions: int = _DEFAULT_MAX_INTERACTIONS,
) -> dict:
    """E(2) for every donor-acceptor pair of a converged mean field.

    ``kind`` selects the Lewis orbital set from ``localized_orbitals``:
    ``"clpo"`` for the chemist's orbitals, which keep lone pairs on their own
    atom, or ``"lpo"`` for the plain ones.  ``threshold_kcal`` is the smallest
    interaction, in kcal/mol, that is listed.
    """
    fock = _symmetrised_fock(mf)

    orbitals = localized_orbitals.lewis_orbitals(mf, atoms, kind=kind)
    if orbitals is None:
        raise ValueError(
            "the Lewis orbital analysis could not run for this wavefunction, "
            "so E(2) is unavailable"
        )

    coefficients = np.asarray(orbitals["coefficients"], dtype=float)
    occupancies = np.asarray(orbitals["occupancies"], dtype=float)
    types = list(orbitals["types"])
    labels = list(orbitals["labels"])

    donor_indices = [i for i, t in enumerate(types) if t in _DONOR_TYPES]
    acceptor_indices = [i for i, t in enumerate(types) if t in _ACCEPTOR_TYPES]
    if not donor_indices:
        raise ValueError("no filled orbitals were found to donate electron density")
    if not acceptor_indices:
        raise ValueError(
            "no empty orbitals were found to accept electron density; a larger "
            "basis set is needed for an E(2) analysis"
        )

    donors, donor_energy = _fock_adapt(fock, coefficients, donor_indices)
    acceptors, acceptor_energy = _fock_adapt(fock, coefficients, acceptor_indices)

    # The block between the two sets is the coupling.  Both sets are orthonormal
    # and they are orthogonal to each other, so this element is the interaction
    # and not partly an overlap of the two spaces.
    coupling = donors.T @ fock @ acceptors
    gap = acceptor_energy[None, :] - donor_energy[:, None]

    # E(2) = -n_i |F_ij|^2 / (eps_j - eps_i).  Only pairs with the acceptor
    # above the donor are included: the opposite ordering would describe
    # density flowing uphill, which the second-order series does not contain.
    uphill = gap <= 0.0
    safe_gap = np.where(uphill, np.inf, gap)
    donor_occupancy = np.clip(occupancies[donor_indices], 0.0, 2.0)
    energy = -donor_occupancy[:, None] * coupling ** 2 / safe_gap
    energy = np.where(uphill, 0.0, energy)

    # Every pair contributes to the total, including those too weak to list.
    total = float(energy.sum())

    # The comparison is against the kcal/mol figure, so the energy is converted
    # rather than the threshold: the threshold is the number the user set and the
    # one the report quotes, and it should be the one that is unambiguous.
    energy_kcal = energy * HARTREE_TO_KCAL
    flat_order = np.argsort(np.abs(energy_kcal).ravel())[::-1]
    interactions = []
    for flat in flat_order:
        donor_local, acceptor_local = divmod(int(flat), energy.shape[1])
        value = float(energy[donor_local, acceptor_local])
        if abs(float(energy_kcal[donor_local, acceptor_local])) < threshold_kcal:
            break
        if len(interactions) >= max_interactions:
            break
        donor_global = donor_indices[donor_local]
        acceptor_global = acceptor_indices[acceptor_local]
        interactions.append(
            {
                "donor": donor_global,
                "acceptor": acceptor_global,
                "donorLabel": labels[donor_global],
                "acceptorLabel": labels[acceptor_global],
                "donorType": types[donor_global],
                "acceptorType": types[acceptor_global],
                "energyKcal": round(value * HARTREE_TO_KCAL, 6),
                "energyEv": round(value * HARTREE_TO_KCAL / _KCAL_PER_EV, 6),
                "donorEnergy": round(float(donor_energy[donor_local]), 8),
                "acceptorEnergy": round(float(acceptor_energy[acceptor_local]), 8),
                "coupling": round(float(coupling[donor_local, acceptor_local]), 8),
                "gap": round(float(gap[donor_local, acceptor_local]), 8),
                "gapEv": round(float(gap[donor_local, acceptor_local]) * _EV_PER_HARTREE, 6),
            }
        )

    diagonal = np.einsum("ij,ij->j", coefficients, fock @ coefficients)
    return {
        "ok": True,
        "kind": orbitals["kind"],
        "donorCount": len(donor_indices),
        "acceptorCount": len(acceptor_indices),
        "totalStabilization": round(total, 10),
        "totalStabilizationKcal": round(total * HARTREE_TO_KCAL, 6),
        "interactionCount": len(interactions),
        "thresholdKcal": threshold_kcal,
        "interactions": interactions,
        "orbitals": [
            {
                "index": i,
                "label": labels[i],
                "type": types[i],
                "occupancy": round(float(occupancies[i]), 6),
                "energy": round(float(diagonal[i]), 8),
            }
            for i in range(len(types))
        ],
        "analysisMethod": (
            f"second-order perturbation energies (E(2)) from {orbitals['kind']} "
            f"Lewis orbitals (JANPA 2.02 port)"
        ),
    }
