// ResultsView.swift
//
// Displays the outcome of the last calculation: headline energies, orbital
// ladder, Mulliken charges, dipole, bond scan, and the engine log.

import SwiftUI
import UIKit

struct ResultsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let optimisation = model.optimisation {
                    optimisationPanel(optimisation)
                }
                if let result = model.result {
                    headline(result)
                    orbitalPanel(result)
                    chargesPanel(result)
                    dipolePanel(result)
                    if let scan = model.scan {
                        scanPanel(scan)
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

    // MARK: - Panels

    /// Geometry relaxation: headline numbers, the optimised coordinates with a
    /// copy button, and the convergence trace.
    private func optimisationPanel(_ optimisation: OptimisationResult) -> some View {
        Panel(title: L("results.optimisation"), systemImage: "arrow.triangle.2.circlepath") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: optimisation.converged
                          ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(optimisation.converged ? .green : .orange)
                    Text(optimisation.converged
                         ? L("results.optimisation.converged")
                         : L("results.optimisation.notConverged"))
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text(LF("results.optimisation.steps", optimisation.steps,
                            optimisation.maxSteps))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(L("results.totalEnergy")).font(.caption).foregroundStyle(.secondary)
                    Text(formatHartree(optimisation.energy))
                        .font(.title3.monospacedDigit().bold())
                        .textSelection(.enabled)
                }

                HStack(spacing: 16) {
                    labelled(L("results.optimisation.maxGrad"),
                             String(format: "%.2e", optimisation.maxGradient))
                    labelled(L("results.optimisation.rmsGrad"),
                             String(format: "%.2e", optimisation.rmsGradient))
                    labelled(L("results.wallTime"),
                             String(format: "%.1f s", optimisation.wallTimeMs / 1000))
                }

                Divider()

                Text(L("results.optimisation.coordinates"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(optimisation.coordinates)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    UIPasteboard.general.string = optimisation.coordinates
                    model.noteCoordinatesCopied()
                } label: {
                    Label(L("results.optimisation.copy"), systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    model.adoptOptimisedGeometry()
                } label: {
                    Label(L("results.optimisation.load"), systemImage: "arrow.down.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if !optimisation.converged {
                    Text(LF("results.optimisation.hint", optimisation.message))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                if optimisation.trajectory.count > 1 {
                    Divider()
                    Text(L("results.optimisation.trace"))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(optimisation.trajectory) { point in
                        HStack {
                            Text("\(point.step)").font(.caption.monospacedDigit())
                                .frame(width: 24, alignment: .trailing)
                            Text(formatHartree(point.energy))
                                .font(.caption.monospacedDigit())
                            Spacer()
                            Text(String(format: "|g| %.1e", point.maxGrad))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func labelled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }

    private func headline(_ result: ScfResult) -> some View {
        Panel(title: result.method, systemImage: "bolt.circle") {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("results.totalEnergy")).font(.caption).foregroundStyle(.secondary)
                Text(formatHartree(result.energy))
                    .font(.title2.monospacedDigit().bold())
                    .textSelection(.enabled)
            }
            if let correlation = result.correlationEnergy, let scf = result.scfEnergy {
                Divider()
                MetricRow(label: L("results.scfReference"), value: formatHartree(scf))
                MetricRow(label: L("results.correlation"), value: formatHartree(correlation))
            }
            Divider()
            MetricRow(label: L("results.converged"),
                          value: result.converged
                              ? LF("results.converged.yes", result.cycles)
                              : L("common.no"))
            MetricRow(label: L("results.electrons"),
                          value: LF("results.electrons.value", result.nElectrons, result.nAlpha, result.nBeta))
            MetricRow(label: L("results.basisFunctions"), value: "\(result.nBasis)")
            MetricRow(label: L("results.wallTime"), value: formatDuration(result.wallTimeMs))
            Divider()
            GapIndicator(gap: result.gap)
        }
    }

    private func orbitalPanel(_ result: ScfResult) -> some View {
        Panel(title: L("results.orbitalEnergies"), systemImage: "waveform.path.ecg") {
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
        Panel(title: L("results.mulliken"), systemImage: "plusminus.circle") {
            if result.mulliken.perAtom.isEmpty {
                Text(L("results.notAvailable")).font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(result.mulliken.perAtom) { charge in
                    MetricRow(
                        label: "\(charge.element)\(charge.index + 1)",
                        value: String(format: "%+.4f e", charge.charge)
                    )
                }
                if !result.mulliken.perElement.isEmpty {
                    Divider()
                    Text(L("results.byElement")).font(.caption).foregroundStyle(.secondary)
                    ForEach(result.mulliken.perElement.sorted(by: { $0.key < $1.key }), id: \.key) { element, charge in
                        MetricRow(label: element, value: String(format: "%+.4f e", charge))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dipolePanel(_ result: ScfResult) -> some View {
        Panel(title: L("results.dipole"), systemImage: "arrow.up.left.and.arrow.down.right") {
            if result.dipole.vector.count == 3 {
                MetricRow(
                    label: L("results.dipoleComponents"),
                    value: result.dipole.vector.map { String(format: "%+.4f", $0) }.joined(separator: ", ")
                )
                MetricRow(label: L("results.magnitude"),
                          value: String(format: "%.4f D", result.dipole.magnitude), emphasised: true)
            } else {
                Text(L("results.notAvailable")).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func scanPanel(_ scan: BondScanResult) -> some View {
        Panel(title: LF("results.bondScan", scan.label), systemImage: "chart.xyaxis.line") {
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
