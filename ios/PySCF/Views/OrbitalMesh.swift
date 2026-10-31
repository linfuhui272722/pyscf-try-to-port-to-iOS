// OrbitalMesh.swift
//
// Turns an orbital isosurface into the vertex/normal/index arrays SceneKit
// wants, and centres it on the same point the ball-and-stick model is centred
// on.  Kept free of SceneKit so the build host can test it: a mesh with the
// wrong vertex count or a mis-centred one still builds a valid geometry and
// renders as a distorted or offset blob, which no screenshot on the device
// would attribute to this code.
//
// The centring is the part that matters.  The engine evaluates the orbital on a
// grid in absolute ångström, while ``MoleculeLayout`` places every atom
// relative to the centre of mass, so the surface has to be shifted by the same
// vector or the lobes float beside the molecule.

import Foundation

/// A SceneKit-ready triangle mesh for one phase of an orbital.
struct OrbitalMesh {
    /// Interleaved source data for ``SCNGeometrySource``: xyz then the normal,
    /// six floats per vertex.
    let vertexData: [Float]
    let vertexCount: Int
    /// Triangle corners, three per triangle.
    let indices: [Int32]
    let triangleCount: Int
    let boundingRadius: Double

    init?(phase: OrbitalPhase, centredOn centre: [Double]) {
        guard !phase.vertices.isEmpty, !phase.indices.isEmpty else { return nil }
        let shift = SIMD3<Float>(
            Float(centre.count == 3 ? centre[0] : 0),
            Float(centre.count == 3 ? centre[1] : 0),
            Float(centre.count == 3 ? centre[2] : 0)
        )

        // A normal is only usable when it is a unit vector; the engine sends
        // unit vectors, but a phase with none (an older payload) still has to
        // render, so the fallback is a degenerate normal that lights flat.
        let hasNormals = phase.normals.count == phase.vertices.count

        var data = [Float]()
        data.reserveCapacity(phase.vertices.count * 6)
        var radiusSquared: Float = 0
        for (index, vertex) in phase.vertices.enumerated() {
            let position = vertex - shift
            radiusSquared = max(radiusSquared, position.x * position.x
                                + position.y * position.y + position.z * position.z)
            let normal = hasNormals ? phase.normals[index] : SIMD3<Float>(0, 1, 0)
            data.append(position.x)
            data.append(position.y)
            data.append(position.z)
            data.append(normal.x)
            data.append(normal.y)
            data.append(normal.z)
        }

        // Indices are dropped rather than clamped when they fall outside the
        // vertex array: a truncated payload should render the triangles it did
        // carry, not crash or draw from whatever memory is next.
        let limit = Int32(phase.vertices.count)
        var safe = [Int32]()
        safe.reserveCapacity(phase.indices.count)
        for index in phase.indices where index >= 0 && index < limit {
            safe.append(index)
        }
        guard safe.count >= 3 else { return nil }

        vertexData = data
        vertexCount = phase.vertices.count
        indices = safe
        triangleCount = safe.count / 3
        boundingRadius = Double(radiusSquared.squareRoot())
    }
}

/// Both phases of one orbital, ready to add to the molecule scene.
struct OrbitalMeshPair {
    let positive: OrbitalMesh?
    let negative: OrbitalMesh?
    let boundingRadius: Double

    init(surface: OrbitalSurface, centreOfMass: [Double]) {
        positive = OrbitalMesh(phase: surface.positive, centredOn: centreOfMass)
        negative = OrbitalMesh(phase: surface.negative, centredOn: centreOfMass)
        // The molecule is framed on its atoms, but a diffuse orbital reaches
        // past them; framing on the surface too keeps the envelope in view.
        boundingRadius = max(positive?.boundingRadius ?? 0, negative?.boundingRadius ?? 0)
    }

    var isEmpty: Bool { positive == nil && negative == nil }
}

/// The density surface as a SceneKit-ready mesh with a colour per vertex.
///
/// The colours are built here rather than in the renderer so the host test can
/// check them: the mapping from an atom attribution to a colour is arithmetic,
/// and a wrong one still renders a perfectly plausible picture in the wrong
/// colours, which nothing on the device would report.
///
/// ``vertexData`` is the same interleaved layout ``OrbitalMesh`` uses -- xyz
/// then the normal, six floats per vertex -- and ``colourData`` is a parallel
/// run of RGB triples, three floats per vertex, which is the layout
/// ``SCNGeometrySource`` wants for a ``.color`` semantic.
struct DensityMesh {
    let vertexData: [Float]
    let colourData: [Float]
    let vertexCount: Int
    let indices: [Int32]
    let triangleCount: Int
    let boundingRadius: Double

    init?(surface: DensitySurface, centredOn centre: [Double]) {
        let phase = surface.mesh
        guard !phase.vertices.isEmpty, !phase.indices.isEmpty else { return nil }
        let shift = SIMD3<Float>(
            Float(centre.count == 3 ? centre[0] : 0),
            Float(centre.count == 3 ? centre[1] : 0),
            Float(centre.count == 3 ? centre[2] : 0)
        )
        let hasNormals = phase.normals.count == phase.vertices.count

        var data = [Float]()
        var colours = [Float]()
        data.reserveCapacity(phase.vertices.count * 6)
        colours.reserveCapacity(phase.vertices.count * 3)
        var radiusSquared: Float = 0
        for (index, vertex) in phase.vertices.enumerated() {
            let position = vertex - shift
            radiusSquared = max(radiusSquared, position.x * position.x
                                + position.y * position.y + position.z * position.z)
            let normal = hasNormals ? phase.normals[index] : SIMD3<Float>(0, 1, 0)
            data.append(position.x)
            data.append(position.y)
            data.append(position.z)
            data.append(normal.x)
            data.append(normal.y)
            data.append(normal.z)

            // An unattributed vertex takes the palette's fallback colour, so a
            // payload whose attribution is short by a few entries still draws
            // the whole surface rather than dropping the tail.
            let base = surface.atom(at: index).map { DensityPalette.parse($0.colorHex) }
                ?? DensityPalette.fallback
            let mixed = DensityPalette.colour(forAtom: base, share: surface.share(at: index))
            colours.append(Float(mixed.red))
            colours.append(Float(mixed.green))
            colours.append(Float(mixed.blue))
        }

        // Same guard as ``OrbitalMesh``: a truncated payload renders the
        // triangles it did carry rather than reading past the vertex array.
        let limit = Int32(phase.vertices.count)
        var safe = [Int32]()
        safe.reserveCapacity(phase.indices.count)
        for index in phase.indices where index >= 0 && index < limit {
            safe.append(index)
        }
        guard safe.count >= 3 else { return nil }

        vertexData = data
        colourData = colours
        vertexCount = phase.vertices.count
        indices = safe
        triangleCount = safe.count / 3
        boundingRadius = Double(radiusSquared.squareRoot())
    }
}
