// Localization.swift
//
// Lookup helpers for the bundled localisations.  English is the development
// region and therefore the fallback, so a key missing from zh-Hans renders the
// English text rather than the raw key: a gap degrades to the wrong language
// instead of leaking an internal identifier into the UI.

import Foundation

/// Localised string for ``key``.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Localised format string for ``key``, filled with ``arguments``.
///
/// Separate from ``L(_:)`` so the two are never ambiguous at a call site, and
/// so a key that needs arguments cannot silently be looked up without them.
func LF(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
}
