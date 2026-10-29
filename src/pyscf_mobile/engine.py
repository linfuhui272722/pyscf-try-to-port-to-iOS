"""Quantum-chemistry engine built on top of PySCF.

The module is written so that it can be imported in three different places:

* on a normal desktop / CI machine, for testing,
* inside the embedded CPython interpreter shipped with the iOS app,
* from the command line (``python -m pyscf_mobile.engine``), which is how the
  Swift layer drives it when the in-process bridge is not used.

All public entry points return plain JSON-serialisable dictionaries so that the
Swift bridge only ever has to deal with ``Codable`` structs.
"""

from __future__ import annotations

import contextlib
import importlib
import io
import os
import sys
import time
import traceback
from typing import Any, Iterable

from . import geometry, localized_orbitals, natural_orbitals, orbital_localization, orbital_surface
from .diaglog import crash_probe, get_logger

# --------------------------------------------------------------------------
# Optional PySCF import.  Keeping the import lazy lets the UI start up and show
# a helpful message on builds where the native extensions are missing.
# --------------------------------------------------------------------------

_PYSCF_ERROR: str | None = None
_PYSCF_TRACEBACK: str | None = None
try:
    import numpy as np
    import pyscf
    from pyscf import cc, dft, gto, mp, scf
except Exception as exc:
    _PYSCF_ERROR = f"{type(exc).__name__}: {exc}"
    _PYSCF_TRACEBACK = traceback.format_exc()
    np = None  # type: ignore[assignment]
    pyscf = None  # type: ignore[assignment]


class EngineUnavailable(RuntimeError):
    """Raised when the PySCF native stack could not be loaded."""


def _require_pyscf() -> None:
    if pyscf is None:
        raise EngineUnavailable(
            "PySCF is not available in this interpreter"
            + (f" ({_PYSCF_ERROR})" if _PYSCF_ERROR else "")
        )


# --------------------------------------------------------------------------
# Basis sets and presets offered by the GUI
# --------------------------------------------------------------------------

BASIS_SETS = (
    "sto-3g",
    "3-21g",
    "6-31g",
    "6-31g*",
    "6-31g**",
    "6-311g",
    "6-311g**",
    "cc-pvdz",
    "cc-pvtz",
    "def2-svp",
    "def2-tzvp",
)

# Number of basis functions below which a density-fitted mean field is *slower*
# than an exact one, measured on the alkanes in 6-31G: the auxiliary basis
# build and its three-centre integrals are a fixed cost that an exact
# four-centre Fock build does not pay until the matrix products grow.  Methane
# (13 functions) runs 6x slower with DF; ethane (26) is already 1.4x faster, so
# the crossover sits between them and the threshold is set below it.
#
# This matters for the geometry optimiser specifically.  A relaxation of a small
# molecule takes a handful of milliseconds per step, so choosing DF there turns
# a 300 ms optimisation into a 2 s one - the opposite of the intent.
DENSITY_FIT_MIN_BASIS = 24

FUNCTIONALS = (
    "lda",
    "pbe",
    "pbesol",
    "b3lyp",
    "b3pw91",
    "pbe0",
    "m06l",
    "wb97x",
    "wb97x-d",
    "tpss",
    "scan",
    "r2scan",
)

METHODS = ("RHF", "UHF", "ROHF", "RKS", "UKS", "MP2", "CCSD")

# Ceiling handed to PySCF for sizing its integral and DFT grid buffers, in MB.
# PySCF's own default is 2000, which assumes a desktop. The grid loop adapts by
# using smaller blocks, so a higher value buys speed and costs memory rather than
# changing the result.
#
# 3072 is usable only because the app carries
# com.apple.developer.kernel.increased-memory-limit (ios/PySCF.entitlements). The
# default jetsam ceiling on a tablet is well below this, so without the
# entitlement a calculation large enough to reach 3072 MB is killed silently
# before it can finish. On a device that ignores the entitlement, treat this as
# an upper bound the OS will not honour rather than a figure that is actually
# available.
DEFAULT_MAX_MEMORY_MB = 3072

# Runtime OpenMP thread count.  ``None`` leaves the runtime's own choice alone,
# which is what the app does until the user picks a number.  The value is set
# through PySCF's own helper rather than ``OMP_NUM_THREADS``: the runtime reads
# that variable once, when it initialises, so exporting it afterwards has no
# effect on a process that is already running.
_THREADS: int | None = None

# Upper bound for the picker.  The runtime accepts any positive integer, but
# past the core count the extra workers only add scheduling overhead, and a
# mistyped value should not be able to ask for thousands of threads.
MAX_THREADS = 64

# CODATA Bohr radius in Angstrom.  PySCF's coordinate and gradient units are
# Bohr, so the optimiser converts at its boundaries.
_BOHR_TO_ANGSTROM = 0.52917721092

_PRESET_ATOMS: dict[str, str] = {
    "water": "O 0 0 0; H 0 0 0.9584; H 0 0.9267 -0.2421",
    "methane": (
        "C 0 0 0; H 0.6286 0.6286 0.6286; H -0.6286 -0.6286 0.6286; "
        "H -0.6286 0.6286 -0.6286; H 0.6286 -0.6286 -0.6286"
    ),
    "ammonia": (
        "N 0 0 0; H 0.9391 0 0.3816; H -0.4696 0.8133 0.3816; "
        "H -0.4696 -0.8133 0.3816"
    ),
    "hydrogen": "H 0 0 0; H 0 0 0.7414",
    "hydrogen_fluoride": "H 0 0 0; F 0 0 0.9171",
    # Regular hexagon, C-C 1.3965 A and C-H 1.0828 A.
    "benzene": (
        "C 1.3965 0 0; C 0.69825 1.2095 0; C -0.69825 1.2095 0; "
        "C -1.3965 0 0; C -0.69825 -1.2095 0; C 0.69825 -1.2095 0; "
        "H 2.4793 0 0; H 1.23965 2.1472 0; H -1.23965 2.1472 0; "
        "H -2.4793 0 0; H -1.23965 -2.1472 0; H 1.23965 -2.1472 0"
    ),
    "oxygen": "O 0 0 0; O 0 0 1.2075",
    "nitrogen": "N 0 0 0; N 0 0 1.0977",
    "carbon_dioxide": "C 0 0 0; O 0 0 1.16; O 0 0 -1.16",
    "ethanol": (
        "C -1.2 0.2 0; C 0.1 -0.5 0; O 1.2 0.4 0; "
        "H -2.0 0.5 0.6; H -1.3 0.8 -0.8; H -1.3 -0.7 -0.4; "
        "H 0.2 -1.1 0.8; H 0.2 -1.1 -0.8; H 1.9 0.0 0.3"
    ),
}


def presets() -> list[dict]:
    return [
        {
            "id": key,
            "name": key.replace("_", " ").title(),
            "atoms": value,
            "formula": geometry.formula(geometry.parse_atom_spec(value)),
        }
        for key, value in _PRESET_ATOMS.items()
    ]


def diagnostics() -> dict:
    """Describe the interpreter the engine is actually running in.

    Used on device: the iOS build cannot be reproduced on the host, because the
    extension modules are arm64-iOS and will not load there, so this reports what
    the embedded interpreter sees — paths, platform, and a fresh import attempt
    for each dependency — rather than making the caller guess.
    """
    import platform
    import sysconfig

    report: dict[str, Any] = {
        "ok": True,
        "python": sys.version,
        "platform": sys.platform,
        "executable": sys.executable,
        "prefix": sys.prefix,
        "home": os.environ.get("PYTHONHOME"),
        "cwd": os.getcwd(),
        "sysPath": [p for p in sys.path if p],
        "extSuffix": sysconfig.get_config_var("EXT_SUFFIX"),
        "soabi": sysconfig.get_config_var("SOABI"),
        "frozen": getattr(sys, "frozen", False),
        "pyscfError": _PYSCF_ERROR,
        "pyscfTraceback": _PYSCF_TRACEBACK,
    }

    imports: dict[str, Any] = {}
    for name in ("numpy", "scipy", "h5py", "pyscf", "pyscf.lib", "pyscf_mobile.vendor"):
        try:
            module = importlib.import_module(name)
            imports[name] = {
                "ok": True,
                "file": getattr(module, "__file__", None),
                "version": getattr(module, "__version__", None),
            }
        except Exception as exc:
            imports[name] = {
                "ok": False,
                "error": f"{type(exc).__name__}: {exc}",
                "traceback": traceback.format_exc(),
            }
    report["imports"] = imports

    # The runtime directories the app staged, and whether they are readable.
    report["paths"] = {}
    for label, path in _runtime_paths().items():
        entry: dict[str, Any] = {"path": path, "exists": os.path.isdir(path)}
        if entry["exists"]:
            try:
                entry["entries"] = sorted(os.listdir(path))[:40]
            except Exception as exc:
                entry["error"] = str(exc)
        report["paths"][label] = entry

    return report


def _runtime_paths() -> dict[str, str]:
    """Locations the packaging script populates, for the diagnostics report."""
    candidates = {
        "pythonHome": os.environ.get("PYTHONHOME"),
    }
    here = os.path.dirname(os.path.abspath(__file__))
    candidates["enginePackage"] = here
    candidates["sitePackages"] = os.path.dirname(here)
    for name in ("numpy", "pyscf", "scipy", "h5py"):
        try:
            module = importlib.import_module(name)
            candidates[name] = os.path.dirname(getattr(module, "__file__", "") or "")
        except Exception:
            candidates[name] = os.path.join(candidates["sitePackages"], name)
    return {k: v for k, v in candidates.items() if v}


def num_threads(n: int | None = None) -> dict:
    """Read or set the OpenMP thread count for subsequent calculations.

    Called with no argument, reports the current setting. Called with ``n``,
    applies it immediately through ``pyscf.lib.num_threads``, which calls
    ``omp_set_num_threads`` — the runtime picks the value up on the next
    parallel region, so a calculation already running is unaffected but the next
    one uses the new count.

    ``n = 0`` means "let the runtime decide" and restores the default, which is
    one thread per available core. This is a distinct state from any particular
    number, so it is reported separately rather than being collapsed into the
    core count.
    """
    _require_pyscf()
    from pyscf import lib as _lib

    global _THREADS
    if n is not None:
        requested = int(n)
        if requested < 0:
            raise ValueError("thread count cannot be negative")
        if requested > MAX_THREADS:
            raise ValueError(f"thread count cannot exceed {MAX_THREADS}")
        if requested == 0:
            _THREADS = None
            # Restoring the default means one thread per core. It cannot be read
            # back from the runtime: ``num_threads()`` reports whatever was set
            # last, so after an override it returns the override. The core count
            # is the value the runtime would have chosen on its own.
            applied = int(_lib.num_threads(os.cpu_count() or 1))
        else:
            _THREADS = requested
            applied = int(_lib.num_threads(requested))
        get_logger().write(
            f"threads: requested={requested} applied={applied} cores={os.cpu_count()}",
            tag="threads",
        )

    return {
        "ok": True,
        "threads": int(_lib.num_threads()),
        "override": _THREADS,
        "maxThreads": MAX_THREADS,
        "cores": os.cpu_count(),
    }


def engine_status() -> dict:
    """Report whether the native PySCF stack loaded correctly."""
    if pyscf is None:
        return {
            "available": False,
            "error": _PYSCF_ERROR,
            "traceback": _PYSCF_TRACEBACK,
            "version": None,
        }
    libs: dict[str, Any] = {}
    from pyscf import lib as _lib

    # libomp is probed alongside the PySCF extensions because it is the one
    # dependency that is not built by PySCF's own CMake: if it failed to load,
    # every extension would fail too, and reporting it separately names the
    # cause instead of leaving three identical "not found" entries.
    for name in ("libcgto", "libdft", "libnp_helper", "libomp"):
        try:
            _lib.load_library(name)
            libs[name] = True
        except Exception as exc:  # pragma: no cover
            libs[name] = False
            libs[f"{name}_error"] = str(exc)

    # The thread count is reported because it is the only way to tell from the
    # device whether OpenMP actually took effect.  Nothing on the build host can
    # observe it: the runtime is linked and the symbols are present either way,
    # and a serial build reports 1 here.  A failure is not fatal, so it is
    # reported alongside rather than raised.
    threads: int | None = None
    threads_error: str | None = None
    try:
        threads = int(_lib.num_threads())
    except Exception as exc:  # pragma: no cover
        threads_error = f"{type(exc).__name__}: {exc}"

    return {
        "available": True,
        "error": None,
        "version": getattr(pyscf, "__version__", "unknown"),
        "numpy": getattr(np, "__version__", "unknown"),
        "libraries": libs,
        "threads": threads,
        "threadsError": threads_error,
        # The user's choice, kept separate from ``threads``: that is what the
        # runtime reports, which equals the override once one is set and the core
        # count otherwise. The UI needs the two apart to show "automatic" as a
        # state rather than as the number it happens to resolve to.
        "threadOverride": _THREADS,
        "maxThreads": MAX_THREADS,
        "cores": os.cpu_count(),
    }


# --------------------------------------------------------------------------
# Job execution
# --------------------------------------------------------------------------


def _coerce_atoms(spec: Any) -> list[dict]:
    if isinstance(spec, str):
        return geometry.parse_atom_spec(spec)
    if isinstance(spec, Iterable):
        atoms = []
        for item in spec:
            if isinstance(item, dict):
                if "element" not in item:
                    raise ValueError(f"atom dict needs an 'element' key: {item!r}")
                element = geometry.resolve(item["element"])
                atoms.append(
                    {
                        "element": element.symbol,
                        "z": element.z,
                        "xyz": [float(v) for v in item["xyz"]],
                    }
                )
            elif isinstance(item, (list, tuple)) and len(item) == 4:
                element = geometry.resolve(item[0])
                atoms.append(
                    {
                        "element": element.symbol,
                        "z": element.z,
                        "xyz": [float(v) for v in item[1:4]],
                    }
                )
            else:
                raise ValueError(f"cannot interpret atom {item!r}")
        if not atoms:
            raise ValueError("empty atom list")
        return atoms
    raise TypeError("atoms must be an XYZ string or a list of atoms")


def _build_mol(atoms: list[dict], basis: str, charge: int, spin: int, unit: str = "Angstrom"):
    _require_pyscf()
    atom_block = [(a["element"], tuple(float(v) for v in a["xyz"])) for a in atoms]
    _check_electrons(atoms, charge, spin)
    return gto.M(
        atom=atom_block,
        basis=basis,
        charge=int(charge),
        spin=int(spin),
        unit=unit,
        verbose=0,
        output=None,
    )


def _check_electrons(atoms: list[dict], charge: int, spin: int) -> None:
    """Reject a charge/spin pair PySCF cannot satisfy, with a usable message.

    PySCF raises its own error here, but it says "electron number and spin are
    not consistent" without naming either number, and the two settings live in
    separate steppers in the UI, so the user has no obvious way to tell which
    one to change. Restating it with both values turns a puzzle into a fix.
    """
    electrons = sum(a["z"] for a in atoms) - int(charge)
    if electrons < 0:
        raise ValueError(
            f"charge {charge:+d} removes more electrons than the {len(atoms)} atoms provide"
        )
    if (electrons - int(spin)) % 2 != 0:
        # 2S = N_alpha - N_beta, and N_alpha + N_beta = N, so N and 2S must share
        # a parity: an even electron count admits only even spin values.
        # Suggest the neighbour that fixes the parity. Stepping down keeps the
        # suggestion small, which is what a user almost always wants, and stays
        # inside the range the stepper offers; stepping up is the fallback when
        # there is no room below.
        suggestion = spin - 1 if spin - 1 >= 0 else spin + 1
        raise ValueError(
            f"{electrons} electrons with 2S = {spin} is not a valid combination: "
            f"{electrons} and {spin} must have the same parity. "
            f"Use 2S = {suggestion} instead."
        )
    if int(spin) > electrons:
        raise ValueError(f"2S = {spin} needs more than the {electrons} available electrons")


def _homo_lumo(mo_energy, mo_occ):
    occupied = [e for e, o in zip(mo_energy, mo_occ) if o > 1e-6]
    virtual = [e for e, o in zip(mo_energy, mo_occ) if o <= 1e-6]
    homo = max(occupied) if occupied else None
    lumo = min(virtual) if virtual else None
    return homo, lumo


def _mulliken(mf, atoms: list[dict]) -> dict | None:
    try:
        _pop, charges = mf.mulliken_pop(verbose=0)
    except Exception:
        return None
    charges = np.asarray(charges, dtype=float)
    if charges.ndim == 0 or charges.shape[0] != len(atoms):
        return None
    per_atom = [
        {"index": i, "element": a["element"], "charge": round(float(c), 6)}
        for i, (a, c) in enumerate(zip(atoms, charges))
    ]
    totals: dict[str, float] = {}
    for entry in per_atom:
        totals[entry["element"]] = totals.get(entry["element"], 0.0) + entry["charge"]
    return {
        "perAtom": per_atom,
        "perElement": {k: round(v, 6) for k, v in sorted(totals.items())},
    }


def _mayer_bond_orders(mf, atoms: list[dict]) -> dict | None:
    """Mayer bond orders, keyed to the bonds the geometry already perceives.

    Uses Mayer's 1986 spin-resolved definition,

        B_AB = sum_{mu in A} sum_{nu in B} [ (P^S S)_mu,nu (P^S S)_nu,mu
                                           + (P^A S)_mu,nu (P^A S)_nu,mu ]

    with P^S = P^alpha + P^beta and P^A = P^alpha - P^beta, which is the form
    that stays correct for open shells.  The commonly quoted closed-shell
    simplification, taking PS = (P^alpha + P^beta) S and dropping the spin part,
    is what most snippets show; for O2 it returns 1.50 against the correct 2.00,
    and for superoxide 1.00 against 1.50, so the spin term is not optional here.
    A restricted density has no spin part, and splitting it into equal alpha and
    beta halves reproduces the closed-shell formula exactly.

    Bond orders are only meaningful between atoms the geometry considers bonded,
    so the output is filtered to ``geometry.perceive_bonds``.  That also drops
    the diagonal terms and the 1,3 H...H contacts, which carry real but small
    population that would otherwise swamp the display.
    """
    try:
        dm = np.asarray(mf.make_rdm1(), dtype=float)
        overlap = np.asarray(mf.get_ovlp(), dtype=float)
    except Exception:
        return None
    if dm.ndim == 3:
        alpha, beta = dm[0], dm[1]
    elif dm.ndim == 2:
        alpha = beta = dm / 2.0
    else:
        return None

    spin_summed = (alpha + beta) @ overlap
    spin_diff = (alpha - beta) @ overlap
    # (PS)_mu,nu * (PS)_nu,mu for both spin channels, elementwise.
    population = spin_summed * spin_summed.T + spin_diff * spin_diff.T

    ranges = _ao_ranges(mf)
    bonds = []
    for i, j, _length in geometry.perceive_bonds(atoms):
        # Only the (mu in A, nu in B) block is needed: the (nu, mu) half of the
        # pair is its transpose, so summing one block covers both directions.
        block = population[ranges[i][0] : ranges[i][1], ranges[j][0] : ranges[j][1]]
        bonds.append(
            {
                "i": i,
                "j": j,
                "a": atoms[i]["element"],
                "b": atoms[j]["element"],
                "order": round(float(block.sum()), 6),
            }
        )

    return {
        "bonds": bonds,
        "total": round(float(population.sum()), 6),
        # Mayer's sum rule: every B_AB over all atom pairs, diagonal included,
        # equals twice the electron count. A mismatch means the density or the
        # overlap is wrong, so the UI shows it as a self-check.
        "expectedTotal": 2 * int(mf.mol.nelectron),
    }


def _ao_ranges(mf) -> list[tuple[int, int]]:
    """AO index range [start, stop) belonging to each atom, cached on the mol."""
    ranges = getattr(mf.mol, "_mayer_ao_ranges", None)
    if ranges is None:
        ranges = [(int(s), int(e)) for _a, _b, s, e in mf.mol.aoslice_by_atom()]
        mf.mol._mayer_ao_ranges = ranges
    return ranges


def _dipole(mf) -> dict | None:
    try:
        moment = mf.dip_moment(verbose=0)
    except Exception:
        return None
    vec = np.asarray(moment, dtype=float).ravel()[:3]
    return {
        "vector": [round(float(v), 6) for v in vec],
        "magnitude": round(float(np.linalg.norm(vec)), 6),
    }


def _orbital_values(mf, atoms: list[dict], column: np.ndarray,
                    points_per_axis: int, padding: float) -> tuple[np.ndarray, list[float], list[float]]:
    """Evaluate one orbital's AO coefficients on a cubic grid.

    Shared by the cube and the surface so both sample the same box at the same
    spacing; a surface drawn against a differently-placed grid would not sit on
    the molecule it belongs to.
    """
    coords = geometry.atoms_to_coords(atoms)
    lo = coords.min(axis=0) - padding
    hi = coords.max(axis=0) + padding
    axes = [np.linspace(lo[i], hi[i], points_per_axis) for i in range(3)]
    gx, gy, gz = np.meshgrid(*axes, indexing="ij")
    flat = np.column_stack([gx.ravel(), gy.ravel(), gz.ravel()])
    ao = mf.mol.eval_gto("GTOval", flat)
    values = np.asarray(ao @ column, dtype=float).reshape(points_per_axis, points_per_axis, points_per_axis)
    origin = [float(lo[i]) for i in range(3)]
    step = [float((hi[i] - lo[i]) / (points_per_axis - 1)) for i in range(3)]
    return values, origin, step


def _localized_column(mf, atoms: list[dict], kind: str, index: int) -> np.ndarray:
    """The AO coefficients of one localised occupied orbital.

    The intrinsic methods return their orbitals as a block of occupied columns,
    so ``index`` picks one of them.  This is what gives the viewer the familiar
    picture for a localised orbital: the isosurface is built from the same
    coefficients the localisation optimised.

    The localisation itself is re-run here rather than carried in from the SCF
    payload.  It is a few sweeps over the occupied pairs, which is cheap next to
    the SCF that preceded it, and keeping the coefficients out of the payload
    keeps a normal run small.
    """
    block, _sweeps, _objective = orbital_localization.localize_coefficients(mf, method=kind)
    coefficients = np.asarray(block, dtype=float)
    if not 0 <= index < coefficients.shape[1]:
        raise ValueError(f"localised orbital index {index} outside 0..{coefficients.shape[1] - 1}")
    return coefficients[:, index]


def _density_grid(mf, atoms: list[dict], points_per_axis: int = 22, padding: float = 1.6) -> dict:
    """Evaluate the total electron density on a coarse cubic grid.

    The UI uses this to draw an isosurface; the grid is deliberately small so
    that the JSON payload stays phone friendly.
    """
    coords = geometry.atoms_to_coords(atoms)
    lo = coords.min(axis=0) - padding
    hi = coords.max(axis=0) + padding
    axes = [np.linspace(lo[i], hi[i], points_per_axis) for i in range(3)]
    gx, gy, gz = np.meshgrid(*axes, indexing="ij")
    flat = np.column_stack([gx.ravel(), gy.ravel(), gz.ravel()])
    dm = np.asarray(mf.make_rdm1(), dtype=float)
    if dm.ndim == 3:  # unrestricted references carry alpha/beta blocks
        dm = dm[0] + dm[1]
    # rho(r) = sum_ij ao_i(r) D_ij ao_j(r); evaluated directly so the helper
    # works for both RHF and UHF/UKS references without API-shape surprises.
    ao = mf.mol.eval_gto("GTOval", flat)
    rho = np.einsum("gi,ij,gj->g", ao, dm, ao)
    return {
        "shape": [points_per_axis] * 3,
        "origin": [round(float(lo[i]), 6) for i in range(3)],
        "step": [round(float((hi[i] - lo[i]) / (points_per_axis - 1)), 6) for i in range(3)],
        "values": [round(float(v), 8) for v in np.asarray(rho).ravel()],
    }


def _wants_density_fit(mol, params: dict) -> bool:
    """Decide whether to build the mean field with density fitting.

    This is off unless a request asks for it.  The optimiser is the only caller
    that turns it on by itself, and it does so from the molecule size; see
    ``run_geometry_optimisation``.

    Density fitting pays off on the *gradient*, where it removes the four-centre
    two-electron integrals that dominate, but not on a single-point SCF: the
    auxiliary basis build and its three-centre integrals are a fixed cost that
    an exact Fock build spreads more cheaply.  Measured on the alkanes in
    6-31G, a density-fitted SCF is slower at every size tried, from ethane
    (0.30x) up to C16H34 with 208 functions (0.65x).  Leaving it on by default
    would therefore make every single-point calculation slower, so it is opt-in.

    The approximation enters through the two-electron integrals only.  Over
    every basis in ``BASIS_SETS``, on water and on benzene, the energy moves by
    at most 7e-4 Ha and the gradient by at most 5e-5 Ha/Bohr.  The gradient
    bound is the one that governs a relaxation, and it sits an order of
    magnitude below the default ``convTolGrad`` of 3e-4, so the nuclei stop in
    the same place; the energy offset is near constant across the surface and
    does not move the minimum.
    """
    requested = params.get("densityFit")
    if requested is not None:
        return bool(requested)
    return False


def _make_method(mol, method: str, xc: str, params: dict):
    method = method.upper()
    if method == "RHF":
        mf = scf.RHF(mol)
    elif method == "UHF":
        mf = scf.UHF(mol)
    elif method == "ROHF":
        mf = scf.ROHF(mol)
    elif method == "RKS":
        mf = dft.RKS(mol)
    elif method == "UKS":
        mf = dft.UKS(mol)
    else:
        raise ValueError(f"unsupported SCF method: {method}")

    if _wants_density_fit(mol, params):
        mf = mf.density_fit()

    if method.endswith("KS"):
        mf.xc = xc or "b3lyp"
    if params.get("maxCycle"):
        mf.max_cycle = int(params["maxCycle"])
    if params.get("convTol"):
        mf.conv_tol = float(params["convTol"])
    if params.get("initGuess"):
        mf.init_guess = str(params["initGuess"])
    level = params.get("gridLevel")
    if level is not None and hasattr(mf, "grids"):
        mf.grids.level = int(level)
    # PySCF sizes its DFT grid buffers from ``max_memory``, which defaults to
    # 2000 MB — a desktop figure. The value only decides how large a block the
    # grid loop works on; a lower figure means more passes, not a different
    # result. See DEFAULT_MAX_MEMORY_MB for why the ceiling is what it is.
    if hasattr(mf, "max_memory"):
        mf.max_memory = float(params.get("maxMemory", DEFAULT_MAX_MEMORY_MB))
    return mf


def _finalise(mf, atoms, method, basis, wall_ms, log, include, localization=None) -> dict:
    result: dict[str, Any] = {
        "ok": True,
        "method": f"{method}/{basis}",
        "energy": round(float(mf.e_tot), 10),
        "converged": bool(mf.converged),
        "cycles": int(getattr(mf, "cycles", 0) or 0),
        "wallTimeMs": round(wall_ms, 3),
        "log": log[-4000:],
    }
    result.update(_electronic_structure(mf, atoms, include, localization))
    return result


def _electronic_structure(mf, atoms, include, localization: str | None = None) -> dict:
    """Orbital, population and density payloads for one converged calculation.

    ``include`` is the set of extra payloads to compute.  ``localization`` is
    kept out of it because the requested value carries the method name, which a
    set cannot hold; ``None`` means the caller did not ask for localisation at
    all.
    """
    mo_energy = np.asarray(mf.mo_energy, dtype=float).ravel()
    mo_occ = np.asarray(mf.mo_occ, dtype=float).ravel()
    homo, lumo = _homo_lumo(mo_energy, mo_occ)

    result: dict[str, Any] = {
        "nElectrons": int(mf.mol.nelectron),
        "nBasis": int(mf.mol.nao_nr()),
        "nAlpha": int(mf.mol.nelec[0]),
        "nBeta": int(mf.mol.nelec[1]),
        "homo": round(float(homo), 8) if homo is not None else None,
        "lumo": round(float(lumo), 8) if lumo is not None else None,
        "gap": round(float(lumo - homo), 8) if homo is not None and lumo is not None else None,
        "orbitalEnergies": [round(float(e), 8) for e in mo_energy],
        "occupations": [round(float(o), 6) for o in mo_occ],
    }
    if "_skip_population" not in include:
        # The bond scan only reads the energy, so it asks for these to be left
        # out rather than paying for three O(N^2) analyses per geometry.
        result["dipole"] = _dipole(mf)
        result["mulliken"] = _mulliken(mf, atoms)
        result["mayer"] = _mayer_bond_orders(mf, atoms)
        # NPA, the natural orbitals and the Wiberg bond orders all come out of
        # one NAO transformation.
        result.update(natural_orbitals.analyze(mf, atoms))
        # The localised orbitals reuse that same NAO basis, so they are cheap
        # next to it. CLPO is the default: it is the one that reads as a Lewis
        # structure, which is what a panel of bonds and lone pairs is for.
        result["localizedOrbitals"] = localized_orbitals.localized_orbitals(
            mf, atoms, kind="clpo"
        )
    if "mo" in include:
        result["moCoefficients"] = np.asarray(mf.mo_coeff, dtype=float).tolist()
    if "overlap" in include:
        result["overlap"] = np.asarray(mf.get_ovlp(), dtype=float).tolist()
    if "density" in include:
        result["density"] = np.asarray(mf.make_rdm1(), dtype=float).tolist()
    if "grid" in include:
        result["grid"] = _density_grid(mf, atoms)
    # The intrinsic localisation methods are opt-in.  Edmiston-Ruedenberg is
    # O(N^5) and even the cheap two are a Jacobi sweep over the occupied space,
    # so they are not worth computing for a run whose panel is not being looked
    # at.  An empty string asks for the default method; a name picks one.
    if localization is not None:
        result["localization"] = orbital_localization.localize(
            mf, atoms, method=localization or "pm-mulliken"
        )
    return result


def _run_mean_field(params: dict, dm0=None):
    """Build the molecule and converge the requested mean field.

    Returns ``(mf, atoms, basis, method, log)``.  Shared by ``run_scf`` and the
    geometry optimiser, which needs the converged object to reach its gradient
    method.

    ``dm0`` seeds the SCF with a density matrix from a previous geometry.  The
    atom-centred basis does not change when the nuclei move, so the matrix stays
    dimensionally valid and a relaxation can walk the surface reusing it.
    """
    _require_pyscf()
    atoms = _coerce_atoms(params["atoms"])
    basis = str(params.get("basis", "sto-3g"))
    method = str(params.get("method", "RHF")).upper()
    xc = str(params.get("xc", "b3lyp"))

    mol = _build_mol(atoms, basis, int(params.get("charge", 0)), int(params.get("spin", 0)),
                     params.get("unit", "Angstrom"))
    buf = io.StringIO()
    # The SCF is the longest single call in the app and the one most likely to
    # be running when the process dies, so it is bracketed in the log.  Written
    # before the call: if it never returns, this line is the last one.
    logger = get_logger()
    logger.write(
        f"scf: starting {method}/{basis} xc={xc} natm={len(atoms)} "
        f"grid={params.get('gridLevel')} dm0={'yes' if dm0 is not None else 'no'}; {crash_probe()}",
        tag="scf",
    )
    with contextlib.redirect_stdout(buf):
        mf = _make_method(mol, method, xc, params)
        mf.kernel(dm0=dm0)
    logger.write(
        f"scf: finished E={mf.e_tot:.10f} cycles={getattr(mf, 'cycles', '?')} "
        f"converged={mf.converged}; {crash_probe()}",
        tag="scf",
    )
    return mf, atoms, basis, method, buf.getvalue()


def _requested_localization(params: dict) -> str | None:
    """The localisation method a request asks for, or ``None`` if it asks for none.

    The value is read from the ``include`` list rather than a key of its own so
    that it travels the same way as ``grid`` and ``mo``.  A bare ``"localization"``
    entry means the default method; ``"localization:boys"`` names one.
    """
    for entry in params.get("include", []) or []:
        text = str(entry).strip().lower()
        if text == "localization":
            return "pm-mulliken"
        if text.startswith("localization:"):
            return text.split(":", 1)[1] or "pm-mulliken"
    return None


def run_scf(params: dict, full: bool = True) -> dict:
    """Run a Hartree-Fock or Kohn-Sham calculation.

    ``full=False`` skips the population analysis. The bond scan calls this once
    per point and reads only the energy, so computing Mayer bond orders for
    every geometry would add work whose result is discarded.
    """
    include = {str(x).lower() for x in params.get("include", [])}
    if not full:
        include.add("_skip_population")
    start = time.perf_counter()
    mf, atoms, basis, method, log = _run_mean_field(params)
    wall_ms = (time.perf_counter() - start) * 1000.0
    return _finalise(mf, atoms, method, basis, wall_ms, log, include,
                     _requested_localization(params))


def _post_hf(params: dict, kind: str) -> dict:
    _require_pyscf()
    atoms = _coerce_atoms(params["atoms"])
    basis = str(params.get("basis", "sto-3g"))
    reference = str(params.get("reference", "RHF"))
    include = {str(x).lower() for x in params.get("include", [])}

    mol = _build_mol(mol_atoms := atoms, basis, int(params.get("charge", 0)), int(params.get("spin", 0)))
    buf = io.StringIO()
    start = time.perf_counter()
    with contextlib.redirect_stdout(buf):
        mf = _make_method(mol, reference, params.get("xc", "b3lyp"), params)
        mf.kernel()
        scf_energy = float(mf.e_tot)
        if kind == "mp2":
            solver = mp.MP2(mf)
        else:
            solver = cc.CCSD(mf)
        solver.kernel()
        e_corr = float(solver.e_corr)
        mf.e_tot = scf_energy + e_corr
    wall_ms = (time.perf_counter() - start) * 1000.0
    label = f"{kind.upper()}({reference.upper()})"
    result = _finalise(mf, mol_atoms, label, basis, wall_ms, buf.getvalue(), include,
                       _requested_localization(params))
    result["correlationEnergy"] = round(e_corr, 10)
    result["scfEnergy"] = round(scf_energy, 10)
    return result


def run_mp2(params: dict) -> dict:
    """Run MP2 on top of the requested mean-field reference."""
    return _post_hf(params, "mp2")


def run_ccsd(params: dict) -> dict:
    """Run CCSD on top of the requested mean-field reference."""
    return _post_hf(params, "ccsd")


def run_bond_scan(params: dict) -> dict:
    """Scan the potential energy surface along one bond length."""
    _require_pyscf()
    atoms = _coerce_atoms(params["atoms"])
    i, j = int(params["i"]), int(params["j"])
    if i == j or not (0 <= i < len(atoms)) or not (0 <= j < len(atoms)):
        raise ValueError("i and j must be two different valid atom indices")
    steps = max(2, min(int(params.get("steps", 10)), 40))
    start_r = float(params.get("start", 0.6))
    stop_r = float(params.get("stop", 2.5))

    coords = geometry.atoms_to_coords(atoms)
    axis = coords[j] - coords[i]
    norm = float(np.linalg.norm(axis))
    if norm < 1e-9:
        raise ValueError("selected atoms are at the same position")
    direction = axis / norm

    points = []
    for k in range(steps):
        r = start_r + (stop_r - start_r) * k / (steps - 1)
        shifted = [dict(a) for a in atoms]
        shifted[j] = {**shifted[j], "xyz": [float(v) for v in coords[i] + direction * r]}
        single = dict(params)
        single["atoms"] = shifted
        single["include"] = []
        try:
            res = run_scf(single, full=False)
            points.append({"r": round(r, 4), "energy": res["energy"], "converged": res["converged"]})
        except Exception as exc:  # pragma: no cover - numerical edge cases
            points.append({"r": round(r, 4), "energy": None, "error": str(exc)})
    usable = [p for p in points if p["energy"] is not None]
    minimum = None
    if usable:
        best = min(usable, key=lambda p: p["energy"])
        minimum = {"r": best["r"], "energy": best["energy"]}
    return {
        "ok": True,
        "i": i,
        "j": j,
        "label": f"{atoms[i]['element']}-{atoms[j]['element']}",
        "points": points,
        "minimum": minimum,
    }


def _gradient_method(mf):
    """Return the analytic gradient driver for ``mf``, or raise a clear error.

    Every basis set in ``BASIS_SETS`` is supported, because the gradient driver
    is derived from the mean-field object itself.  A few Kohn-Sham functionals
    have no gradient implementation upstream; PySCF raises its own error for
    those and it is surfaced unchanged.
    """
    try:
        return mf.nuc_grad_method()
    except Exception as exc:
        raise ValueError(
            f"analytic gradients are unavailable for {type(mf).__name__}: {exc}"
        ) from exc


def run_geometry_optimisation(params: dict) -> dict:
    """Relax the molecular geometry and report the optimised coordinates."""
    from . import geomopt

    max_steps = max(1, min(int(params.get("maxSteps", 40)), 200))
    conv_tol_grad = float(params.get("convTolGrad", 3e-4))
    conv_tol_energy = float(params.get("convTolEnergy", 1e-6))
    basis = str(params.get("basis", "sto-3g"))
    method = str(params.get("method", "RHF")).upper()
    xc = str(params.get("xc", "b3lyp"))
    include = {str(x).lower() for x in params.get("include", [])}

    base = {
        "atoms": params["atoms"],
        "basis": basis,
        "charge": int(params.get("charge", 0)),
        "spin": int(params.get("spin", 0)),
        "method": method,
        "xc": xc,
        "unit": "Angstrom",
    }
    for key in ("maxCycle", "convTol", "initGuess", "densityFit"):
        if params.get(key) is not None:
            base[key] = params[key]

    # A relaxation walks a sequence of very similar geometries, and the XC
    # quadrature dominates every step for a Kohn-Sham reference.  Evaluating the
    # forces on a coarser grid is far cheaper and moves the nuclei to the same
    # place; the reported energy is then taken from a single point on the
    # production grid, so the number that reaches the user is not the cheap one.
    # Hartree-Fock has no quadrature, so this only applies to the KS methods.
    is_dft = method.endswith("KS")
    production_level = int(params["gridLevel"]) if params.get("gridLevel") is not None else None
    if production_level is None:
        production_level = 3
    relax_level = int(params["relaxGridLevel"]) if params.get("relaxGridLevel") is not None else None
    if relax_level is None:
        relax_level = 1 if is_dft else None
    if relax_level is not None:
        relax_level = max(0, min(relax_level, production_level))

    start = time.perf_counter()
    call_log: list[str] = []
    state = {"mf": None, "atoms": None, "dm": None}

    logger = get_logger()
    logger.section(f"optimise {method}/{basis} xc={xc} relaxGrid={relax_level} prodGrid={production_level}")
    logger.write(
        f"optimise: {len(params['atoms']) if isinstance(params.get('atoms'), list) else '?'} atoms, "
        f"maxSteps={max_steps}, charge={base['charge']}, spin={base['spin']}; {crash_probe()}",
        tag="optimise",
    )

    def energy_and_grad(flat):
        # PySCF takes and returns Bohr; the UI works in Angstrom.
        coords = np.asarray(flat, dtype=float).reshape(-1, 3)
        atoms = [
            {"element": a["element"], "z": a["z"], "xyz": [float(v) for v in row]}
            for a, row in zip(state["atoms"], coords)
        ]
        step_params = dict(base)
        step_params["atoms"] = atoms
        step_params["unit"] = "Bohr"
        if relax_level is not None:
            step_params["gridLevel"] = relax_level
        # Seeding each step with the previous density matrix keeps the atom
        # basis fixed, so the matrix stays valid across the relaxation.
        #
        # The two calls below are separated by a log line each: an SCF failure
        # and a gradient failure need different fixes, and a crash between them
        # is otherwise indistinguishable from a crash inside either.
        logger.write(f"energy_and_grad: SCF starting (gridLevel={step_params.get('gridLevel')})", tag="optimise")
        mf, built, _basis, _method, log = _run_mean_field(step_params, dm0=state["dm"])
        logger.write(f"energy_and_grad: SCF done, E={mf.e_tot:.10f} converged={mf.converged}", tag="optimise")
        if not mf.converged:
            call_log.append("warning: an SCF cycle during the relaxation did not converge")
        state["mf"] = mf
        state["dm"] = mf.make_rdm1()
        logger.write("energy_and_grad: gradient starting", tag="optimise")
        gradient = np.asarray(_gradient_method(mf).kernel(), dtype=float).reshape(-1)
        logger.write(
            f"energy_and_grad: gradient done, max|g|={np.max(np.abs(gradient)):.3e}",
            tag="optimise",
        )
        return float(mf.e_tot), gradient

    initial = _coerce_atoms(params["atoms"])
    state["atoms"] = initial
    # PySCF's mol.atom_coords() is in Bohr, and the gradient is Ha/Bohr, so the
    # whole relaxation runs in Bohr and is converted back at the end.
    reference = _build_mol(initial, basis, base["charge"], base["spin"], "Angstrom")
    # A relaxation is the one place density fitting pays: the gradient is the
    # dominant cost there and DF removes the four-centre integrals it is built
    # from.  It is deliberately not enabled for single-point SCF, where it is
    # slower at every size measured.  ``base`` is captured by ``energy_and_grad``
    # above, so setting the key here still reaches every step.
    if "densityFit" not in base:
        base["densityFit"] = reference.nao_nr() >= DENSITY_FIT_MIN_BASIS
    x0 = np.asarray(reference.atom_coords(), dtype=float).reshape(-1)
    logger.write(f"optimise: reference built, {x0.size // 3} atoms, starting minimiser", tag="optimise")

    outcome = geomopt.minimise(
        x0,
        energy_and_grad,
        max_steps=max_steps,
        conv_tol_grad=conv_tol_grad,
        conv_tol_energy=conv_tol_energy,
    )
    wall_ms = (time.perf_counter() - start) * 1000.0
    logger.write(
        f"optimise: minimiser returned after {wall_ms:.0f}ms, "
        f"steps={outcome['steps']} converged={outcome['converged']}",
        tag="optimise",
    )

    # The relaxation grid is deliberately coarse, so re-evaluate the converged
    # geometry on the production grid.  This is what makes the reported energy
    # and gradient trustworthy while the relaxation stays cheap.
    refined = None
    if is_dft and relax_level is not None and relax_level != production_level:
        relaxed_coords = np.asarray(outcome["x"], dtype=float).reshape(-1, 3)
        relaxed_atoms = [
            {"element": a["element"], "z": a["z"], "xyz": [float(v) for v in row]}
            for a, row in zip(initial, relaxed_coords)
        ]
        refine_params = dict(base)
        refine_params["atoms"] = relaxed_atoms
        refine_params["unit"] = "Bohr"
        refine_params["gridLevel"] = production_level
        logger.write(f"optimise: refining on production grid (level {production_level})", tag="optimise")
        mf, _b, _ba, _m, refine_log = _run_mean_field(refine_params, dm0=state["dm"])
        if refine_log.strip():
            call_log.append(refine_log.strip())
        gradient = np.asarray(_gradient_method(mf).kernel(), dtype=float).reshape(-1)
        state["mf"] = mf
        refined = (float(mf.e_tot), gradient)
        logger.write(f"optimise: refined, E={mf.e_tot:.10f}", tag="optimise")

    final_coords = outcome["x"].reshape(-1, 3)
    # geometry.describe expects Angstrom.
    angstrom_atoms = [
        {"element": a["element"], "z": a["z"],
         "xyz": [float(v) * _BOHR_TO_ANGSTROM for v in row]}
        for a, row in zip(initial, final_coords)
    ]
    optimised_spec = geometry.atoms_to_spec(angstrom_atoms)

    mf = state["mf"]
    reported_energy = float(outcome["energy"])
    reported_gradient = np.asarray(outcome["gradient"]).ravel()
    if refined is not None:
        reported_energy, reported_gradient = refined
    result: dict[str, Any] = {
        "ok": True,
        "method": f"{method}/{basis}",
        "functional": xc if method.endswith("KS") else None,
        "converged": bool(outcome["converged"]),
        "message": outcome["message"],
        "steps": int(outcome["steps"]),
        "maxSteps": max_steps,
        "wallTimeMs": round(wall_ms, 3),
        "energy": round(reported_energy, 10),
        "gradient": [round(float(v), 8) for v in reported_gradient],
        "maxGradient": round(geomopt.max_abs(reported_gradient), 8),
        "rmsGradient": round(geomopt.rms(reported_gradient), 8),
        "convTolGrad": conv_tol_grad,
        "gridLevel": production_level if is_dft else None,
        "relaxGridLevel": relax_level if is_dft else None,
        "optimisedAtoms": optimised_spec,
        "atoms": [
            {"element": a["element"], "z": a["z"], "xyz": [round(float(v), 8) for v in a["xyz"]]}
            for a in angstrom_atoms
        ],
        "initialAtoms": geometry.atoms_to_spec(initial),
        "trajectory": [
            {
                "step": point["step"],
                "energy": round(point["energy"], 10),
                "maxGrad": round(point["maxGrad"], 8),
                "rmsGrad": round(point["rmsGrad"], 8),
                "deltaE": None if point["deltaE"] is None else round(point["deltaE"], 10),
            }
            for point in outcome["trajectory"]
        ],
        "geometry": geometry.describe(angstrom_atoms),
        "log": "\n".join(call_log)[-4000:],
    }
    if mf is not None:
        result.update(_electronic_structure(mf, angstrom_atoms, include,
                                            _requested_localization(params)))
    return result


def analyse_geometry(params: dict) -> dict:
    atoms = _coerce_atoms(params["atoms"])
    return {"ok": True, **geometry.describe(atoms)}


def run_natural_population(params: dict) -> dict:
    """Natural orbital analysis for an existing wavefunction.

    Standalone so the analysis can be asked for directly, without re-running
    the mean field that produced the density.  Returns the NAO/NPA charges, the
    per-orbital detail and the Wiberg bond orders, all from one NAO
    transformation.  ``include`` accepts the same ``_skip_population`` switch as
    the SCF entry points.
    """
    start = time.perf_counter()
    mf, atoms, basis, method, _log = _run_mean_field(params)
    wall_ms = (time.perf_counter() - start) * 1000.0
    analysis = natural_orbitals.analyze(mf, atoms)
    if analysis["npa"] is None:
        raise ValueError("natural orbital analysis is unavailable for this wavefunction")
    return {
        "ok": True,
        "method": f"{method}/{basis}",
        "energy": round(float(mf.e_tot), 10),
        "wallTimeMs": round(wall_ms, 3),
        **analysis,
    }


def run_wiberg(params: dict) -> dict:
    """Wiberg-Mayer bond orders in the NAO basis for an existing wavefunction."""
    start = time.perf_counter()
    mf, atoms, basis, method, _log = _run_mean_field(params)
    wall_ms = (time.perf_counter() - start) * 1000.0
    bonds = natural_orbitals.wiberg_bond_orders(mf, atoms)
    if bonds is None:
        raise ValueError("Wiberg bond orders are unavailable for this wavefunction")
    return {
        "ok": True,
        "method": f"{method}/{basis}",
        "energy": round(float(mf.e_tot), 10),
        "wallTimeMs": round(wall_ms, 3),
        **bonds,
    }


def run_intrinsic_localization(params: dict) -> dict:
    """Pipek-Mezey, Foster-Boys or Edmiston-Ruedenberg localised orbitals.

    ``kind`` selects the objective: ``"pm-mulliken"``, ``"pm-lowdin"``,
    ``"boys"`` or ``"er"``.  These are the intrinsic methods, which optimise a
    property of the occupied orbitals directly, as opposed to the JANPA
    LPO/CLPO orbitals that ``run_localized_orbitals`` returns and which are
    built from natural atomic orbitals.

    The objective is read from ``kind`` rather than ``method`` because
    ``method`` is the mean-field reference (RHF, B3LYP, ...) throughout this
    module.
    """
    start = time.perf_counter()
    mf, atoms, basis, method, _log = _run_mean_field(params)
    wall_ms = (time.perf_counter() - start) * 1000.0
    variant = str(params.get("kind", "pm-mulliken")).lower()
    result = orbital_localization.localize(mf, atoms, method=variant)
    if result is None:
        raise ValueError("orbital localisation is unavailable for this wavefunction")
    return {
        "ok": True,
        "method": f"{method}/{basis}",
        "energy": round(float(mf.e_tot), 10),
        "wallTimeMs": round(wall_ms, 3),
        **result,
    }


def _orbital_column(mf, index: int) -> np.ndarray:
    """The AO coefficients of one canonical orbital, as a 1-D column.

    A closed-shell reference stores one ``(nao, nmo)`` block.  An unrestricted
    one stores the alpha and beta blocks stacked, as ``(2, nao, nmo)`` or a
    tuple of two ``(nao, nmo)`` arrays, and the energy ladder the app shows is
    those blocks concatenated in that order, so an index past the first block
    selects from the second.  Treating the stacked array as a single block would
    pick the wrong orbital and then fail on the shape, so the two cases are
    separated here rather than left to the caller.
    """
    coefficients = mf.mo_coeff
    blocks = None
    if isinstance(coefficients, (tuple, list)):
        blocks = [np.asarray(block, dtype=float) for block in coefficients]
    else:
        stacked = np.asarray(coefficients, dtype=float)
        if stacked.ndim == 3:
            blocks = [stacked[spin] for spin in range(stacked.shape[0])]

    if blocks is not None:
        per_block = blocks[0].shape[1]
        if not 0 <= index < per_block * len(blocks):
            raise ValueError(
                f"orbital index {index} outside 0..{per_block * len(blocks) - 1}")
        spin, column = divmod(index, per_block)
        return blocks[spin][:, column]

    stacked = np.asarray(coefficients, dtype=float)
    if not 0 <= index < stacked.shape[1]:
        raise ValueError(f"orbital index {index} outside 0..{stacked.shape[1] - 1}")
    column = stacked[:, index]
    if column.ndim > 1:
        column = column[:, 0]
    return column


def run_orbital_surface(params: dict) -> dict:
    """The isosurface of one orbital, for the 3D viewer.

    Returns a triangle mesh in absolute ångström, in the same frame as the
    molecule the app is already drawing, so the Swift side can add it to the
    existing ball-and-stick scene and have it land in the right place.

    ``source`` picks what to draw.  ``"mo"`` is a canonical molecular orbital,
    indexed the way the energy ladder numbers them.  Any of the intrinsic
    localisation methods (``"pm-mulliken"``, ``"pm-lowdin"``, ``"boys"``,
    ``"er"``) draws a localised occupied orbital instead, which is the picture
    that reads as a bond or a lone pair rather than as a delocalised MO.

    ``isovalue`` is the amplitude the envelope is drawn at, as a fraction of the
    orbital's own peak.  Both lobes are returned, as separate meshes: an orbital
    is signed, and the two phases are what the picture has to show.
    """
    start = time.perf_counter()
    mf, atoms, basis, method, _log = _run_mean_field(params)
    index = int(params.get("index", 0))
    source = str(params.get("source", "mo")).lower()
    points = int(params.get("pointsPerAxis", 40))
    # A fraction of the peak rather than an absolute amplitude: orbitals differ
    # in scale by orders of magnitude between basis sets, and a fixed absolute
    # isovalue would give an empty picture for one and a ball for another.
    fraction = float(params.get("isovalue", 0.05))
    if not 0.0 < fraction < 1.0:
        raise ValueError(f"isovalue must be a fraction in (0, 1), not {fraction}")

    if source == "mo":
        column = _orbital_column(mf, index)
        label = f"MO {index + 1}"
        energies = np.asarray(mf.mo_energy, dtype=float).ravel()
        occupations = np.asarray(mf.mo_occ, dtype=float).ravel()
        orbital_energy = float(energies[index])
        occupation = float(occupations[index])
    elif source in orbital_localization.METHODS:
        column = _localized_column(mf, atoms, source, index)
        label = f"LMO {index + 1}"
        # A localised occupied orbital carries one electron pair, so its energy
        # is not a single MO eigenvalue; the diagonal Fock element is the
        # meaningful one and is what the panel shows.
        fock = np.asarray(mf.get_fock(), dtype=float)
        orbital_energy = float(column @ fock @ column)
        occupation = 2.0
    else:
        raise ValueError(f"unknown orbital source: {source!r}")

    values, origin, step = _orbital_values(mf, atoms, column, points, 1.6)
    peak = float(np.abs(values).max())
    if peak <= 0:
        raise ValueError("the selected orbital is zero everywhere on the grid")
    level = fraction * peak

    # The two phases.  Each is the isosurface of a field whose enclosed region
    # is the lobe in question, so they are extracted independently and coloured
    # differently by the viewer.
    positive = orbital_surface.isosurface(
        values, values.shape, np.asarray(origin), np.asarray(step), level
    )
    negative = orbital_surface.isosurface(
        -values, values.shape, np.asarray(origin), np.asarray(step), level
    )

    wall_ms = (time.perf_counter() - start) * 1000.0
    return {
        "ok": True,
        "method": f"{method}/{basis}",
        "energy": round(float(mf.e_tot), 10),
        "wallTimeMs": round(wall_ms, 3),
        "source": source,
        "index": index,
        "label": label,
        "orbitalEnergy": round(orbital_energy, 8),
        "occupation": round(occupation, 6),
        "nBasis": int(mf.mol.nao_nr()),
        "pointsPerAxis": points,
        "isovalue": round(level, 8),
        "isovalueFraction": fraction,
        "peak": round(peak, 8),
        "positive": positive,
        "negative": negative,
        "triangles": (len(positive["indices"]) + len(negative["indices"])) // 3,
    }


def run_localized_orbitals(params: dict) -> dict:
    """Localised property-optimised orbitals for an existing wavefunction.

    ``kind`` selects JANPA's two variants: ``"clpo"`` for the chemist's orbitals
    that keep lone pairs on their own atom, ``"lpo"`` for the plain
    property-optimised ones.  Defaults to CLPO, the one that reads as a Lewis
    structure.
    """
    start = time.perf_counter()
    mf, atoms, basis, method, _log = _run_mean_field(params)
    wall_ms = (time.perf_counter() - start) * 1000.0
    kind = str(params.get("kind", "clpo")).lower()
    if kind not in ("clpo", "lpo"):
        raise ValueError(f"kind must be 'clpo' or 'lpo', not {kind!r}")
    result = localized_orbitals.localized_orbitals(mf, atoms, kind=kind)
    if result is None:
        raise ValueError("localised orbital analysis is unavailable for this wavefunction")
    return {
        "ok": True,
        "method": f"{method}/{basis}",
        "energy": round(float(mf.e_tot), 10),
        "wallTimeMs": round(wall_ms, 3),
        **result,
    }


def dispatch(method: str, params: dict) -> dict:
    """Route a request to the matching handler."""
    if method == "elements":
        from .elements import all_elements

        return {"ok": True, "elements": all_elements()}
    if method == "presets":
        return {
            "ok": True,
            "presets": presets(),
            "basisSets": list(BASIS_SETS),
            "functionals": list(FUNCTIONALS),
            "methods": list(METHODS),
        }
    if method == "status":
        return {"ok": True, **engine_status()}
    if method == "diagnostics":
        return diagnostics()
    if method == "openmp":
        from .omp_probe import openmp_report

        return {"ok": True, **openmp_report()}
    if method == "threads":
        # Read when "threads" is absent, set when it is present. A single method
        # for both keeps the two directions from drifting apart.
        return num_threads(params.get("threads"))

    handlers = {
        "scf": run_scf,
        "dft": run_scf,
        "mp2": run_mp2,
        "ccsd": run_ccsd,
        "bond_scan": run_bond_scan,
        "geometry": analyse_geometry,
        "nbo": run_natural_population,
        "wiberg": run_wiberg,
        # The method name is the default variant, so "lpo" does not need an
        # explicit kind while "clpo" can still be asked for anything.
        "lpo": lambda params: run_localized_orbitals({**params, "kind": params.get("kind", "lpo")}),
        "clpo": lambda params: run_localized_orbitals({**params, "kind": params.get("kind", "clpo")}),
        # The intrinsic methods, each named after its objective.  The objective
        # travels in "kind" because "method" is the mean-field reference here.
        "pm": run_intrinsic_localization,
        "pipek_mezey": run_intrinsic_localization,
        "boys": lambda params: run_intrinsic_localization({**params, "kind": "boys"}),
        "er": lambda params: run_intrinsic_localization({**params, "kind": "er"}),
        "optimise": run_geometry_optimisation,
        "orbital_surface": run_orbital_surface,
    }
    if method not in handlers:
        raise ValueError(f"unknown method: {method!r}")
    return handlers[method](params or {})


def handle(request: dict) -> dict:
    """Execute one JSON-RPC style request, never raising."""
    req_id = request.get("id")
    method = request.get("method", "")
    params = request.get("params") or {}
    try:
        payload = dispatch(str(method), params)
        return {"jsonrpc": "2.0", "id": req_id, "result": payload}
    except EngineUnavailable as exc:
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32001, "message": str(exc), "data": {"kind": "unavailable"}},
        }
    except Exception as exc:
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {
                "code": -32000,
                "message": f"{type(exc).__name__}: {exc}",
                "data": {"kind": "execution", "traceback": traceback.format_exc()[-2000:]},
            },
        }


def _main() -> int:
    """CLI entry point: read one JSON request from stdin, write one response."""
    import json
    import sys

    raw = sys.stdin.read()
    try:
        request = json.loads(raw)
    except json.JSONDecodeError as exc:
        sys.stdout.write(
            json.dumps(
                {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": f"parse error: {exc}"}}
            )
        )
        return 1
    sys.stdout.write(json.dumps(handle(request)))
    sys.stdout.flush()
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(_main())
