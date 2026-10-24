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
struct MoleculeView: UIViewRepresentable {
    let geometry: GeometryDescription?
    let elementTable: [Element]

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
        context.coordinator.update(geometry: geometry, elements: elementTable)
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
        private var atomNodes: [Int: SCNNode] = [:]
        private var bondNodes: [SCNNode] = []
        /// Identifies the geometry currently built, so identical input does not
        /// rebuild the graph.
        private var signature = ""
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

        func update(geometry: GeometryDescription?, elements: [Element]) {
            guard let geometry = geometry, !geometry.atoms.isEmpty else {
                content.isHidden = true
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
            reframe(to: layout.cameraDistance)
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

        /// Points the camera at the origin from its current direction.
        ///
        /// Only the distance changes, so an orbit the user has performed
        /// survives a geometry refresh.
        private func reframe(to distance: Double) {
            guard distance > 0, distance.isFinite else { return }
            let current = cameraNode.position
            let length = (current.x * current.x + current.y * current.y
                          + current.z * current.z).squareRoot()

            if length < 0.0001 {
                cameraNode.position = SCNVector3(0, 0, Float(distance))
            } else if abs(distance - cameraDistance) > 0.001 {
                let scale = Float(distance / Double(length))
                cameraNode.position = SCNVector3(
                    current.x * scale, current.y * scale, current.z * scale)
            }
            cameraDistance = distance
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
