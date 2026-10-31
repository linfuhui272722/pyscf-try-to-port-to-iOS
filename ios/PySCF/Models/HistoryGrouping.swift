// HistoryGrouping.swift
//
// Groups saved calculations by the molecule they were run on.
//
// The history list used to be one flat run of entries, newest first, so the
// orbital view of a molecule and the density view of the same molecule landed
// wherever their timestamps put them -- often far apart, with unrelated runs
// between them.  Grouping by molecule keeps everything about one molecule
// together: the calculations, and the 3D pictures drawn from them.
//
// Foundation only, and no reference to SwiftUI: the host test compiles this file
// to check the grouping and the identity rule, and a wrong key is silent on a
// device -- the entries still list, just in the wrong groups.
import Foundation
/// Entries belonging to one molecule, newest first.
struct HistoryGroup: Identifiable {
    /// The molecule's identity: its atoms, charge and spin.
    let key: String
    /// What the group is called in the list.
    let title: String
    let entries: [HistoryEntry]
    var id: String { key }
    /// The newest entry's date, which is what orders the groups.
    var date: Date { entries.first?.date ?? Date.distantPast }
}
enum HistoryGrouping {
    /// The identity of the molecule an entry was run on.
    ///
    /// Built from the *parsed* atoms rather than the raw text, so two entries
    /// that describe the same molecule in different whitespace, separators or
    /// number formatting group together.  Charge and spin are part of the
    /// identity: the same atoms at a different charge are a different species,
    /// and their results should not be mixed.
    ///
    /// A spec that does not parse falls back to the raw text, so an entry is
    /// always in some group -- never dropped, never merged with an unrelated one
    /// by a key that came out empty.
    static func key(for entry: HistoryEntry) -> String {
        let atoms = AtomSpec.parse(entry.atoms)
        let body: String
        if atoms.isEmpty {
            body = entry.atoms.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            body = atoms
                .map { "\($0.symbol) \(String(format: "%.4f", $0.x)) "
                     + "\(String(format: "%.4f", $0.y)) \(String(format: "%.4f", $0.z))" }
                .joined(separator: "; ")
        }
        return "\(body)|\(entry.charge)|\(entry.spin)"
    }
    /// Groups entries by molecule, most recently used first.
    ///
    /// The entries inside a group are sorted newest first, and the groups
    /// themselves by their newest member, so the result depends only on *which*
    /// entries are passed rather than on the order they arrive in.  That matters
    /// because the caller's order is an implementation detail of the store, and
    /// a grouping that silently depended on it would break the moment the store
    /// changed.  Ties fall back to the id so the order is deterministic.
    static func groups(_ entries: [HistoryEntry]) -> [HistoryGroup] {
        var order: [String] = []
        var buckets: [String: [HistoryEntry]] = [:]
        for entry in entries {
            let key = key(for: entry)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(entry)
        }
        return order.compactMap { key -> HistoryGroup? in
            guard let members = buckets[key], !members.isEmpty else { return nil }
            let sorted = members.sorted {
                $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
            }
            let first = sorted[0]
            let formula = first.formula
            let title = formula.isEmpty
                ? first.atoms.trimmingCharacters(in: .whitespacesAndNewlines)
                : formula
            return HistoryGroup(key: key, title: title, entries: sorted)
        }
        .sorted { $0.date == $1.date ? $0.key < $1.key : $0.date > $1.date }
    }
}
