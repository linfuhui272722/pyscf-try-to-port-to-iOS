// MoleculeLayout.swift
//
// Sizing and framing rules for the ball-and-stick preview, kept free of
// SceneKit so the build host can test them.  SceneKit does not exist on Linux,
// and the preview is the one view whose failures are invisible in the model
// layer: a wrong sphere radius produces a perfectly valid scene that happens to
// be empty-looking on screen.
//
// The rules are deliberately molecule-independent.  Deriving the sphere size
// from the molecule's own bounding radius made the same element render at
// 0.079 Å in water and 0.180 Å in benzene, and water — whose whole extent is
// under 1 Å — came out as specks a few percent of a bond length across.

import Foundation

/// Atom positions, radii and camera framing for one molecule.
struct MoleculeLayout {

    struct Atom: Equatable {
        let index: Int
        let element: String
        /// Position relative to the centre of mass, in ångström.
        let x: Double
        let y: Double
        let z: Double
        let radius: Double
    }

    struct Bond: Equatable {
        /// Indices into ``atoms``.
        let start: Int
        let end: Int
        let radius: Double
    }

    /// Fraction of the covalent radius drawn as the sphere radius. Small enough
    /// that bonded spheres stay distinct, large enough to read at a glance.
    static let atomRadiusScale = 0.38
    static let minimumAtomRadius = 0.14
    static let maximumAtomRadius = 0.95
    /// The range the orbital transparency slider spans, and the value the
    /// viewer opens at.  A floor above zero keeps the envelope visible as a
    /// shape while the atoms inside stay readable.
    static let minimumOrbitalOpacity = 0.05
    static let maximumOrbitalOpacity = 1.0
    static let defaultOrbitalOpacity = 0.55
    /// The same range for the density surface.
    ///
    /// The default is low because this envelope **closes around the whole
    /// molecule**: every atom is behind the near wall, so at 0.55 the atoms were
    /// half-veiled and the screen read as "the molecule is hidden", which is what
    /// the user reported.  At 0.28 the shape still reads as a cloud while the
    /// ball-and-stick model stays legible through it.  The floor is above zero
    /// so the bottom of the slider leaves a visible shell rather than nothing.
    static let minimumDensityOpacity = 0.05
    static let maximumDensityOpacity = 1.0
    static let defaultDensityOpacity = 0.28

    /// One lamp of the light rig, in camera-relative coordinates.
    struct Lamp: Equatable {
        let x: Double
        let y: Double
        let z: Double
        let intensity: Double
    }

    /// The light rig, kept here rather than inline in the renderer so the host
    /// tests can check its shape.
    ///
    /// Twelve lamps on the vertices of a regular icosahedron.  The first two
    /// attempts were both directional, and measuring is what showed it:
    ///
    /// * key/fill/rim at 700/320/260, all three on the camera side — the far
    ///   side of the cloud fell into shadow and the dark end of the ramp came
    ///   out black, so part of the colour range was unreadable;
    /// * six lamps on ±x, ±y and ±z — symmetric through the origin, and its
    ///   direction sum is exactly zero, so it *looked* omnidirectional, but a
    ///   lamp on each axis leaves the diagonals lit by three lamps against the
    ///   axis's one.  Measured irradiance runs 1.00 on an axis to 1.73 at a
    ///   corner, so the corners of the cloud were 73% brighter than its faces
    ///   and the shading still read as coming from particular directions.
    ///
    /// The icosahedron's vertices are the most even spread of twelve directions
    /// on a sphere.  Measured the same way, irradiance runs 2.76 to 3.24 — a
    /// ratio of **1.17** against the six-lamp ring's **1.71**, and the residual
    /// is spread over many directions rather than concentrated on the axes.
    /// ``MoleculeLayout/irradianceSpread`` recomputes that ratio so a test can
    /// hold the rig to it.
    ///
    /// Equal intensity, deliberately: a dominant lamp would reintroduce exactly
    /// the directionality the rig exists to remove.
    static let lamps: [Lamp] = {
        // Vertices of a regular icosahedron, normalised to the unit sphere.
        let phi = (1.0 + 5.0.squareRoot()) / 2.0
        var points: [(Double, Double, Double)] = []
        for a in [1.0, -1.0] {
            for b in [phi, -phi] {
                points.append((0, a, b))
                points.append((a, b, 0))
                points.append((b, 0, a))
            }
        }
        return points.map { point in
            let length = (point.0 * point.0 + point.1 * point.1
                          + point.2 * point.2).squareRoot()
            return Lamp(
                x: point.0 / length,
                y: point.1 / length,
                z: point.2 / length,
                intensity: 95)
        }
    }()

    /// Distance of each lamp from the camera node.
    static let lampDistance = 3.0

    /// How evenly the rig lights a surface, as the ratio of the brightest to
    /// the dimmest direction.
    ///
    /// 1.0 is perfectly even light.  This is the number that matters for "the
    /// model is lit from every side": the earlier rigs were checked by summing
    /// their lamp directions, which the six-axis ring satisfied at exactly zero
    /// while still being 1.71 uneven.  Sampling the actual irradiance over
    /// directions on the sphere is what catches that, and it is what the layout
    /// test asserts.
    ///
    /// The sample count is fixed so the value is deterministic.  ``lamps`` is a
    /// parameter so a test can measure a *rejected* rig with the same code and
    /// show that the threshold catches it — a check whose discriminating power
    /// is never demonstrated is one that can silently stop discriminating.
    static func irradianceSpread(
        lamps: [Lamp] = MoleculeLayout.lamps, samples: Int = 2048
    ) -> Double {
        var lowest = Double.greatestFiniteMagnitude
        var highest = 0.0
        for index in 0..<samples {
            // A Fibonacci sphere: an even spread of directions without a
            // random generator, so the number is reproducible.
            let y = 1.0 - 2.0 * (Double(index) + 0.5) / Double(samples)
            let radius = max(0.0, 1.0 - y * y).squareRoot()
            let theta = Double(index) * 2.39996322972865332
            let direction = (radius * cos(theta), radius * sin(theta), y)

            var irradiance = 0.0
            for lamp in lamps {
                let length = (lamp.x * lamp.x + lamp.y * lamp.y
                              + lamp.z * lamp.z).squareRoot()
                let cosine = (direction.0 * lamp.x + direction.1 * lamp.y
                              + direction.2 * lamp.z) / length
                // A surface only receives a lamp it faces, which is what makes
                // a sparse rig directional.
                if cosine > 0 { irradiance += cosine }
            }
            lowest = Swift.min(lowest, irradiance)
            highest = Swift.max(highest, irradiance)
        }
        guard lowest > 0 else { return Double.greatestFiniteMagnitude }
        return highest / lowest
    }

    /// How much light comes from every direction at once, as the surrounding
    /// light image's intensity.
    ///
    /// This is also the ambient floor, and it is deliberately the *only* place
    /// the floor comes from.  Setting ``ambient`` on each lamp was the first
    /// attempt and is a trap: SceneKit sums ambient contributions across lights,
    /// so twelve lamps at 0.45 would deliver 5.4 and blow the model out to
    /// white.  A single uniform light image has one well-defined intensity
    /// instead, and being uniform it lifts a crevice that no lamp can reach
    /// without making any direction brighter than another.
    ///
    /// It carries most of the light here, with the lamps shaping the form.  The
    /// environment term is perfectly even, so leaning on it is what flattens the
    /// rig's residual directionality: the lamps only have to give the atoms and
    /// the cloud enough shading to read as solid, not to light them.
    static let environmentIntensity: Double = 1.0

    /// Whether a translucent overlay writes depth, for the orbital envelope and
    /// the density cloud.
    ///
    /// Both are **false**, and they must stay equal.  The density cloud used to
    /// write depth on the theory that a closed surface should hide its own far
    /// wall; what it actually hid was the molecule, because the cloud's near wall
    /// fills the depth buffer and every atom behind it is culled before it is
    /// drawn.  The screen then showed the cloud over the background with no
    /// molecule under it, which is why the transparency slider had nothing to
    /// reveal and felt dead.  Apple's guidance agrees: "Typically, you disable
    /// writing to the depth buffer when rendering semitransparent objects."
    ///
    /// The far wall stays out of the picture through back-face culling instead:
    /// the engine orients every triangle outward and ``isDoubleSided`` is false,
    /// so the far wall is discarded before it can blend and the veil over the
    /// atoms is exactly one layer.
    ///
    /// Stated here rather than inline in the renderer so the layout tests can
    /// hold the two overlays to the same behaviour; the renderer itself needs
    /// SceneKit, which cannot run on the build host.
    static let orbitalWritesDepth = false
    static let cloudWritesDepth = false

    /// Mid-grey the light image is built from, and how far the six cube faces
    /// vary around it.
    ///
    /// A uniform image is the point: any variation would be a direction the
    /// model is lit from, which is what this rig exists to avoid.  The small
    /// spread keeps the faces from being bit-identical, which makes the cube
    /// map cheap to validate and avoids a degenerate texture.
    static let environmentGrey: Double = 0.5
    static let environmentSpread: Double = 0.06

    /// Roughness of the density cloud's material.
    ///
    /// The material is physically based, so ``specular`` and ``shininess`` do
    /// nothing and glare comes from low roughness — a smooth surface concentrates
    /// the lamps into a small bright highlight.  High roughness spreads the same
    /// light over a wide area, which is the "not hard on the eyes" reading.  The
    /// atoms stay glossier (0.35) on purpose: they are small and reading them as
    /// spheres is useful.
    static let cloudRoughness: Double = 0.9
    /// One radius for every bond, in ångström, so bonds do not thicken just
    /// because a molecule is larger.
    static let bondRadius = 0.075
    static let fieldOfViewDegrees = 45.0
    /// Extra distance so the outermost sphere clears the frustum edge.
    static let framingMargin = 1.08
    /// Floor for the framing distance, so a lone atom still fills the view.
    static let minimumExtent = 0.5
    /// Radius used when the element table has no entry for a symbol.
    static let unknownCovalentRadius = 0.6

    let atoms: [Atom]
    let bonds: [Bond]
    /// Distance from the origin to the furthest atom surface.
    let extent: Double
    /// Camera distance that frames ``extent`` in the vertical field of view.
    let cameraDistance: Double

    init(geometry: GeometryDescription, covalentRadii: [String: Double]) {
        let centre = geometry.centreOfMass.count == 3 ? geometry.centreOfMass : [0, 0, 0]

        var placed: [Atom] = []
        placed.reserveCapacity(geometry.atoms.count)
        for atom in geometry.atoms {
            let xyz = atom.xyz.count == 3 ? atom.xyz : [0, 0, 0]
            placed.append(Atom(
                index: atom.index,
                element: atom.element,
                x: xyz[0] - centre[0],
                y: xyz[1] - centre[1],
                z: xyz[2] - centre[2],
                radius: MoleculeLayout.atomRadius(covalentRadius: covalentRadii[atom.element])
            ))
        }
        atoms = placed

        bonds = geometry.bonds.compactMap { bond in
            guard placed.indices.contains(bond.i), placed.indices.contains(bond.j) else {
                return nil
            }
            return Bond(start: bond.i, end: bond.j, radius: MoleculeLayout.bondRadius)
        }

        let furthest = atoms.map { atom -> Double in
            let distance = (atom.x * atom.x + atom.y * atom.y + atom.z * atom.z).squareRoot()
            return distance + atom.radius
        }.max() ?? 0
        extent = max(furthest, MoleculeLayout.minimumExtent)
        cameraDistance = MoleculeLayout.cameraDistance(forExtent: extent)
    }

    /// Sphere radius for one element, independent of the molecule it appears in.
    static func atomRadius(covalentRadius: Double?) -> Double {
        let base = (covalentRadius ?? unknownCovalentRadius) * atomRadiusScale
        return min(max(base, minimumAtomRadius), maximumAtomRadius)
    }

    /// Distance at which a sphere of ``extent`` fits the vertical field of view.
    ///
    /// Applies the same floor as the initialiser, so a caller cannot obtain a
    /// degenerate (zero or negative) distance from an empty molecule.
    static func cameraDistance(forExtent extent: Double) -> Double {
        let halfAngle = fieldOfViewDegrees / 2 * .pi / 180
        return max(extent, minimumExtent) / sin(halfAngle) * framingMargin
    }

    /// Fraction of the vertical half-angle the molecule covers, 0 to 1.
    ///
    /// A value near 1 means the model reaches the edge of the viewport; the
    /// preview used to sit at 0.37, which left two thirds of the frame empty.
    func framingFraction() -> Double {
        let halfAngle = MoleculeLayout.fieldOfViewDegrees / 2 * .pi / 180
        return atan(extent / cameraDistance) / halfAngle
    }
}
