// ElementsView.swift
//
// Reference table of the elements the engine knows about, including the CPK
// colours used by the 3D view.

import SwiftUI

struct ElementsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            ForEach(model.elements) { element in
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(element.color).frame(width: 30, height: 30)
                        Text(element.symbol)
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(element.name).font(.subheadline)
                        Text("Z = \(element.z) · \(String(format: "%.3f u", element.mass))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(String(format: "r %.2f Å", element.covalentRadius))
                        Text(String(format: "χ %.2f", element.electronegativity))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Elements")
    }
}
