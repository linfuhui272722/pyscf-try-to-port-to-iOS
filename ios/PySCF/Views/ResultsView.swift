// ResultsView.swift
//
// Displays the outcome of the last calculation: headline energies, orbital
// ladder, Mulliken charges, dipole, bond scan, and the engine log.

import SwiftUI

struct ResultsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let result = model.result {
                    headline(result)
                    orbitalPanel(result)
                    chargesPanel(result)
                    dipolePanel(result)
                    if let scan = model.scan {
                        scanPanel(scan)
                    }
                    logPanel(result.log)
                } else {
                    Panel(title: "No results yet", systemImage: "hourglass") {
                        Text("Build a molecule and press Compute to run a calculation.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Results")
    }

    // MARK: - Panels

    private func headline(_ result: ScfResult) -> some View {
        Panel(title: result.method, systemImage: "bolt.circle") {
            VStack(alignment: .leading, spacing: 2) {
                Text("Total energy").font(.caption).foregroundStyle(.secondary)
                Text(formatHartree(result.energy))
                    .font(.title2.monospacedDigit().bold())
                    .textSelection(.enabled)
            }
            if let correlation = result.correlationEnergy, let scf = result.scfEnergy {
                Divider()
                MetricRow(label: "SCF reference", value: formatHartree(scf))
                MetricRow(label: "Correlation energy", value: formatHartree(correlation))
            }
            Divider()
            MetricRow(label: "Converged", value: result.converged ? "yes (\(result.cycles) cycles)" : "no")
            MetricRow(label: "Electrons", value: "\(result.nElectrons)  (α \(result.nAlpha) / β \(result.nBeta))")
            MetricRow(label: "Basis functions", value: "\(result.nBasis)")
            MetricRow(label: "Wall time", value: formatDuration(result.wallTimeMs))
            Divider()
            GapIndicator(gap: result.gap)
        }
    }

    private func orbitalPanel(_ result: ScfResult) -> some View {
        Panel(title: "Orbital energies", systemImage: "waveform.path.ecg") {
            OrbitalEnergyChart(
                energies: result.orbitalEnergies,
                occupations: result.occupations,
                homo: result.homo,
                lumo: result.lumo
            )
            Divider()
            ForEach(Array(result.orbitalEnergies.enumerated()), id: \.offset) { index, energy in
                let occupation = index < result.occupations.count ? result.occupations[index] : 0
                MetricRow(
                    label: "MO \(index + 1)",
                    value: String(format: "%9.5f Ha   occ %.2f", energy, occupation)
                )
            }
        }
    }

    private func chargesPanel(_ result: ScfResult) -> some View {
        Panel(title: "Mulliken charges", systemImage: "plusminus.circle") {
            if result.mulliken.perAtom.isEmpty {
                Text("Not available for this method.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(result.mulliken.perAtom) { charge in
                    MetricRow(
                        label: "\(charge.element)\(charge.index + 1)",
                        value: String(format: "%+.4f e", charge.charge)
                    )
                }
                if !result.mulliken.perElement.isEmpty {
                    Divider()
                    Text("By element").font(.caption).foregroundStyle(.secondary)
                    ForEach(result.mulliken.perElement.sorted(by: { $0.key < $1.key }), id: \.key) { element, charge in
                        MetricRow(label: element, value: String(format: "%+.4f e", charge))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dipolePanel(_ result: ScfResult) -> some View {
        Panel(title: "Dipole moment", systemImage: "arrow.up.left.and.arrow.down.right") {
            if result.dipole.vector.count == 3 {
                MetricRow(
                    label: "Components (x, y, z)",
                    value: result.dipole.vector.map { String(format: "%+.4f", $0) }.joined(separator: ", ")
                )
                MetricRow(label: "Magnitude", value: String(format: "%.4f D", result.dipole.magnitude), emphasised: true)
            } else {
                Text("Not available for this method.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func scanPanel(_ scan: BondScanResult) -> some View {
        Panel(title: "Bond scan — \(scan.label)", systemImage: "chart.xyaxis.line") {
            BondScanChart(scan: scan)
            Divider()
            ForEach(scan.points) { point in
                MetricRow(
                    label: formatLength(point.r),
                    value: point.energy.map { formatHartree($0) } ?? (point.error ?? "failed")
                )
            }
        }
    }

    private func logPanel(_ log: String) -> some View {
        Panel(title: "Engine log", systemImage: "text.alignleft") {
            if log.isEmpty {
                Text("(empty)").font(.caption.monospaced()).foregroundStyle(.secondary)
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
