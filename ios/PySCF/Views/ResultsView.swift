// ResultsView.swift
//
// Displays the outcome of the last calculation: headline energies, orbital
// ladder, Mulliken charges, dipole, bond scan, and the engine log.
//
// The panels themselves live in ResultPanels.swift, shared with the History
// detail screen so a saved run and the run that produced it read the same.

import SwiftUI

struct ResultsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let optimisation = model.optimisation {
                    OptimisationPanel(optimisation: optimisation, showActions: true)
                }
                if let result = model.result {
                    ScfResultPanels(result: result)
                    if let scan = model.scan {
                        BondScanPanel(scan: scan)
                    }
                    logPanel(result.log)
                } else if model.optimisation == nil {
                    Panel(title: L("results.empty.title"), systemImage: "hourglass") {
                        Text(L("results.empty.body"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L("screen.results"))
    }

    private func logPanel(_ log: String) -> some View {
        Panel(title: L("results.engineLog"), systemImage: "text.alignleft") {
            if log.isEmpty {
                Text(L("results.empty")).font(.caption.monospaced()).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(log)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
        }
    }
}
