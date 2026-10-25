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

from . import geometry

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

    for name in ("libcgto", "libdft", "libnp_helper"):
        try:
            _lib.load_library(name)
            libs[name] = True
        except Exception as exc:  # pragma: no cover
            libs[name] = False
            libs[f"{name}_error"] = str(exc)
    return {
        "available": True,
        "error": None,
        "version": getattr(pyscf, "__version__", "unknown"),
        "numpy": getattr(np, "__version__", "unknown"),
        "libraries": libs,
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
    return gto.M(
        atom=atom_block,
        basis=basis,
        charge=int(charge),
        spin=int(spin),
        unit=unit,
        verbose=0,
        output=None,
    )


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
    return mf


def _finalise(mf, atoms, method, basis, wall_ms, log, include) -> dict:
    result: dict[str, Any] = {
        "ok": True,
        "method": f"{method}/{basis}",
        "energy": round(float(mf.e_tot), 10),
        "converged": bool(mf.converged),
        "cycles": int(getattr(mf, "cycles", 0) or 0),
        "wallTimeMs": round(wall_ms, 3),
        "log": log[-4000:],
    }
    result.update(_electronic_structure(mf, atoms, include))
    return result


def _electronic_structure(mf, atoms, include) -> dict:
    """Orbital, population and density payloads for one converged calculation."""
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
        "dipole": _dipole(mf),
        "mulliken": _mulliken(mf, atoms),
    }
    if "mo" in include:
        result["moCoefficients"] = np.asarray(mf.mo_coeff, dtype=float).tolist()
    if "overlap" in include:
        result["overlap"] = np.asarray(mf.get_ovlp(), dtype=float).tolist()
    if "density" in include:
        result["density"] = np.asarray(mf.make_rdm1(), dtype=float).tolist()
    if "grid" in include:
        result["grid"] = _density_grid(mf, atoms)
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
    with contextlib.redirect_stdout(buf):
        mf = _make_method(mol, method, xc, params)
        mf.kernel(dm0=dm0)
    return mf, atoms, basis, method, buf.getvalue()


def run_scf(params: dict) -> dict:
    """Run a Hartree-Fock or Kohn-Sham calculation."""
    include = {str(x).lower() for x in params.get("include", [])}
    start = time.perf_counter()
    mf, atoms, basis, method, log = _run_mean_field(params)
    wall_ms = (time.perf_counter() - start) * 1000.0
    return _finalise(mf, atoms, method, basis, wall_ms, log, include)


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
    result = _finalise(mf, mol_atoms, label, basis, wall_ms, buf.getvalue(), include)
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
            res = run_scf(single)
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
    for key in ("maxCycle", "convTol", "initGuess"):
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
        mf, built, _basis, _method, log = _run_mean_field(step_params, dm0=state["dm"])
        if not mf.converged:
            call_log.append("warning: an SCF cycle during the relaxation did not converge")
        state["mf"] = mf
        state["dm"] = mf.make_rdm1()
        gradient = np.asarray(_gradient_method(mf).kernel(), dtype=float).reshape(-1)
        return float(mf.e_tot), gradient

    initial = _coerce_atoms(params["atoms"])
    state["atoms"] = initial
    # PySCF's mol.atom_coords() is in Bohr, and the gradient is Ha/Bohr, so the
    # whole relaxation runs in Bohr and is converted back at the end.
    reference = _build_mol(initial, basis, base["charge"], base["spin"], "Angstrom")
    x0 = np.asarray(reference.atom_coords(), dtype=float).reshape(-1)

    outcome = geomopt.minimise(
        x0,
        energy_and_grad,
        max_steps=max_steps,
        conv_tol_grad=conv_tol_grad,
        conv_tol_energy=conv_tol_energy,
    )
    wall_ms = (time.perf_counter() - start) * 1000.0

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
        mf, _b, _ba, _m, refine_log = _run_mean_field(refine_params, dm0=state["dm"])
        if refine_log.strip():
            call_log.append(refine_log.strip())
        gradient = np.asarray(_gradient_method(mf).kernel(), dtype=float).reshape(-1)
        state["mf"] = mf
        refined = (float(mf.e_tot), gradient)

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
        result.update(_electronic_structure(mf, angstrom_atoms, include))
    return result


def analyse_geometry(params: dict) -> dict:
    atoms = _coerce_atoms(params["atoms"])
    return {"ok": True, **geometry.describe(atoms)}


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

    handlers = {
        "scf": run_scf,
        "dft": run_scf,
        "mp2": run_mp2,
        "ccsd": run_ccsd,
        "bond_scan": run_bond_scan,
        "geometry": analyse_geometry,
        "optimise": run_geometry_optimisation,
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
