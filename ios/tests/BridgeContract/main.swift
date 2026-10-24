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
func fixture(_ name: String) -> JSONObject {
    guard let raw = rawFixture(name),
          let data = raw.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let result = parsed["result"] as? [String: Any]
    else {
        print("  FAIL could not load fixture '\(name)'")
        failures += 1
        checks += 1
        return JSONObject([:])
    }
    return JSONObject(result)
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
        if case .engine(let code, let message, _) = error {
            expect(code < 0, "error code is negative (\(code))")
            expect(!message.isEmpty, "error message present (\(message))")
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
