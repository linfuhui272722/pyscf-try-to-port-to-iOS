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
    // The density picture is one closed surface at a single contour, coloured by
    // the density each atom carries at its own nucleus.  Both halves are silent
    // on a device: a surface at the wrong contour still draws, and a density
    // mapped to the wrong colour still draws -- it just carries no information.
    let surface = DensitySurface(fixture("density_surface"))

    expect(surface.hasGeometry, "the surface has geometry")
    expect(surface.peak > 0, "the peak is positive (\(surface.peak))")
    expect(surface.level > 0, "the contour is positive (\(surface.level))")
    expect(surface.level < surface.peak, "the contour is below the peak")
    expect(surface.triangleCount > 0, "the surface has triangles (\(surface.triangleCount))")

    // The colouring has to cover the mesh. The renderer indexes the density per
    // vertex, so a short array would colour the tail with the cool end.
    let vertexCount = surface.mesh.vertices.count
    expect(vertexCount > 0, "the mesh has vertices (\(vertexCount))")
    expect(surface.vertexDensity.count == vertexCount,
           "one density per vertex (\(surface.vertexDensity.count) vs \(vertexCount))")
    expect(surface.atoms.count == 3, "water has three atoms (\(surface.atoms.count))")

    // The range is what the ramp is scaled to, so it must bracket the values.
    expect(surface.densityRange.count == 2, "the range has two ends")
    if surface.densityRange.count == 2 {
        let low = surface.densityRange[0]
        let high = surface.densityRange[1]
        expect(low > 0, "the low end is positive (\(low))")
        expect(high >= low, "the range is ordered (\(low) ... \(high))")
        expect(surface.vertexDensity.allSatisfy { $0 >= low - 1e-6 && $0 <= high + 1e-6 },
               "every vertex density lies inside the range")
    }

    // Oxygen's nucleus is far denser than hydrogen's: the whole point of the
    // colouring is that the atoms are told apart.
    let oxygen = surface.atoms.first { $0.element == "O" }
    let hydrogen = surface.atoms.first { $0.element == "H" }
    expect(oxygen != nil && hydrogen != nil, "water has O and H")
    if let oxygen = oxygen, let hydrogen = hydrogen {
        expect(oxygen.nucleusDensity > hydrogen.nucleusDensity * 10,
               "oxygen out-carries hydrogen (\(oxygen.nucleusDensity) vs \(hydrogen.nucleusDensity))")
    }

    // The legend orders the atoms densest first, so the red end is explained
    // first; and the CPK palette still reaches the model, so the legend and the
    // ball-and-stick atoms agree about which colour means which element.
    let ordered = surface.atomsByNuclearDensity
    expect(ordered.count == surface.atoms.count, "the legend lists every atom")
    let descending = zip(ordered, ordered.dropFirst())
        .allSatisfy { $0.nucleusDensity >= $1.nucleusDensity }
    expect(descending, "the legend is ordered densest first")
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
    // The colour is a position on the red-to-blue ramp, taken from the density
    // in the logarithm.  A wrong ramp still renders a plausible picture in the
    // wrong colours, so it is pinned here rather than eyeballed on a device.

    // The ends of the ramp are the named colours, so a change to the stops that
    // broke the meaning would fail here.
    let red = DensityPalette.colour(at: 0.0)
    expect(red.red > 0.5 && red.green < 0.1 && red.blue < 0.1,
           "the dense end is red (\(red))")
    let blue = DensityPalette.colour(at: 1.0)
    expect(blue.blue > 0.7 && blue.red < 0.2 && blue.green < 0.4,
           "the diffuse end is blue (\(blue))")

    // The named colours in between, in order, so the ramp reads red -> orange ->
    // yellow -> green -> blue and not some other rainbow.
    let orange = DensityPalette.colour(at: 0.25)
    expect(orange.red > 0.8 && orange.green > 0.2 && orange.green < 0.5 && orange.blue < 0.1,
           "a quarter in is orange (\(orange))")
    let yellow = DensityPalette.colour(at: 0.5)
    expect(yellow.red > 0.8 && yellow.green > 0.7 && yellow.blue < 0.2,
           "the middle is yellow (\(yellow))")
    let green = DensityPalette.colour(at: 0.75)
    expect(green.green > 0.6 && green.red < 0.4 && green.blue < 0.4,
           "three quarters in is green (\(green))")

    // Every component stays a colour, including off the ends and for a
    // non-finite position: these come from the payload and go to SceneKit.
    for position in [-1.0, 2.0, Double.nan, Double.infinity] {
        let colour = DensityPalette.colour(at: position)
        expect(colour.red >= 0 && colour.red <= 1
               && colour.green >= 0 && colour.green <= 1
               && colour.blue >= 0 && colour.blue <= 1,
               "position \(position) yields an in-range colour")
    }

    // The mapping is logarithmic, and the densest value lands at the red end.
    expect(abs(DensityPalette.position(of: 100, low: 0.1, high: 100)) < 1e-9,
           "the densest value is at the red end")
    expect(abs(DensityPalette.position(of: 0.1, low: 0.1, high: 100) - 1) < 1e-9,
           "the emptiest value is at the blue end")
    // The geometric mean sits halfway on a log scale; a linear mapping would
    // put it near the red end and lose the contrast the ramp exists to show.
    let geometric = (0.1 * 100.0).squareRoot()
    expect(abs(DensityPalette.position(of: geometric, low: 0.1, high: 100) - 0.5) < 1e-9,
           "the geometric mean sits halfway")

    // A degenerate or reversed range, or a non-positive density, collapses to
    // the dense end rather than dividing by zero or going out of range.
    for position in [DensityPalette.position(of: 1, low: 1, high: 1),
                     DensityPalette.position(of: 1, low: 100, high: 0.1),
                     DensityPalette.position(of: 0, low: 0.1, high: 100),
                     DensityPalette.position(of: -1, low: 0.1, high: 100)] {
        expect(position >= 0 && position <= 1, "a degenerate input stays on the ramp (\(position))")
    }

    // The mesh colours each vertex from the ramp, so a vertex over oxygen comes
    // out hotter than one over hydrogen.  This is the end-to-end statement of
    // what the picture shows.
    let surface = DensitySurface(fixture("density_surface"))
    let mesh = DensityMesh(surface: surface, centredOn: [0, 0, 0])
    expect(mesh != nil, "the surface builds a mesh")
    if let mesh = mesh {
        var hottest = 0.0
        var coolest = 1.0
        for index in stride(from: 0, to: mesh.colourData.count, by: 3) {
            let r = Double(mesh.colourData[index])
            let g = Double(mesh.colourData[index + 1])
            let b = Double(mesh.colourData[index + 2])
            // Redness: red high, blue low.  A proxy for the ramp position that
            // does not need the mesh to hand back the density.
            hottest = max(hottest, r - b)
            coolest = min(coolest, r - b)
        }
        expect(hottest - coolest > 0.3,
               "the surface spans the ramp (\(hottest) vs \(coolest))")
    }
}

print("the light rig lights the model from every side")
do {
    // The rig has to be omnidirectional: a directional rig leaves the far side
    // of the cloud in shadow, and the colours there read as black, so part of
    // the ramp is invisible.  A rig that is symmetric through the origin has a
    // direction sum of zero, which is the property that makes it omnidirectional
    // rather than merely bright.
    let lamps = MoleculeLayout.lamps
    expect(lamps.count >= 4, "there are several lamps (\(lamps.count))")

    let sum = lamps.reduce((x: 0.0, y: 0.0, z: 0.0)) {
        (x: $0.x + $1.x, y: $0.y + $1.y, z: $0.z + $1.z)
    }
    let magnitude = (sum.x * sum.x + sum.y * sum.y + sum.z * sum.z).squareRoot()
    expect(magnitude < 1e-9,
           "the lamps cancel through the origin, so no direction dominates (\(magnitude))")

    // Every lamp the same brightness, or the brightest one becomes a key light
    // and the rig is directional again.
    let intensities = Set(lamps.map { $0.intensity })
    expect(intensities.count == 1, "every lamp is equally bright (\(intensities))")

    // Each lamp at a real distance from the origin, so none sits inside the
    // molecule where it would light one atom and not the others.
    let radii = lamps.map { ($0.x * $0.x + $0.y * $0.y + $0.z * $0.z).squareRoot() }
    expect(radii.allSatisfy { abs($0 - 1.0) < 1e-9 },
           "every lamp is on the unit sphere (\(Set(radii)))")

    // A ring with a lamp on every axis, so the six faces of the model each get
    // a lamp rather than the light favouring one plane.
    let components = lamps.map { [$0.x, $0.y, $0.z] }
    for axis in 0..<3 {
        let others = (0..<3).filter { $0 != axis }
        let aligned = components.filter { vector in
            others.allSatisfy { abs(vector[$0]) < 1e-9 }
        }
        expect(aligned.contains { $0[axis] > 0.5 },
               "axis \(axis) has a lamp on its positive side")
        expect(aligned.contains { $0[axis] < -0.5 },
               "axis \(axis) has a lamp on its negative side")
    }

    // The ambient floor is what keeps a crevice between two atoms, which no lamp
    // can reach, from going black.  It must come from the surrounding light
    // image rather than from `ambient` on the lamps: SceneKit sums ambient
    // across lights, so a floor set on six of them would be delivered six times
    // over and blow the model out to white.
    expect(MoleculeLayout.environmentIntensity >= 0.3,
           "the omnidirectional fill is substantial (\(MoleculeLayout.environmentIntensity))")
    expect(MoleculeLayout.environmentIntensity <= 1.0,
           "the fill does not blow the model out to white")

    // The light image must be nearly uniform: variation in it is a direction the
    // model is lit from, which is what the rig exists to avoid.
    expect(MoleculeLayout.environmentSpread < 0.15,
           "the light image is nearly uniform (\(MoleculeLayout.environmentSpread))")

    // A physically-based material's glare comes from low roughness, which
    // concentrates the lamps into a small highlight.  The cloud must be rougher
    // than a glossy default, or the highlight is hard on the eyes.
    expect(MoleculeLayout.cloudRoughness >= 0.7,
           "the cloud's material is diffuse, not glossy (\(MoleculeLayout.cloudRoughness))")
}

print("the cloud does not veil the molecule it encloses")
do {
    // The density surface closes around the whole molecule, so every atom is
    // behind its near wall and the veil applies at full strength.  At the old
    // default of 0.55 the atoms were half-covered and the screen read as "the
    // molecule is hidden", which is what the user reported.
    expect(MoleculeLayout.defaultDensityOpacity < 0.4,
           "the cloud opens transparent enough to see the atoms through "
           + "(\(MoleculeLayout.defaultDensityOpacity))")
    expect(MoleculeLayout.defaultDensityOpacity > MoleculeLayout.minimumDensityOpacity,
           "the default is above the slider's floor, so it can be made fainter")

    // A floor above zero so the bottom of the slider leaves a visible shell
    // rather than making the surface vanish.
    expect(MoleculeLayout.minimumDensityOpacity > 0.0,
           "the floor leaves the surface visible as a shape")

    // The slider must have real travel, or "adjusting" it does nothing -- which
    // is what the user suspected.
    let travel = MoleculeLayout.maximumDensityOpacity - MoleculeLayout.minimumDensityOpacity
    expect(travel > 0.5, "the slider has real travel (\(travel))")

    // The density veil is drawn through one layer only (the near wall), so it
    // can afford to be fainter than the orbital envelope, which is a set of
    // overlapping walls.
    expect(MoleculeLayout.defaultDensityOpacity <= MoleculeLayout.defaultOrbitalOpacity,
           "the enclosing cloud is no more opaque than the orbital envelope")
}

print("")
print(failures == 0 ? "\(checks)/\(checks) checks passed" : "\(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)
