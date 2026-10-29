"""Turn a scalar field on a grid into a triangle mesh for the 3D viewer.

The orbital viewer draws the familiar picture: the molecule in 3D with a
translucent envelope around each lobe of the orbital.  That envelope is the
isosurface of the orbital amplitude, and this module extracts it as triangles
the Swift side can hand straight to SceneKit.

Marching *tetrahedra* rather than marching cubes, deliberately.  Cubes need a
256-entry triangle table that has to be transcribed exactly; a single wrong row
produces holes that are invisible in the vertex count and only show up as a
gap on screen.  Splitting each cell into six tetrahedra needs three cases and no
table, so the correctness argument is short enough to check by reading.  It
costs roughly twice the triangles for the same grid, which is irrelevant at the
sizes here.

Normals are taken from the field's gradient rather than from the triangle
faces.  The gradient is what the surface is perpendicular to, and it makes the
shading smooth across a lobe instead of faceted, which is what makes the shape
read as an orbital.  Because explicit normals drive the lighting, the triangle
winding does not have to be solved for: the phase's normal is ``-grad`` by
construction, so both lobes shade outward without any orientation bookkeeping.
"""

from __future__ import annotations

import numpy as np

# Cube corners, indexed by the bit pattern of (i, j, k): bit 0 is +i, bit 1 is
# +j, bit 2 is +k.  The tetrahedra below all share the 0-7 body diagonal.
_CORNERS = np.array(
    [
        [0, 0, 0],
        [1, 0, 0],
        [0, 1, 0],
        [1, 1, 0],
        [0, 0, 1],
        [1, 0, 1],
        [0, 1, 1],
        [1, 1, 1],
    ],
    dtype=np.intp,
)

# Six tetrahedra covering the cube, all incident on the 0-7 diagonal so that
# neighbouring cells agree on the surface where they meet.
_TETRAHEDRA = np.array(
    [
        [0, 1, 3, 7],
        [0, 3, 2, 7],
        [0, 2, 6, 7],
        [0, 6, 4, 7],
        [0, 4, 5, 7],
        [0, 5, 1, 7],
    ],
    dtype=np.intp,
)

# The six edges of a tetrahedron, as index pairs into its four vertices.
_TET_EDGES = np.array(
    [[0, 1], [0, 2], [0, 3], [1, 2], [1, 3], [2, 3]], dtype=np.intp
)


def _triangles_for(code: int) -> list[tuple[tuple[int, int], ...]]:
    """The crossing edges of one tetrahedron's inside/outside pattern.

    ``code`` is a four-bit mask over the tetrahedron's vertices, set when the
    vertex is inside the surface.  The return value is a list of triangles, each
    a tuple of edge endpoints; an edge is named by its two vertex indices and is
    turned into a position by the caller.  Building this from the mask rather
    than tabulating it keeps the three real cases (one in, two in, three in)
    visible as code.
    """
    inside = [vertex for vertex in range(4) if code & (1 << vertex)]
    outside = [vertex for vertex in range(4) if not code & (1 << vertex)]

    if len(inside) == 1:
        # One corner inside: the surface cuts the three edges leaving it.
        apex = inside[0]
        return [tuple((apex, other) for other in outside)]
    if len(inside) == 3:
        # One corner outside: the same, viewed from the other side.
        apex = outside[0]
        return [tuple((apex, other) for other in inside)]
    if len(inside) == 2:
        # Two in, two out: the cut is a quadrilateral, split into two triangles.
        first, second = inside
        third, fourth = outside
        return [
            ((first, third), (first, fourth), (second, fourth)),
            ((first, third), (second, fourth), (second, third)),
        ]
    return []


# Built once: the 14 non-trivial patterns, so the inner loop only looks up.
_TET_TABLE: list[list[tuple[tuple[int, int], ...]]] = [
    _triangles_for(code) for code in range(16)
]


def _edge_index(vertex_a: int, vertex_b: int) -> int:
    """Position of an edge in ``_TET_EDGES``, for edge-keyed caches.

    The pair is sorted first: the three-inside case names its edges from the
    outside vertex, which gives the reverse order of the table, and an edge is
    the same edge whichever end it is named from.
    """
    low, high = (vertex_a, vertex_b) if vertex_a < vertex_b else (vertex_b, vertex_a)
    for position, (a, b) in enumerate(_TET_EDGES):
        if (a, b) == (low, high):
            return position
    raise KeyError((vertex_a, vertex_b))


def isosurface(
    values: np.ndarray,
    shape: tuple[int, int, int],
    origin: np.ndarray,
    step: np.ndarray,
    isovalue: float,
    *,
    max_triangles: int = 400_000,
) -> dict:
    """Extract the surface where ``values == isovalue``.

    The surface is closed around the region where ``values > isovalue``, so
    calling this with ``-values`` gives the opposite lobe of a signed field.
    Vertices are in the same coordinate frame as ``origin`` (absolute
    ångström), which is what lets the viewer line the surface up with the atoms
    it was computed from.

    Returns ``{"vertices": [[x, y, z], ...], "normals": [...], "indices": [...]}``
    with vertices welded, or empty lists when the isovalue does not intersect
    the field.  An empty surface is a legitimate answer -- a tightly-bound
    orbital can be entirely below a high isovalue -- so it is not an error.
    """
    field = np.asarray(values, dtype=float).reshape(shape)
    origin = np.asarray(origin, dtype=float).reshape(3)
    step = np.asarray(step, dtype=float).reshape(3)
    nx, ny, nz = shape
    if nx < 2 or ny < 2 or nz < 2:
        return {"vertices": [], "normals": [], "indices": []}

    # Gradient of the field, used for the vertex normals.  Spacing is the grid
    # step on each axis, so the components come out in per-ångström units.
    gradient = np.gradient(field, step[0], step[1], step[2])
    gradient = np.stack(gradient, axis=-1)  # (nx, ny, nz, 3)

    # Gather the eight corner values of every cell, plus their gradient vectors.
    cells = (nx - 1, ny - 1, nz - 1)
    corner_values = np.empty((8,) + cells, dtype=float)
    corner_gradients = np.empty((8,) + cells + (3,), dtype=float)
    for corner in range(8):
        di, dj, dk = _CORNERS[corner]
        slices = (slice(di, di + cells[0]), slice(dj, dj + cells[1]), slice(dk, dk + cells[2]))
        corner_values[corner] = field[slices]
        corner_gradients[corner] = gradient[slices]

    # Cell corner positions, so an interpolated point lands in real space.
    axis = [origin[i] + np.arange(shape[i]) * step[i] for i in range(3)]
    corner_positions = np.empty((8,) + cells + (3,), dtype=float)
    for corner in range(8):
        di, dj, dk = _CORNERS[corner]
        grids = np.meshgrid(
            axis[0][di:di + cells[0]],
            axis[1][dj:dj + cells[1]],
            axis[2][dk:dk + cells[2]],
            indexing="ij",
        )
        for component in range(3):
            corner_positions[corner, ..., component] = grids[component]

    inside = corner_values > isovalue

    triangle_edges: list[np.ndarray] = []
    triangle_cells: list[np.ndarray] = []

    for tetrahedron in _TETRAHEDRA:
        tet_values = corner_values[tetrahedron]  # (4,) + cells
        tet_inside = inside[tetrahedron]  # (4,) + cells
        # The pattern of one cell is a four-bit number; encode it per cell and
        # group the cells by it, so each of the 16 cases is handled in one
        # vectorised pass rather than cell by cell.
        codes = (
            tet_inside[0].astype(np.uint8)
            | (tet_inside[1].astype(np.uint8) << 1)
            | (tet_inside[2].astype(np.uint8) << 2)
            | (tet_inside[3].astype(np.uint8) << 3)
        )
        flat_codes = codes.ravel()
        for code in range(16):
            triangles = _TET_TABLE[code]
            if not triangles:
                continue
            cell_indices = np.nonzero(flat_codes == code)[0]
            if cell_indices.size == 0:
                continue
            for triangle in triangles:
                for vertex_a, vertex_b in triangle:
                    edge = _edge_index(vertex_a, vertex_b)
                    a, b = _TET_EDGES[edge]
                    value_a = tet_values[a].ravel()[cell_indices]
                    value_b = tet_values[b].ravel()[cell_indices]
                    span = value_b - value_a
                    # The crossing fraction; the guard keeps a zero span from
                    # producing a nan when both endpoints sit on the isovalue.
                    denominator = np.where(np.abs(span) < 1e-30, 1e-30, span)
                    fraction = np.clip((isovalue - value_a) / denominator, 0.0, 1.0)

                    position_a = corner_positions[tetrahedron[a]].reshape(-1, 3)[cell_indices]
                    position_b = corner_positions[tetrahedron[b]].reshape(-1, 3)[cell_indices]
                    points = position_a + (position_b - position_a) * fraction[:, None]

                    gradient_a = corner_gradients[tetrahedron[a]].reshape(-1, 3)[cell_indices]
                    gradient_b = corner_gradients[tetrahedron[b]].reshape(-1, 3)[cell_indices]
                    gradients = gradient_a + (gradient_b - gradient_a) * fraction[:, None]

                    triangle_cells.append(cell_indices)
                    triangle_edges.append(
                        np.concatenate([points, gradients], axis=1)
                    )

    if not triangle_edges:
        return {"vertices": [], "normals": [], "indices": []}

    # One row per triangle corner: xyz then the gradient at that point.
    rows = np.concatenate(triangle_edges, axis=0)
    if rows.shape[0] // 3 > max_triangles:
        raise ValueError(
            f"isosurface would need {rows.shape[0] // 3} triangles, over the "
            f"{max_triangles} limit; raise the isovalue or lower the resolution"
        )

    positions = rows[:, :3]
    gradients = rows[:, 3:]
    # Outward is the direction of decreasing field, because the enclosed region
    # is the one above the isovalue.
    lengths = np.linalg.norm(gradients, axis=1)
    lengths = np.where(lengths < 1e-30, 1.0, lengths)
    normals = -gradients / lengths[:, None]

    # Weld duplicate positions so the mesh is connected: shared corners then
    # reference one vertex, which halves the payload and makes an edge count a
    # meaningful check.
    rounded = np.round(positions, 6)
    _unique, first, inverse = np.unique(
        rounded, axis=0, return_index=True, return_inverse=True
    )
    inverse = inverse.ravel()
    vertices = positions[first]
    vertex_normals = normals[first]
    # Re-normalise after welding, since the averaged members of a welded vertex
    # can differ slightly.
    lengths = np.linalg.norm(vertex_normals, axis=1)
    lengths = np.where(lengths < 1e-30, 1.0, lengths)
    vertex_normals = vertex_normals / lengths[:, None]

    return {
        "vertices": [[round(float(c), 5) for c in vertex] for vertex in vertices],
        "normals": [[round(float(c), 4) for c in normal] for normal in vertex_normals],
        "indices": [int(index) for index in inverse],
    }
