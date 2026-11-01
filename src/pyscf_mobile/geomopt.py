"""Cartesian geometry relaxation for the mobile engine.

PySCF ships two optimisers and neither can run on iOS: ``geomopt.berny_solver``
needs the ``berny`` package and ``geomopt.geometric_solver`` needs
``geometric``, and both pull in SciPy's Fortran linear algebra.  This module does
the same job on top of the analytic gradients PySCF already computes, using only
NumPy.

Coordinates are Cartesian and in Bohr, because PySCF reports gradients in
Ha/Bohr.  Rigid-body translations and rotations are projected out of every
gradient before it is used as a step direction; that is what stops the molecule
from drifting across the cell or tumbling, which an unprojected gradient
eventually does because those motions cost no energy.
"""

from __future__ import annotations

import numpy as np

from .diaglog import crash_probe, get_logger

__all__ = ["max_abs", "rms", "rigid_body_basis", "minimise"]


def max_abs(vector) -> float:
    """Largest absolute component, the usual convergence measure for a gradient."""
    values = np.asarray(vector, dtype=float)
    return float(np.max(np.abs(values))) if values.size else 0.0


def rms(vector) -> float:
    """Root-mean-square of the components."""
    values = np.asarray(vector, dtype=float)
    return float(np.sqrt(np.mean(values ** 2))) if values.size else 0.0


def rigid_body_basis(coords) -> np.ndarray:
    """Orthonormal basis for the rigid-body motions of ``coords``.

    ``coords`` is an ``(n, 3)`` array in Bohr.  The result has one column per
    independent motion: three translations, plus the rotations that actually
    displace the atoms.  A single atom has no independent rotation and a linear
    molecule has only two, so dependent columns are dropped rather than left to
    make the projection ill-conditioned.
    """
    coords = np.asarray(coords, dtype=float)
    n = coords.shape[0]
    if n == 0:
        return np.zeros((0, 0))

    basis = np.zeros((3 * n, 6))
    for axis in range(3):
        column = np.zeros((n, 3))
        column[:, axis] = 1.0
        basis[:, axis] = column.ravel()

    relative = coords - coords.mean(axis=0)
    for index, (i, j) in enumerate(((1, 2), (2, 0), (0, 1))):
        column = np.zeros((n, 3))
        column[:, i] = -relative[:, j]
        column[:, j] = relative[:, i]
        basis[:, 3 + index] = column.ravel()

    orthogonal, triangular = np.linalg.qr(basis)
    diagonal = np.abs(np.diag(triangular))
    if diagonal.size == 0:
        return orthogonal[:, :0]
    threshold = max(float(diagonal.max()) * 1e-9, 1e-12)
    return orthogonal[:, diagonal > threshold]


def _project(x, gradient, projector):
    if projector is not None:
        return np.asarray(projector(x, gradient), dtype=float)
    basis = rigid_body_basis(np.asarray(x, dtype=float).reshape(-1, 3))
    if basis.shape[1] == 0:
        return np.asarray(gradient, dtype=float)
    return gradient - basis @ (basis.T @ gradient)


def translation_basis(coords) -> np.ndarray:
    """Orthonormal basis for the uniform translations of ``coords``.

    This is ``rigid_body_basis`` without the rotations, and the difference
    matters for a periodic cell.  In a molecule the lattice is not there, so
    translating or rotating the whole thing costs no energy and both are removed
    from the gradient before it is used as a step direction.

    In a cell whose lattice vectors are fixed — which is how a relaxation is run
    here — translation is still free, because the cell is periodic and moving
    every atom by one cell vector returns the same crystal.  Rotation is *not*
    free: the lattice does not turn with the atoms, so rotating the contents
    changes the structure and the energy.  Measured on a silicon cell, the
    gradient has a component of 8.1 Ha/Bohr along the rotations against 1e-13
    along the translations, so projecting the rotations out would delete a real
    force and stop the relaxation from finding the true minimum.
    """
    coords = np.asarray(coords, dtype=float)
    n = coords.shape[0]
    if n == 0:
        return np.zeros((0, 0))

    basis = np.zeros((3 * n, 3))
    for axis in range(3):
        column = np.zeros((n, 3))
        column[:, axis] = 1.0
        basis[:, axis] = column.ravel()
    orthogonal, _triangular = np.linalg.qr(basis)
    return orthogonal[:, :3]


def translation_projector(x, gradient):
    """``_project``'s projector argument for a periodic cell.

    Returns the gradient with the uniform translations removed.  The rotations
    are left in, unlike a molecular relaxation, because the lattice does not turn
    with the atoms — see ``translation_basis``.
    """
    basis = translation_basis(np.asarray(x, dtype=float).reshape(-1, 3))
    values = np.asarray(gradient, dtype=float).reshape(-1)
    if basis.shape[1] == 0:
        return values
    return values - basis @ (basis.T @ values)


def _numerical_gradient(energy, x, step: float = 1e-3) -> np.ndarray:
    """Central-difference gradient of ``energy`` at ``x``.

    Used for a periodic relaxation, where the analytic lattice gradient cannot
    be trusted.  PySCF's ``pyscf.pbc.grad`` implements the local pseudopotential
    and the Hellmann-Feynman terms but not the nonlocal one, and its own
    docstring says so; measured against a central difference on a silicon cell
    the result is 13.15 Ha/Bohr where the true gradient is 24.85, a factor of
    two.  A relaxation driven by that converges to the wrong structure, so the
    difference is taken numerically instead.

    ``step`` is in the same unit as ``x``.  1e-3 Bohr is small enough that the
    truncation error is far below the convergence tolerance and large enough
    that the difference is not dominated by SCF noise, which is around 1e-8 Ha
    at the default convergence settings.

    The cost is two energies per coordinate, so a relaxation is much more
    expensive than the molecular one.  That is the honest price of a correct
    gradient, and it is reported to the user rather than hidden.
    """
    values = np.asarray(x, dtype=float).reshape(-1).copy()
    gradient = np.empty(values.size)
    for index in range(values.size):
        original = values[index]
        values[index] = original + step
        plus = float(energy(values))
        values[index] = original - step
        minus = float(energy(values))
        values[index] = original
        gradient[index] = (plus - minus) / (2.0 * step)
    return gradient


def minimise(
    x0,
    energy_and_grad,
    max_steps: int = 40,
    conv_tol_grad: float = 3e-4,
    conv_tol_energy: float = 1e-6,
    max_step_size: float = 0.3,
    projector=None,
) -> dict:
    """Relax ``x0`` towards a stationary point with BFGS on analytic gradients.

    ``energy_and_grad(x)`` must return ``(energy, gradient)`` for the flattened
    coordinate vector ``x``.  Convergence is the maximum absolute component of
    the projected gradient falling below ``conv_tol_grad``, which is the same
    criterion PySCF's own optimisers use.

    Returns the final coordinates, energy, gradient and a per-step trajectory.
    """
    x = np.asarray(x0, dtype=float).copy()
    size = x.size
    if size == 0:
        raise ValueError("no coordinates to optimise")

    # Each step is logged as it starts and finishes. The device crash this was
    # added for happened on the second step and left no record anywhere, so the
    # last line before the log stops is the whole point of these calls.
    logger = get_logger()
    logger.write(
        f"minimise: start, {size // 3} atoms ({size} coords), maxSteps={max_steps} "
        f"tolGrad={conv_tol_grad} tolE={conv_tol_energy}; {crash_probe()}",
        tag="geomopt",
    )

    energy, gradient = energy_and_grad(x)
    gradient = _project(x, gradient, projector)
    hessian = np.eye(size)
    trajectory = [
        {
            "step": 0,
            "energy": float(energy),
            "maxGrad": max_abs(gradient),
            "rmsGrad": rms(gradient),
            "deltaE": None,
        }
    ]
    logger.write(
        f"minimise: step 0 done, E={energy:.10f} max|g|={max_abs(gradient):.3e}; {crash_probe()}",
        tag="geomopt",
    )
    converged = False
    message = "maximum steps reached"

    for step in range(1, max_steps + 1):
        if max_abs(gradient) < conv_tol_grad:
            converged, message = True, "converged"
            break

        direction = -hessian @ gradient
        # A bad curvature estimate can turn the quasi-Newton direction uphill.
        if float(direction @ gradient) > 0:
            direction = -gradient
            hessian = np.eye(size)

        # The first step starts from an identity Hessian, so cap its length;
        # an uncapped step can throw the atoms far enough that the SCF fails.
        largest = float(np.max(np.abs(direction)))
        step_size = min(1.0, max_step_size / largest) if largest > 0 else 1.0

        trial = None
        attempt = 0
        while step_size > 1e-10:
            attempt += 1
            trial = x + step_size * direction
            # Logged before the call, not after: if the SCF or the gradient
            # driver dies inside it, this is the line that says so.
            logger.write(
                f"minimise: step {step} trial {attempt} at stepSize={step_size:.6f}; {crash_probe()}",
                tag="geomopt",
            )
            trial_energy, trial_gradient = energy_and_grad(trial)
            trial_gradient = _project(trial, trial_gradient, projector)
            if trial_energy <= energy + 1e-4 * step_size * float(gradient @ direction):
                break
            trial = None
            step_size *= 0.5

        if trial is None:
            logger.write(f"minimise: step {step} line search exhausted", tag="geomopt")
            message = "line search could not lower the energy"
            break

        displacement = trial - x
        change = trial_gradient - gradient
        curvature = float(displacement @ change)
        if curvature > 1e-12 * float(np.linalg.norm(displacement)) * float(np.linalg.norm(change)):
            rho = 1.0 / curvature
            update = np.eye(size) - rho * np.outer(displacement, change)
            hessian = update @ hessian @ update.T + rho * np.outer(displacement, displacement)

        delta_e = trial_energy - energy
        x, energy, gradient = trial, trial_energy, trial_gradient
        trajectory.append(
            {
                "step": step,
                "energy": float(energy),
                "maxGrad": max_abs(gradient),
                "rmsGrad": rms(gradient),
                "deltaE": float(delta_e),
            }
        )
        logger.write(
            f"minimise: step {step} done, E={energy:.10f} dE={delta_e:+.3e} "
            f"max|g|={max_abs(gradient):.3e}; {crash_probe()}",
            tag="geomopt",
        )

        if max_abs(gradient) < conv_tol_grad:
            converged, message = True, "converged"
            break
        # A flat surface with a small gradient is a stationary point even if the
        # gradient never quite reaches the tight threshold.
        if abs(delta_e) < conv_tol_energy and max_abs(gradient) < 10 * conv_tol_grad:
            converged, message = True, "converged"
            break

    logger.write(
        f"minimise: finished, steps={len(trajectory) - 1} converged={converged} "
        f"({message}); {crash_probe()}",
        tag="geomopt",
    )
    return {
        "x": x,
        "energy": float(energy),
        "gradient": gradient,
        "steps": len(trajectory) - 1,
        "converged": converged,
        "message": message,
        "trajectory": trajectory,
    }
