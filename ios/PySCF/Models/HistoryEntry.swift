// HistoryEntry.swift
//
// One saved calculation, as it is stored on disk and listed in the History
// screen.
//
// Foundation only, and no reference to AppModel: the host test compiles this
// file against the plain Linux Swift toolchain to check the round trip and the
// report rendering, and neither SwiftUI nor the app's state exists there.

import Foundation

/// What kind of calculation produced an entry.
///
/// Deliberately its own type rather than a reuse of ``CalculationKind``: a
/// history entry outlives the code that wrote it, and a case removed from the
/// picker must not make old entries unreadable. An unknown ``rawValue`` decodes
/// to ``.other`` instead of failing the whole record.
enum HistoryKind: String, CaseIterable, Identifiable {
    case scf = "SCF"
    case dft = "DFT"
    case optimise = "OPT"
    case mp2 = "MP2"
    case ccsd = "CCSD"
    case scan = "SCAN"
    /// A 3D orbital surface that was drawn.  Not a calculation: the entry
    /// records which orbital was viewed, and the detail view rebuilds the
    /// surface through the engine.
    case orbitals = "ORB"
    /// A 3D electron-density cloud that was drawn, recorded the same way.
    case density = "DEN"
    case other = "OTHER"

    var id: String { rawValue }

    init(stored: String) {
        self = HistoryKind(rawValue: stored) ?? .other
    }

    /// Whether the entry records a view rather than a calculation.
    ///
    /// A view entry carries no energy of its own and its payload describes what
    /// was drawn; the detail view rebuilds it instead of rendering result
    /// panels from it.
    var isView: Bool {
        switch self {
        case .orbitals, .density: return true
        default: return false
        }
    }
}

/// One saved calculation.
///
/// The decoded result is not stored: ``payload`` holds the engine's own JSON, so
/// the file stays readable by anything that understands the bridge protocol, and
/// a field added to the engine does not need a migration here. The model types
/// are rebuilt from it on demand.
struct HistoryEntry: Identifiable, Equatable {

    /// Identity and file name. Assigned once and never reused.
    let id: String

    /// When the calculation finished, in local time.
    var date: Date

    var kind: HistoryKind

    /// Method label as the engine reported it, e.g. ``RHF`` or ``RKS``.
    var method: String

    var basis: String

    /// Functional for a Kohn-Sham run, nil otherwise.
    var functional: String?

    /// The molecule, in the builder's own atom notation, so the entry can be
    /// loaded back into the editor.
    var atoms: String

    var charge: Int
    var spin: Int

    /// Headline energy in Hartree. For a relaxation this is the final energy.
    var energy: Double

    var converged: Bool

    /// Wall-clock time the engine reported.
    var wallTimeMs: Double

    /// One-line summary shown in the list, e.g. ``converged in 8 cycles``.
    var summary: String

    /// The engine's result object, verbatim.
    var payload: JSONObject

    init(id: String = UUID().uuidString,
         date: Date = Date(),
         kind: HistoryKind,
         method: String,
         basis: String,
         functional: String? = nil,
         atoms: String,
         charge: Int = 0,
         spin: Int = 0,
         energy: Double,
         converged: Bool,
         wallTimeMs: Double,
         summary: String,
         payload: JSONObject) {
        self.id = id
        self.date = date
        self.kind = kind
        self.method = method
        self.basis = basis
        self.functional = functional
        self.atoms = atoms
        self.charge = charge
        self.spin = spin
        self.energy = energy
        self.converged = converged
        self.wallTimeMs = wallTimeMs
        self.summary = summary
        self.payload = payload
    }

    /// Identity used by `ForEach`. Kept separate from ``id`` so the stored file
    /// name is free to change format without touching the view layer.
    static func == (lhs: HistoryEntry, rhs: HistoryEntry) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - Coding

    /// Field names as they appear in the JSON file. Kept short and explicit so
    /// the file can be read by hand.
    private enum Key {
        static let id = "id"
        static let date = "date"
        static let kind = "kind"
        static let method = "method"
        static let basis = "basis"
        static let functional = "functional"
        static let atoms = "atoms"
        static let charge = "charge"
        static let spin = "spin"
        static let energy = "energy"
        static let converged = "converged"
        static let wallTimeMs = "wallTimeMs"
        static let summary = "summary"
        static let payload = "payload"
    }

    init?(json: [String: Any]) {
        guard let id = json[Key.id] as? String,
              let kind = json[Key.kind] as? String,
              let method = json[Key.method] as? String,
              let basis = json[Key.basis] as? String,
              let atoms = json[Key.atoms] as? String,
              let payload = json[Key.payload] as? [String: Any]
        else { return nil }

        // A missing date would make the entry sort to 1970 and read as a bug in
        // the list rather than as a damaged record, so treat it as required too.
        guard let seconds = (json[Key.date] as? NSNumber)?.doubleValue else { return nil }

        self.id = id
        self.date = Date(timeIntervalSince1970: seconds)
        self.kind = HistoryKind(stored: kind)
        self.method = method
        self.basis = basis
        self.functional = json[Key.functional] as? String
        self.atoms = atoms
        self.charge = (json[Key.charge] as? NSNumber)?.intValue ?? 0
        self.spin = (json[Key.spin] as? NSNumber)?.intValue ?? 0
        self.energy = (json[Key.energy] as? NSNumber)?.doubleValue ?? 0
        self.converged = json[Key.converged] as? Bool ?? false
        self.wallTimeMs = (json[Key.wallTimeMs] as? NSNumber)?.doubleValue ?? 0
        self.summary = json[Key.summary] as? String ?? ""
        self.payload = JSONObject(payload)
    }

    /// The record as it is written to disk.
    func encoded() -> [String: Any] {
        var json: [String: Any] = [
            Key.id: id,
            Key.date: date.timeIntervalSince1970,
            Key.kind: kind.rawValue,
            Key.method: method,
            Key.basis: basis,
            Key.atoms: atoms,
            Key.charge: charge,
            Key.spin: spin,
            Key.energy: energy,
            Key.converged: converged,
            Key.wallTimeMs: wallTimeMs,
            Key.summary: summary,
            Key.payload: payload.raw,
        ]
        if let functional = functional { json[Key.functional] = functional }
        return json
    }

    // MARK: - Display

    /// The molecule as a Hill-order formula, for the list subtitle.
    ///
    /// Parsed from ``atoms`` rather than stored, so an entry written before a
    /// formula helper existed still shows one.
    var formula: String {
        AtomSpec.formula(atoms)
    }

    /// Title line, e.g. ``RHF/sto-3g`` or ``RKS/def2-tzvp (b3lyp)``.
    ///
    /// A view entry records what was drawn rather than a calculation, so its
    /// title leads with that and then the reference it was built on: ``MO 5
    /// (RHF/sto-3g)`` reads as "the fifth orbital, from this run", which is what
    /// the entry is.
    var title: String {
        var text = "\(method)/\(basis)"
        if let functional = functional, !functional.isEmpty {
            text += " (\(functional))"
        }
        if kind.isView {
            text = "\(method) — \(text)"
        }
        return text
    }
}
