// Theme.swift
//
// Small presentation helpers shared by the views: hex colour parsing for the
// engine's CPK palette, and the card/metric components the panels are built
// from.  Number formatting lives in Models/Formatting.swift, which does not
// import SwiftUI so the host tests can use it.

import SwiftUI

extension Color {
    /// Builds a colour from ``#rrggbb`` / ``rrggbb`` / ``#rgb``.
    init(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 {
            text = text.map { "\($0)\($0)" }.joined()
        }
        var value: UInt64 = 0
        guard text.count == 6, Scanner(string: text).scanHexInt64(&value) else {
            self = .gray
            return
        }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension Element {
    var color: Color { Color(hex: colorHex) }
}

/// A labelled value row used across the result panels.
struct MetricRow: View {
    let label: String
    let value: String
    var emphasised: Bool = false

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(emphasised ? .body.monospacedDigit().bold() : .body.monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

/// Section wrapper with a title, used for the card-style result groups.
struct Panel<Content: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(title).font(.headline)
            } icon: {
                if let systemImage = systemImage {
                    Image(systemName: systemImage)
                }
            }
            .foregroundStyle(.tint)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
