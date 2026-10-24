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
                previewPanel
                presetPanel
                geometryPanel
                settingsPanel
                actionPanel

                if let message = model.errorMessage {
                    Panel(title: "Problem", systemImage: "exclamationmark.triangle") {
                        Text(message).font(.callout).foregroundStyle(.red)
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Builder")
    }

    // MARK: - Panels

    private var previewPanel: some View {
        Panel(title: model.geometry?.formula.isEmpty == false
                ? "\(model.geometry!.formula) — 3D preview"
                : "3D preview",
              systemImage: "cube.transparent") {
            MoleculeView(geometry: model.geometry, elementTable: model.elements)
                .frame(height: 280)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottomTrailing) {
                    Text("drag to rotate · pinch to zoom")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
        }
    }

    private var presetPanel: some View {
        Panel(title: "Molecule", systemImage: "atom") {
            if model.catalog.presets.isEmpty {
                Text("Loading presets…").font(.callout).foregroundStyle(.secondary)
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
                Text("Atom specification").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $model.atomSpec)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 90)
                    .padding(6)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    .disableAutocorrection(true)
                    .onChange(of: model.atomSpec) { _ in
                        Task { await model.refreshGeometry() }
                    }
                Text("One atom per line or separated by “;”: element x y z (ångström).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var geometryPanel: some View {
        if let geometry = model.geometry {
            Panel(title: "Geometry", systemImage: "ruler") {
                MetricRow(label: "Formula", value: geometry.formula, emphasised: true)
                MetricRow(label: "Atoms", value: "\(geometry.atomCount)")
                MetricRow(label: "Molecular mass", value: String(format: "%.4f u", geometry.mass))
                if !geometry.inertia.rotationalConstantsGHz.isEmpty {
                    MetricRow(
                        label: "Rotational constants",
                        value: geometry.inertia.rotationalConstantsGHz
                            .map { String(format: "%.1f", $0) }.joined(separator: " · ") + " GHz"
                    )
                }
                if !geometry.bonds.isEmpty {
                    Divider()
                    Text("Bonds").font(.caption).foregroundStyle(.secondary)
                    ForEach(geometry.bonds) { bond in
                        MetricRow(label: "\(bond.a)\(bond.i + 1) – \(bond.b)\(bond.j + 1)",
                                  value: formatLength(bond.length))
                    }
                }
                if !geometry.angles.isEmpty {
                    Divider()
                    Text("Angles").font(.caption).foregroundStyle(.secondary)
                    ForEach(geometry.angles) { angle in
                        MetricRow(label: angle.label, value: String(format: "%.2f°", angle.angle))
                    }
                }
            }
        }
    }

    private var settingsPanel: some View {
        Panel(title: "Calculation", systemImage: "slider.horizontal.3") {
            Picker("Method", selection: $model.calculation) {
                ForEach(CalculationKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            Text(model.calculation.blurb).font(.caption2).foregroundStyle(.secondary)

            if model.calculation == .dft {
                Picker("Functional", selection: $model.functional) {
                    ForEach(model.capabilities?.functionals ?? [model.functional], id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            }

            Picker("Basis set", selection: $model.basis) {
                ForEach(model.capabilities?.basisSets ?? [model.basis], id: \.self) { name in
                    Text(name).tag(name)
                }
            }

            Stepper("Charge: \(model.charge)", value: $model.charge, in: -4...4)
            Stepper("Spin (2S): \(model.spin)", value: $model.spin, in: 0...4)

            if model.calculation == .scf || model.calculation == .dft {
                Toggle("Density cube (for the Density tab)", isOn: $model.wantGrid)
            }
        }
    }

    private var actionPanel: some View {
        Panel(title: "Run", systemImage: "play.circle") {
            Button {
                Task { await model.run() }
            } label: {
                Label("Compute \(model.calculation.rawValue)", systemImage: "bolt.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isBusy)

            if model.calculation == .scf {
                Divider()
                Text("Bond scan").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Stepper("Atom i: \(model.scanI)", value: $model.scanI, in: 0...max((model.geometry?.atomCount ?? 1) - 1, 0))
                    Stepper("Atom j: \(model.scanJ)", value: $model.scanJ, in: 0...max((model.geometry?.atomCount ?? 1) - 1, 0))
                }
                Button {
                    Task { await model.runBondScan() }
                } label: {
                    Label("Scan \(model.scanI)–\(model.scanJ) bond", systemImage: "chart.xyaxis.line")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.isBusy || model.scanI == model.scanJ)
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
