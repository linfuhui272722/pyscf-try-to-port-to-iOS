"""Periodic (infinite-molecule) cells for the mobile engine.

A molecule is a finite set of nuclei; a crystal is that set repeated by a
lattice.  PySCF expresses the difference with one extra input — the lattice
vectors — and a different module tree (``pyscf.pbc`` rather than ``pyscf``), so
everything here exists to turn a cell request into that tree and a result back
into the payload shape the rest of the engine already produces.

Two periodicities are supported, and the reason there are not three is worth
stating:

* ``3`` — a crystal, periodic in all three directions;
* ``2`` — a slab, periodic in two and separated by vacuum in the third.

``1`` — a wire — is not supported by this build.  PySCF's cell builder
generates a uniform real-space grid for the lattice sums and rejects
``dimension=1`` with "Uniform grids for dimension=1 not supported"; the failure
is in the cell itself, before any solver runs, so it is not something this
module can work around.  A request for it is refused with that explanation
rather than attempted.

The lattice is always a full, non-singular ``(3, 3)`` matrix, and this is the
one convention that has to be right for a low-dimensional cell.  A slab is
written with a *vacuum vector* in the non-periodic direction — ``c = [0, 0, 15]``
for a slab with a 15 Å gap — and **not** with a row of zeros.  A zero row makes
the matrix singular, and PySCF inverts it while building the grid, so a
zero-row lattice fails with a bare ``LinAlgError: Singular matrix``.  The
periodicity is then stated separately with ``dimension``, because the matrix
cannot express it: the same vacuum vector describes a slab when the physics is
two-dimensional and a crystal when it is three.

``dimension`` therefore defaults to ``3`` and is always reported back, along
with a flag saying whether it was defaulted.  No attempt is made to infer a
slab from a long lattice vector: "long" is relative, an anisotropic crystal can
have one, and a wrong guess would give a different calculation from the one
asked for with no error to notice.  A caller that wants a slab says so.

Only the lattice vectors are needed.  PySCF's k-point mesh is derived from them
and the requested sampling, and the number of cells it sums over is derived from
the basis — so there is no second place for the geometry to go stale.
"""

from __future__ import annotations

import numpy as np

__all__ = [
    "BOHR_TO_ANGSTROM",
    "ANGSTROM_TO_BOHR",
    "cell_dimensions",
    "lattice_from_params",
    "kmesh_from_params",
    "lattice_summary",
    "pseudopotential_for",
    "is_periodic",
]

#: CODATA value, matching the constant PySCF uses for ``Bohr``.
BOHR_TO_ANGSTROM = 0.52917721092
ANGSTROM_TO_BOHR = 1.0 / BOHR_TO_ANGSTROM

#: Periodicities this build can actually run.  ``1`` is excluded because PySCF's
#: cell builder rejects it outright — see the module note.
SUPPORTED_DIMENSIONS = (2, 3)

#: The periodicity used when a request supplies a lattice but does not say how
#: many directions are periodic.
DEFAULT_DIMENSION = 3


def is_periodic(params: dict) -> bool:
    """Whether a request asks for a periodic calculation.

    Two spellings are accepted: an explicit ``periodic`` flag, and the presence
    of ``lattice``/``cell``.  The second is there because a caller that has gone
    to the trouble of supplying a lattice clearly means it to be used, and
    silently treating the calculation as molecular would give a wrong number
    without an error — the worst possible outcome for a chemistry result.
    """
    if params.get("periodic") is not None:
        return bool(params["periodic"])
    for key in ("lattice", "cell", "a"):
        if params.get(key) is not None:
            return True
    return False


def _as_matrix(value, name: str) -> np.ndarray:
    """Coerce a lattice into a ``(3, 3)`` array of row vectors."""
    if isinstance(value, dict):
        # A dict of named vectors, so a caller can write the conventional
        # a/b/c labels instead of positional rows.
        rows = []
        for key in ("a", "b", "c"):
            if key not in value:
                raise ValueError(f"lattice dict is missing vector {key!r}")
            rows.append(value[key])
        value = rows
    array = np.asarray(value, dtype=float)
    if array.shape == (3,):
        raise ValueError(
            f"{name} must be three lattice vectors, each of three numbers; "
            f"got a single vector of length 3"
        )
    if array.shape != (3, 3):
        raise ValueError(
            f"{name} must be a 3x3 array of lattice vectors, got shape {array.shape}"
        )
    if not np.all(np.isfinite(array)):
        raise ValueError(f"{name} contains a non-finite number")
    return array


def lattice_from_params(params: dict) -> np.ndarray | None:
    """The lattice vectors in Bohr, or ``None`` for a molecule.

    The UI works in ångström, like every other geometry input, so the vectors
    are converted here.  PySCF takes a cell's lattice in Bohr.
    """
    value = None
    for key in ("lattice", "cell", "a"):
        if params.get(key) is not None:
            value = params[key]
            break
    if value is None:
        return None

    array = _as_matrix(value, "lattice")
    unit = str(params.get("latticeUnit", params.get("unit", "Angstrom"))).lower()
    if unit in ("angstrom", "angs", "a", "å"):
        array = array * ANGSTROM_TO_BOHR
    elif unit in ("bohr", "au"):
        pass
    else:
        raise ValueError(f"unknown lattice unit: {params.get('latticeUnit')!r}")
    return array


def _validate_lattice(lattice: np.ndarray) -> None:
    """Reject a lattice PySCF cannot build, with a message that says why.

    Two failures are worth catching here rather than letting them surface as a
    bare ``LinAlgError`` from deep inside the grid setup:

    * a singular matrix — the usual cause is a row of zeros, which is a natural
      but wrong way to write a slab (use a vacuum vector instead);
    * a matrix whose rows are linearly dependent, which is the same problem
      without being as obvious.
    """
    array = np.asarray(lattice, dtype=float)
    if np.any(np.linalg.norm(array, axis=1) == 0.0):
        raise ValueError(
            "a lattice row is zero, which makes the cell singular and cannot be "
            "built; a slab is written with a vacuum vector in the non-periodic "
            "direction, for example c = [0, 0, 15], and then dimension = 2"
        )
    rank = int(np.linalg.matrix_rank(array))
    if rank < 3:
        raise ValueError(
            f"the lattice vectors are linearly dependent (rank {rank}); the cell "
            f"needs three independent vectors, including in the non-periodic "
            f"direction, where a vacuum vector such as [0, 0, 15] is used"
        )
    volume = float(abs(np.linalg.det(array)))
    if volume <= 0.0 or not np.isfinite(volume):
        raise ValueError("the lattice encloses no volume, so there is no cell")


def cell_dimensions(params: dict) -> int | None:
    """The periodicity to build, or ``None`` when the request is molecular.

    A stated ``dimension`` is validated against the lattice and against what this
    build supports.  When it is absent the default is three, and the caller is
    told it was defaulted — see ``dimension_was_stated`` — so that a slab is
    never produced by accident.
    """
    lattice = lattice_from_params(params)
    if lattice is None:
        return None
    _validate_lattice(lattice)
    stated = params.get("dimension")
    if stated is None:
        return DEFAULT_DIMENSION
    dimension = int(stated)
    if dimension == 1:
        raise ValueError(
            "a one-dimensional wire is not supported: PySCF's cell builder needs "
            "a uniform real-space grid, which it does not provide for dimension=1. "
            "Use dimension=2 for a slab or dimension=3 for a crystal."
        )
    if dimension not in SUPPORTED_DIMENSIONS:
        raise ValueError(
            f"dimension must be one of {SUPPORTED_DIMENSIONS}, got {dimension}"
        )
    return dimension


def dimension_was_stated(params: dict) -> bool:
    """Whether the request named a periodicity, or took the default."""
    if lattice_from_params(params) is None:
        return False
    return params.get("dimension") is not None


def kmesh_from_params(params: dict) -> list[int]:
    """The k-point sampling, defaulting to the Γ point.

    Γ alone is the default because it is the cheapest sampling and the one that
    is correct for a molecule in a box — a cell whose contents are finite.  A
    caller that wants a real crystal's sampling asks for it.
    """
    value = params.get("kmesh", params.get("kPoints"))
    if value is None:
        return [1, 1, 1]
    if isinstance(value, int):
        return [int(value)] * 3
    array = [int(v) for v in value]
    if len(array) != 3:
        raise ValueError(f"kmesh must have three entries, got {len(array)}")
    if any(v < 1 for v in array):
        raise ValueError(f"every kmesh entry must be at least 1, got {array}")
    return array


def uses_kpoints(params: dict) -> bool:
    """Whether the sampling needs the k-point (``K``-prefixed) solvers.

    Γ alone can be run with the ordinary solvers, which are both faster and
    better tested.  Anything denser needs the k-point ones.
    """
    return any(v > 1 for v in kmesh_from_params(params))


#: Elements whose default pseudopotential is a plain local one.  The choice
#: only decides which files are looked for; the values are PySCF's.
_PSEUDO_FOR_ELEMENT = {
    "H": "gth-pade",
    "He": "gth-pade",
    "Li": "gth-pade",
    "Be": "gth-pade",
    "B": "gth-pade",
    "C": "gth-pade",
    "N": "gth-pade",
    "O": "gth-pade",
    "F": "gth-pade",
    "Ne": "gth-pade",
    "Na": "gth-pade",
    "Mg": "gth-pade",
    "Al": "gth-pade",
    "Si": "gth-pade",
    "P": "gth-pade",
    "S": "gth-pade",
    "Cl": "gth-pade",
    "Ar": "gth-pade",
}


def pseudopotential_for(atoms: list[dict], requested: str | None = None) -> str | None:
    """The pseudopotential name to use for a periodic cell.

    A pseudopotential is not optional for a periodic calculation on anything but
    hydrogen and helium: the nuclear cusp makes the plane-wave-like lattice sums
    diverge, and PySCF's cell builder refuses the basis outright.  So a periodic
    request gets one whether or not it asked, and only hydrogen and helium are
    left without.

    This matters beyond the energy: the analytic lattice gradients in
    ``pyscf.pbc.grad`` are only implemented *with* a pseudopotential.  Without
    one they raise, and the numerical fallback is used instead — see
    ``_gradient_method`` in the engine.
    """
    if requested is not None:
        text = str(requested).strip()
        if text.lower() in ("none", "null", ""):
            return None
        return text
    for atom in atoms:
        symbol = str(atom.get("element", ""))
        if symbol not in ("H", "He"):
            return _PSEUDO_FOR_ELEMENT.get(symbol, "gth-pade")
    return None


def lattice_summary(lattice: np.ndarray | None, dimension: int | None) -> dict | None:
    """Report the cell back in ångström, for the UI to echo.

    Cell parameters are reported the way a crystallographer reads them — the
    three lengths and the three angles — because the matrix itself is not
    something a user can check at a glance.
    """
    if lattice is None or dimension is None:
        return None
    array = np.asarray(lattice, dtype=float) * BOHR_TO_ANGSTROM
    lengths = np.linalg.norm(array, axis=1)
    angles = []
    for i, j in ((1, 2), (0, 2), (0, 1)):
        a, b = array[i], array[j]
        cosine = float(np.dot(a, b) / (lengths[i] * lengths[j])) if lengths[i] and lengths[j] else 0.0
        angles.append(float(np.degrees(np.arccos(max(-1.0, min(1.0, cosine))))))
    return {
        "dimension": int(dimension),
        "lattice": [[round(float(v), 8) for v in row] for row in array],
        "a": round(float(lengths[0]), 8),
        "b": round(float(lengths[1]), 8),
        "c": round(float(lengths[2]), 8),
        "alpha": round(angles[0], 6),
        "beta": round(angles[1], 6),
        "gamma": round(angles[2], 6),
        "volume": round(float(abs(np.linalg.det(array))), 8),
    }
