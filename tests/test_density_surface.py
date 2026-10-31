"""The electron-density surface the 3D density view draws.

The picture is a single closed surface at one absolute contour of the total
density, coloured by the density the molecule carries at each atom's position.
Both halves of that are silent when they go wrong: a surface drawn at the wrong
contour still renders as a plausible blob, and a colouring that puts every
vertex on the wrong density still renders -- in the wrong colours.  The tests
therefore pin the mesh to the field it claims to bound, and pin the colour to
the density matrix's own atomic blocks, computed independently.

Run with ``python tests/run_tests.py``.
"""

from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "src"))

import numpy as np  # noqa: E402

from pyscf_mobile import bridge, engine, geometry  # noqa: E402

WATER = "O 0 0 0; H 0 -0.757 0.587; H 0 0.757 0.587"
BENZENE = (
    "C 0.0000 1.3960 0; C 1.2090 0.6980 0; C 1.2090 -0.6980 0; "
    "C 0.0000 -1.3960 0; C -1.2090 -0.6980 0; C -1.2090 0.6980 0; "
    "H 0.0000 2.4810 0; H 2.1490 1.2405 0; H 2.1490 -1.2405 0; "
    "H 0.0000 -2.4810 0; H -2.1490 -1.2405 0; H -2.1490 1.2405 0"
)
HELIUM = "He 0 0 0"


def _rpc(method: str, params: dict) -> dict:
    """One bridge round trip, failing loudly on an engine error."""
    payload = json.loads(bridge.handle_json(json.dumps(
        {"id": 1, "method": method, "params": params})))
    if "error" in payload:
        raise AssertionError(f"{method} failed: {payload['error']['message']}")
    return payload["result"]


def _mean_field(atoms: str, basis: str = "6-31g", method: str = "RHF"):
    params = {"atoms": atoms, "basis": basis, "method": method}
    mf, atom_list, _basis, _method, _log = engine._run_mean_field(params)
    return mf, atom_list


def _vertices(result: dict) -> np.ndarray:
    return np.asarray(result["vertices"], dtype=float).reshape(-1, 3)


def _cell_corners(values: np.ndarray, origin: np.ndarray, step: np.ndarray,
                  points: np.ndarray) -> np.ndarray:
    """The eight grid samples of the cell each point falls in, one row per point.

    A marching-tetrahedra vertex is reported on an edge of a cell whose corner
    values straddle the level, so the vertex's own cell is the only thing that
    has to be inspected to check it: if the level falls outside the cell's value
    range, no crossing could have produced that vertex.
    """
    flat = np.asarray(points, dtype=float).reshape(-1, 3)
    shape = np.asarray(values.shape)
    lower = np.clip(np.floor((flat - origin) / step).astype(int), 0, shape - 2)
    return np.stack([values[lower[:, 0] + di, lower[:, 1] + dj, lower[:, 2] + dk]
                     for di in (0, 1) for dj in (0, 1) for dk in (0, 1)], axis=1)


def _sampled_density_grid(mf, atoms: list[dict], points_per_axis: int):
    """The engine's own grid helper, re-run to check the mesh against it."""
    return engine._density_values(mf, atoms, points_per_axis, engine._DENSITY_PADDING)


def _nuclear_densities(mf, atoms: list[dict]) -> np.ndarray:
    """Each atom's own electrons at that atom's own nucleus, independently."""
    ranges = [(int(s), int(e)) for _a, _b, s, e in mf.mol.aoslice_by_atom()]
    dm = np.asarray(mf.make_rdm1(), dtype=float)
    if dm.ndim == 3:
        dm = dm[0] + dm[1]
    coords = geometry.atoms_to_coords(atoms) / engine._BOHR_TO_ANGSTROM
    out = np.zeros(len(ranges), dtype=float)
    for index, (first, last) in enumerate(ranges):
        ao = mf.mol.eval_gto("GTOval", coords[index:index + 1])[0]
        column = ao[first:last]
        out[index] = float(column @ dm[first:last, first:last] @ column)
    return out


# --------------------------------------------------------------------------
# the field the mesh claims to bound
# --------------------------------------------------------------------------


def test_every_vertex_brackets_the_contour():
    """Each vertex lies on the requested isosurface of the sampled field.

    A vertex of a marching-tetrahedra mesh sits on an edge of a cell whose
    corner values straddle the level, so the level must fall inside the value
    range of the cell the vertex lands in.  That is an exact invariant -- the
    measured violation count is zero -- which makes it a sharp test: a surface
    drawn at the wrong level, or in the wrong frame, puts its vertices in cells
    that do not bracket it.

    Note the comparison is against the *sampled* field, not the analytic
    density.  On a 0.19 A grid the density's nuclear cusp is unresolved, so the
    analytic density at a vertex differs from the level by tens of percent; that
    is the grid's resolution, not the mesh's error.
    """
    result = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 40})
    mf, atoms = _mean_field(WATER)
    values, origin, step = _sampled_density_grid(mf, atoms, result["gridPointsPerAxis"])
    assert result["gridPointsPerAxis"] == values.shape[0]
    assert np.allclose(origin, result["gridOrigin"], atol=1e-6)
    # ``gridStep`` is the largest of the three axis steps: the box is fitted to
    # the molecule's own extent, so the three steps differ and the reported
    # figure is the coarsest of them.
    assert abs(max(float(v) for v in step) - result["gridStep"]) < 1e-6

    vertices = _vertices(result)
    assert vertices.size > 0
    corners = _cell_corners(values, np.asarray(origin), np.asarray(step), vertices)
    level = result["level"]
    straddles = (corners.min(axis=1) <= level) & (corners.max(axis=1) >= level)
    assert straddles.all(), (
        f"level {level}: {int((~straddles).sum())} of {len(straddles)} vertices "
        f"fall in cells that do not contain the level")


def test_the_peak_is_the_largest_density_on_the_sampled_box():
    """``peak`` is the maximum of the field the mesh was built from.

    It is deliberately *not* the density at the nuclei: the peak sits on a cusp
    that a grid of this spacing does not resolve, so the box maximum is far
    below it.  Reporting the cusp would be a number the drawn surface does not
    relate to.
    """
    result = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 32})
    mf, atoms = _mean_field(WATER)
    values, _origin, _step = _sampled_density_grid(mf, atoms, result["gridPointsPerAxis"])
    assert abs(result["peak"] - float(values.max())) < 1e-6
    assert result["peak"] > 0
    # The contour really is below the peak, so the surface exists.
    assert result["level"] < result["peak"]


def test_the_surface_wraps_the_whole_molecule():
    """The default contour reaches past every atom, so the cloud is around them."""
    result = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 40})
    _mf, atoms = _mean_field(WATER)
    coords = geometry.atoms_to_coords(atoms)
    centre = coords.mean(axis=0)
    radii = np.linalg.norm(_vertices(result) - centre, axis=1)
    assert radii.max() > np.linalg.norm(coords - centre, axis=1).max()


def test_a_higher_contour_shrinks_the_surface():
    """Raising the level tightens the surface onto the atoms.

    This is what the screen's detail control turns, and the direction matters:
    a higher contour must not produce a larger surface.
    """
    _mf, atoms = _mean_field(WATER)
    centre = geometry.atoms_to_coords(atoms).mean(axis=0)

    def extent(level):
        result = _rpc("density_surface", {
            "atoms": WATER, "basis": "6-31g", "method": "RHF",
            "pointsPerAxis": 36, "level": level})
        return float(np.linalg.norm(_vertices(result) - centre, axis=1).max())

    loose, tight = extent(0.002), extent(0.05)
    assert tight < loose, f"a higher contour grew the surface: {tight} vs {loose}"


def test_the_winding_agrees_with_the_outward_normals():
    """Every triangle is wound so its normal points outward.

    The renderer culls back faces, which is only correct if the winding is
    consistent: with an arbitrary winding, half the triangles would vanish and
    the surface would look torn from every angle.  The outward direction is the
    reported vertex normal, which is the negated field gradient and points
    outward by construction.
    """
    result = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 32})
    vertices = _vertices(result)
    normals = np.asarray(result["normals"], dtype=float).reshape(-1, 3)
    triangles = np.asarray(result["indices"], dtype=int).reshape(-1, 3)
    p0, p1, p2 = vertices[triangles[:, 0]], vertices[triangles[:, 1]], vertices[triangles[:, 2]]
    geometric = np.cross(p1 - p0, p2 - p0)
    reference = normals[triangles].sum(axis=1)
    agrees = np.einsum("ij,ij->i", geometric, reference) > 0
    assert agrees.all(), f"{int((~agrees).sum())} of {len(agrees)} triangles wind inward"


# --------------------------------------------------------------------------
# the colour, which is the density at each atom's own nucleus
# --------------------------------------------------------------------------


def test_one_density_per_vertex_and_a_range_that_brackets_them():
    """Every vertex is coloured, and the ramp's range spans the values.

    The Swift side scales the ramp to ``densityRange``, so a range that did not
    bracket the vertex values would clip the picture at one end and lose the
    contrast it exists to show.
    """
    result = _rpc("density_surface", {
        "atoms": BENZENE, "basis": "sto-3g", "method": "RHF", "pointsPerAxis": 28})
    count = len(_vertices(result))
    assert count > 0
    values = np.asarray(result["vertexDensity"], dtype=float)
    assert values.size == count
    assert np.all(values > 0.0), "a vertex carries no density"
    low, high = result["densityRange"]
    assert abs(low - values.min()) < 1e-6
    assert abs(high - values.max()) < 1e-6


def test_each_atom_carries_the_density_at_its_own_nucleus():
    """The per-atom figure is that atom's own electrons at its own nucleus.

    Recomputed from ``aoslice_by_atom`` and the density matrix, so this checks
    the engine's answer against the definition rather than against itself.
    """
    result = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 32})
    mf, atoms = _mean_field(WATER)
    expected = _nuclear_densities(mf, atoms)
    got = np.asarray([atom["nucleusDensity"] for atom in result["atoms"]], dtype=float)
    assert np.allclose(got, expected, rtol=1e-6), f"{got} vs {expected}"


def test_the_heavy_atom_carries_far_more_density_than_hydrogen():
    """The colouring is only informative if the atoms really differ.

    Water's oxygen nucleus holds 193 e/bohr^3 against the hydrogens' 0.24, so
    the ramp has nearly three decades to work with.  If the atoms came out
    similar the picture would be one flat colour and the ramp pointless.
    """
    result = _rpc("density_surface", {
        "atoms": WATER, "basis": "sto-3g", "method": "RHF", "pointsPerAxis": 24})
    by_element = {atom["element"]: atom["nucleusDensity"] for atom in result["atoms"]}
    assert by_element["O"] > 10.0, by_element
    assert by_element["H"] < 1.0, by_element
    assert by_element["O"] / by_element["H"] > 100.0, by_element


def test_the_vertex_density_is_bounded_by_the_nuclear_densities():
    """A vertex cannot be denser than the densest nucleus or emptier than the
    emptiest.

    The blend is a convex combination in the logarithm -- the weights are
    normalised -- so it lies between the extremes of the atoms it mixes.  A value
    outside that band would mean the weighting is not normalised, and the ramp
    would then clip against its ends and flatten the picture.
    """
    result = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 32})
    nuclei = [atom["nucleusDensity"] for atom in result["atoms"]]
    values = np.asarray(result["vertexDensity"], dtype=float)
    assert values.min() > min(nuclei) * (1 - 1e-6), (values.min(), min(nuclei))
    assert values.max() < max(nuclei) * (1 + 1e-6), (values.max(), max(nuclei))
    # The surface sits more than an ångström outside every nucleus at the contour
    # the app draws, so it never reaches the nuclear densities themselves -- the
    # oxygen nucleus carries 291 e/bohr^3 and the densest point on water's surface
    # about 9.  What matters is that it still spans enough of the range for the
    # ramp to tell the atoms apart: measured, it spans about a factor of ten.
    low, high = result["densityRange"]
    assert high / low > 5.0, f"the surface only spans {low} to {high}"


def test_a_vertex_on_a_nucleus_takes_that_atoms_density():
    """The blend is anchored at the atoms: on a nucleus it is that atom's alone.

    The inverse-square weight is unbounded at a nucleus, so a vertex there is
    dominated by it.  This cannot be checked through the surface, whose vertices
    sit a ångström or more outside every nucleus at the contour the app draws, so
    it is checked against the helper with vertices placed on the nuclei
    themselves -- which is also the statement that the blend has no bias: with
    the weight unbounded, the other atoms drop out entirely.
    """
    mf, atoms = _mean_field(WATER)
    coords = geometry.atoms_to_coords(atoms)
    colours = engine._density_vertex_colours(mf, atoms, coords)
    expected = _nuclear_densities(mf, atoms)
    got = np.asarray(colours["vertexDensity"], dtype=float)
    assert np.allclose(got, expected, rtol=1e-3), f"{got} vs {expected}"


def test_the_colour_is_continuous_across_the_surface():
    """Neighbouring vertices carry neighbouring colours.

    This is what makes the surface a gradient rather than a map of hard-edged
    atom regions.  The measure is the jump along the *ramp*, because that is what
    the eye sees: a blend can be smooth in the density and still band if the ramp
    is steep there.  The first attempt at this -- weighting by the atomic blocks'
    share of the local density -- measured a worst jump of 0.71 and a 99th
    percentile of 0.55 along the ramp, which is a hard edge at most bond
    midpoints.  Distance weighting measures 0.17 and 0.13.
    """
    result = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 32})
    vertices = _vertices(result)
    indices = np.asarray(result["indices"], dtype=int).reshape(-1, 3)
    values = np.asarray(result["vertexDensity"], dtype=float)
    low, high = result["densityRange"]
    log_low, log_high = np.log(low), np.log(high)
    position = np.clip((log_high - np.log(values)) / (log_high - log_low), 0.0, 1.0)

    # Vertices sit one grid step apart, so a short edge is one of the marching
    # step's own; the colour must not jump across it.
    edge = np.concatenate([indices[:, [0, 1]], indices[:, [1, 2]], indices[:, [2, 0]]])
    length = np.linalg.norm(vertices[edge[:, 0]] - vertices[edge[:, 1]], axis=1)
    near = length < 1.5 * result["gridStep"]
    assert near.sum() > 100, f"only {int(near.sum())} short edges to check"
    jump = np.abs(position[edge[near, 0]] - position[edge[near, 1]])
    worst = float(jump.max())
    assert worst < 0.3, f"a jump of {worst:.2f} along the ramp across one grid step"
    assert float(np.percentile(jump, 99)) < 0.2, (
        f"the 99th percentile jump is {float(np.percentile(jump, 99)):.2f}")


def test_a_single_atom_colours_the_whole_surface_its_own_density():
    """With one atom there is nothing to blend, so every vertex is its density.

    This is the cleanest statement of what the colour means: a helium atom's
    surface carries helium's nuclear density and nothing else, so the surface
    is one flat colour.
    """
    result = _rpc("density_surface", {
        "atoms": HELIUM, "basis": "sto-3g", "method": "RHF", "pointsPerAxis": 24})
    assert len(result["atoms"]) == 1
    assert result["atoms"][0]["element"] == "He"
    nucleus = result["atoms"][0]["nucleusDensity"]
    assert nucleus > 0
    assert all(abs(value - nucleus) < 1e-6 for value in result["vertexDensity"])
    low, high = result["densityRange"]
    assert abs(low - high) < 1e-9, "a one-atom surface has no range to show"


def test_the_atoms_carry_the_engine_colour_palette():
    """The atom list still reports the engine's own CPK colour for the element.

    The surface is coloured by density now, but the legend and the ball-and-stick
    model still agree about which colour means which element, and the engine is
    the authority on that palette.
    """
    from pyscf_mobile import elements

    result = _rpc("density_surface", {
        "atoms": WATER, "basis": "sto-3g", "method": "RHF", "pointsPerAxis": 24})
    by_symbol = {atom["element"]: atom["color"] for atom in result["atoms"]}
    assert by_symbol["O"] == elements.BY_SYMBOL["O"].color
    assert by_symbol["H"] == elements.BY_SYMBOL["H"].color
    assert [atom["index"] for atom in result["atoms"]] == [0, 1, 2]


# --------------------------------------------------------------------------
# the sampling box
# --------------------------------------------------------------------------


def test_the_surface_does_not_meet_the_box_wall():
    """The box grows until the contour is below its faces.

    A surface closed against the wall reads as a shape spanning the whole box
    rather than one around the molecule, so ``clipped`` must be false and the
    report must agree.
    """
    result = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 40})
    assert result["clipped"] is False
    assert result["gridPointsPerAxis"] >= result["pointsPerAxis"]


def test_the_resolution_is_bounded_when_the_box_grows():
    """The point count stays within the ceiling the phone can afford.

    The cost of the grid is cubic in the point count, so an unbounded growth
    loop is a silent jetsam kill rather than an error the user can see.
    """
    benzene = _rpc("density_surface", {
        "atoms": BENZENE, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 32})
    assert benzene["gridStep"] > 0
    assert benzene["gridPointsPerAxis"] <= engine._MAX_DENSITY_POINTS_PER_AXIS


# --------------------------------------------------------------------------
# frame
# --------------------------------------------------------------------------


def test_the_surface_is_in_the_same_frame_as_the_atoms():
    """The surface is centred where the atoms are, so it overlays the model."""
    result = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 32})
    _mf, atoms = _mean_field(WATER)
    centre = geometry.atoms_to_coords(atoms).mean(axis=0)
    assert np.linalg.norm(_vertices(result).mean(axis=0) - centre) < 0.6


def test_the_surface_follows_a_translated_molecule():
    """Shifting the molecule shifts the cloud by the same vector.

    The molecule is translated rigidly -- every coordinate, including the
    hydrogens' -- so the sampled box is the same box moved, and the cloud's
    bounding-box centre has to move with it.  The bounding box is compared
    rather than the vertex centroid because the centroid also depends on where
    the marching step happened to cut triangles, which the translation should
    not change but which is a weaker statement than "the box moved".
    """
    shifted = "O 5 5 5; H 5 4.243 5.587; H 5 5.757 5.587"
    plain = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 32})
    moved = _rpc("density_surface", {
        "atoms": shifted, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 32})

    def box_centre(result):
        vertices = _vertices(result)
        return (vertices.min(axis=0) + vertices.max(axis=0)) / 2

    delta = box_centre(moved) - box_centre(plain)
    assert np.allclose(delta, [5.0, 5.0, 5.0], atol=0.3), delta


# --------------------------------------------------------------------------
# the RPC contract
# --------------------------------------------------------------------------


def test_the_rpc_reports_the_contour_and_the_system():
    result = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 32})
    assert result["level"] == engine.DENSITY_CONTOUR
    assert result["method"] == "RHF/6-31g"
    assert result["nElectrons"] == 10
    assert result["nBasis"] > 0
    assert result["wallTimeMs"] > 0
    assert result["triangles"] == len(result["indices"]) // 3


def test_the_contour_can_be_asked_for():
    """The UI's detail control sends its own contour, and it is honoured."""
    result = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 24,
        "level": 0.01})
    assert result["level"] == 0.01


def test_a_contour_above_the_peak_yields_an_empty_surface_not_an_error():
    """A contour with no density above it is a legitimate empty answer."""
    result = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 24,
        "level": 999.0})
    assert result["vertices"] == []
    assert result["indices"] == []
    assert result["vertexDensity"] == []
    assert result["densityRange"] == [0.0, 0.0]


def test_a_non_positive_contour_is_rejected():
    payload = json.loads(bridge.handle_json(json.dumps({
        "id": 1, "method": "density_surface",
        "params": {"atoms": WATER, "basis": "6-31g", "method": "RHF",
                   "level": 0.0}})))
    assert "error" in payload


def test_a_too_coarse_grid_is_rejected():
    payload = json.loads(bridge.handle_json(json.dumps({
        "id": 1, "method": "density_surface",
        "params": {"atoms": WATER, "basis": "6-31g", "method": "RHF",
                   "pointsPerAxis": 4}})))
    assert "error" in payload


def test_the_payload_is_json_serialisable_and_bounded():
    """The whole result survives a round trip through JSON, and stays small."""
    result = _rpc("density_surface", {
        "atoms": BENZENE, "basis": "sto-3g", "method": "RHF", "pointsPerAxis": 32})
    encoded = json.dumps(result)
    assert json.loads(encoded)["level"] == result["level"]
    # A phone has to hold this: the picture is fetched per view, and a runaway
    # mesh is a jetsam kill rather than an error the user can see.  The budget is
    # loose because every vertex now carries its atom and its share as well as
    # its position.
    assert len(encoded) < 8_000_000, f"{len(encoded)} bytes"


def test_a_density_fitted_run_draws_the_same_surface():
    """The picture does not depend on how the integrals were built."""
    plain = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 32})
    fitted = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 32,
        "densityFit": True})
    assert abs(plain["peak"] - fitted["peak"]) < 0.05 * plain["peak"]
    assert plain["level"] == fitted["level"]
    assert len(plain["vertexDensity"]) == len(fitted["vertexDensity"])


def test_a_dft_run_draws_a_surface():
    """Kohn-Sham densities reach the same code path as Hartree-Fock ones."""
    result = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RKS", "xc": "b3lyp",
        "pointsPerAxis": 32})
    assert result["indices"]
    assert result["vertexDensity"]


def test_an_unrestricted_reference_draws_a_surface():
    """The alpha and beta blocks are summed before the density is evaluated."""
    result = _rpc("density_surface", {
        "atoms": "O 0 0 0; H 0 -0.757 0.587; H 0 0.757 0.587", "basis": "6-31g",
        "method": "UHF", "spin": 2, "charge": 0, "pointsPerAxis": 24})
    assert result["indices"]
    assert result["peak"] > 0
    assert result["vertexDensity"]
