// RootView.swift
//
// Split-view shell.  On iPad the sidebar stays visible; on iPhone the same
// structure collapses into a navigation stack.

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationView {
            List {
                ForEach(Screen.allCases) { screen in
                    Button {
                        model.screen = screen
                    } label: {
                        HStack {
                            Label(screen.title, systemImage: screen.systemImage)
                            Spacer()
                            if model.screen == screen {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(L("app.title"))
            .safeAreaInset(edge: .bottom) {
                statusFooter
            }

            detailView
        }
        .navigationViewStyle(.columns)
    }

    @ViewBuilder
    private var detailView: some View {
        Group {
            switch model.screen {
            case .builder: BuilderView()
            case .results: ResultsView()
            case .history: HistoryView()
            case .orbitals: OrbitalsScreen()
            case .density: DensityScreen()
            case .table: ElementsView()
            case .diagnostics: DiagnosticsScreen()
            }
        }
        .navigationTitle(model.screen.title)
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let caps = model.capabilities {
                Label(
                    caps.engine.available ? L("engine.online") : L("engine.unavailable"),
                    systemImage: caps.engine.available ? "checkmark.seal.fill" : "xmark.seal"
                )
                .foregroundStyle(caps.engine.available ? Color.green : Color.red)
                Text(LF("engine.versions", caps.engine.version, caps.engine.numpyVersion))
                Text(LF("engine.protocol", caps.protocolVersion, caps.packageVersion))
                if let threads = caps.engine.threads {
                    Text(LF("engine.threads", threads))
                } else if let reason = caps.engine.threadsError {
                    Text(LF("engine.threadsUnknown", reason))
                        .foregroundStyle(.orange)
                }
                if !caps.engine.available {
                    // Show why, rather than only that it failed. On a device this
                    // footer is often the only feedback available.
                    Text(caps.engine.error ?? L("engine.noReason"))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } else {
                Label(L("engine.starting"), systemImage: "hourglass")
                Text(L("engine.booting"))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.bar)
    }
}

/// Shows the interpreter report and the log file locations.
///
/// Reached from the sidebar. The report is collected from inside the embedded
/// interpreter, which is the only way to see the runtime state on a device: the
/// iOS extension modules will not load on the build host.
struct DiagnosticsScreen: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Panel(title: L("diag.logFiles"), systemImage: "doc.text") {
                    VStack(alignment: .leading, spacing: 6) {
                        if model.logLocations.isEmpty {
                            Text(L("diag.noLogLocation"))
                        } else {
                            ForEach(model.logLocations, id: \.self) { path in
                                Text(path)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                Panel(title: L("diag.engineStatus"), systemImage: "stethoscope") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let caps = model.capabilities {
                            Text(LF("diag.available", caps.engine.available ? L("common.yes") : L("common.no")))
                            if let error = caps.engine.error {
                                Text(error).foregroundStyle(.red).textSelection(.enabled)
                            }
                            if let traceback = caps.engine.traceback {
                                Text(traceback)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        } else {
                            Text(L("diag.capsNotLoaded"))
                        }
                    }
                }

                Panel(title: L("diag.interpreterReport"), systemImage: "curlybraces") {
                    VStack(alignment: .leading, spacing: 8) {
                        Button(L("diag.collectAgain")) {
                            Task { await model.captureDiagnostics() }
                        }
                        if model.diagnostics.isEmpty {
                            Text(L("diag.notCollected"))
                        } else {
                            Text(model.diagnostics)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }

                Panel(title: L("diag.openmp"), systemImage: "cpu") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("diag.openmpHint"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(L("diag.runProbe")) {
                                Task { await model.probeOpenMP() }
                            }
                            .disabled(model.isBusy)
                            Button(L("diag.reloadLog")) { model.refreshDeviceLog() }
                            Button(L("diag.clearLog"), role: .destructive) { model.clearDeviceLog() }
                        }
                        if model.openmpReport.isEmpty {
                            Text(L("diag.probeNotRun"))
                        } else {
                            Text(model.openmpReport)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }

                Panel(title: L("diag.deviceLog"), systemImage: "doc.plaintext") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("diag.deviceLogHint"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if model.deviceLog.isEmpty {
                            Text(L("diag.deviceLogEmpty"))
                        } else {
                            // Bottom-anchored: when a run crashes, the answer is
                            // in the last few lines, so they are shown first.
                            ScrollView {
                                Text(model.deviceLog)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 320)
                        }
                    }
                }
            }
            .padding()
        }
        .onAppear { model.refreshDeviceLog() }
    }
}

/// Dedicated orbital view, reachable from the sidebar independently of Results.
struct OrbitalsScreen: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let result = model.result {
                    Panel(title: LF("orbitals.ladder", result.method), systemImage: "waveform.path.ecg") {
                        OrbitalEnergyChart(
                            energies: result.orbitalEnergies,
                            occupations: result.occupations,
                            homo: result.homo,
                            lumo: result.lumo
                        )
                    }
                    Panel(title: L("orbitals.occupations"), systemImage: "circle.grid.2x2") {
                        ForEach(Array(result.occupations.enumerated()), id: \.offset) { index, occupation in
                            MetricRow(label: "MO \(index + 1)", value: String(format: "%.3f", occupation))
                        }
                    }
                    orbitalViewerPanel(result)
                } else {
                    Panel(title: L("orbitals.empty.title"), systemImage: "hourglass") {
                        Text(L("orbitals.empty.body"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L("screen.orbitals"))
    }

    /// The orbital viewer: pick an orbital from the ladder, see its shape.
    ///
    /// The cube is fetched on selection rather than with the run, so the
    /// selector is a list of buttons rather than a picker bound to the model:
    /// choosing one has to start a request, and a picker would appear to have
    /// already switched to a cube that has not arrived.
    @ViewBuilder
    private func orbitalViewerPanel(_ result: ScfResult) -> some View {
        Panel(title: L("orbitals.viewer"), systemImage: "cube") {
            if result.orbitalEnergies.isEmpty {
                Text(L("orbitals.viewer.unavailable"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(L("orbitals.viewer.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(result.orbitalEnergies.enumerated()), id: \.offset) { index, energy in
                            let occupation = index < result.occupations.count ? result.occupations[index] : 0
                            Button {
                                Task { await model.loadOrbital(index) }
                            } label: {
                                VStack(spacing: 2) {
                                    Text("\(index + 1)").font(.caption.monospacedDigit().bold())
                                    Text(String(format: "%.3f", energy))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    model.viewedOrbital == index
                                        ? Color.accentColor.opacity(0.25)
                                        : Color(.secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .overlay(alignment: .topTrailing) {
                                    // A dot marks the occupied orbitals, so the
                                    // virtual ones are not mistaken for electrons.
                                    if occupation > 0.5 {
                                        Circle().fill(Color.accentColor)
                                            .frame(width: 5, height: 5)
                                            .padding(3)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if model.isLoadingOrbital {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(L("orbitals.viewer.loading"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let cube = model.orbitalCube {
                    OrbitalSliceView(cube: cube, zIndex: cube.grid.shape.count == 3 ? cube.grid.shape[2] / 2 : 0)
                    MetricRow(
                        label: L("orbitals.viewer.orbital"),
                        value: LF("orbitals.viewer.selection",
                                  cube.index + 1,
                                  String(format: "%.5f", cube.orbitalEnergy),
                                  String(format: "%.2f", cube.occupation))
                    )
                    MetricRow(
                        label: L("orbitals.viewer.phase"),
                        value: L("orbitals.viewer.phase.legend")
                    )
                    Text(L("orbitals.viewer.note"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
