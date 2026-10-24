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

print("")
print(failures == 0 ? "\(checks)/\(checks) checks passed" : "\(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)
