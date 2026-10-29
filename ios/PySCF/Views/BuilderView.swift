// BuilderView.swift
//
// Molecule builder: preset picker, free-form atom specification, calculation
// settings, and a live 3D preview of the parsed geometry.

import SwiftUI

struct BuilderView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Shown first: an engine failure is the reason the panels below
                // stay empty, and at the bottom of a long scroll it is invisible.
                if let message = model.errorMessage {
                    Panel(title: L("builder.problem"), systemImage: "exclamationmark.triangle") {
                        Text(message).font(.callout).foregroundStyle(.red)
                    }
                }

                previewPanel
                presetPanel
                geometryPanel
                settingsPanel
                actionPanel
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L("screen.builder"))
    }

    // MARK: - Panels

    private var previewPanel: some View {
        Panel(title: model.geometry?.formula.isEmpty == false
                ? LF("builder.preview.titled", model.geometry!.formula)
                : L("builder.preview.title"),
              systemImage: "cube.transparent") {
            MoleculeView(geometry: model.geometry, elementTable: model.elements)
                .frame(height: 280)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottomTrailing) {
                    Text(L("builder.preview.hint"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
        }
    }

    private var presetPanel: some View {
        Panel(title: L("builder.molecule"), systemImage: "atom") {
            if model.catalog.presets.isEmpty {
                // Presets only stay empty when the catalog call failed, so say so
                // instead of showing a spinner that will never resolve.
                if model.errorMessage == nil {
                    Text(L("builder.loadingPresets"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text(L("builder.presetsFailed"))
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.catalog.presets) { preset in
                            Button {
                                model.apply(preset)
                            } label: {
                                VStack(spacing: 3) {
                                    Text(preset.formula).font(.subheadline.bold())
                                    Text(preset.name).font(.caption2).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    model.atomSpec == preset.atoms
                                        ? Color.accentColor.opacity(0.2)
                                        : Color(.tertiarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 10)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L("builder.atomSpec")).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $model.atomSpec)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 90)
                    .padding(6)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    .disableAutocorrection(true)
                    .onChange(of: model.atomSpec) { _ in
                        Task { await model.refreshGeometry() }
                    }
                Text(L("builder.atomSpec.hint"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var geometryPanel: some View {
        if let geometry = model.geometry {
            Panel(title: L("builder.geometry"), systemImage: "ruler") {
                MetricRow(label: L("builder.formula"), value: geometry.formula, emphasised: true)
                MetricRow(label: L("builder.atoms"), value: "\(geometry.atomCount)")
                MetricRow(label: L("builder.mass"), value: String(format: "%.4f u", geometry.mass))
                if !geometry.inertia.rotationalConstantsGHz.isEmpty {
                    MetricRow(
                        label: L("builder.rotationalConstants"),
                        value: geometry.inertia.rotationalConstantsGHz
                            .map { String(format: "%.1f", $0) }.joined(separator: " · ") + " GHz"
                    )
                }
                if !geometry.bonds.isEmpty {
                    Divider()
                    Text(L("builder.bonds")).font(.caption).foregroundStyle(.secondary)
                    ForEach(geometry.bonds) { bond in
                        MetricRow(label: "\(bond.a)\(bond.i + 1) – \(bond.b)\(bond.j + 1)",
                                  value: formatLength(bond.length))
                    }
                }
                if !geometry.angles.isEmpty {
                    Divider()
                    Text(L("builder.angles")).font(.caption).foregroundStyle(.secondary)
                    ForEach(geometry.angles) { angle in
                        MetricRow(label: angle.label, value: String(format: "%.2f°", angle.angle))
                    }
                }
            }
        }
    }

    /// Charge and spin, plus the reason they cannot be used together.
    ///
    /// Grouped into one view rather than left inline: the panel's ViewBuilder is
    /// at its ten-child limit, and the pair reads as a unit — the warning only
    /// makes sense directly under both controls.
    @ViewBuilder
    private var chargeSpinControls: some View {
        Stepper(LF("builder.charge", model.charge), value: $model.charge, in: -4...4)
        Stepper(LF("builder.spin", model.spin), value: $model.spin, in: 0...4)
        if let problem = model.chargeSpinProblem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var settingsPanel: some View {
        Panel(title: L("builder.calculation"), systemImage: "slider.horizontal.3") {
            Picker(L("builder.method"), selection: $model.calculation) {
                ForEach(CalculationKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            Text(model.calculation.blurb).font(.caption2).foregroundStyle(.secondary)

            if model.calculation.usesFunctional {
                Picker(L("builder.functional"), selection: $model.functional) {
                    ForEach(model.capabilities?.functionals ?? [model.functional], id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            }

            Picker(L("builder.basis"), selection: $model.basis) {
                ForEach(model.capabilities?.basisSets ?? [model.basis], id: \.self) { name in
                    Text(name).tag(name)
                }
            }

            chargeSpinControls

            if model.calculation == .optimise {
                Stepper(LF("builder.maxSteps", model.maxOptimisationSteps),
                        value: $model.maxOptimisationSteps, in: 5...100, step: 5)
                Picker(L("builder.accuracy"), selection: $model.relaxationAccuracy) {
                    ForEach(RelaxationAccuracy.allCases) { accuracy in
                        Text(accuracy.label).tag(accuracy)
                    }
                }
                .pickerStyle(.segmented)
                Text(model.relaxationAccuracy.blurb)
                    .font(.caption2).foregroundStyle(.secondary)

                Picker(L("builder.densityFit"), selection: $model.densityFit) {
                    ForEach(DensityFitChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                Text(model.densityFit.blurb)
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if model.calculation == .scf || model.calculation == .dft {
                Toggle(L("builder.densityCube"), isOn: $model.wantGrid)
                Toggle(L("builder.localization"), isOn: $model.wantLocalization)
            }

            Divider()
            threadPicker
        }
    }

    /// Thread count for the calculation.
    ///
    /// Offered here rather than only in Diagnostics because it is a setting the
    /// user changes for a reason — a long run on a warm device, or a phone where
    /// using every core drains the battery — and the reason is present while
    /// choosing the calculation, not while reading logs.
    @ViewBuilder
    private var threadPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(L("builder.threads"), selection: $model.threadOverride) {
                Text(L("builder.threads.auto")).tag(Int?.none)
                ForEach(1...max(model.availableCores, 1), id: \.self) { count in
                    Text(LF("builder.threads.count", count)).tag(Int?.some(count))
                }
            }
            .pickerStyle(.menu)
            .onChange(of: model.threadOverride) { value in
                Task { await model.applyThreads(value) }
            }
            Text(threadHint)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var threadHint: String {
        if let override = model.threadOverride {
            return LF("builder.threads.hint.fixed", override)
        }
        let cores = model.availableCores
        return LF("builder.threads.hint.auto", cores)
    }

    private var actionPanel: some View {
        Panel(title: L("builder.run"), systemImage: "play.circle") {
            Button {
                Task { await model.run() }
            } label: {
                Label(LF("builder.compute", model.calculation.rawValue), systemImage: "bolt.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isBusy || model.chargeSpinProblem != nil)

            if model.calculation == .scf {
                Divider()
                Text(L("builder.bondScan")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Stepper(LF("builder.atomI", model.scanI), value: $model.scanI, in: 0...max((model.geometry?.atomCount ?? 1) - 1, 0))
                    Stepper(LF("builder.atomJ", model.scanJ), value: $model.scanJ, in: 0...max((model.geometry?.atomCount ?? 1) - 1, 0))
                }
                Button {
                    Task { await model.runBondScan() }
                } label: {
                    Label(LF("builder.scanBond", model.scanI, model.scanJ), systemImage: "chart.xyaxis.line")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.isBusy || model.scanI == model.scanJ
                          || model.chargeSpinProblem != nil)
            }

            if model.isBusy {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(model.busyLabel).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}
