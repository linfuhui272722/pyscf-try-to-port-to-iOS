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

print("density cloud")
do {
    // The density picture is drawn as nested shells coloured along one ramp.
    // Both halves of that are silent on a device: a shell at the wrong level
    // still draws, and a ramp that maps every level to the same colour still
    // draws - it just carries no information.
    let surface = DensitySurface(fixture("density_surface"))

    expect(!surface.shells.isEmpty, "the fixture has shells (\(surface.shells.count))")
    expect(surface.hasGeometry, "the cloud has geometry")
    expect(surface.peak > 0, "the peak is positive (\(surface.peak))")

    // Ordered by ascending level, so the first shell is the diffuse cloud and
    // the last is the densest core. The viewer relies on this for the legend.
    let levels = surface.shells.map { $0.level }
    expect(levels == levels.sorted(), "shells ascend by level")
    expect(surface.levels == surface.levels.sorted(), "the level list ascends")
    expect(Set(levels).count == levels.count, "no level is drawn twice")

    // Every level asked for has a shell, including an empty one: dropping a
    // level silently would make the legend disagree with the picture.
    expect(surface.shells.count == surface.levels.count,
           "one shell per level (\(surface.shells.count) vs \(surface.levels.count))")

    // The ramp must actually separate the shells. A linear mapping over these
    // absolute levels would put nearly all of them in the last few percent;
    // this is the check that the logarithmic mapping is in place.
    let positions = surface.shells.map { surface.palettePosition(of: $0) }
    let spread = (positions.max() ?? 0) - (positions.min() ?? 0)
    expect(spread > 0.5, "the ramp spans the shells (spread \(String(format: "%.2f", spread)))")
    // Densest at the red end, so the position must fall as the level rises.
    for (a, b) in zip(surface.shells, surface.shells.dropFirst()) {
        expect(surface.palettePosition(of: a) >= surface.palettePosition(of: b),
               "level \(a.level) is not bluer than \(b.level)")
    }

    // Framing: the cloud reaches past the atoms, so it must take part in the
    // camera distance, or a diffuse shell is cropped at the viewport.
    let meshes = DensityMeshSet(surface: surface, centreOfMass: [0, 0, 0])
    expect(meshes.shells.count == surface.shells.filter { !$0.isEmpty }.count,
           "a mesh per non-empty shell")
    expect(meshes.boundingRadius > 0, "the cloud has a radius (\(meshes.boundingRadius))")
    let atomExtent = layout("geometry").extent
    expect(meshes.boundingRadius > atomExtent,
           "the cloud reaches past the atoms (\(String(format: "%.2f", meshes.boundingRadius)) vs \(String(format: "%.2f", atomExtent)))")

    // A cloud drawn around a molecule that is not at the origin must be shifted
    // by the same vector the atoms are, or the shells sit beside the molecule.
    // ``boundingRadius`` is measured from the given centre, so it changes with
    // the centre; what must not change is the relationship between the mesh and
    // that centre, which is what this checks: every vertex moves by exactly the
    // centre, so the cloud keeps its position relative to the atoms.
    let centre = GeometryDescription(fixture("geometry")).centreOfMass
    expect(centre.count == 3, "the fixture reports a centre of mass")
    let shifted = DensityMeshSet(surface: surface, centreOfMass: centre)
    expect(shifted.shells.count == meshes.shells.count, "the same shells are built")
    if let plain = meshes.shells.first?.mesh, let moved = shifted.shells.first?.mesh,
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
        expect(false, "the shells built meshes to compare")
    }
}

print("density ramp")
do {
    // The ramp is a fixed table; these pin the ends and the monotone walk
    // between them, so a stop edited by hand cannot silently reorder the
    // colours the shells are drawn in.
    expect(DensityPalette.stops.count >= 3, "the ramp has stops")
    let positions = DensityPalette.stops.map { $0.position }
    expect(positions == positions.sorted(), "stops ascend")
    expect(positions.first == 0 && positions.last == 1, "the ramp covers 0 to 1")

    let red = DensityPalette.colour(at: 0)
    let blue = DensityPalette.colour(at: 1)
    expect(red.red > red.blue, "the dense end is red")
    expect(blue.blue > blue.red, "the diffuse end is blue")

    // Out-of-range input is clamped rather than extrapolated: a shell whose
    // level falls outside the list must still get a valid colour.
    let below = DensityPalette.colour(at: -5)
    expect(abs(below.red - red.red) < 1e-9, "below the ramp clamps to the dense end")
    let above = DensityPalette.colour(at: 5)
    expect(abs(above.blue - blue.blue) < 1e-9, "above the ramp clamps to the diffuse end")
    let nan = DensityPalette.colour(at: Double.nan)
    expect(nan.red.isFinite && nan.green.isFinite && nan.blue.isFinite, "a NaN position yields a colour")

    // Every colour must be a real RGB triple in range: the values are handed
    // straight to UIColor, which traps on out-of-range components.
    for step in 0...20 {
        let colour = DensityPalette.colour(at: Double(step) / 20)
        expect(colour.red >= 0 && colour.red <= 1
               && colour.green >= 0 && colour.green <= 1
               && colour.blue >= 0 && colour.blue <= 1,
               "colour at \(step)/20 is in range")
    }

    // Position mapping: the extremes of the level list land on the ramp ends,
    // and the middle sits between them.
    let levels = [0.002, 0.01, 0.05, 0.2, 1.0]
    expect(DensityPalette.position(of: 1.0, among: levels) == 0, "the densest level is at the red end")
    expect(DensityPalette.position(of: 0.002, among: levels) == 1, "the most diffuse level is at the blue end")
    let middle = DensityPalette.position(of: 0.05, among: levels)
    expect(middle > 0 && middle < 1, "a middle level sits between the ends (\(middle))")
    // A single-level list must not divide by zero.
    expect(DensityPalette.position(of: 0.1, among: [0.1]) == 0, "a lone level is handled")
    expect(DensityPalette.position(of: 0.1, among: []) == 0, "an empty level list is handled")
}

print("")
print(failures == 0 ? "\(checks)/\(checks) checks passed" : "\(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)
