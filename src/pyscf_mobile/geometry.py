"""Geometry helpers: parsing, bond perception and shape analysis.

Everything here is pure Python/NumPy so the same code runs in the iOS app and
in the desktop test-suite.  It deliberately avoids importing PySCF so that the
molecule builder can work before any quantum-chemistry engine is loaded.
"""

from __future__ import annotations

import math

import numpy as np

from .elements import Element, resolve


def parse_atom_spec(spec: str) -> list[dict]:
    """Parse an XYZ-style atom block.

    Accepts the PySCF notation ``"O 0 0 0; H 0 0 0.96; H 0 0.9 -0.3"`` as well
    as plain newline separated ``"O 0 0 0"`` lines.  Units are Angstrom.
    """
    if not isinstance(spec, str):
        raise TypeError("atom specification must be a string")
    text = spec.replace(";", "\n")
    atoms: list[dict] = []
    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.replace(",", " ").split()
        if len(parts) < 4:
            raise ValueError(
                f"line {lineno}: expected 'symbol x y z', got {raw!r}"
            )
        try:
            element = resolve(parts[0])
            xyz = [float(v) for v in parts[1:4]]
        except (KeyError, ValueError) as exc:
            raise ValueError(f"line {lineno}: {exc}") from exc
        atoms.append({"element": element.symbol, "z": element.z, "xyz": xyz})
    if not atoms:
        raise ValueError("no atoms found in the atom specification")
    return atoms


def atoms_to_coords(atoms: list[dict]) -> np.ndarray:
    return np.array([a["xyz"] for a in atoms], dtype=float)


def atoms_to_spec(atoms: list[dict]) -> str:
    """Serialise atoms back to the canonical ``"Sym x y z; ..."`` form."""
    return "; ".join(
        f"{a['element']} {a['xyz'][0]:.8f} {a['xyz'][1]:.8f} {a['xyz'][2]:.8f}"
        for a in atoms
    )


def formula(atoms: list[dict]) -> str:
    """Hill-order molecular formula, e.g. ``C2H6O``."""
    counts: dict[str, int] = {}
    for atom in atoms:
        counts[atom["element"]] = counts.get(atom["element"], 0) + 1
    order: list[str] = []
    if "C" in counts:
        order.append("C")
        if "H" in counts:
            order.append("H")
    order += sorted(k for k in counts if k not in order)
    return "".join(
        sym + (str(counts[sym]) if counts[sym] > 1 else "") for sym in order
    )


def molecular_mass(atoms: list[dict]) -> float:
    return sum(resolve(a["element"]).mass for a in atoms)


def total_charge_from_atoms(atoms: list[dict], charge: int) -> int:
    """Return the electron count for the given total charge."""
    protons = sum(a["z"] for a in atoms)
    return protons - charge


def _element_of(atom: dict) -> Element:
    return resolve(atom["element"])


def perceive_bonds(
    atoms: list[dict],
    tolerance: float = 1.3,
    min_distance: float = 0.4,
) -> list[tuple[int, int, float]]:
    """Infer bonds from interatomic distances vs. the sum of covalent radii.

    Returns a list of ``(i, j, length)`` triples.  ``tolerance`` scales the
    sum of the two covalent radii; 1.3 works well for organic molecules.
    """
    coords = atoms_to_coords(atoms)
    radii = np.array([_element_of(a).covalent_radius for a in atoms])
    bonds: list[tuple[int, int, float]] = []
    n = len(atoms)
    for i in range(n):
        for j in range(i + 1, n):
            dist = float(np.linalg.norm(coords[i] - coords[j]))
            if dist < min_distance:
                continue
            if dist <= tolerance * (radii[i] + radii[j]):
                bonds.append((i, j, dist))
    return bonds


def bond_lengths(atoms: list[dict], tolerance: float = 1.3) -> list[dict]:
    result = []
    for i, j, length in perceive_bonds(atoms, tolerance):
        result.append(
            {
                "i": i,
                "j": j,
                "a": atoms[i]["element"],
                "b": atoms[j]["element"],
                "length": round(length, 4),
            }
        )
    return result


def bond_angles(atoms: list[dict], tolerance: float = 1.3) -> list[dict]:
    """Valence angles (degrees) for every bonded neighbour pair around a centre."""
    bonds = perceive_bonds(atoms, tolerance)
    neighbours: dict[int, list[int]] = {}
    for i, j, _ in bonds:
        neighbours.setdefault(i, []).append(j)
        neighbours.setdefault(j, []).append(i)

    coords = atoms_to_coords(atoms)
    angles: list[dict] = []
    for centre, nbrs in sorted(neighbours.items()):
        for a in range(len(nbrs)):
            for b in range(a + 1, len(nbrs)):
                i, j = nbrs[a], nbrs[b]
                v1 = coords[i] - coords[centre]
                v2 = coords[j] - coords[centre]
                cosang = float(
                    np.dot(v1, v2) / (np.linalg.norm(v1) * np.linalg.norm(v2))
                )
                cosang = max(-1.0, min(1.0, cosang))
                angles.append(
                    {
                        "centre": centre,
                        "i": i,
                        "j": j,
                        "label": (
                            f"{atoms[i]['element']}-"
                            f"{atoms[centre]['element']}-"
                            f"{atoms[j]['element']}"
                        ),
                        "angle": round(math.degrees(math.acos(cosang)), 3),
                    }
                )
    return angles


def centre_of_mass(atoms: list[dict]) -> np.ndarray:
    masses = np.array([_element_of(a).mass for a in atoms])
    coords = atoms_to_coords(atoms)
    return (coords * masses[:, None]).sum(axis=0) / masses.sum()


def moments_of_inertia(atoms: list[dict]) -> dict:
    """Principal moments of inertia (amu*A^2) in the centre-of-mass frame."""
    masses = np.array([_element_of(a).mass for a in atoms])
    coords = atoms_to_coords(atoms) - centre_of_mass(atoms)
    tensor = np.zeros((3, 3))
    for m, r in zip(masses, coords):
        tensor += m * (np.dot(r, r) * np.eye(3) - np.outer(r, r))
    moments = np.linalg.eigvalsh(tensor)
    return {
        "moments": [round(float(m), 6) for m in moments],
        "rotationalConstantsGHz": [
            round(float(505379.006 / m), 6) if m > 1e-8 else None for m in moments
        ],
    }


def describe(atoms: list[dict]) -> dict:
    """Everything the UI needs to display a molecule's static shape."""
    com = centre_of_mass(atoms)
    coords = atoms_to_coords(atoms)
    return {
        "formula": formula(atoms),
        "atomCount": len(atoms),
        "mass": round(molecular_mass(atoms), 6),
        "centreOfMass": [round(float(v), 6) for v in com],
        "atoms": [
            {
                "index": index,
                "element": atom["element"],
                "xyz": [round(float(v), 6) for v in coords[index]],
            }
            for index, atom in enumerate(atoms)
        ],
        "bonds": bond_lengths(atoms),
        "angles": bond_angles(atoms),
        "inertia": moments_of_inertia(atoms),
    }
