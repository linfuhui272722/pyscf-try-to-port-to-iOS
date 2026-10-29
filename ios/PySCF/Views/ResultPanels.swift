// ResultPanels.swift
//
// The read-only panels that render a finished calculation.
//
// Shared by the live Results screen and the History detail screen. Both show
// the same numbers for the same run, so they are rendered by the same code: a
// panel that only the live screen knows about would be missing from a saved
// entry, and the difference would look like data loss rather than a UI choice.

import SwiftUI
import UIKit

/// A single-point result: headline, orbital ladder, charges, and the
/// population and bond-order analyses.
struct ScfResultPanels: View {
    let result: ScfResult

    var body: some View {
        VStack(spacing: 16) {
            headline
            orbitalPanel
            chargesPanel
            naturalPanel
            localizedOrbitalsPanel
            intrinsicLocalizationPanel
            mayerPanel
            dipolePanel
        }
    }

    private var headline: some View {
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

    private var orbitalPanel: some View {
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

    private var chargesPanel: some View {
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

    /// Natural population analysis. Shown next to Mulliken rather than instead
    /// of it: the two answer the same question, and the fact that NPA barely
    /// moves between bases while Mulliken does is the reason to trust it.
    @ViewBuilder
    private var naturalPanel: some View {
        Panel(title: L("results.npa"), systemImage: "atom") {
            if let npa = result.npa, !npa.perAtom.isEmpty {
                ForEach(npa.perAtom) { atom in
                    MetricRow(
                        label: "\(atom.element)\(atom.index + 1)",
                        value: String(format: "%+.4f e", atom.charge),
                        emphasised: abs(atom.charge) > 0.5
                    )
                    if !atom.configuration.isEmpty {
                        Text(atom.configurationText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
                MetricRow(
                    label: L("results.npa.sumRule"),
                    value: String(format: "%.4f / %d", npa.totalPopulation, npa.nElectrons)
                )
                if !npa.sumRuleOk {
                    // The occupancies partition the density, so their sum is
                    // fixed by the electron count. A mismatch means the
                    // transform or the density is wrong, not that the numbers
                    // are merely imprecise.
                    Label(L("results.npa.sumMismatch"), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(L("results.npa.note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(L("results.notAvailable")).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// Localised property-optimised orbitals: the bonds and lone pairs.
    ///
    /// This is the panel that answers "what does this molecule look like". The
    /// natural orbitals above delocalise the density across the whole molecule,
    /// which is what makes them basis-stable but unreadable as chemistry; these
    /// orbitals rotate that same density back onto individual bonds and lone
    /// pairs. The valence per atom is the count of two-centre bonds, which is
    /// the Lewis picture made numerical.
    @ViewBuilder
    private var localizedOrbitalsPanel: some View {
        Panel(title: L("results.localized"), systemImage: "circle.hexagongrid") {
            if let localized = result.localizedOrbitals, !localized.orbitals.isEmpty {
                Text(localized.isCLPO ? L("results.localized.clpo") : L("results.localized.lpo"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(localized.bonds) { orbital in
                    MetricRow(
                        label: orbital.label,
                        value: String(format: "%.4f", orbital.occupancy),
                        emphasised: orbital.occupancy >= 1.5
                    )
                }

                let lonePairs = localized.lonePairs
                if !lonePairs.isEmpty {
                    Divider()
                    Text(L("results.localized.lonePairs")).font(.caption).foregroundStyle(.secondary)
                    ForEach(lonePairs) { orbital in
                        MetricRow(
                            label: "\(orbital.elements.first ?? "?")\(orbital.centres.first.map { $0 + 1 } ?? 1)",
                            value: String(format: "%.4f", orbital.occupancy),
                            emphasised: orbital.occupancy >= 1.5
                        )
                    }
                }

                if !localized.valences.isEmpty {
                    Divider()
                    Text(L("results.localized.valence")).font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(localized.valences.enumerated()), id: \.offset) { index, valence in
                        MetricRow(label: "\(elementLabel(index))", value: "\(valence)")
                    }
                }

                Text(L("results.localized.note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(L("results.notAvailable")).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// The element symbol for an atom index, from the molecule as entered.
    private func elementLabel(_ index: Int) -> String {
        let elements = result.mulliken.perAtom.map(\.element)
        guard index < elements.count else { return "#\(index + 1)" }
        return "\(elements[index])\(index + 1)"
    }

    /// Intrinsic localisation: Pipek-Mezey, Foster-Boys or ER.
    ///
    /// Unlike the JANPA panel above, there are no hybrids or bond labels to
    /// show, because these methods do not build hybrids.  What tells the user
    /// whether the result is chemical is where each orbital sits, so the
    /// panel lists each orbital's dominant centres alongside its objective.
    @ViewBuilder
    private var intrinsicLocalizationPanel: some View {
        if let localization = result.localization, localization.orbitalCount > 0 {
            Panel(title: L("results.localization"), systemImage: "target") {
                Text(localization.family)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(0..<localization.orbitalCount, id: \.self) { orbital in
                    let centres = localization.centres(ofOrbital: orbital)
                    MetricRow(
                        label: "LMO \(orbital + 1)",
                        value: centres.isEmpty
                            ? L("results.localization.delocalised")
                            : centres.map { elementLabel($0) }.joined(separator: " \u{2013} ")
                    )
                }

                Divider()
                MetricRow(
                    label: L("results.localization.objective"),
                    value: String(format: "%.8f", localization.objective)
                )
                if !localization.population.isEmpty {
                    MetricRow(
                        label: L("results.localization.population"),
                        value: localization.population
                    )
                }
                MetricRow(
                    label: L("results.localization.sweeps"),
                    value: "\(localization.sweeps)"
                )
                Text(L("results.localization.note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Mayer bond orders. Sorted strongest first, because a bond order is read
    /// as "how many bonds is this", so the interesting entries are at the top.
    @ViewBuilder
    private var mayerPanel: some View {
        Panel(title: L("results.mayer"), systemImage: "link") {
            if let mayer = result.mayer, !mayer.bonds.isEmpty {
                let sorted = mayer.bonds.sorted { $0.order > $1.order }
                ForEach(sorted) { bond in
                    MetricRow(
                        label: bond.label,
                        value: String(format: "%.4f", bond.order),
                        emphasised: bond.order >= 0.5
                    )
                }
                Divider()
                MetricRow(
                    label: L("results.mayer.sumRule"),
                    value: String(format: "%.4f / %.0f", mayer.total, mayer.expectedTotal)
                )
                if !mayer.isValid {
                    // The sum rule holds for any correct density, so a mismatch
                    // means something upstream is wrong. Say so instead of
                    // showing numbers that look fine.
                    Label(L("results.mayer.sumMismatch"), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text(L("results.mayer.note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(L("results.notAvailable")).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var dipolePanel: some View {
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
}

/// A potential-energy scan along one bond.
struct BondScanPanel: View {
    let scan: BondScanResult

    var body: some View {
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
}

/// A geometry relaxation.
///
/// ``showActions`` adds the two buttons that push the optimised coordinates back
/// into the builder. A saved entry passes false: acting on a run from the past
/// would overwrite the geometry the user is working on.
struct OptimisationPanel: View {
    @EnvironmentObject private var model: AppModel

    let optimisation: OptimisationResult
    var showActions: Bool = false

    var body: some View {
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

                if showActions {
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
                }

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
}
