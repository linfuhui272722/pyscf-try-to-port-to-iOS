// AtomSpec.swift
//
// The builder's atom notation, parsed on the Swift side.
//
// The engine is the authority on this format and parses it too, but the history
// list needs a formula and an atom count for every saved entry while the
// interpreter is still booting, and a record that fails to parse here must still
// be listable rather than dropped. So this is a best-effort reader for display,
// not a second parser: anything it cannot read yields an empty result and the
// caller shows the raw text.

import Foundation

enum AtomSpec {

    /// One atom read from a spec line.
    struct Atom: Equatable {
        var symbol: String
        var x: Double
        var y: Double
        var z: Double
    }

    /// Parses ``"O 0 0 0; H 0 0 0.96"`` or newline-separated lines.
    ///
    /// Lines that do not hold a symbol and three numbers are skipped rather than
    /// failing the whole spec: a partially typed spec in the editor is normal,
    /// and the UI shows the count it could read.
    static func parse(_ spec: String) -> [Atom] {
        var atoms: [Atom] = []
        for raw in spec.replacingOccurrences(of: ";", with: "\n").split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line
                .replacingOccurrences(of: ",", with: " ")
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 4,
                  let x = Double(parts[1]),
                  let y = Double(parts[2]),
                  let z = Double(parts[3])
            else { continue }
            let symbol = canonicalSymbol(String(parts[0]))
            guard !symbol.isEmpty else { continue }
            atoms.append(Atom(symbol: symbol, x: x, y: y, z: z))
        }
        return atoms
    }

    /// Hill-order molecular formula, e.g. ``C6H6``.
    ///
    /// Carbon first, then hydrogen, then the rest alphabetically -- the
    /// convention a chemist reads without having to work it out. Returns an
    /// empty string when nothing parses.
    static func formula(_ spec: String) -> String {
        let atoms = parse(spec)
        guard !atoms.isEmpty else { return "" }

        var counts: [String: Int] = [:]
        for atom in atoms { counts[atom.symbol, default: 0] += 1 }

        var order = counts.keys.filter { $0 != "C" && $0 != "H" }.sorted()
        if counts["H"] != nil { order.insert("H", at: 0) }
        if counts["C"] != nil { order.insert("C", at: 0) }

        return order.map { symbol in
            let n = counts[symbol] ?? 0
            return n > 1 ? "\(symbol)\(n)" : symbol
        }.joined()
    }

    /// Normalises an element symbol to ``Sym`` capitalisation.
    ///
    /// The engine accepts lowercase input, and an entry written from such a spec
    /// should still show ``Oh``-style symbols consistently.
    private static func canonicalSymbol(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard let first = text.first, first.isLetter else { return "" }
        return first.uppercased() + text.dropFirst().lowercased()
    }
}
