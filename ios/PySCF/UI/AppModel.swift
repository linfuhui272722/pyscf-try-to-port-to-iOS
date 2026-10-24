// AppModel.swift
//
// Observable application state.  Owns the engine client and publishes the
// results the SwiftUI views render.  All mutations happen on the main actor;
// the expensive engine calls are awaited off the main thread.

import Foundation
import SwiftUI

/// Which calculation the run button should perform.
enum CalculationKind: String, CaseIterable, Identifiable {
    case scf = "SCF"
    case dft = "DFT"
    case mp2 = "MP2"
    case ccsd = "CCSD"

    var id: String { rawValue }

    var blurb: String {
        switch self {
        case .scf: return L("calc.scf.blurb")
        case .dft: return L("calc.dft.blurb")
        case .mp2: return L("calc.mp2.blurb")
        case .ccsd: return L("calc.ccsd.blurb")
        }
    }
}

/// Navigation destinations for the iPad/iPhone split view.
enum Screen: String, CaseIterable, Identifiable {
    case builder = "Builder"
    case results = "Results"
    case orbitals = "Orbitals"
    case density = "Density"
    case table = "Elements"
    case diagnostics = "Diagnostics"

    var id: String { rawValue }

    /// Localised sidebar and navigation title.
    var title: String { L("screen.\(rawValue.lowercased())") }

    var systemImage: String {
        switch self {
        case .builder: return "atom"
        case .results: return "chart.bar.doc.horizontal"
        case .orbitals: return "waveform.path.ecg"
        case .density: return "square.grid.3x3"
        case .table: return "tablecells"
        case .diagnostics: return "stethoscope"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {

    // MARK: - Published state

    @Published var screen: Screen = .builder

    @Published var atomSpec: String = "O 0 0 0; H 0 0 0.9584; H 0 0.9267 -0.2421"
    @Published var calculation: CalculationKind = .scf
    @Published var basis: String = "sto-3g"
    @Published var functional: String = "b3lyp"
    @Published var charge: Int = 0
    @Published var spin: Int = 0
    @Published var wantGrid: Bool = true
    @Published var scanI: Int = 0
    @Published var scanJ: Int = 1

    @Published var capabilities: Capabilities?
    @Published var catalog = PresetCatalog(JSONObject([:]))
    @Published var elements: [Element] = []
    @Published var geometry: GeometryDescription?
    @Published var result: ScfResult?
    @Published var scan: BondScanResult?

    @Published var isBusy = false
    @Published var busyLabel = ""
    @Published var errorMessage: String?
    @Published var logText = ""
    @Published var diagnostics: String = ""
    @Published var logLocations: [String] = []

    private let engine = PySCFEngine()
    private var didBootstrap = false

    // MARK: - Bootstrap

    /// Boots Python and loads the static tables.  Safe to call repeatedly.
    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        DiagnosticsLog.shared.write("app launch, log destinations: "
            + "\(DiagnosticsLog.shared.writableDestinations())", tag: "app")
        do {
            let caps = try await engine.capabilities()
            capabilities = caps
            log("engine ready — PySCF \(caps.engine.version), NumPy \(caps.engine.numpyVersion)")
            if !caps.engine.available {
                // The engine answered but its native stack is missing. Record the
                // reason: this is the only view of the failure on a device.
                let reason = caps.engine.error ?? "no reason reported"
                log("engine unavailable — \(reason)")
                DiagnosticsLog.shared.write("engine unavailable — \(reason)", tag: "engine")
                await captureDiagnostics()
            }
            if !caps.basisSets.isEmpty {
                basis = caps.basisSets.contains("sto-3g") ? "sto-3g" : caps.basisSets[0]
            }
            if !caps.functionals.isEmpty {
                functional = caps.functionals.contains("b3lyp") ? "b3lyp" : caps.functionals[0]
            }
            catalog = try await engine.presets()
            elements = try await engine.elements()
            await refreshGeometry()
        } catch {
            report(error)
            await captureDiagnostics()
        }
        logLocations = DiagnosticsLog.shared.writableDestinations()
    }

    /// Dumps the interpreter report to the log file.
    ///
    /// Called whenever the engine looks unhealthy, so the on-device log carries
    /// the interpreter state rather than only the failure.
    func captureDiagnostics() async {
        do {
            let report = try await engine.diagnostics()
            let text = report.prettyPrinted()
            diagnostics = text
            DiagnosticsLog.shared.writeBlock(text, tag: "diagnostics")
        } catch {
            diagnostics = "could not collect diagnostics: "
                + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            DiagnosticsLog.shared.write(diagnostics, tag: "diagnostics")
        }
    }

    // MARK: - Actions

    func apply(_ preset: MoleculePreset) {
        atomSpec = preset.atoms
        result = nil
        scan = nil
        Task { await refreshGeometry() }
    }

    func refreshGeometry() async {
        let spec = atomSpec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spec.isEmpty else {
            geometry = nil
            return
        }
        do {
            geometry = try await engine.geometry(atoms: spec)
        } catch {
            geometry = nil
            report(error)
        }
    }

    /// Runs the selected calculation.
    func run() async {
        isBusy = true
        busyLabel = LF("busy.running", calculation.rawValue)
        errorMessage = nil
        defer { isBusy = false }

        var include: [String] = []
        if wantGrid { include.append("grid") }
        include.append("mo")

        let spec = atomSpec
        do {
            let output: ScfResult
            switch calculation {
            case .scf:
                output = try await engine.scf(
                    atoms: spec, method: spin > 0 ? "ROHF" : "RHF",
                    basis: basis, charge: charge, spin: spin, include: include)
            case .dft:
                output = try await engine.dft(
                    atoms: spec, functional: functional, basis: basis,
                    charge: charge, spin: spin, include: include)
            case .mp2:
                output = try await engine.mp2(
                    atoms: spec, reference: spin > 0 ? "ROHF" : "RHF",
                    basis: basis, include: include)
            case .ccsd:
                output = try await engine.ccsd(
                    atoms: spec, reference: spin > 0 ? "ROHF" : "RHF",
                    basis: basis, include: include)
            }
            result = output
            scan = nil
            logText = output.log
            screen = .results
            log("\(output.method): E = \(String(format: "%.8f", output.energy)) Ha "
                + "in \(Int(output.wallTimeMs)) ms")
            if output.converged == false {
                log("warning: SCF did not converge in \(output.cycles) cycles")
            }
        } catch {
            report(error)
        }
    }

    /// Scans the potential-energy surface along the selected bond.
    func runBondScan() async {
        isBusy = true
        busyLabel = LF("busy.scanning", scanI, scanJ)
        errorMessage = nil
        defer { isBusy = false }
        do {
            let output = try await engine.bondScan(
                atoms: atomSpec, i: scanI, j: scanJ,
                method: spin > 0 ? "ROHF" : "RHF", basis: basis)
            scan = output
            screen = .results
            if let r = output.minimumR, let e = output.minimumEnergy {
                log("\(output.label) scan: minimum at \(String(format: "%.3f", r)) Å, "
                    + "\(String(format: "%.6f", e)) Ha")
            }
        } catch {
            report(error)
        }
    }

    // MARK: - Helpers

    private func log(_ line: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logText = "[\(stamp)] \(line)\n" + logText
    }

    private func report(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        errorMessage = message
        log("error: \(message)")
    }
}
