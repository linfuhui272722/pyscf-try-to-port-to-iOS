// ContractTests.swift
//
// Host-side validation that the Swift models decode the exact JSON the Python
// bridge emits.  The fixtures are produced by scripts/check-bridge-contract.sh
// from the real engine, so drift on either side fails the check.
//
// Runs on the build host with the plain Linux Swift toolchain, since the models
// depend only on Foundation:
//   swiftc ContractTests.swift PySCFModels.swift -o contract && ./contract

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

/// Raw response strings, keyed by fixture name.
func rawFixture(_ name: String) -> String? {
    guard let data = FileManager.default.contents(atPath: fixturesPath),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return root[name] as? String
}

/// Decoded ``result`` object for a successful fixture.
///
/// Goes through ``RPCResponse.decode`` rather than reaching into the JSON by
/// hand. The previous version unwrapped ``result`` itself, which is exactly the
/// step the app got wrong, so the check passed while the app showed empty menus
/// and "Engine unavailable" on device.
func fixture(_ name: String) -> JSONObject {
    guard let raw = rawFixture(name) else {
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

print("capabilities")
do {
    let caps = Capabilities(fixture("capabilities"))
    expect(caps.protocolVersion == 1, "protocol version is 1")
    expect(caps.engine.available, "engine reports available")
    expect(!caps.engine.version.isEmpty, "engine version present (\(caps.engine.version))")
    expect(!caps.basisSets.isEmpty, "basis sets present (\(caps.basisSets.count))")
    expect(caps.methods.contains("scf"), "methods list includes scf")
}

print("elements")
do {
    let elements = fixture("elements").objects("elements").map(Element.init)
    expect(elements.count > 50, "more than 50 elements (\(elements.count))")
    let oxygen = elements.first { $0.symbol == "O" }
    expect(oxygen != nil, "oxygen present")
    expect(oxygen?.z == 8, "oxygen Z == 8")
    expect(oxygen?.colorHex.hasPrefix("#") == true, "oxygen has hex colour (\(oxygen?.colorHex ?? "-"))")
    expect((oxygen?.mass ?? 0) > 15 && (oxygen?.mass ?? 0) < 16, "oxygen mass in range")
}

print("presets")
do {
    let catalog = PresetCatalog(fixture("presets"))
    expect(catalog.presets.count > 3, "several presets (\(catalog.presets.count))")
    expect(catalog.presets.allSatisfy { !$0.atoms.isEmpty }, "every preset has atoms")
    expect(catalog.presets.contains { $0.id == "water" }, "water preset present")
}

print("geometry")
do {
    let geometry = GeometryDescription(fixture("geometry"))
    expect(geometry.formula == "H2O", "formula is H2O")
    expect(geometry.atomCount == 3, "three atoms")
    expect(geometry.atoms.count == 3, "three placed atoms")
    expect(geometry.atoms.allSatisfy { $0.xyz.count == 3 }, "every atom has xyz")
    expect(geometry.bonds.count == 2, "two bonds")
    expect(geometry.angles.count == 1, "one angle")
    expect(geometry.inertia.moments.count == 3, "three principal moments")
    expect(geometry.centreOfMass.count == 3, "centre of mass is a 3-vector")
}

print("scf")
do {
    let scf = ScfResult(fixture("scf"))
    expect(scf.method.hasPrefix("RHF"), "method starts with RHF (\(scf.method))")
    expect(scf.converged, "converged")
    expect(scf.cycles > 0, "cycles recorded (\(scf.cycles))")
    expect(scf.nElectrons == 10, "ten electrons")
    expect(scf.nBasis == 7, "seven basis functions (sto-3g water)")
    expect(abs(scf.energy - (-74.9627)) < 0.01, "energy near -74.96 Ha (\(scf.energy))")
    expect(scf.orbitalEnergies.count == scf.nBasis, "one energy per MO")
    expect(scf.occupations.count == scf.nBasis, "one occupation per MO")
    expect(scf.homo != nil && scf.lumo != nil, "HOMO and LUMO present")
    expect((scf.gap ?? 0) > 0, "positive HOMO-LUMO gap")
    expect(scf.mulliken.perAtom.count == 3, "three Mulliken charges")
    expect(abs(scf.mulliken.perAtom.reduce(0) { $0 + $1.charge }) < 1e-6, "Mulliken charges sum to zero")
    // Natural population analysis decodes from the same payload. The field is
    // optional on the Swift side, so a rename on either side would silently
    // drop the panel rather than fail; assert the numbers instead.
    if let npa = scf.npa {
        expect(npa.perAtom.count == 3, "three natural charges")
        expect(npa.analysisMethod == "NAO/NPA (JANPA 2.02 port)", "analysis names the method (\(npa.analysisMethod))")
        expect(npa.sumRuleOk, "occupancies sum to the electron count")
        expect(abs(npa.totalPopulation - Double(npa.nElectrons)) < 1e-6, "occupancy total matches N")
        // The fixture is sto-3g, a minimal basis, so the natural charge is much
        // smaller than the -0.95 the same molecule shows in 6-31G.  The value
        // asserted here is the published NPA result for water/STO-3G.
        expect(abs(npa.perAtom[0].charge - (-0.3996)) < 0.01, "oxygen charge matches NPA for sto-3g (\(npa.perAtom[0].charge))")
        expect(npa.perAtom[0].charge < npa.perAtom[1].charge, "oxygen is more negative than hydrogen")
        expect(npa.perAtom[0].configuration["1s"] != nil, "oxygen has a 1s shell")
        expect(npa.perAtom[0].configurationText.contains("2s"), "configuration prints shell labels (\(npa.perAtom[0].configurationText))")
        // The orbitals live on the fuller payload, not on the charge summary;
        // assert the count there so a rename of either key is caught.
        if let orbitals = scf.naturalOrbitals {
            expect(orbitals.orbitals(ofAtom: 0).count == 5, "oxygen has five NAOs (\(orbitals.orbitals(ofAtom: 0).count))")
        } else {
            expect(false, "natural orbital detail missing from the SCF payload")
        }
    } else {
        expect(false, "natural population analysis missing from the SCF payload")
    }
    // The localised orbitals are the chemistry-facing view: bonds and lone
    // pairs. The field is optional on the Swift side, so a rename would drop
    // the panel silently; assert the shape and the Lewis structure instead.
    if let localized = scf.localizedOrbitals {
        expect(localized.kind == "CLPO", "SCF defaults to CLPO (\(localized.kind))")
        expect(localized.analysisMethod == "LPO/CLPO (JANPA 2.02 port)", "localised analysis names the method (\(localized.analysisMethod))")
        expect(localized.bonds.count == 2, "water has two bonds (\(localized.bonds.count))")
        expect(localized.lonePairs.count == 3, "oxygen keeps three lone pairs (\(localized.lonePairs.count))")
        expect(localized.valences == [2, 1, 1], "valence is O=2, H=1 (\(localized.valences))")
        expect(localized.bonds.allSatisfy { abs($0.occupancy - 2.0) < 0.05 }, "each bond holds two electrons")
    } else {
        expect(false, "localised orbitals missing from the SCF payload")
    }
    expect(scf.dipole.vector.count == 3, "dipole vector is 3D")
    expect(scf.dipole.magnitude > 0.5, "water has a dipole (\(scf.dipole.magnitude) D)")
    expect(scf.wallTimeMs > 0, "wall time recorded")
    expect(scf.grid != nil, "density grid present")
    expect(scf.moCoefficients?.count == 7, "MO coefficient matrix present")

    if let grid = scf.grid {
        expect(grid.shape.count == 3, "grid shape is 3D \(grid.shape)")
        expect(grid.values.count == grid.shape.reduce(1, *), "grid values match shape")
        expect(grid.value(x: 0, y: 0, z: 0) != nil, "corner voxel readable")
        expect(grid.value(x: -1, y: 0, z: 0) == nil, "out-of-range voxel returns nil")
    }
}

print("intrinsic localization")
do {
    // Opt-in: absent unless the request asked for it.
    let plain = ScfResult(fixture("scf"))
    expect(plain.localization == nil, "the default SCF call does not compute localisation")

    let localized = ScfResult(fixture("scf_localized"))
    if let localization = localized.localization {
        expect(localization.localization == "pm-mulliken",
               "a bare request selects Pipek-Mezey (\(localization.localization))")
        expect(localization.family == "Pipek-Mezey", "family named (\(localization.family))")
        expect(localization.population == "Mulliken", "population named (\(localization.population))")
        expect(localization.orbitalCount == 5, "water has five occupied orbitals (\(localization.orbitalCount))")
        expect(localization.centroids.count == localization.orbitalCount, "one centroid per orbital")
        expect(localization.centroids.allSatisfy { $0.count == 3 }, "centroids are 3D")
        expect(localization.sweeps > 0, "sweeps recorded (\(localization.sweeps))")
        expect(localization.objective > 0, "objective recorded (\(localization.objective))")
        expect(localization.analysisMethod.contains("Multiwfn"), "method names the reference (\(localization.analysisMethod))")

        // The composition is the point of the panel: an orbital that sits on
        // one atom is a lone pair, one that sits on two is a bond.  Both must
        // appear for water, or the panel would show the same label five times.
        let centreCounts = (0..<localization.orbitalCount).map { localization.centres(ofOrbital: $0).count }
        expect(centreCounts.contains(1), "at least one one-centre orbital (\(centreCounts))")
        expect(centreCounts.contains(2), "at least one two-centre orbital (\(centreCounts))")
        expect(centreCounts.allSatisfy { $0 <= 2 }, "no orbital spans more than two centres (\(centreCounts))")

        // Every orbital's populations add up to one electron pair's worth of
        // population, which is what makes the composition readable as a share.
        for orbital in 0..<localization.orbitalCount {
            let total = (0..<localization.perAtom.count)
                .compactMap { localization.population(atom: $0, orbital: orbital) }
                .reduce(0, +)
            expect(abs(total - 1.0) < 1e-3,
                   "orbital \(orbital + 1) populations sum to 1 (\(total))")
        }
    } else {
        expect(false, "localisation missing from the payload that asked for it")
    }

    // The objective can be chosen per request.
    let boys = ScfResult(fixture("scf_boys"))
    expect(boys.localization?.localization == "boys",
           "an explicit method is honoured (\(boys.localization?.localization ?? "nil"))")
    expect(boys.localization?.family == "Foster-Boys", "Boys family named")
}

print("orbital surface")
do {
    let surface = OrbitalSurface(fixture("orbital_surface"))
    expect(surface.source == "mo", "the source is echoed (\(surface.source))")
    expect(surface.index == 4, "the requested index is echoed (\(surface.index))")
    expect(surface.label == "MO 5", "the label names the orbital (\(surface.label))")
    expect(surface.pointsPerAxis == 24, "the resolution is echoed (\(surface.pointsPerAxis))")
    expect(surface.isovalueFraction > 0 && surface.isovalueFraction < 1,
           "the isovalue fraction is a fraction (\(surface.isovalueFraction))")
    expect(abs(surface.isovalue - surface.isovalueFraction * surface.peak) < 1e-6,
           "the absolute isovalue is the fraction of the peak")

    // The picture has to be two lobes.  A single-lobe payload would still
    // render, and would still look like an orbital, so the second lobe is
    // asserted rather than inferred from the triangle count.
    expect(surface.hasGeometry, "the surface has geometry")
    expect(!surface.positive.isEmpty, "the positive lobe is present")
    expect(!surface.negative.isEmpty, "the negative lobe is present")
    expect(surface.triangleCount > 100, "the surface has a useful triangle count (\(surface.triangleCount))")

    // Every index has to address a vertex, and the triangles have to be whole.
    for (name, phase) in [("positive", surface.positive), ("negative", surface.negative)] {
        expect(phase.indices.count % 3 == 0, "\(name) triangles are whole")
        expect(phase.indices.allSatisfy { $0 >= 0 && Int($0) < phase.vertices.count },
               "\(name) indices are in range")
        expect(phase.normals.count == phase.vertices.count,
               "\(name) has one normal per vertex")
        // Normals drive the shading, so they have to be unit vectors.
        let lengths = phase.normals.map { sqrt($0.x * $0.x + $0.y * $0.y + $0.z * $0.z) }
        expect(lengths.allSatisfy { abs($0 - 1) < 0.01 },
               "\(name) normals are unit length")
    }

    // The two lobes of this orbital sit on opposite sides of the molecular
    // plane, so their centroids must differ; identical centroids would mean the
    // phases had been extracted from the same field.
    func centroid(_ phase: OrbitalPhase) -> SIMD3<Float> {
        guard !phase.vertices.isEmpty else { return SIMD3<Float>(0, 0, 0) }
        var total = SIMD3<Float>(0, 0, 0)
        for vertex in phase.vertices { total += vertex }
        return total / Float(phase.vertices.count)
    }
    func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = a - b
        return sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
    }
    let separation = distance(centroid(surface.positive), centroid(surface.negative))
    expect(separation > 0.2, "the two lobes are spatially separated (\(separation))")

    // The mesh builder centres on the molecule and must keep every vertex
    // usable; a shift applied twice or not at all still renders, just offset.
    if let mesh = OrbitalMesh(phase: surface.positive, centredOn: [0, 0, 0]) {
        expect(mesh.vertexCount == surface.positive.vertices.count, "the mesh keeps every vertex")
        expect(mesh.triangleCount == surface.positive.triangleCount, "the mesh keeps every triangle")
        expect(mesh.vertexData.count == mesh.vertexCount * 6, "six floats per vertex")
        expect(mesh.boundingRadius > 0, "the bounding radius is positive (\(mesh.boundingRadius))")
    } else {
        expect(false, "the mesh builder accepts the fixture")
    }

    // Centring is a pure translation: every vertex moves by exactly the centre,
    // and the bounding radius is the furthest vertex from the origin in the
    // shifted frame, so it is recomputed here rather than assumed invariant.
    let shifted = OrbitalMeshPair(surface: surface, centreOfMass: [1, 2, 3])
    let unshifted = OrbitalMeshPair(surface: surface, centreOfMass: [0, 0, 0])
    expect(shifted.isEmpty == false, "the pair has geometry")
    if let a = shifted.positive, let b = unshifted.positive {
        expect(a.vertexData[0] == b.vertexData[0] - 1, "centring shifts x by the centre")
        expect(a.vertexData[1] == b.vertexData[1] - 2, "centring shifts y by the centre")
        expect(a.vertexData[2] == b.vertexData[2] - 3, "centring shifts z by the centre")

        // The radius has to be measured in the same frame as the stored
        // vertices; a radius kept in the unshifted frame would under-frame a
        // molecule whose centre of mass is not the origin.
        var furthest = 0.0
        var index = 0
        while index < a.vertexData.count {
            let x = Double(a.vertexData[index])
            let y = Double(a.vertexData[index + 1])
            let z = Double(a.vertexData[index + 2])
            furthest = max(furthest, (x * x + y * y + z * z).squareRoot())
            index += 6
        }
        expect(abs(a.boundingRadius - furthest) < 1e-6,
               "the bounding radius is the furthest shifted vertex (\(a.boundingRadius) vs \(furthest))")
    }

    // A localised orbital is single-signed: it is a bond or a lone pair, so its
    // second lobe may legitimately be empty while the first is not.
    let localised = OrbitalSurface(fixture("orbital_surface_lmo"))
    expect(localised.source == "pm-mulliken", "the localisation method is echoed (\(localised.source))")
    expect(localised.label == "LMO 1", "the label marks a localised orbital (\(localised.label))")
    expect(abs(localised.occupation - 2.0) < 1e-6,
           "a localised occupied orbital holds a pair (\(localised.occupation))")
    expect(localised.hasGeometry, "the localised orbital has geometry")
    expect(localised.positive.isEmpty != localised.negative.isEmpty,
           "exactly one lobe carries the localised orbital")
}

print("ccsd")
do {
    let ccsd = ScfResult(fixture("ccsd"))
    expect(ccsd.method.contains("CCSD"), "method mentions CCSD (\(ccsd.method))")
    expect(ccsd.energy < -74.9, "CCSD energy is a total energy (\(ccsd.energy))")
    expect(ccsd.correlationEnergy != nil, "correlation energy present")
    expect(ccsd.scfEnergy != nil, "SCF reference energy present")
    if let correlation = ccsd.correlationEnergy, let scf = ccsd.scfEnergy {
        expect(abs((scf + correlation) - ccsd.energy) < 1e-6, "E_scf + E_corr == E_total")
    }
}

print("dft")
do {
    let dft = ScfResult(fixture("dft"))
    expect(dft.method.hasPrefix("RKS"), "method starts with RKS (\(dft.method))")
    expect(dft.converged, "converged")
    expect(dft.nBasis == 7, "seven basis functions")
    // B3LYP is variationally above Hartree-Fock but far below the bare nuclei.
    expect(dft.energy < -74.9 && dft.energy > -76.0, "B3LYP energy is physical (\(dft.energy))")
    expect(dft.mulliken.perAtom.count == 3, "three Mulliken charges")
}

print("mp2")
do {
    let mp2 = ScfResult(fixture("mp2"))
    expect(mp2.method.contains("MP2"), "method mentions MP2 (\(mp2.method))")
    expect(mp2.correlationEnergy != nil, "correlation energy present")
    if let correlation = mp2.correlationEnergy {
        // MP2 recovers correlation, so it must sit below the SCF reference.
        expect(correlation < 0, "MP2 correlation energy is negative (\(correlation))")
    }
}

print("bond_scan")
do {
    let scan = BondScanResult(fixture("bond_scan"))
    expect(scan.points.count == 5, "five scan points (\(scan.points.count))")
    expect(scan.points.allSatisfy { $0.r > 0 }, "every point has a distance")
    expect(scan.points.contains { $0.energy != nil }, "at least one converged energy")
    expect(scan.minimumR != nil && scan.minimumEnergy != nil, "minimum located")
    expect(scan.label.contains("O"), "scan label names the bond (\(scan.label))")
}

print("optimise with density fitting")
do {
    // Forced on for a molecule below the automatic threshold.  The override has
    // to survive the request and the relaxation still has to converge on the
    // same surface, so the gradient threshold is the check that matters.
    let fitted = OptimisationResult(fixture("optimise_df"))
    expect(fitted.converged, "density-fitted relaxation converged")
    expect(fitted.maxGradient < fitted.convTolGrad * 10,
           "density-fitted gradient reached the threshold (\(fitted.maxGradient))")
    expect(fitted.optimisedAtoms.contains("O"), "optimised geometry reported")
}

print("optimise with density fitting explicitly off")
do {
    // ``false`` has to be carried through as a decision rather than dropped and
    // read as "unset".  The two runs sit on different surfaces -- that offset is
    // the point of offering the choice -- so the energies must differ.
    let exact = OptimisationResult(fixture("optimise_no_df"))
    let fitted = OptimisationResult(fixture("optimise_df"))
    expect(exact.converged, "exact-integral relaxation converged")
    expect(abs(exact.energy - fitted.energy) > 1e-6,
           "explicitly-off run differs from the fitted one "
           + "(\(exact.energy) vs \(fitted.energy))")
    expect(exact.maxGradient < exact.convTolGrad * 10,
           "exact gradient reached the threshold (\(exact.maxGradient))")
}

print("optimise")
do {
    let optimisation = OptimisationResult(fixture("optimise"))
    expect(optimisation.method.hasPrefix("RKS"), "method names the reference (\(optimisation.method))")
    expect(optimisation.functional == "b3lyp", "functional reported (\(optimisation.functional ?? "nil"))")
    expect(optimisation.converged, "relaxation converged")
    expect(optimisation.steps > 0, "at least one relaxation step (\(optimisation.steps))")
    expect(optimisation.maxGradient < optimisation.convTolGrad * 10,
           "gradient reached the threshold (\(optimisation.maxGradient))")
    expect(optimisation.trajectory.count == optimisation.steps + 1,
           "trajectory covers every step (\(optimisation.trajectory.count))")

    // The energy must drop along the trajectory, which is what makes the
    // reported minimum believable.
    let energies = optimisation.trajectory.map(\.energy)
    expect(energies == energies.sorted(by: >), "energy decreases monotonically")

    // The copy button ships `coordinates`; it must be the optimised structure
    // in the same "Sym x y z; ..." form the builder's atom field accepts.
    let coordinates = optimisation.coordinates
    expect(!coordinates.isEmpty, "coordinates are present")
    expect(coordinates.contains("O") && coordinates.contains("H"), "coordinates name the atoms")
    let rows = coordinates.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
    expect(rows.count == 3, "three coordinate rows (\(rows.count))")
    expect(rows.allSatisfy { $0.split(separator: " ").count == 4 },
           "each row is 'Sym x y z'")
    // Water must have relaxed from 1.30 A towards ~1.03 A.
    if rows.count == 3 {
        let oxygen = rows[0].split(separator: " ").dropFirst().compactMap { Double($0) }
        let hydrogen = rows[1].split(separator: " ").dropFirst().compactMap { Double($0) }
        if oxygen.count == 3 && hydrogen.count == 3 {
            let dx = oxygen[0] - hydrogen[0]
            let dy = oxygen[1] - hydrogen[1]
            let dz = oxygen[2] - hydrogen[2]
            let bond = (dx * dx + dy * dy + dz * dz).squareRoot()
            expect(bond > 0.90 && bond < 1.15, "O-H relaxed to a physical length (\(bond))")
        } else {
            expect(false, "coordinate rows are numeric")
        }
    }

    // The panel also shows the geometry block and the engine log.
    expect(optimisation.geometry.bonds.count == 2, "two bonds reported")
    expect(optimisation.geometry.angles.count == 1, "one valence angle reported")

    // The cheap relaxation grid is reported alongside the production grid, so
    // the UI can say which numbers came from where.
    expect(optimisation.gridLevel != nil, "production grid level reported (\(optimisation.gridLevel.map(String.init) ?? "nil"))")
    expect(optimisation.relaxGridLevel != nil, "relaxation grid level reported (\(optimisation.relaxGridLevel.map(String.init) ?? "nil"))")
    if let production = optimisation.gridLevel, let relax = optimisation.relaxGridLevel {
        expect(relax <= production, "relaxation grid is not finer than the production grid (\(relax) <= \(production))")
    }
}

print("error envelope")
do {
    guard let errorJSON = rawFixture("error") else {
        expect(false, "could not load error fixture")
        exit(1)
    }
    do {
        _ = try RPCResponse.decode(errorJSON)
        expect(false, "error response should throw")
    } catch let error as RPCError {
        if case .engine(let code, let message, let detail) = error {
            expect(code < 0, "error code is negative (\(code))")
            expect(!message.isEmpty, "error message present (\(message))")
            // The engine sends `data` as an object with a traceback, so the
            // detail must survive rather than being dropped by a String cast.
            expect(detail?.isEmpty == false, "error detail present")
        } else {
            expect(false, "unexpected RPCError case")
        }
    } catch {
        expect(false, "unexpected error type")
    }
}

print("error detail from a missing field")
do {
    // An error whose data is an object, as raised when the interpreter fails to
    // boot. The detail must reach the caller or the failure is invisible.
    let json = """
    {"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"engine unavailable",\
    "data":{"kind":"unavailable","traceback":"Traceback (most recent call last): ..."}}}
    """
    do {
        _ = try RPCResponse.decode(json)
        expect(false, "object-data error should throw")
    } catch let error as RPCError {
        if case .engine(_, let message, let detail) = error {
            expect(message == "engine unavailable", "message preserved")
            expect(detail?.contains("Traceback") == true, "traceback preserved in detail")
        } else {
            expect(false, "unexpected RPCError case")
        }
    } catch {
        expect(false, "unexpected error type")
    }
}

print("")
print(failures == 0 ? "\(checks)/\(checks) checks passed" : "\(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)
