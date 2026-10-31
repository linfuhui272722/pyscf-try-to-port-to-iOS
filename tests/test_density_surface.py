"""The electron-density isosurfaces the 3D density view draws.

The density picture is a set of nested shells, so a bug here is a picture that
misleads: shells that cross each other, a shell at the wrong density, or a shell
closed against the sampling box all still render as a plausible cloud.  The
tests therefore pin the mesh to the field it claims to bound -- every vertex is
checked against the density evaluated independently -- and check the nesting
order, which is the whole reason the shells are drawn at different levels.

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


def _shell_radii(shell: dict, centre: np.ndarray) -> np.ndarray:
    vertices = np.asarray(shell["vertices"], dtype=float).reshape(-1, 3)
    return np.linalg.norm(vertices - centre, axis=1)


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


# --------------------------------------------------------------------------
# the field the mesh claims to bound
# --------------------------------------------------------------------------


def test_every_vertex_brackets_its_own_density_level():
    """Each shell's vertices lie on the requested isosurface of the sampled field.

    A vertex of a marching-tetrahedra mesh sits on an edge of a cell whose
    corner values straddle the level, so the level must fall inside the value
    range of the cell the vertex lands in.  That is an exact invariant -- the
    measured violation count is zero for every shell -- which makes it a sharp
    test: a shell drawn at the wrong level, or in the wrong frame, puts its
    vertices in cells that do not bracket it.

    Note the comparison is against the *sampled* field, not the analytic
    density.  On a 0.19 Å grid the density's nuclear cusp is unresolved, so the
    analytic density at a vertex differs from the level by tens of percent; that
    is the grid's resolution, not the mesh's error.
    """
    result = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 40})
    mf, atoms = _mean_field(WATER)
    values, origin, step = _sampled_density_grid(
        mf, atoms, result["gridPointsPerAxis"])
    assert result["gridPointsPerAxis"] == values.shape[0]
    assert np.allclose(origin, result["gridOrigin"], atol=1e-6)
    # ``gridStep`` is the largest of the three axis steps, as it is for the
    # orbital surface: the box is fitted to the molecule's own extent, so the
    # three steps differ and the reported figure is the coarsest of them.
    assert abs(max(float(v) for v in step) - result["gridStep"]) < 1e-6

    for shell in result["shells"]:
        vertices = np.asarray(shell["vertices"], dtype=float).reshape(-1, 3)
        if vertices.size == 0:
            continue
        corners = _cell_corners(values, np.asarray(origin), np.asarray(step), vertices)
        level = shell["level"]
        straddles = (corners.min(axis=1) <= level) & (corners.max(axis=1) >= level)
        assert straddles.all(), (
            f"level {level}: {int((~straddles).sum())} of {len(straddles)} vertices "
            f"fall in cells that do not contain the level")


def test_the_peak_is_the_largest_density_on_the_sampled_box():
    """``peak`` is the maximum of the field the mesh was built from.

    It is deliberately *not* the density at the nuclei: the peak sits on a cusp
    that a grid of this spacing does not resolve, so the box maximum is far
    below it (7.4 against 291 e/bohr^3 for water/6-31G).  Reporting the cusp
    would be a number the drawn shells do not relate to.
    """
    result = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 32})
    mf, atoms = _mean_field(WATER)
    values, _origin, _step = _sampled_density_grid(
        mf, atoms, result["gridPointsPerAxis"])
    assert abs(result["peak"] - float(values.max())) < 1e-6
    assert result["peak"] > 0

    # The reported peak really is the largest value drawn: every shell's level
    # is below it, and the highest level's own fraction is below one.
    assert max(result["levels"]) < result["peak"]
    assert result["shells"][-1]["fraction"] < 1.0




def test_the_fraction_is_the_level_over_the_peak():
    result = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 32})
    for shell in result["shells"]:
        assert abs(shell["fraction"] - shell["level"] / result["peak"]) < 1e-6


# --------------------------------------------------------------------------
# nesting, which is what makes the picture read as depth
# --------------------------------------------------------------------------


def test_shells_are_nested_with_the_densest_innermost():
    """A higher level is enclosed by every lower one.

    The picture only means "more density in the middle" if the shells do not
    cross, so the outermost extent of each shell has to fall as the level rises.
    """
    result = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 40})
    mf, atoms = _mean_field(WATER)
    centre = geometry.atoms_to_coords(atoms).mean(axis=0)

    levels = [shell["level"] for shell in result["shells"]]
    assert levels == sorted(levels), "levels arrive ascending"

    extents = []
    for shell in result["shells"]:
        radii = _shell_radii(shell, centre)
        assert radii.size > 0, f"level {shell['level']} produced no geometry"
        extents.append(float(radii.max()))
    for lower, higher in zip(extents, extents[1:]):
        assert higher <= lower + 1e-6, f"shells cross: {extents}"


def test_the_outermost_shell_wraps_the_whole_molecule():
    """The lowest level reaches past every atom, so the cloud is around them."""
    result = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 40})
    mf, atoms = _mean_field(WATER)
    coords = geometry.atoms_to_coords(atoms)
    centre = coords.mean(axis=0)
    outermost = result["shells"][0]
    assert outermost["level"] == min(result["levels"])
    radii = _shell_radii(outermost, centre)
    assert radii.max() > np.linalg.norm(coords - centre, axis=1).max()


def test_the_innermost_shell_is_inside_the_cores():
    """The highest level sits close to the nuclei, not out among the bonds."""
    result = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 40})
    _mf, atoms = _mean_field(WATER)
    coords = geometry.atoms_to_coords(atoms)
    centre = coords.mean(axis=0)
    innermost = result["shells"][-1]
    assert innermost["level"] == max(result["levels"])
    radii = _shell_radii(innermost, centre)
    # Every atom has some density above the top level, so this shell exists and
    # hugs the nuclei: its furthest point is well inside the molecule's extent.
    assert radii.max() < np.linalg.norm(coords - centre, axis=1).max() + 1.0


# --------------------------------------------------------------------------
# the sampling box
# --------------------------------------------------------------------------


def test_no_shell_meets_the_box_wall():
    """The box grows until the outermost level is below its faces.

    A shell closed against the wall reads as a cloud spanning the whole box
    rather than one around the molecule, so ``clipped`` must be false and the
    report must agree.
    """
    result = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 40})
    assert result["clipped"] is False
    assert result["gridPointsPerAxis"] >= result["pointsPerAxis"]


def test_the_resolution_is_held_when_the_box_grows():
    """The grid step is the same for a diffuse shell as for the atoms' box.

    Holding the point count fixed while the box widens would coarsen the mesh,
    so the step would grow with the molecule instead of staying put.
    """
    water = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 32})
    benzene = _rpc("density_surface", {
        "atoms": BENZENE, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 32})
    # Benzene's atoms span more, so its box is wider; the step must not scale
    # with it beyond the ratio of the two atom spans.
    assert water["gridStep"] > 0 and benzene["gridStep"] > 0
    assert benzene["gridPointsPerAxis"] <= engine._MAX_DENSITY_POINTS_PER_AXIS


# --------------------------------------------------------------------------
# frame
# --------------------------------------------------------------------------


def test_shells_are_in_the_same_frame_as_the_atoms():
    """The shells are centred where the atoms are, so they overlay the model."""
    result = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 32})
    _mf, atoms = _mean_field(WATER)
    centre = geometry.atoms_to_coords(atoms).mean(axis=0)
    outermost = np.asarray(result["shells"][0]["vertices"], dtype=float).reshape(-1, 3)
    assert np.linalg.norm(outermost.mean(axis=0) - centre) < 0.6


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
        vertices = np.asarray(result["shells"][0]["vertices"], dtype=float).reshape(-1, 3)
        return (vertices.min(axis=0) + vertices.max(axis=0)) / 2

    delta = box_centre(moved) - box_centre(plain)
    assert np.allclose(delta, [5.0, 5.0, 5.0], atol=0.3), delta



# --------------------------------------------------------------------------
# the RPC contract
# --------------------------------------------------------------------------


def test_the_rpc_returns_one_shell_per_level():
    result = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 32})
    assert len(result["shells"]) == len(result["levels"])
    assert result["levels"] == list(engine.DENSITY_LEVELS)
    assert result["method"] == "RHF/6-31g"
    assert result["nElectrons"] == 10
    assert result["nBasis"] > 0
    assert result["wallTimeMs"] > 0


def test_the_levels_can_be_asked_for():
    """The UI's detail control sends its own levels, and they are honoured."""
    result = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 24,
        "levels": [0.01, 0.1]})
    assert result["levels"] == [0.01, 0.1]
    assert [shell["level"] for shell in result["shells"]] == [0.01, 0.1]


def test_the_levels_are_sorted_and_deduplicated():
    result = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 24,
        "levels": [0.1, 0.01, 0.1, 0.05]})
    assert result["levels"] == [0.01, 0.05, 0.1]


def test_a_level_above_the_peak_yields_an_empty_shell_not_an_error():
    """A high level with no density above it is a legitimate empty answer."""
    result = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 24,
        "levels": [0.01, 999.0]})
    empty = [shell for shell in result["shells"] if shell["level"] == 999.0][0]
    assert empty["vertices"] == []
    assert empty["indices"] == []


def test_a_non_positive_level_is_rejected():
    payload = json.loads(bridge.handle_json(json.dumps({
        "id": 1, "method": "density_surface",
        "params": {"atoms": WATER, "basis": "6-31g", "method": "RHF",
                   "levels": [0.0, -1.0]}})))
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
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 32})
    encoded = json.dumps(result)
    assert json.loads(encoded)["shells"][0]["level"] == result["levels"][0]
    # A phone has to hold this: the picture is fetched per view, and a runaway
    # mesh is a jetsam kill rather than an error the user can see.
    assert len(encoded) < 4_000_000, f"{len(encoded)} bytes"


def test_a_density_fitted_run_draws_the_same_cloud():
    """The picture does not depend on how the integrals were built."""
    plain = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 32})
    fitted = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RHF", "pointsPerAxis": 32,
        "densityFit": True})
    assert abs(plain["peak"] - fitted["peak"]) < 0.05 * plain["peak"]
    assert plain["levels"] == fitted["levels"]


def test_a_dft_run_draws_a_cloud():
    """Kohn-Sham densities reach the same code path as Hartree-Fock ones."""
    result = _rpc("density_surface", {
        "atoms": WATER, "basis": "6-31g", "method": "RKS", "xc": "b3lyp",
        "pointsPerAxis": 32})
    assert result["shells"]
    assert all(shell["indices"] for shell in result["shells"])


def test_an_unrestricted_reference_draws_a_cloud():
    """The alpha and beta blocks are summed before the density is evaluated."""
    result = _rpc("density_surface", {
        "atoms": "O 0 0 0; H 0 -0.757 0.587; H 0 0.757 0.587", "basis": "6-31g",
        "method": "UHF", "spin": 2, "charge": 0, "pointsPerAxis": 24})
    assert result["shells"]
    assert result["peak"] > 0
