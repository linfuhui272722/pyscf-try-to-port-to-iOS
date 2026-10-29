// HistoryTests.swift
//
// Host-side checks for the saved-calculation store and its text export.
//
// These exist because both failures are silent on a device. A store that drops
// a field on the way to disk still lists entries and still shows energies, and
// an export that renders an empty section still produces a file -- the user
// only finds out when the number they wanted is missing. So the checks drive a
// real entry through a real directory and read the file back, rather than
// asserting on the encoder in isolation.
//
// Runs with the plain Linux Swift toolchain, since the store and the report are
// Foundation only:
//   swiftc HistoryTests.swift PySCFModels.swift Formatting.swift AtomSpec.swift \
//          HistoryEntry.swift HistoryStore.swift HistoryReport.swift -o history

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

// A scratch directory per run, removed at the end.
let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pyscf-history-tests-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: scratch) }

// MARK: - Atom spec parsing

print("atom spec parsing")
do {
    expect(AtomSpec.formula("O 0 0 0; H 0 0 0.96; H 0 0.9 -0.3") == "H2O",
           "water parses to H2O")
    expect(AtomSpec.formula("C 0 0 0; H 0 0 1.09; H 1.02 0 -0.36; H -0.51 0.88 -0.36; H -0.51 -0.88 -0.36")
           == "CH4", "methane parses to CH4")

    // Hill order: carbon, then hydrogen, then the rest alphabetically.
    let ethanol = "C 0 0 0; C 1.5 0 0; O 2.0 1.0 0; H 0 0 1; H 0 1 0; H 0 -1 0; "
        + "H 2 0 1; H 3 0 0; H 2.5 -0.5 0"
    expect(AtomSpec.formula(ethanol) == "C2H6O", "ethanol parses to C2H6O in Hill order")

    // Newlines and commas are both accepted, as the engine accepts them.
    expect(AtomSpec.parse("O 0 0 0\nH 0 0,0.96").count == 2,
           "newlines and commas separate atoms")

    // A spec the user is still typing must not crash or produce a wrong count.
    expect(AtomSpec.parse("O 0 0").isEmpty, "an incomplete line is skipped")
    expect(AtomSpec.parse("").isEmpty, "an empty spec has no atoms")
    expect(AtomSpec.formula("") == "", "an empty spec has no formula")
    expect(AtomSpec.parse("# comment\nO 0 0 0").count == 1, "a comment line is skipped")

    // Lowercase input is accepted by the engine, so the display normalises it.
    expect(AtomSpec.formula("o 0 0 0; h 0 0 0.96; h 0 0.9 -0.3") == "H2O",
           "lowercase symbols normalise")
}

// MARK: - Stripping the payload

print("payload stripping")
do {
    let scf = fixture("scf")
    let stripped = HistoryStore.stripped(scf)
    expect(stripped.raw["grid"] == nil, "the density cube is dropped")
    expect(stripped.raw["moCoefficients"] == nil, "the MO coefficients are dropped")
    expect(stripped.raw["energy"] != nil, "the energy survives")
    expect(stripped.raw["orbitalEnergies"] != nil, "the orbital ladder survives")
    expect(stripped.raw["mulliken"] != nil, "the Mulliken analysis survives")

    // The whole point of stripping is the size: a saved entry must not carry
    // the cube, which is the bulk of the payload at every basis size.
    let full = (try? JSONSerialization.data(withJSONObject: scf.raw))?.count ?? 0
    let slim = (try? JSONSerialization.data(withJSONObject: stripped.raw))?.count ?? 0
    expect(slim < full, "the stripped payload is smaller (\(slim) < \(full) bytes)")
    expect(HistoryStore.droppedKeys(in: scf).sorted() == ["grid", "moCoefficients"],
           "both bulky keys are reported as dropped")
    expect(HistoryStore.droppedKeys(in: JSONObject(["energy": 1])).isEmpty,
           "nothing is reported dropped when nothing is present")

    // Stripping must not mutate the caller's payload: the live result is still
    // on screen and the Density tab still reads its cube.
    expect(scf.raw["grid"] != nil, "the original payload is untouched")
}

// MARK: - Store round trip

print("history store round trip")
do {
    let store = HistoryStore(directory: scratch)
    expect(store.load().isEmpty, "a fresh store is empty")

    let scf = fixture("scf")
    let entry = HistoryEntry(
        id: "scf-1",
        date: Date(timeIntervalSince1970: 1_700_000_000),
        kind: .scf,
        method: "RHF",
        basis: "6-31g",
        atoms: "O 0 0 0; H 0 0 0.96; H 0 0.9 -0.3",
        energy: -75.123456789,
        converged: true,
        wallTimeMs: 1234,
        summary: "converged in 8 cycles",
        payload: HistoryStore.stripped(scf))

    let afterAdd = store.add(entry)
    expect(afterAdd.count == 1, "the entry is listed after adding")
    expect(FileManager.default.fileExists(
        atPath: scratch.appendingPathComponent("scf-1.json").path),
        "one file per entry, named by id")

    // Reload from disk through a second store, so nothing is served from the
    // first instance's memory.
    let reloaded = HistoryStore(directory: scratch).load()
    expect(reloaded.count == 1, "the entry survives a reload")
    guard let loaded = reloaded.first else {
        print("  FAIL no entry to inspect")
        exit(1)
    }
    expect(loaded.id == "scf-1", "id round trips")
    expect(loaded.kind == .scf, "kind round trips")
    expect(loaded.method == "RHF", "method round trips")
    expect(loaded.basis == "6-31g", "basis round trips")
    expect(abs(loaded.energy - (-75.123456789)) < 1e-9, "the energy keeps its precision")
    expect(loaded.converged, "the convergence flag round trips")
    expect(loaded.atoms == entry.atoms, "the molecule round trips")
    expect(abs(loaded.date.timeIntervalSince1970 - 1_700_000_000) < 1,
           "the timestamp round trips")
    expect(loaded.formula == "H2O", "the formula is derived from the stored molecule")

    // The payload is the engine's own JSON, so the model layer must be able to
    // rebuild the result from it after a reload.
    let rebuilt = ScfResult(loaded.payload)
    expect(abs(rebuilt.energy - ScfResult(scf).energy) < 1e-12,
           "the result rebuilds from the stored payload")
    expect(rebuilt.nBasis == ScfResult(scf).nBasis, "the rebuilt result keeps its basis size")
}

// MARK: - Ordering, deletion and the cap

print("history ordering and deletion")
do {
    let store = HistoryStore(directory: scratch)
    // Strictly newer than the entry written above, so "oldest" is unambiguous.
    // Equal timestamps would make the order depend on the directory listing.
    for index in 0..<3 {
        let entry = HistoryEntry(
            id: "ordered-\(index)",
            date: Date(timeIntervalSince1970: 1_700_000_100 + Double(index)),
            kind: .scf, method: "RHF", basis: "sto-3g", atoms: "O 0 0 0",
            energy: Double(index), converged: true, wallTimeMs: 1,
            summary: "", payload: JSONObject([:]))
        store.add(entry)
    }
    let all = store.load()
    expect(all.count == 4, "all entries are listed (\(all.count))")
    expect(all.first?.id == "ordered-2", "newest is first")
    expect(all.last?.id == "scf-1", "oldest is last")

    store.remove("ordered-1")
    let afterRemove = store.load()
    expect(afterRemove.count == 3, "the deleted entry is gone (\(afterRemove.count))")
    expect(!afterRemove.contains { $0.id == "ordered-1" }, "the right entry was deleted")
    expect(afterRemove.contains { $0.id == "scf-1" }, "the others are untouched")

    // Deleting something already gone must not throw or remove a neighbour.
    store.remove("ordered-1")
    expect(store.load().count == 3, "deleting a missing entry is harmless")

    expect(store.removeAll().isEmpty, "removeAll returns an empty history")
    expect(store.load().isEmpty, "removeAll clears the directory")
}

print("history cap")
do {
    let capDirectory = scratch.appendingPathComponent("cap")
    let store = HistoryStore(directory: capDirectory)
    let total = HistoryStore.maximumEntries + 5
    var listed: [HistoryEntry] = []
    for index in 0..<total {
        let entry = HistoryEntry(
            id: "cap-\(index)",
            date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
            kind: .scf, method: "RHF", basis: "sto-3g", atoms: "O 0 0 0",
            energy: 0, converged: true, wallTimeMs: 1,
            summary: "", payload: JSONObject([:]))
        listed = store.add(entry)
    }
    expect(listed.count == HistoryStore.maximumEntries,
           "the list is capped at \(HistoryStore.maximumEntries) (\(listed.count))")
    expect(listed.first?.id == "cap-\(total - 1)", "the newest entry is kept")
    expect(!listed.contains { $0.id == "cap-0" }, "the oldest entry is evicted")
    // Eviction must remove the file, not only hide it from the list.
    let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: capDirectory.path)) ?? []
    expect(onDisk.count == HistoryStore.maximumEntries,
           "evicted entries are deleted from disk (\(onDisk.count) files)")
}

// MARK: - Corrupt records

print("corrupt records")
do {
    let corrupt = scratch.appendingPathComponent("corrupt")
    try? FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)

    // A truncated file, a valid JSON object missing required fields, and a
    // non-object. None may take the whole history down.
    try? Data("{ not json".utf8).write(to: corrupt.appendingPathComponent("broken.json"))
    try? Data("{\"id\": \"x\"}".utf8).write(to: corrupt.appendingPathComponent("partial.json"))
    try? Data("[1, 2, 3]".utf8).write(to: corrupt.appendingPathComponent("array.json"))
    try? Data("not json at all".utf8).write(to: corrupt.appendingPathComponent("garbage.txt"))

    let store = HistoryStore(directory: corrupt)
    let good = HistoryEntry(
        id: "good", date: Date(), kind: .scf, method: "RHF", basis: "sto-3g",
        atoms: "O 0 0 0", energy: -1, converged: true, wallTimeMs: 1,
        summary: "", payload: JSONObject([:]))
    store.add(good)

    let loaded = store.load()
    expect(loaded.count == 1, "only the readable entry is listed (\(loaded.count))")
    expect(loaded.first?.id == "good", "the readable entry is the one loaded")
    // The damaged files are left alone so the user can inspect them.
    let remaining = (try? FileManager.default.contentsOfDirectory(atPath: corrupt.path)) ?? []
    expect(remaining.contains("broken.json"), "a damaged file is left on disk")
    expect(remaining.contains("partial.json"), "a partial record is left on disk")
}

// MARK: - Unknown kinds

print("forward compatibility")
do {
    let future = HistoryEntry(json: [
        "id": "future",
        "date": 1_700_000_000.0,
        "kind": "SOMETHING_NEW",
        "method": "X",
        "basis": "y",
        "atoms": "O 0 0 0",
        "energy": 1.0,
        "payload": [:],
    ])
    expect(future != nil, "a record with an unknown kind still decodes")
    expect(future?.kind == .other, "an unknown kind becomes .other")
    expect(future?.title == "X/y", "the title still renders")
}

// MARK: - Text export

print("text export")
do {
    let scf = HistoryStore.stripped(fixture("scf"))
    // The report renders the payload, which is the engine's own record, so the
    // energy it must show is the payload's and not a hand-written number.
    let authoritative = ScfResult(scf).energy
    let entry = HistoryEntry(
        id: "report-1",
        date: Date(timeIntervalSince1970: 1_700_000_000),
        kind: .scf, method: "RHF", basis: "6-31g",
        atoms: "O 0 0 0; H 0 0 0.96; H 0 0.9 -0.3",
        energy: authoritative, converged: true, wallTimeMs: 1234,
        summary: "converged in 8 cycles", payload: scf)
    let text = HistoryReport.text(for: entry)

    expect(text.contains("RHF/6-31g"), "the report names the method")
    expect(text.contains("H2O"), "the report names the molecule")
    expect(text.contains(String(format: "%.8f", authoritative)),
           "the report carries the energy (\(authoritative))")
    expect(text.contains("Orbital energies"), "the orbital section is present")
    expect(text.contains("Mulliken"), "the charge section is present")
    expect(text.contains("PySCF mobile"), "the report is headed")
    expect(text.hasSuffix("\n"), "the report ends with a newline")

    // The orbital ladder has to survive into the file: it is the reason to
    // export a single-point run at all.
    let result = ScfResult(fixture("scf"))
    if let homo = result.homo {
        expect(text.contains(String(format: "%.6f", homo)),
               "the HOMO energy is in the report")
    }
    expect(text.contains("\(result.nBasis)"), "the basis size is in the report")

    // A report must never contain the stripped bulk.
    expect(!text.contains("\"values\""), "the report carries no raw density cube")
}

print("text export of intrinsic localization")
do {
    // The localisation section is driven by an opt-in field, so a report built
    // from a run that did not request it must simply omit the section rather
    // than print an empty one.
    let plain = HistoryReport.text(for: HistoryEntry(
        id: "report-plain", date: Date(), kind: .scf, method: "RHF", basis: "6-31g",
        atoms: "O 0 0 0", energy: -75.0, converged: true, wallTimeMs: 0,
        summary: "", payload: HistoryStore.stripped(fixture("scf"))))
    expect(!plain.contains("Localized orbitals (intrinsic"),
           "a run without localisation omits the section")

    let payload = HistoryStore.stripped(fixture("scf_localized"))
    let result = ScfResult(payload)
    let text = HistoryReport.text(for: HistoryEntry(
        id: "report-loc", date: Date(), kind: .scf, method: "RHF", basis: "6-31g",
        atoms: "O 0 0 0; H 0 0 0.96; H 0 0.9 -0.3",
        energy: result.energy, converged: true, wallTimeMs: 0,
        summary: "", payload: payload))

    if let localization = result.localization {
        expect(text.contains("Localized orbitals (intrinsic, \(localization.localization))"),
               "the section names the method")
        expect(text.contains(String(format: "%.8f", localization.objective)),
               "the objective is in the report (\(localization.objective))")
        // Every orbital gets a line, so a molecule's localised set is fully
        // described rather than truncated at the first few.
        expect((0..<localization.orbitalCount).allSatisfy { text.contains("LMO \($0 + 1)") },
               "every orbital has a line")
    } else {
        expect(false, "the localised fixture carried no localisation")
    }
}

print("the list energy agrees with the payload")
do {
    // The list shows the cached energy and the report shows the payload's. A
    // record built from a result must have them agree, or the two views would
    // quote different numbers for the same run.
    let scf = fixture("scf")
    let cached = ScfResult(scf).energy
    let entry = HistoryEntry(
        id: "agree", date: Date(), kind: .scf, method: "RHF", basis: "6-31g",
        atoms: "O 0 0 0", energy: cached, converged: true, wallTimeMs: 0,
        summary: "", payload: HistoryStore.stripped(scf))
    expect(abs(entry.energy - ScfResult(entry.payload).energy) < 1e-12,
           "the cached energy matches the stored payload")
}

print("text export of an optimisation")
do {
    let payload = HistoryStore.stripped(fixture("optimise_df"))
    let entry = HistoryEntry(
        id: "report-opt", date: Date(), kind: .optimise, method: "RHF", basis: "6-31g",
        atoms: "O 0 0 0; H 0 0 1.3; H 0 1.1 -0.3",
        energy: -75.5, converged: true, wallTimeMs: 2000, summary: "", payload: payload)
    let text = HistoryReport.text(for: entry)

    expect(text.contains("Relaxation"), "the relaxation section is present")
    expect(text.contains("Initial geometry"), "the starting geometry is in the report")
    expect(text.contains("Optimised geometry"), "the final geometry is in the report")
    expect(text.contains("Max gradient"), "the gradient is in the report")

    // The optimised coordinates are the deliverable of a relaxation, so they
    // must appear as coordinates and not only in the summary line.
    let result = OptimisationResult(fixture("optimise_df"))
    let firstLine = result.optimisedAtoms
        .split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces)
    if let firstLine = firstLine {
        expect(text.contains(firstLine), "the first optimised atom is in the report")
    }
}

print("text export of an empty history")
do {
    expect(HistoryReport.text(for: [HistoryEntry]()).isEmpty,
           "an empty history exports nothing rather than an empty header")
}

print("export file names")
do {
    let entry = HistoryEntry(
        id: "name-1",
        date: Date(timeIntervalSince1970: 1_700_000_000),
        kind: .scf, method: "RHF", basis: "6-31g",
        atoms: "O 0 0 0; H 0 0 0.96; H 0 0.9 -0.3", energy: 0, converged: true,
        wallTimeMs: 0, summary: "", payload: JSONObject([:]))
    let name = HistoryReport.fileName(for: entry)
    expect(name.hasSuffix(".txt"), "the name ends in .txt")
    expect(name.contains("RHF"), "the name says the method")
    expect(name.contains("H2O"), "the name says the molecule")
    // A slash in a method or basis would produce a path rather than a name.
    expect(!name.contains("/"), "the name carries no path separator")
    expect(HistoryReport.fileName(count: 3).hasSuffix(".txt"),
           "a bundled name ends in .txt")
}

print("")
if failures == 0 {
    print("\(checks)/\(checks) checks passed")
    exit(0)
} else {
    print("\(checks - failures)/\(checks) checks passed, \(failures) FAILED")
    exit(1)
}
