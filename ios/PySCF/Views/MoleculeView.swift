// MoleculeView.swift
//
// Renders the current geometry as a ball-and-stick model with SceneKit.
// Bond and atom colours come from the engine's CPK palette so the 3D view and
// the element table stay consistent.
//
// Sizing and camera framing come from ``MoleculeLayout``, which is plain
// Foundation and therefore covered by the host tests. Everything here is
// SceneKit plumbing: building the node graph, and updating it without throwing
// away the user's rotation.

import SwiftUI
import SceneKit

/// Ball-and-stick renderer for the current molecule.
///
/// When ``surface`` is set the orbital is drawn into the same scene as the
/// molecule, as a translucent envelope around each lobe.  Sharing the scene is
/// what puts the orbital at its correct position in the molecule: both are in
/// the same absolute frame, so there is no alignment to get wrong.
struct MoleculeView: UIViewRepresentable {
    let geometry: GeometryDescription?
    let elementTable: [Element]
    /// The orbital to overlay, or ``nil`` for the molecule alone.
    var surface: OrbitalSurface? = nil
    /// Whether the orbital envelope is drawn, so the molecule can be seen
    /// without it.
    var showsOrbital: Bool = true
    /// How opaque the envelope is drawn.  Applied to the existing material, so
    /// changing it never rebuilds the mesh.
    var orbitalOpacity: Double = MoleculeLayout.defaultOrbitalOpacity
    /// The electron-density cloud to overlay, or ``nil``.  Drawn as one closed
    /// surface coloured by atom, around the same molecule and in the same frame
    /// as the orbital would be.
    var density: DensitySurface? = nil
    /// Whether the density cloud is drawn.
    var showsDensity: Bool = true
    var densityOpacity: Double = MoleculeLayout.defaultDensityOpacity

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        // Custom lights are installed below. Leaving this on as well double-lit
        // the model and washed out the CPK colours.
        view.autoenablesDefaultLighting = false
        view.scene = SCNScene()
        context.coordinator.installRig(in: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.update(
            geometry: geometry, elements: elementTable,
            surface: surface, showsOrbital: showsOrbital,
            orbitalOpacity: orbitalOpacity,
            density: density, showsDensity: showsDensity,
            densityOpacity: densityOpacity)
    }

    // MARK: - Node graph

    /// Owns the scene contents across SwiftUI updates.
    ///
    /// ``updateUIView`` runs on every keystroke in the atom editor, so the scene
    /// must be updated rather than replaced: assigning a new ``SCNScene``
    /// reset the camera each time, and the model jumped back to its start
    /// orientation while the user was turning it.
    final class Coordinator {
        private let content = SCNNode()
        private let cameraNode = SCNNode()
        /// The orbital envelope, kept separate from the molecule so hiding it
        /// does not disturb the molecule's nodes or the camera.
        private let orbitalNode = SCNNode()
        /// The density cloud, likewise kept separate: it is a different overlay
        /// on the same molecule, and the two can be shown independently.
        private let densityNode = SCNNode()
        private var atomNodes: [Int: SCNNode] = [:]
        private var bondNodes: [SCNNode] = []
        /// Identifies the geometry currently built, so identical input does not
        /// rebuild the graph.
        private var signature = ""
        /// Identifies the orbital currently built, so a rebuild only happens
        /// when the orbital itself changes and not on every SwiftUI update.
        private var orbitalSignature = ""
        /// Identifies the density cloud currently built, for the same reason.
        private var densitySignature = ""
        /// How far the current envelope reaches from the origin, so the camera
        /// can frame it.
        private var orbitalRadius: Double = 0
        /// How far the current density cloud reaches.
        private var densityRadius: Double = 0
        private var cameraDistance: Double = 0

        func installRig(in view: SCNView) {
            guard let scene = view.scene else { return }

            let camera = SCNCamera()
            camera.fieldOfView = CGFloat(MoleculeLayout.fieldOfViewDegrees)
            camera.zNear = 0.01
            camera.zFar = 500
            cameraNode.camera = camera
            cameraNode.name = "camera"
            scene.rootNode.addChildNode(cameraNode)
            view.pointOfView = cameraNode

            scene.rootNode.addChildNode(content)
            // Added after the molecule so its translucent envelope blends over
            // the atoms rather than being hidden behind them.  The density
            // cloud is added last so it wraps the orbital as well as the atoms
            // when both are shown.
            scene.rootNode.addChildNode(orbitalNode)
            scene.rootNode.addChildNode(densityNode)
            installLights()
        }

        /// Key, fill and rim lights parented to the camera, so the shading does
        /// not change when a larger molecule pushes the camera back.
        private func installLights() {
            let key = SCNLight()
            key.type = .omni
            key.intensity = 700
            let keyNode = SCNNode()
            keyNode.light = key
            keyNode.position = SCNVector3(2.2, 1.8, 2.6)
            cameraNode.addChildNode(keyNode)

            let fill = SCNLight()
            fill.type = .omni
            fill.intensity = 320
            let fillNode = SCNNode()
            fillNode.light = fill
            fillNode.position = SCNVector3(-2.4, -1.2, 1.4)
            cameraNode.addChildNode(fillNode)

            let rim = SCNLight()
            rim.type = .omni
            rim.intensity = 260
            let rimNode = SCNNode()
            rimNode.light = rim
            rimNode.position = SCNVector3(0, 1.6, -3.0)
            cameraNode.addChildNode(rimNode)
        }

        func update(geometry: GeometryDescription?, elements: [Element],
                    surface: OrbitalSurface? = nil, showsOrbital: Bool = true,
                    orbitalOpacity: Double = MoleculeLayout.defaultOrbitalOpacity,
                    density: DensitySurface? = nil, showsDensity: Bool = true,
                    densityOpacity: Double = MoleculeLayout.defaultDensityOpacity) {
            guard let geometry = geometry, !geometry.atoms.isEmpty else {
                content.isHidden = true
                orbitalNode.isHidden = true
                densityNode.isHidden = true
                return
            }
            content.isHidden = false

            var radii: [String: Double] = [:]
            for element in elements {
                radii[element.symbol] = element.covalentRadius
            }
            let layout = MoleculeLayout(geometry: geometry, covalentRadii: radii)

            let current = Self.signature(of: geometry)
            if signature != current {
                signature = current
                rebuild(layout: layout, elements: elements)
            }

            updateOrbital(showsOrbital ? surface : nil, centreOfMass: geometry.centreOfMass)
            updateDensity(showsDensity ? density : nil, centreOfMass: geometry.centreOfMass)
            applyOpacity(orbitalOpacity, to: orbitalNode)
            applyOpacity(densityOpacity, to: densityNode, floor: MoleculeLayout.minimumDensityOpacity)
            // Either overlay can reach past the atoms, so both take part in the
            // framing; otherwise a diffuse cloud is cropped at the viewport.
            let overlay = max(orbitalNode.isHidden ? 0 : orbitalRadius,
                              densityNode.isHidden ? 0 : densityRadius)
            reframe(to: layout.cameraDistance, orbitalRadius: overlay)
        }

        /// Sets an overlay's transparency on the materials already built.
        ///
        /// Separate from the mesh builders on purpose: opacity is a render
        /// property, and routing it through a rebuild would re-derive the
        /// geometry on every step of the slider drag.  The floor is applied here
        /// so a slider that reaches its bottom still leaves the surface visible
        /// as a shape rather than making it vanish.
        private func applyOpacity(_ opacity: Double, to node: SCNNode,
                                  floor: Double = MoleculeLayout.minimumOrbitalOpacity) {
            let clamped = min(max(opacity, floor), 1.0)
            node.childNodes.forEach { child in
                child.geometry?.materials.forEach { material in
                    material.transparency = CGFloat(clamped)
                }
            }
        }

        /// Builds the orbital nodes, or hides them when there is no surface.
        ///
        /// Rebuilt only when the orbital changes: the surface arrives as a
        /// fresh object on every load, so the signature is what stops a
        /// re-render on each SwiftUI update from discarding the mesh.
        private func updateOrbital(_ surface: OrbitalSurface?, centreOfMass: [Double]) {
            guard let surface = surface else {
                orbitalNode.isHidden = true
                orbitalNode.childNodes.forEach { $0.removeFromParentNode() }
                orbitalSignature = ""
                orbitalRadius = 0
                return
            }
            orbitalNode.isHidden = false

            let current = "\(surface.source)|\(surface.index)|\(surface.isovalueFraction)|"
                + "\(surface.triangleCount)|\(surface.pointsPerAxis)"
            if orbitalSignature != current {
                orbitalSignature = current
                orbitalNode.childNodes.forEach { $0.removeFromParentNode() }
                let meshes = OrbitalMeshPair(surface: surface, centreOfMass: centreOfMass)
                if let positive = meshes.positive {
                    orbitalNode.addChildNode(Self.makeOrbitalNode(positive, phase: .positive))
                }
                if let negative = meshes.negative {
                    orbitalNode.addChildNode(Self.makeOrbitalNode(negative, phase: .negative))
                }
                orbitalRadius = meshes.boundingRadius
            }
        }

        /// Builds the density surface, or hides it when there is no cloud.
        ///
        /// Rebuilt only when the surface changes, for the same reason the
        /// orbital is: the surface arrives as a fresh object on every load, so
        /// the signature is what stops a re-render on each SwiftUI update from
        /// discarding the mesh.
        ///
        /// The mesh is drawn as a single closed surface with a colour per
        /// vertex, so there is no nesting and no render-order problem: the
        /// shell version drew nine translucent surfaces at one render order,
        /// and an outer one hid the inner ones from most angles.
        private func updateDensity(_ surface: DensitySurface?, centreOfMass: [Double]) {
            guard let surface = surface else {
                densityNode.isHidden = true
                densityNode.childNodes.forEach { $0.removeFromParentNode() }
                densitySignature = ""
                densityRadius = 0
                return
            }
            densityNode.isHidden = false

            let current = "\(surface.method)|\(surface.level)|\(surface.pointsPerAxis)|"
                + "\(surface.triangleCount)|\(surface.atoms.count)"
            if densitySignature != current {
                densitySignature = current
                densityNode.childNodes.forEach { $0.removeFromParentNode() }
                if let mesh = DensityMesh(surface: surface, centredOn: centreOfMass) {
                    densityNode.addChildNode(Self.makeColouredNode(
                        mesh,
                        opacity: MoleculeLayout.defaultDensityOpacity,
                        renderingOrder: 5))
                    densityRadius = mesh.boundingRadius
                } else {
                    densityRadius = 0
                }
            }
        }

        /// Which lobe a mesh is, which picks its colour.
        enum Phase { case positive, negative }

        /// An orbital lobe as a SceneKit node, shaded by the mesh's own normals.
        private static func makeOrbitalNode(_ mesh: OrbitalMesh, phase: Phase) -> SCNNode {
            // Two hues that read as opposite phases, translucent so the atoms
            // inside the envelope stay visible.
            let colour: UIColor = phase == .positive
                ? UIColor(red: 0.30, green: 0.55, blue: 0.95, alpha: 1)
                : UIColor(red: 0.95, green: 0.45, blue: 0.25, alpha: 1)
            return makeSurfaceNode(
                mesh, colour: colour,
                opacity: MoleculeLayout.defaultOrbitalOpacity, renderingOrder: 10)
        }

        /// A single-sided isosurface mesh as a SceneKit node.
        ///
        /// Shared by the orbital lobes and the density surface: both are
        /// translucent envelopes over the same molecule, and the only
        /// differences are the colour, the opening opacity and the render
        /// order that decides which blends over which.
        ///
        /// ``isDoubleSided`` is deliberately **false**.  It used to be true,
        /// which was right while the triangle winding was arbitrary: a
        /// double-sided surface shades and blends from either face, so the far
        /// wall of an envelope blended over the near wall and the surface read
        /// as a haze of mixed colours rather than as a shell.  The engine now
        /// orients every triangle outward, so culling back faces is correct and
        /// each surface contributes exactly one layer of colour.
        private static func makeSurfaceNode(
            _ mesh: OrbitalMesh, colour: UIColor, opacity: Double, renderingOrder: Int
        ) -> SCNNode {
            let source = SCNGeometrySource(
                data: Data(bytes: mesh.vertexData, count: mesh.vertexData.count * MemoryLayout<Float>.size),
                semantic: .vertex,
                vectorCount: mesh.vertexCount,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<Float>.size * 6
            )
            let normalSource = SCNGeometrySource(
                data: Data(bytes: mesh.vertexData, count: mesh.vertexData.count * MemoryLayout<Float>.size),
                semantic: .normal,
                vectorCount: mesh.vertexCount,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: MemoryLayout<Float>.size * 3,
                dataStride: MemoryLayout<Float>.size * 6
            )
            let element = SCNGeometryElement(
                data: Data(bytes: mesh.indices, count: mesh.indices.count * MemoryLayout<Int32>.size),
                primitiveType: .triangles,
                primitiveCount: mesh.triangleCount,
                bytesPerIndex: MemoryLayout<Int32>.size
            )
            let geometry = SCNGeometry(sources: [source, normalSource], elements: [element])

            let material = SCNMaterial()
            material.diffuse.contents = colour
            material.emission.contents = colour.withAlphaComponent(0.25)
            material.transparency = CGFloat(opacity)
            material.lightingModel = .physicallyBased
            material.roughness.contents = 0.6
            material.metalness.contents = 0.0
            material.isDoubleSided = false
            // Writing depth but not testing it against itself would make two
            // overlapping surfaces fight where they meet; leaving the test on
            // and the writes off lets them blend.
            material.writesToDepthBuffer = false
            material.blendMode = .alpha
            geometry.materials = [material]

            let node = SCNNode(geometry: geometry)
            node.renderingOrder = renderingOrder
            return node
        }

        /// The density surface as a node with a colour per vertex.
        ///
        /// Same geometry as ``makeSurfaceNode``, with a third source carrying
        /// the per-vertex colours, so the surface shows which atom each region
        /// belongs to.  The material's own ``diffuse`` is left white: with a
        /// ``.color`` source present the vertex colour is multiplied by it, and
        /// anything but white would tint every element the same way.
        ///
        /// ``isDoubleSided`` is false here too, and the depth write is on: this
        /// is a closed surface drawn opaquely enough that the far wall should
        /// be hidden behind the near one, which is what makes the near wall's
        /// colour the one that reads.
        private static func makeColouredNode(
            _ mesh: DensityMesh, opacity: Double, renderingOrder: Int
        ) -> SCNNode {
            let vertexSource = SCNGeometrySource(
                data: Data(bytes: mesh.vertexData, count: mesh.vertexData.count * MemoryLayout<Float>.size),
                semantic: .vertex,
                vectorCount: mesh.vertexCount,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<Float>.size * 6
            )
            let normalSource = SCNGeometrySource(
                data: Data(bytes: mesh.vertexData, count: mesh.vertexData.count * MemoryLayout<Float>.size),
                semantic: .normal,
                vectorCount: mesh.vertexCount,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: MemoryLayout<Float>.size * 3,
                dataStride: MemoryLayout<Float>.size * 6
            )
            let colourSource = SCNGeometrySource(
                data: Data(bytes: mesh.colourData, count: mesh.colourData.count * MemoryLayout<Float>.size),
                semantic: .color,
                vectorCount: mesh.vertexCount,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<Float>.size * 3
            )
            let element = SCNGeometryElement(
                data: Data(bytes: mesh.indices, count: mesh.indices.count * MemoryLayout<Int32>.size),
                primitiveType: .triangles,
                primitiveCount: mesh.triangleCount,
                bytesPerIndex: MemoryLayout<Int32>.size
            )
            let geometry = SCNGeometry(
                sources: [vertexSource, normalSource, colourSource], elements: [element])

            let material = SCNMaterial()
            material.diffuse.contents = UIColor.white
            material.lightingModel = .physicallyBased
            material.roughness.contents = 0.55
            material.metalness.contents = 0.0
            material.transparency = CGFloat(opacity)
            material.isDoubleSided = false
            material.blendMode = .alpha
            geometry.materials = [material]

            let node = SCNNode(geometry: geometry)
            node.renderingOrder = renderingOrder
            return node
        }

        /// Points the camera at the origin from its current direction.
        ///
        /// Only the distance changes, so an orbit the user has performed
        /// survives a geometry refresh.  The orbital radius is folded in so an
        /// envelope that reaches past the atoms is not cropped.
        private func reframe(to distance: Double, orbitalRadius: Double = 0) {
            let target = max(distance, MoleculeLayout.cameraDistance(forExtent: orbitalRadius))
            guard target > 0, target.isFinite else { return }
            let current = cameraNode.position
            let length = (current.x * current.x + current.y * current.y
                          + current.z * current.z).squareRoot()

            if length < 0.0001 {
                cameraNode.position = SCNVector3(0, 0, Float(target))
            } else if abs(target - cameraDistance) > 0.001 {
                let scale = Float(target / Double(length))
                cameraNode.position = SCNVector3(
                    current.x * scale, current.y * scale, current.z * scale)
            }
            cameraDistance = target
        }

        private func rebuild(layout: MoleculeLayout, elements: [Element]) {
            content.childNodes.forEach { $0.removeFromParentNode() }
            atomNodes.removeAll()
            bondNodes.removeAll()

            var colours: [String: Color] = [:]
            for element in elements where colours[element.symbol] == nil {
                colours[element.symbol] = element.color
            }

            // Bonds first so the spheres sit on top of the joins.
            for bond in layout.bonds {
                let node = Self.makeBond(
                    from: layout.atoms[bond.start], to: layout.atoms[bond.end],
                    radius: bond.radius)
                content.addChildNode(node)
                bondNodes.append(node)
            }

            for atom in layout.atoms {
                let node = Self.makeAtom(
                    atom, colour: colours[atom.element] ?? Color(UIColor.systemGray))
                content.addChildNode(node)
                atomNodes[atom.index] = node
            }
        }

        private static func signature(of geometry: GeometryDescription) -> String {
            var parts = [geometry.formula, String(geometry.atoms.count)]
            for atom in geometry.atoms {
                parts.append(atom.element)
                parts.append(atom.xyz.map { String(format: "%.4f", $0) }.joined(separator: ","))
            }
            return parts.joined(separator: "|")
        }

        // MARK: - Geometry construction

        private static func makeAtom(_ atom: MoleculeLayout.Atom, colour: Color) -> SCNNode {
            let sphere = SCNSphere(radius: CGFloat(atom.radius))
            sphere.segmentCount = 48

            let material = SCNMaterial()
            material.diffuse.contents = colour.uiColor
            material.specular.contents = UIColor.white
            material.shininess = 0.6
            material.lightingModel = .physicallyBased
            material.roughness.contents = 0.35
            material.metalness.contents = 0.05
            sphere.materials = [material]

            let node = SCNNode(geometry: sphere)
            node.position = SCNVector3(Float(atom.x), Float(atom.y), Float(atom.z))
            node.name = "atom-\(atom.index)"
            return node
        }

        private static func makeBond(
            from start: MoleculeLayout.Atom, to end: MoleculeLayout.Atom, radius: Double
        ) -> SCNNode {
            let a = SCNVector3(Float(start.x), Float(start.y), Float(start.z))
            let b = SCNVector3(Float(end.x), Float(end.y), Float(end.z))
            let delta = b - a
            let length = delta.length
            guard length > 0.0001 else { return SCNNode() }

            let cylinder = SCNCylinder(radius: CGFloat(radius), height: CGFloat(length))
            cylinder.radialSegmentCount = 24
            let material = SCNMaterial()
            material.diffuse.contents = UIColor.systemGray.withAlphaComponent(0.85)
            material.lightingModel = .physicallyBased
            material.roughness.contents = 0.5
            cylinder.materials = [material]

            let node = SCNNode(geometry: cylinder)
            node.position = (a + b) / 2
            node.orientation = orientation(from: SCNVector3(0, 1, 0), to: delta.normalized)
            return node
        }

        /// Rotation that maps ``source`` onto ``target``.
        private static func orientation(from source: SCNVector3, to target: SCNVector3) -> SCNQuaternion {
            let dot = source.dot(target)
            if dot > 0.9999 { return SCNQuaternion(0, 0, 0, 1) }
            if dot < -0.9999 { return SCNQuaternion(1, 0, 0, 0) }
            let axis = source.cross(target)
            let quaternion = SCNQuaternion(axis.x, axis.y, axis.z, 1 + dot)
            return quaternion.normalized
        }
    }
}

// MARK: - Small vector helpers

private extension SCNVector3 {
    static func + (lhs: SCNVector3, rhs: SCNVector3) -> SCNVector3 {
        SCNVector3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }

    static func - (lhs: SCNVector3, rhs: SCNVector3) -> SCNVector3 {
        SCNVector3(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
    }

    static func / (lhs: SCNVector3, rhs: Float) -> SCNVector3 {
        SCNVector3(lhs.x / rhs, lhs.y / rhs, lhs.z / rhs)
    }

    var length: Float { sqrt(x * x + y * y + z * z) }

    var normalized: SCNVector3 {
        let magnitude = length
        return magnitude > 0 ? self / magnitude : self
    }

    func dot(_ other: SCNVector3) -> Float { x * other.x + y * other.y + z * other.z }

    func cross(_ other: SCNVector3) -> SCNVector3 {
        SCNVector3(
            y * other.z - z * other.y,
            z * other.x - x * other.z,
            x * other.y - y * other.x
        )
    }
}

private extension SCNQuaternion {
    var normalized: SCNQuaternion {
        let magnitude = sqrt(x * x + y * y + z * z + w * w)
        guard magnitude > 0 else { return SCNQuaternion(0, 0, 0, 1) }
        return SCNQuaternion(x / magnitude, y / magnitude, z / magnitude, w / magnitude)
    }
}

private extension Color {
    var uiColor: UIColor { UIColor(self) }
}
