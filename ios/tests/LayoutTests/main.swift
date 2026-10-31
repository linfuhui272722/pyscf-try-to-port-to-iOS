// LayoutTests.swift
//
// Host-side checks for the 3D preview's sizing and framing rules.
//
// These exist because the preview's failure mode is invisible from the model
// layer: the engine returned correct water geometry the whole time, and the
// scene graph built without error, but every sphere was scaled by the molecule's
// own bounding radius. Water, whose entire extent is under 1 Å, came out as
// specks, and the same element rendered at a different size in every molecule.
// A scene like that still renders, so nothing on the device reports it.
//
// Runs with the plain Linux Swift toolchain, since MoleculeLayout is Foundation
// only:
//   swiftc LayoutTests.swift PySCFModels.swift MoleculeLayout.swift -o layout

import Foundation

var failures = 0
var checks = 0

func expect(_ condition: Bool, _ label: String) {
    checks += 1
    if condition {
        print("  ok   \(label)")
    } else {
        print("  FAIL \(label)")
        failures += 1
    }
}

let fixturesPath = ProcessInfo.processInfo.environment["FIXTURES"] ?? "/tmp/contract/fixtures.json"

func fixture(_ name: String) -> JSONObject {
    guard let data = FileManager.default.contents(atPath: fixturesPath),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let raw = root[name] as? String
    else {
        print("  FAIL could not load fixture '\(name)'")
        failures += 1
        checks += 1
        return JSONObject([:])
    }
    do {
        if case .result(let object) = try RPCResponse.decode(raw) {
            return object
        }
    } catch {
        print("  FAIL fixture '\(name)' did not decode: \(error)")
        failures += 1
        checks += 1
    }
    return JSONObject([:])
}

/// Covalent radii taken from the engine's own table.
let radii: [String: Double] = ["H": 0.31, "C": 0.76, "O": 0.66, "He": 0.28]

func layout(_ name: String) -> MoleculeLayout {
    MoleculeLayout(geometry: GeometryDescription(fixture(name)), covalentRadii: radii)
}

print("atom sizing is independent of the molecule")
do {
    let water = layout("geometry")
    let benzene = layout("geometry_benzene")
    let ethanol = layout("geometry_ethanol")

    func radius(_ layout: MoleculeLayout, _ symbol: String) -> Double? {
        layout.atoms.first { $0.element == symbol }?.radius
    }

    // The defect: the same element had a different radius in every molecule.
    for symbol in ["H", "C", "O"] {
        let values = [radius(water, symbol), radius(benzene, symbol), radius(ethanol, symbol)]
            .compactMap { $0 }
        expect(values.count >= 2, "\(symbol) appears in several fixtures (\(values.count))")
        if let first = values.first {
            expect(values.allSatisfy { abs($0 - first) < 1e-9 },
                   "\(symbol) radius is the same in every molecule")
        }
    }

    expect(radius(water, "O") != nil, "water has an oxygen")
    if let oxygen = radius(water, "O"), let hydrogen = radius(water, "H") {
        expect(oxygen > hydrogen, "oxygen renders larger than hydrogen")
        // A hydrogen sphere must be visible against a ~0.96 Å bond; the old
        // rule produced 0.037 Å here, about 4% of the bond length.
        expect(hydrogen > 0.05, "hydrogen is not a speck (\(hydrogen) Å)")
        expect(hydrogen < 0.5, "hydrogen stays smaller than a bond (\(hydrogen) Å)")
    }
    expect(MoleculeLayout.atomRadius(covalentRadius: nil) >= MoleculeLayout.minimumAtomRadius,
           "an unknown element still gets a drawable radius")
}

print("bond radius is constant")
do {
    let water = layout("geometry")
    let benzene = layout("geometry_benzene")
    let waterBond = water.bonds.first?.radius ?? 0
    let benzeneBond = benzene.bonds.first?.radius ?? 0
    expect(water.bonds.count == 2, "water has two bonds (\(water.bonds.count))")
    expect(benzene.bonds.count > water.bonds.count, "benzene has more bonds")
    expect(abs(waterBond - benzeneBond) < 1e-9, "bonds are the same thickness everywhere")
    expect(waterBond > 0.01, "bond radius is drawable (\(waterBond) Å)")
    expect(waterBond < 0.2, "bond radius does not swallow the atoms (\(waterBond) Å)")
}

print("camera framing")
do {
    // The old camera sat at 6.8 x the bounding radius, filling ~37% of the
    // viewport. Anything much below 0.6 reads as a tiny molecule in a big box.
    for name in ["geometry", "geometry_benzene", "geometry_ethanol", "geometry_h2", "geometry_helium"] {
        let value = layout(name).framingFraction()
        expect(value > 0.6 && value <= 1.0, "\(name) fills the frame (\(String(format: "%.2f", value)))")
    }

    // Framing must not depend on the fov by accident: a bigger molecule needs a
    // proportionally larger distance.
    let small = layout("geometry_h2")
    let large = layout("geometry_benzene")
    expect(large.cameraDistance > small.cameraDistance,
           "benzene's camera is further back than H2's")
    expect(MoleculeLayout.cameraDistance(forExtent: 1) > 0, "distance is positive")
    expect(MoleculeLayout.cameraDistance(forExtent: 0) > 0, "a zero extent still yields a distance")
}

print("geometry is centred and validated")
do {
    let water = layout("geometry")
    // Centring on the centre of mass means the model sits on the camera axis
    // rather than drifting to one side as atoms are added.
    let centroid = water.atoms.map { ($0.x + $0.y + $0.z) / 3 }.reduce(0, +)
    expect(abs(centroid) < 0.5, "water is roughly centred (\(String(format: "%.3f", centroid)))")
    expect(water.atoms.count == 3, "three atoms placed")
    expect(water.atoms.allSatisfy { $0.radius > 0 }, "every atom has a radius")

    let helium = layout("geometry_helium")
    expect(helium.atoms.count == 1, "single atom is placed")
    expect(helium.bonds.isEmpty, "a lone atom has no bonds")
    expect(helium.extent >= MoleculeLayout.minimumExtent, "extent has a floor")
    expect(helium.cameraDistance.isFinite, "single atom frames without a NaN")

    // An empty payload must produce an empty layout rather than a crash: the
    // renderer indexes the atom array with the bond indices.
    let empty = MoleculeLayout(geometry: GeometryDescription(JSONObject([:])), covalentRadii: radii)
    expect(empty.atoms.isEmpty && empty.bonds.isEmpty, "empty geometry yields an empty layout")
    expect(empty.cameraDistance.isFinite, "empty geometry still frames")
}

print("density surface")
do {
    // The density picture is one closed surface at a single contour, coloured
    // by which atom dominates each vertex.  Both halves are silent on a device:
    // a surface at the wrong contour still draws, and an attribution mapped to
    // the wrong colour still draws -- it just carries no information.
    let surface = DensitySurface(fixture("density_surface"))

    expect(surface.hasGeometry, "the surface has geometry")
    expect(surface.peak > 0, "the peak is positive (\(surface.peak))")
    expect(surface.level > 0, "the contour is positive (\(surface.level))")
    expect(surface.level < surface.peak, "the contour is below the peak")
    expect(surface.triangleCount > 0, "the surface has triangles (\(surface.triangleCount))")

    // The attribution has to cover the mesh. The renderer indexes these arrays
    // per vertex, so a short one would colour the tail with the fallback.
    let vertexCount = surface.mesh.vertices.count
    expect(vertexCount > 0, "the mesh has vertices (\(vertexCount))")
    expect(surface.atomIndex.count == vertexCount,
           "one atom index per vertex (\(surface.atomIndex.count) vs \(vertexCount))")
    expect(surface.atomShare.count == vertexCount,
           "one share per vertex (\(surface.atomShare.count) vs \(vertexCount))")
    expect(surface.atoms.count == 3, "water has three atoms (\(surface.atoms.count))")

    // Every index must be in range, or the lookup traps on the device.
    let inRange = surface.atomIndex.allSatisfy { $0 >= 0 && $0 < surface.atoms.count }
    expect(inRange, "every atom index is in range")

    // Every atom of water owns some of the surface: the whole point of the
    // colouring is that the atoms are told apart.
    let owners = Set(surface.atomIndex)
    expect(owners == Set(0..<surface.atoms.count),
           "every atom owns part of the surface (owners \(owners.sorted()))")

    // The per-atom counts the legend shows must agree with the attribution.
    let counts = surface.vertexCounts
    expect(counts.values.reduce(0, +) == vertexCount,
           "the legend counts cover the mesh (\(counts.values.reduce(0, +)) vs \(vertexCount))")
    expect(counts.keys.allSatisfy { owners.contains($0) },
           "the legend only lists atoms that own surface")

    // The engine's CPK palette reaches the model, so the surface and the
    // ball-and-stick atoms agree about which colour means which element.
    let oxygen = surface.atoms.first { $0.element == "O" }
    expect(oxygen?.colorHex == "#FF0D0D", "oxygen carries the CPK colour (\(oxygen?.colorHex ?? "nil"))")

    // Framing: the cloud reaches past the atoms, so it must take part in the
    // camera distance, or a diffuse surface is cropped at the viewport.
    let mesh = DensityMesh(surface: surface, centredOn: [0, 0, 0])
    expect(mesh != nil, "the surface builds a mesh")
    if let mesh = mesh {
        expect(mesh.colourData.count == mesh.vertexCount * 3,
               "one RGB triple per vertex (\(mesh.colourData.count) vs \(mesh.vertexCount * 3))")
        let inUnitRange = stride(from: 0, to: mesh.colourData.count, by: 1)
            .allSatisfy { mesh.colourData[$0] >= 0 && mesh.colourData[$0] <= 1 }
        expect(inUnitRange, "every colour component is in 0...1")
        expect(mesh.boundingRadius > 0, "the cloud has a radius (\(mesh.boundingRadius))")
        let atomExtent = layout("geometry").extent
        expect(mesh.boundingRadius > atomExtent,
               "the cloud reaches past the atoms (\(String(format: "%.2f", mesh.boundingRadius)) vs \(String(format: "%.2f", atomExtent)))")
    }

    // A cloud drawn around a molecule that is not at the origin must be shifted
    // by the same vector the atoms are, or the surface sits beside the molecule.
    let centre = GeometryDescription(fixture("geometry")).centreOfMass
    expect(centre.count == 3, "the fixture reports a centre of mass")
    if let plain = mesh, let moved = DensityMesh(surface: surface, centredOn: centre),
       plain.vertexData.count == moved.vertexData.count {
        // The first three floats of each vertex are its position.
        var maxDelta = 0.0
        for index in stride(from: 0, to: plain.vertexData.count, by: 6) {
            for axis in 0..<3 {
                let delta = Double(plain.vertexData[index + axis] - moved.vertexData[index + axis])
                maxDelta = max(maxDelta, abs(delta - centre[axis]))
            }
        }
        expect(maxDelta < 1e-5,
               "every vertex is shifted by the centre (\(String(format: "%.2e", maxDelta)))")
    } else {
        expect(false, "the surface built meshes to compare")
    }
}

print("density colours")
do {
    // The colour is per atom, from the engine's CPK palette.  A wrong mapping
    // still renders a plausible picture in the wrong colours, so it is pinned
    // here rather than eyeballed on a device.
    let oxygen = DensityPalette.parse("#FF0D0D")
    expect(abs(oxygen.red - 1.0) < 1e-6, "oxygen parses to red (\(oxygen.red))")
    expect(oxygen.green < 0.1 && oxygen.blue < 0.1, "oxygen has no green or blue")

    let white = DensityPalette.parse("#FFFFFF")
    expect(abs(white.red - 1) < 1e-6 && abs(white.green - 1) < 1e-6 && abs(white.blue - 1) < 1e-6,
           "hydrogen parses to white")

    // A malformed hex string degrades to the fallback rather than to black, so
    // a bad payload looks unattributed rather than deliberate.
    for bad in ["", "#12", "zzzzzz", "#GGGGGG", "#1234567"] {
        let colour = DensityPalette.parse(bad)
        expect(abs(colour.red - DensityPalette.fallback.red) < 1e-9,
               "a bad hex string '\(bad)' falls back")
    }

    // A share of one leaves the atom's own colour untouched: the vertex is
    // entirely that atom's.
    let full = DensityPalette.colour(forAtom: oxygen, share: 1.0)
    expect(abs(full.red - oxygen.red) < 1e-9
           && abs(full.green - oxygen.green) < 1e-9
           && abs(full.blue - oxygen.blue) < 1e-9,
           "a full share leaves the colour untouched")

    // A lower share mixes toward the neutral tone, but only shallowly: the
    // atom's colour must still dominate, or every atom would wash to grey.
    let shared = DensityPalette.colour(forAtom: oxygen, share: 0.5)
    expect(shared.red < oxygen.red, "a shared vertex is mixed down (\(shared.red))")
    expect(shared.red > DensityPalette.fallback.red,
           "but stays nearer the atom than the fallback (\(shared.red))")
    expect(shared.green > oxygen.green, "and gains some of the neutral tone")

    // Out-of-range and non-finite shares must still yield a usable colour:
    // these come from the payload and are handed straight to SceneKit.
    for share in [-1.0, 2.0, Double.nan, Double.infinity] {
        let colour = DensityPalette.colour(forAtom: oxygen, share: share)
        expect(colour.red >= 0 && colour.red <= 1
               && colour.green >= 0 && colour.green <= 1
               && colour.blue >= 0 && colour.blue <= 1,
               "share \(share) yields an in-range colour")
    }
}

print("")
print(failures == 0 ? "\(checks)/\(checks) checks passed" : "\(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)
