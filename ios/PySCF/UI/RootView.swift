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
            }
            .padding()
        }
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
}
