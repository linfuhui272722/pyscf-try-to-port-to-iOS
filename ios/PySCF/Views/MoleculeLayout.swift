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
    /// The same range for the density surface.  It opens opaque enough that the
    /// atom colours read: there is now one surface rather than several nested
    /// shells, so the transparencies no longer compound, and the colour is the
    /// information the picture carries.  A floor above zero keeps the surface
    /// visible as a shape while the atoms inside stay readable.
    static let minimumDensityOpacity = 0.10
    static let maximumDensityOpacity = 1.0
    static let defaultDensityOpacity = 0.55
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
