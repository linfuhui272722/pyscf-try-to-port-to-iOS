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
    /// Six equal lamps along ±x, ±y and ±z: an axis-aligned ring, so the
    /// direction sum is exactly zero and the model is lit from every side at
    /// once.  The first attempt was a key/fill/rim trio — all three on the
    /// camera side, at 700/320/260 — which left the far side of the cloud in
    /// shadow and made those colours read as black, so part of the ramp was
    /// invisible.  It also pointed the brightness at the camera, which is what
    /// made it glare.
    ///
    /// Equal intensity rather than a brighter key: a ring with a dominant lamp
    /// would reintroduce the directionality the ring exists to remove.  The
    /// per-lamp intensity is lower than the old key's because six lamps sum
    /// where one key stood alone.
    static let lamps: [Lamp] = [
        Lamp(x: 1, y: 0, z: 0, intensity: 220),
        Lamp(x: -1, y: 0, z: 0, intensity: 220),
        Lamp(x: 0, y: 1, z: 0, intensity: 220),
        Lamp(x: 0, y: -1, z: 0, intensity: 220),
        Lamp(x: 0, y: 0, z: 1, intensity: 220),
        Lamp(x: 0, y: 0, z: -1, intensity: 220),
    ]

    /// Distance of each lamp from the camera node.
    static let lampDistance = 3.0

    /// How much light comes from every direction at once, as the surrounding
    /// light image's intensity.
    ///
    /// This is also the ambient floor, and it is deliberately the *only* place
    /// the floor comes from.  Setting ``ambient`` on each of the six lamps was
    /// the first attempt and is a trap: SceneKit sums ambient contributions
    /// across lights, so six lamps at 0.45 would deliver 2.7 and blow the model
    /// out to white.  A single uniform light image has one well-defined
    /// intensity instead, and being uniform it lifts a crevice that no lamp can
    /// reach without making any direction brighter than another.
    ///
    /// It is what keeps the low end of the ramp readable: a crevice between two
    /// atoms is shadowed from every lamp at once, and those vertices used to
    /// come out black, which swallowed the blue end of the ramp.
    static let environmentIntensity: Double = 0.7

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
