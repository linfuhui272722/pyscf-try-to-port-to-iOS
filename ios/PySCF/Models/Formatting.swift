// Formatting.swift
//
// Number formatting shared by the views and the history report.
//
// Kept out of Theme.swift because that file imports SwiftUI: the report is
// rendered by HistoryStore, which the host test compiles against Foundation
// alone, and the build host has no SwiftUI.

import Foundation

/// Formats a Hartree energy with enough precision to see correlation effects.
func formatHartree(_ value: Double) -> String {
    String(format: "%.8f Ha", value)
}

/// Formats an energy difference in both Hartree and electron-volts.
func formatEnergyDelta(_ value: Double) -> String {
    String(format: "%.6f Ha  (%.4f eV)", value, value * 27.211386245988)
}

/// Formats a length in ångström.
func formatLength(_ value: Double) -> String {
    String(format: "%.3f Å", value)
}

/// Formats a duration in milliseconds.
func formatDuration(_ milliseconds: Double) -> String {
    milliseconds >= 1000
        ? String(format: "%.2f s", milliseconds / 1000)
        : String(format: "%.0f ms", milliseconds)
}
