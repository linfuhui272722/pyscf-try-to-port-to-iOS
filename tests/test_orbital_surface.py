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

from pyscf_mobile import engine, geometry, orbital_surface  # noqa: E402

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
        # Signed tetrahedron volumes about the lobe's own centre.  Taking them
        # about the coordinate origin instead measures how far the lobe sits
        # from the origin, not how much it encloses: this orbital's positive
        # lobe is centred half an ångström off the oxygen, so an origin-based
        # sum ranks the tight contour above the loose one.  For a closed
        # surface the enclosed volume is independent of the reference point,
        # so any interior point works and the vertex mean is one.
        shift = vertices.mean(axis=0)
        a, b, c = (triangles - shift)[:, 0], (triangles - shift)[:, 1], (triangles - shift)[:, 2]
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
        # on the molecule, and none reaches absurdly far away.  These bounds are
        # deliberately close -- a Bohr/ångström mix-up inflates the envelope by
        # 1.8897 and, on a molecule away from the origin, displaces it, so a
        # bound loose enough to admit that is a bound that tests nothing.
        centre = vertices.mean(axis=0)
        molecule_centre = (coordinates.min(axis=0) + coordinates.max(axis=0)) / 2
        assert np.abs(centre - molecule_centre).max() < 0.9, (
            f"MO {index + 1} surface centre {np.round(centre, 2)} is far from "
            f"the molecule centre {np.round(molecule_centre, 2)}"
        )
        # Every orbital of a 0.9 A molecule fits well inside a 3 A cube; the
        # inflated version spanned over 5 A.
        assert np.abs(vertices).max() < 3.0
        # A surface that was not clipped is closed by the field, so it must not
        # lie against the sampling box.  This is the invariant the old fixed
        # padding broke: the mesh ran to the box wall and read as the orbital
        # filling the whole molecule.
        if not payload.get("clipped"):
            assert vertices.min(axis=0).min() > coordinates.min() - 3.0


def test_orbital_surface_is_translation_covariant():
    """Moving the molecule moves the envelope with it, and changes nothing else.

    ``mol.eval_gto`` reads its argument in Bohr while the app works in
    ångström.  Passing the grid through unconverted stretches the orbital by
    1.8897 about the *global origin*, so a molecule at the origin still looks
    roughly right while one anywhere else gets an envelope that is too large
    and centred on the wrong point -- the "wraps the whole molecule" report.

    Both symptoms come from the same factor, so the test pins both: the shape
    must be identical under translation (same peak, same extent, same triangle
    count) and the envelope must sit on the atoms it was computed from.
    """
    shift = np.array([5.0, 3.0, -2.0])
    at_origin = "O 0 0 0; H 0 0 0.96; H 0 0.9 0"
    moved = "; ".join(
        f"{line.split()[0]} {float(line.split()[1]) + shift[0]:.4f} "
        f"{float(line.split()[2]) + shift[1]:.4f} {float(line.split()[3]) + shift[2]:.4f}"
        for line in at_origin.split("; ")
    )

    def draw(spec):
        return engine.dispatch("orbital_surface", {
            "atoms": spec, "basis": "sto-3g", "method": "RHF",
            "source": "mo", "index": 4, "pointsPerAxis": 32, "isovalue": 0.05,
        })

    here, there = draw(at_origin), draw(moved)

    # The field is evaluated on a grid of the same shape in both cases, so the
    # peak must match to grid resolution.  A Bohr/ångström mix-up moves it by
    # percent, not by rounding.
    assert abs(here["peak"] - there["peak"]) < 1e-6, (
        f"the orbital peak changed under translation "
        f"({here['peak']} vs {there['peak']}) -- the grid is not in the molecule's frame"
    )

    def extent(payload):
        phases = [np.asarray(payload[k]["vertices"], dtype=float) for k in ("positive", "negative")]
        points = np.vstack([p for p in phases if p.size])
        return points.max(axis=0) - points.min(axis=0), points.mean(axis=0)

    span_here, centre_here = extent(here)
    span_there, centre_there = extent(there)
    assert np.allclose(span_here, span_there, atol=1e-6), (
        f"the envelope changed size under translation ({span_here} vs {span_there})"
    )
    assert np.allclose(centre_there - centre_here, shift, atol=1e-6), (
        f"the envelope did not follow the molecule: moved by "
        f"{centre_there - centre_here}, expected {shift}"
    )

    # And in absolute terms it must land on the nuclei, not near them: the
    # oxygen is the first atom, and the 1s core-like HOMO lobe is centred on it.
    oxygen = np.array([shift[0], shift[1], shift[2]])
    assert np.linalg.norm(centre_there - oxygen) < 0.15, (
        f"the envelope is centred {np.linalg.norm(centre_there - oxygen):.2f} A from the oxygen"
    )


def test_orbital_surface_encloses_a_physical_volume():
    """The drawn envelope is orbital-sized, not molecule-sized.

    With the grid in the wrong units the contour is inflated until it spans the
    whole molecule; water's atoms span 0.9 A, and the inflated envelope spanned
    over 5 A.  The correct 0.05 contour spans about 2 A, so the bound below
    separates the two without pinning the number to the grid resolution.
    """
    payload = engine.dispatch("orbital_surface", {
        "atoms": WATER, "basis": "sto-3g", "method": "RHF",
        "source": "mo", "index": 4, "pointsPerAxis": 32, "isovalue": 0.05,
    })
    vertices, _n, indices = _mesh(payload["positive"])
    assert len(vertices) > 0, "the HOMO lobe is empty at the default isovalue"

    span = vertices.max(axis=0) - vertices.min(axis=0)
    assert span.max() < 3.0, (
        f"the HOMO lobe spans {span.max():.2f} A on a 0.9 A molecule; an "
        f"envelope this large is the wrong-units signature"
    )

    triangles = vertices[indices.reshape(-1, 3)]
    shift = vertices.mean(axis=0)
    a, b, c = (triangles - shift)[:, 0], (triangles - shift)[:, 1], (triangles - shift)[:, 2]
    volume = abs(float(np.einsum("ij,ij->i", a, np.cross(b, c)).sum()) / 6.0)
    # A valence lobe at this contour is a couple of cubic ångström; the bound is
    # loose because the grid spacing sets the last digit.
    assert 0.1 < volume < 4.0, f"the HOMO lobe encloses {volume:.3f} A^3"


def test_orbital_surface_keeps_its_resolution_when_the_box_grows():
    """A bigger box is sampled more finely, not more coarsely.

    The box has to grow for a diffuse orbital or the envelope is closed by the
    wall instead of the field.  Growing it while holding the point count fixed
    coarsens the spacing, and a grid too coarse to resolve the orbital draws a
    blob whose size tracks the grid rather than the orbital -- the same wrong
    picture as a units error, from the other direction.  The engine instead
    scales the point count to hold the spacing.

    The invariant is stated on ``gridStep``, the coarsest axis's spacing: a
    coarsened grid still produces a well-formed, correctly-placed surface, so
    only the spacing distinguishes it.  Benzene's pi orbital grows the box
    enough to add points without reaching ``_MAX_POINTS_PER_AXIS``, which is the
    case this test is about; at the cap the spacing is expected to coarsen.
    """
    BENZENE = ("C 0.0000 1.3960 0; C 1.2090 0.6980 0; C 1.2090 -0.6980 0; "
               "C 0.0000 -1.3960 0; C -1.2090 -0.6980 0; C -1.2090 0.6980 0; "
               "H 0.0000 2.4810 0; H 2.1490 1.2405 0; H 2.1490 -1.2405 0; "
               "H 0.0000 -2.4810 0; H -2.1490 -1.2405 0; H -2.1490 1.2405 0")
    grown = engine.dispatch("orbital_surface", {
        "atoms": BENZENE, "basis": "sto-3g", "method": "RHF",
        "source": "mo", "index": 20, "pointsPerAxis": 40, "isovalue": 0.05,
    })

    # The spacing the atom-sized box would have used: its widest axis is the
    # molecule's span plus the default 1.6 A padding either side, over 40 points.
    # A coarsened grid reports a much larger value here.
    coords = geometry.atoms_to_coords(engine._coerce_atoms(BENZENE))
    atom_box_step = (float(np.ptp(coords, axis=0).max()) + 2 * 1.6) / 39
    assert abs(grown["gridStep"] - atom_box_step) < 0.01, (
        f"the grid coarsened as the box grew: {grown['gridStep']:.3f} A spacing "
        f"over {grown['gridPointsPerAxis']} points, against the "
        f"{atom_box_step:.3f} A the atom-sized box would have used"
    )
    assert grown["gridPointsPerAxis"] > 40, (
        "the box did not grow, so this test is not exercising the growth path"
    )
    assert grown["gridPointsPerAxis"] < engine._MAX_POINTS_PER_AXIS, (
        "the box grew to the cap, so this test cannot see the spacing invariant"
    )
    assert not grown["clipped"]


# ---------------------------------------------------------------------------
# Orbital composition
# ---------------------------------------------------------------------------
#
# Each orbital is annotated with what it is built from: which atom, which
# angular momentum, what share.  The failure this guards against is chemical,
# not numerical -- a composition that names an atomic orbital the basis does not
# contain reads as a plausible percentage and no arithmetic check would catch
# it, so the tests pin the answer to the chemistry.


def test_composition_names_angular_momentum_not_shell_label():
    """Water's HOMO is the oxygen p lone pair, and it says so.

    The 1b1 lone pair of water is pure oxygen 2p by symmetry.  A split-valence
    basis puts two p shells on oxygen, and PySCF labels them ``2p`` and ``3p``
    because its principal number counts per angular momentum rather than
    following the aufbau filling.  Reporting the second as ``3p`` would name a
    high-lying atomic orbital water does not have -- the kind of number that
    looks right and is not.  Only the angular momentum is reported.
    """
    payload = engine.dispatch("scf", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "include": [],
    })
    compositions = payload["orbitalCompositions"]
    assert compositions is not None, "the composition is missing from the payload"
    assert len(compositions["orbitals"]) == payload["nBasis"], (
        "one composition per orbital, in the ladder's order")

    # MO 5 is the 1b1 lone pair (index 4).  It is oxygen p and nothing else.
    homo = compositions["orbitals"][4]
    angular = {component["angular"] for component in homo["components"]}
    assert angular == {"p"}, (
        f"the 1b1 lone pair is reported as {sorted(angular)}; it is pure oxygen p"
    )
    oxygen_p = [component for component in homo["components"]
                if component["element"] == "O" and component["angular"] == "p"]
    assert len(oxygen_p) == 1, "oxygen's p population is reported as one component"
    assert abs(oxygen_p[0]["percent"] - 100.0) < 0.5, (
        f"the lone pair is {oxygen_p[0]['percent']}% oxygen p, not all of it")
    for component in homo["components"]:
        assert component["angular"] in ("s", "p", "d", "f"), (
            f"{component['angular']!r} is not an angular momentum; a principal "
            f"quantum number leaked back into the composition")


def test_composition_percentages_sum_to_one_hundred():
    """Every orbital's shares add to 100, including the virtuals.

    ``C^T S C = I`` makes the signed per-AO Mulliken populations of any orbital
    sum to exactly one, so the percentages sum to 100.  Summing magnitudes
    instead would let a negative overlap term inflate the total and break the
    one property that makes the numbers readable as a share, so the invariant is
    checked on a case -- water's 4a1, MO 6 -- that carries a large negative
    oxygen s contribution.
    """
    payload = engine.dispatch("scf", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "include": [],
    })
    for index, orbital in enumerate(payload["orbitalCompositions"]["orbitals"]):
        assert abs(orbital["total"] - 100.0) < 0.5, (
            f"orbital {index + 1} sums to {orbital['total']}, not 100")


def test_composition_keeps_the_largest_component_when_all_are_small():
    """A delocalised orbital still reports what it is made of.

    Benzene's pi orbital spreads over six carbons, so at a one-percent floor
    every component survives and the list is long.  The floor exists for the
    orbitals that spread over far more atoms than that, and the guarantee is
    that the strongest component is never dropped: an orbital annotated with
    nothing at all is worse than one annotated with only its main contributor.
    """
    payload = engine.dispatch("scf", {
        "atoms": BENZENE, "basis": "sto-3g", "method": "RHF", "include": [],
    })
    compositions = payload["orbitalCompositions"]
    for index, orbital in enumerate(compositions["orbitals"]):
        assert orbital["components"], f"orbital {index + 1} reports no components"
        assert abs(orbital["components"][0]["percent"]) > 0, (
            f"orbital {index + 1}'s leading component is zero")
        percents = [component["percent"] for component in orbital["components"]]
        assert percents == sorted(percents, key=abs, reverse=True), (
            f"orbital {index + 1}'s components are not strongest first")


def test_orbital_surface_reports_the_composition_of_what_it_drew():
    """The drawn orbital carries its own composition, not the ladder's.

    The viewer can draw a localised orbital, which is not one of the canonical
    orbitals the run payload describes, so the surface has to carry the
    composition of the coefficients it was actually built from.  A localised
    lone pair on oxygen is a single centre, which is what makes the annotation
    on the picture agree with the picture.
    """
    canonical = engine.dispatch("orbital_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF",
        "source": "mo", "index": 4, "pointsPerAxis": 20,
    })
    assert canonical["composition"] is not None, "the surface carries no composition"
    angular = {component["angular"] for component in canonical["composition"]["components"]}
    assert angular == {"p"}, f"the drawn lone pair is reported as {sorted(angular)}"

    localised = engine.dispatch("orbital_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF",
        "source": "pm-mulliken", "index": 0, "pointsPerAxis": 20,
    })
    assert localised["composition"] is not None, (
        "a localised orbital's surface carries no composition")
    assert abs(localised["composition"]["total"] - 100.0) < 0.5, (
        f"the localised orbital sums to {localised['composition']['total']}, not 100")


def test_composition_survives_an_unrestricted_reference():
    """Both spin blocks are annotated, in the ladder's own order.

    An unrestricted reference stores the alpha and beta orbitals as separate
    blocks and the energy ladder concatenates them, so the composition has to
    cover the same span.  Getting this wrong reports one block's composition
    against the other block's index, which still sums to 100 and so passes any
    arithmetic check.
    """
    payload = engine.dispatch("scf", {
        "atoms": "O 0 0 0; O 0 0 1.21", "basis": "sto-3g",
        "method": "UHF", "spin": 2, "include": [],
    })
    assert payload["nAlpha"] != payload["nBeta"], (
        "the fixture is not spin-polarised, so it does not exercise both blocks")
    orbitals = payload["orbitalCompositions"]["orbitals"]
    # Each spin block carries one orbital per basis function, so the unrestricted
    # ladder is twice the basis size -- the same span the energy chart shows.
    assert len(orbitals) == 2 * payload["nBasis"], (
        f"{len(orbitals)} compositions for {payload['nBasis']} basis functions "
        f"across both spins")
    for index, orbital in enumerate(orbitals):
        assert abs(orbital["total"] - 100.0) < 0.5, (
            f"orbital {index + 1} of the unrestricted reference sums to "
            f"{orbital['total']}, not 100")

