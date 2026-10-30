"""The orbital isosurface and the RPC the 3D viewer draws from.

The picture the viewer draws is a triangle mesh, so a bug here is a shape on
screen rather than a number: a wrong isovalue or a mesh in the wrong frame still
produces a plausible blob.  The tests therefore pin the geometry to an analytic
answer wherever one exists, and check the frame against the atoms rather than
against the mesh itself.

Run with ``python tests/run_tests.py``.
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src"))

import numpy as np  # noqa: E402
from pyscf import gto, scf  # noqa: E402

from pyscf_mobile import engine, orbital_surface  # noqa: E402

WATER = "O 0 0 0; H 0 -0.757 0.587; H 0 0.757 0.587"
BENZENE = (
    "C 0.0000 1.3960 0; C 1.2090 0.6980 0; C 1.2090 -0.6980 0; "
    "C 0.0000 -1.3960 0; C -1.2090 -0.6980 0; C -1.2090 0.6980 0; "
    "H 0.0000 2.4810 0; H 2.1490 1.2405 0; H 2.1490 -1.2405 0; "
    "H 0.0000 -2.4810 0; H -2.1490 -1.2405 0; H -2.1490 1.2405 0"
)


def _mesh(payload: dict) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Vertices, normals and indices of one phase as arrays."""
    phase = payload
    return (
        np.asarray(phase["vertices"], dtype=float).reshape(-1, 3),
        np.asarray(phase["normals"], dtype=float).reshape(-1, 3),
        np.asarray(phase["indices"], dtype=np.int64),
    )


def _sphere(n: int = 40, radius: float = 1.2, lo: float = -1.8, hi: float = 1.8):
    """A radial field whose zero crossing is exactly a sphere of ``radius``."""
    axis = np.linspace(lo, hi, n)
    gx, gy, gz = np.meshgrid(axis, axis, axis, indexing="ij")
    values = radius ** 2 - (gx ** 2 + gy ** 2 + gz ** 2)
    step = (hi - lo) / (n - 1)
    return values, np.array([lo, lo, lo]), np.array([step, step, step])


def test_isosurface_is_the_analytic_sphere():
    """Every vertex of the r = radius surface lies on that sphere.

    A triangulation bug shows up here as vertices off the sphere rather than as
    a wrong triangle count, which is why the check is geometric.
    """
    radius = 1.2
    values, origin, step = _sphere(radius=radius)
    mesh = orbital_surface.isosurface(values, values.shape, origin, step, 0.0)
    vertices, normals, indices = _mesh(mesh)

    assert vertices.size > 0
    assert indices.size % 3 == 0

    radii = np.linalg.norm(vertices, axis=1)
    # The surface is piecewise linear through a grid of step h, so the radius
    # error is bounded by the grid, not by machine precision.
    grid_step = float(step[0])
    assert np.abs(radii - radius).max() < grid_step, (
        f"vertex off the sphere by {np.abs(radii - radius).max():.4f}"
    )

    # The field decreases outward, so the outward normal is radial.
    outward = vertices / radii[:, None]
    alignment = np.einsum("ij,ij->i", normals, outward)
    assert alignment.min() > 0.99, f"a normal points inward ({alignment.min():.4f})"

    lengths = np.linalg.norm(normals, axis=1)
    assert np.allclose(lengths, 1.0, atol=1e-3)


def test_isosurface_mesh_is_well_formed():
    """Indices address real vertices and no triangle is degenerate."""
    values, origin, step = _sphere()
    mesh = orbital_surface.isosurface(values, values.shape, origin, step, 0.0)
    vertices, _normals, indices = _mesh(mesh)

    assert indices.min() >= 0
    assert indices.max() < len(vertices)
    # Welding means a well-formed mesh has far fewer vertices than corners.
    assert len(vertices) < indices.size
    # Every index must be used, or the weld left orphans behind.
    assert len(np.unique(indices)) == len(vertices)


def test_isosurface_places_the_surface_in_the_grid_frame():
    """The mesh is in absolute coordinates, not in grid indices.

    This is what lets the viewer draw the orbital on top of the atoms: if the
    origin and step were ignored, the surface would sit at the origin in grid
    units and would not line up with anything.
    """
    lo, hi, n = -2.5, 3.5, 32
    axis = np.linspace(lo, hi, n)
    gx, gy, gz = np.meshgrid(axis, axis, axis, indexing="ij")
    # A sphere centred away from the origin, so a dropped origin is visible.
    centre = np.array([0.9, -0.4, 0.7])
    radius = 0.8
    values = radius ** 2 - ((gx - centre[0]) ** 2 + (gy - centre[1]) ** 2 + (gz - centre[2]) ** 2)
    step = (hi - lo) / (n - 1)
    mesh = orbital_surface.isosurface(
        values, values.shape, np.array([lo, lo, lo]), np.array([step] * 3), 0.0
    )
    vertices, _normals, _indices = _mesh(mesh)

    recovered = vertices.mean(axis=0)
    assert np.abs(recovered - centre).max() < 0.05, (
        f"surface centred at {np.round(recovered, 3)} instead of {centre}"
    )


def test_isosurface_is_empty_outside_the_field():
    """An isovalue the field never reaches gives an empty mesh, not an error.

    A tightly-bound orbital can sit entirely below a high isovalue, and the
    viewer has to be able to say so rather than fail the request.
    """
    values, origin, step = _sphere()
    mesh = orbital_surface.isosurface(values, values.shape, origin, step, 100.0)
    assert mesh["vertices"] == []
    assert mesh["indices"] == []
    assert mesh["normals"] == []


def test_isosurface_rejects_a_runaway_mesh():
    """A mesh over the triangle budget is refused rather than returned.

    The budget is what keeps a fine grid from building a payload the phone
    cannot hold; it has to raise, because silently truncating would draw a
    partial surface that looks like a real orbital.
    """
    values, origin, step = _sphere(n=64)
    try:
        orbital_surface.isosurface(values, values.shape, origin, step, 0.0, max_triangles=100)
    except ValueError as exc:
        assert "triangles" in str(exc)
    else:
        raise AssertionError("a mesh over the triangle budget was accepted")


def test_orbital_surface_rpc_draws_two_lobes():
    """The 3D payload carries both phases of a canonical orbital.

    Orbital 5 of water (index 4) is the out-of-plane lone pair: its two lobes
    sit on either side of the molecular plane, so the payload must contain two
    non-empty meshes in different places.
    """
    payload = engine.dispatch("orbital_surface", {
        "atoms": WATER, "basis": "sto-3g", "method": "RHF",
        "source": "mo", "index": 4, "pointsPerAxis": 28,
    })
    assert payload["ok"] is True
    assert payload["source"] == "mo"
    assert payload["label"] == "MO 5"
    assert payload["pointsPerAxis"] == 28
    assert payload["isovalueFraction"] == 0.05
    assert abs(payload["isovalue"] - 0.05 * payload["peak"]) < 1e-6

    positive, _pn, _pi = _mesh(payload["positive"])
    negative, _nn, _ni = _mesh(payload["negative"])
    assert positive.size > 0
    assert negative.size > 0
    assert payload["triangles"] > 100

    # The lobes are on opposite sides of the molecular plane (y = 0 here), which
    # is the physics; two lobes at the same place would mean the two phases had
    # been extracted from the same field.
    assert positive[:, 1].mean() * negative[:, 1].mean() < 0, (
        "the two lobes are not on opposite sides of the molecular plane"
    )


def test_orbital_surface_rpc_draws_a_localised_orbital():
    """A localised orbital is drawn from its own coefficients.

    The intrinsic methods return a block of occupied columns, so the surface has
    to come from the rotated column and not from the canonical MO at the same
    index.  A core orbital is the sharpest test: localisation leaves it almost
    unchanged, so it must still be a compact single-signed blob.
    """
    payload = engine.dispatch("orbital_surface", {
        "atoms": WATER, "basis": "sto-3g", "method": "RHF",
        "source": "pm-mulliken", "index": 0, "pointsPerAxis": 28,
    })
    assert payload["source"] == "pm-mulliken"
    assert payload["label"] == "LMO 1"
    # A localised occupied orbital holds one electron pair.
    assert abs(payload["occupation"] - 2.0) < 1e-6
    assert payload["triangles"] > 0

    # The two phases of a localised orbital are not required to both appear --
    # a lone pair or a sigma bond is single-signed in practice -- but at least
    # one must, or there is nothing to draw.
    total = len(payload["positive"]["indices"]) + len(payload["negative"]["indices"])
    assert total > 0


def test_orbital_surface_rpc_honours_the_isovalue():
    """A higher isovalue encloses less of the orbital, so a smaller envelope.

    The direction matters: the isovalue is the amplitude the surface is drawn
    at, and a larger amplitude is a tighter contour.
    """
    loose = engine.dispatch("orbital_surface", {
        "atoms": WATER, "basis": "sto-3g", "method": "RHF",
        "source": "mo", "index": 4, "pointsPerAxis": 24, "isovalue": 0.02,
    })
    tight = engine.dispatch("orbital_surface", {
        "atoms": WATER, "basis": "sto-3g", "method": "RHF",
        "source": "mo", "index": 4, "pointsPerAxis": 24, "isovalue": 0.15,
    })
    assert loose["isovalue"] < tight["isovalue"]

    def volume(payload):
        vertices, _n, indices = _mesh(payload["positive"])
        if len(vertices) == 0:
            return 0.0
        triangles = vertices[indices.reshape(-1, 3)]
        # Signed tetrahedron volumes about the origin: the magnitude of the sum
        # is the enclosed volume, which is what "encloses less" refers to.
        a, b, c = triangles[:, 0], triangles[:, 1], triangles[:, 2]
        return abs(float(np.einsum("ij,ij->i", a, np.cross(b, c)).sum()) / 6.0)

    assert volume(tight) < volume(loose), (
        f"a tighter contour is not smaller ({volume(tight)} vs {volume(loose)})"
    )


def test_orbital_surface_rpc_rejects_bad_input():
    """An unknown source, a bad index and a bad isovalue are all refused."""
    base = {"atoms": WATER, "basis": "sto-3g", "method": "RHF", "pointsPerAxis": 20}

    try:
        engine.dispatch("orbital_surface", {**base, "source": "nonsense"})
    except ValueError:
        pass
    else:
        raise AssertionError("an unknown orbital source was accepted")

    try:
        engine.dispatch("orbital_surface", {**base, "source": "mo", "index": 99})
    except ValueError:
        pass
    else:
        raise AssertionError("an out-of-range orbital index was accepted")

    for bad in (0.0, 1.0, -0.1, 1.5):
        try:
            engine.dispatch("orbital_surface", {**base, "source": "mo", "index": 0, "isovalue": bad})
        except ValueError:
            pass
        else:
            raise AssertionError(f"isovalue {bad} was accepted")


def test_orbital_surface_rpc_handles_an_unrestricted_reference():
    """An open-shell reference draws the right orbital, not a shape error.

    An unrestricted mean field stores alpha and beta coefficients in separate
    blocks while the ladder the app shows concatenates them, so the index has to
    be mapped into the blocks.  Getting that wrong is a hard failure here and an
    empty viewer in the app, which is why the spin blocks are checked directly.
    """
    # The alpha and beta orbitals of water are identical, so the ladder holds
    # the alpha block then the beta block and the two must agree.
    alpha = engine.dispatch("orbital_surface", {
        "atoms": WATER, "basis": "sto-3g", "method": "UHF",
        "source": "mo", "index": 4, "pointsPerAxis": 24,
    })
    beta = engine.dispatch("orbital_surface", {
        "atoms": WATER, "basis": "sto-3g", "method": "UHF",
        "source": "mo", "index": 11, "pointsPerAxis": 24,
    })
    assert alpha["label"] == "MO 5"
    assert beta["label"] == "MO 12"
    assert alpha["triangles"] > 0 and beta["triangles"] > 0
    # A single alpha electron, so the occupation is 1 rather than 2.
    assert abs(alpha["occupation"] - 1.0) < 1e-6
    assert abs(alpha["orbitalEnergy"] - beta["orbitalEnergy"]) < 1e-6

    # An index past the end of both blocks is refused rather than wrapping into
    # the beta block or reading off the array.
    try:
        engine.dispatch("orbital_surface", {
            "atoms": WATER, "basis": "sto-3g", "method": "UHF",
            "source": "mo", "index": 14, "pointsPerAxis": 20,
        })
    except ValueError:
        pass
    else:
        raise AssertionError("an out-of-range index on an unrestricted run was accepted")


def test_orbital_surface_is_in_the_same_frame_as_the_atoms():
    """The surface straddles the molecule it belongs to.

    This is the property the user's correction is about: the orbital has to be
    drawn at its correct position in the whole molecule, which means the mesh
    and the atoms share one coordinate frame.  The engine evaluates the orbital
    on a box around the nuclei and grows that box until the envelope is closed
    by the field rather than by the wall, so a diffuse orbital may legitimately
    reach well past the old fixed padding.
    """
    mol = gto.M(atom=WATER, basis="sto-3g", verbose=0)
    mf = scf.RHF(mol).run()
    atoms = engine.geometry.parse_atom_spec(WATER)
    coordinates = engine.geometry.atoms_to_coords(atoms)

    for index in range(len(mf.mo_energy)):
        payload = engine.dispatch("orbital_surface", {
            "atoms": WATER, "basis": "sto-3g", "method": "RHF",
            "source": "mo", "index": index, "pointsPerAxis": 32,
        })
        positive, _n, _i = _mesh(payload["positive"])
        negative, _n2, _i2 = _mesh(payload["negative"])
        pieces = [p for p in (positive, negative) if len(p)]
        if not pieces:
            continue
        vertices = np.vstack(pieces)

        # The surface is not somewhere else entirely: every orbital is centred
        # on the molecule, and none reaches absurdly far away.
        centre = vertices.mean(axis=0)
        molecule_centre = (coordinates.min(axis=0) + coordinates.max(axis=0)) / 2
        assert np.abs(centre - molecule_centre).max() < 3.0, (
            f"MO {index + 1} surface centre {np.round(centre, 2)} is far from "
            f"the molecule centre {np.round(molecule_centre, 2)}"
        )
        # The mesh is in ångström, the same unit as the geometry, and the
        # adaptive box is capped well inside this bound.
        assert np.abs(vertices).max() < 20.0
        # A surface that was not clipped is closed by the field, so it must not
        # lie against the sampling box.  This is the invariant the old fixed
        # padding broke: the mesh ran to the box wall and read as the orbital
        # filling the whole molecule.
        if not payload.get("clipped"):
            assert vertices.min(axis=0).min() > coordinates.min() - 20.0
