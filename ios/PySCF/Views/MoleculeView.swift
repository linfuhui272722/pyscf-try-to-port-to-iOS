// MoleculeView.swift
//
// Renders the current geometry as a ball-and-stick model with SceneKit.
// Bond and atom colours come from the engine's CPK palette so the 3D view and
// the element table stay consistent.

import SwiftUI
import SceneKit

/// Ball-and-stick renderer for the current molecule.
struct MoleculeView: UIViewRepresentable {
    let geometry: GeometryDescription?
    let elementTable: [Element]

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.scene = makeScene()
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let scene = makeScene()
        view.scene = scene
        view.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: false)
    }

    // MARK: - Scene construction

    private func makeScene() -> SCNScene {
        let scene = SCNScene()
        guard let geometry = geometry, !geometry.atoms.isEmpty else {
            scene.rootNode.addChildNode(makeCamera(radius: 6))
            return scene
        }

        let coords = geometry.atoms.map { vector($0.xyz) }
        let radius = boundingRadius(coords)
        let root = SCNNode()
        scene.rootNode.addChildNode(root)

        // Recentre on the centre of mass so the model spins in place.
        let centre = vector(geometry.centreOfMass)
        for (index, atom) in geometry.atoms.enumerated() {
            let position = coords[index] - centre
            let node = makeAtom(atom, position: position, radius: radius)
            root.addChildNode(node)
        }

        for bond in geometry.bonds {
            guard bond.i < coords.count, bond.j < coords.count else { continue }
            let a = coords[bond.i] - centre
            let b = coords[bond.j] - centre
            root.addChildNode(makeBond(from: a, to: b, radius: radius))
        }

        scene.rootNode.addChildNode(makeCamera(radius: radius * 3.4))
        scene.rootNode.addChildNode(makeLight(at: SCNVector3(radius, radius, radius)))
        scene.rootNode.addChildNode(makeLight(at: SCNVector3(-radius, -radius * 0.5, -radius)))
        return scene
    }

    private func makeAtom(_ atom: PlacedAtom, position: SCNVector3, radius: Float) -> SCNNode {
        let element = elementTable.first { $0.symbol == atom.element }
        let scale: Float = element.map { Float(max($0.covalentRadius, 0.3)) } ?? 0.5
        let sphere = SCNSphere(radius: CGFloat(max(radius * 0.11, 0.12) * scale))
        sphere.segmentCount = 48

        let material = SCNMaterial()
        material.diffuse.contents = element?.color.uiColor ?? UIColor.systemGray
        material.specular.contents = UIColor.white
        material.shininess = 0.6
        material.lightingModel = .physicallyBased
        material.roughness.contents = 0.35
        material.metalness.contents = 0.05
        sphere.materials = [material]

        let node = SCNNode(geometry: sphere)
        node.position = position
        node.name = "atom-\(atom.index)"
        return node
    }

    private func makeBond(from a: SCNVector3, to b: SCNVector3, radius: Float) -> SCNNode {
        let delta = b - a
        let length = delta.length
        guard length > 0.0001 else { return SCNNode() }

        let cylinder = SCNCylinder(radius: CGFloat(max(radius * 0.035, 0.035)), height: CGFloat(length))
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

    private func makeCamera(radius: Float) -> SCNNode {
        let camera = SCNCamera()
        camera.fieldOfView = 45
        camera.zNear = 0.01
        camera.zFar = 500
        let node = SCNNode()
        node.camera = camera
        node.name = "camera"
        node.position = SCNVector3(0, 0, radius * 2)
        node.look(at: SCNVector3Zero)
        return node
    }

    private func makeLight(at position: SCNVector3) -> SCNNode {
        let light = SCNLight()
        light.type = .omni
        light.intensity = 900
        let node = SCNNode()
        node.light = light
        node.position = position
        return node
    }

    // MARK: - Geometry helpers

    private func boundingRadius(_ points: [SCNVector3]) -> Float {
        let centre = points.reduce(SCNVector3Zero, +) / Float(points.count)
        let furthest = points.map { ($0 - centre).length }.max() ?? 1
        return max(furthest, 0.6)
    }

    /// Rotation that maps ``source`` onto ``target``.
    private func orientation(from source: SCNVector3, to target: SCNVector3) -> SCNQuaternion {
        let dot = source.dot(target)
        if dot > 0.9999 { return SCNQuaternion(0, 0, 0, 1) }
        if dot < -0.9999 { return SCNQuaternion(1, 0, 0, 0) }
        let axis = source.cross(target)
        let quaternion = SCNQuaternion(axis.x, axis.y, axis.z, 1 + dot)
        return quaternion.normalized
    }
}

// MARK: - Small vector helpers

private func vector(_ values: [Double]) -> SCNVector3 {
    guard values.count >= 3 else { return SCNVector3Zero }
    return SCNVector3(Float(values[0]), Float(values[1]), Float(values[2]))
}

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
