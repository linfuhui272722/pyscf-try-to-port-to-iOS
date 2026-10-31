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
    case optimise = "OPT"
    case mp2 = "MP2"
    case ccsd = "CCSD"

    var id: String { rawValue }

    /// Geometry relaxation runs on a Kohn-Sham reference, so it needs the
    /// functional picker that DFT uses.
    var usesFunctional: Bool { self == .dft || self == .optimise }

    var blurb: String {
        switch self {
        case .scf: return L("calc.scf.blurb")
        case .dft: return L("calc.dft.blurb")
        case .optimise: return L("calc.optimise.blurb")
        case .mp2: return L("calc.mp2.blurb")
        case .ccsd: return L("calc.ccsd.blurb")
        }
    }
}

/// How hard the geometry relaxation works per step.
///
/// The XC quadrature dominates the cost of a Kohn-Sham relaxation, and a coarse
/// grid moves the nuclei to the same place for a fraction of the time. The
/// engine always re-evaluates the final structure on the production grid, so
/// these settings trade only relaxation time against how tightly the surface is
/// followed, never the accuracy of the reported energy.
enum RelaxationAccuracy: String, CaseIterable, Identifiable {
    case fast
    case balanced
    case precise

    var id: String { rawValue }

    /// Grid used while the nuclei move. `nil` lets the engine pick.
    var relaxGridLevel: Int? {
        switch self {
        case .fast: return 0
        case .balanced: return nil
        case .precise: return nil
        }
    }

    /// Grid used for the reported single point. `nil` keeps the PySCF default.
    var gridLevel: Int? {
        switch self {
        case .fast, .balanced: return nil
        case .precise: return 4
        }
    }

    /// Set on the precise setting, where the relaxation must not use the cheap
    /// grid at all.
    var forcesProductionGrid: Bool { self == .precise }

    var blurb: String {
        switch self {
        case .fast: return L("accuracy.fast.blurb")
        case .balanced: return L("accuracy.balanced.blurb")
        case .precise: return L("accuracy.precise.blurb")
        }
    }

    var label: String {
        switch self {
        case .fast: return L("accuracy.fast")
        case .balanced: return L("accuracy.balanced")
        case .precise: return L("accuracy.precise")
        }
    }
}

/// Whether a geometry relaxation approximates its two-electron integrals.
///
/// Density fitting replaces the four-centre integrals a relaxation is built from
/// with three-centre ones against an auxiliary basis, which is a large win once
/// the basis is big enough to make those integrals the bottleneck and a loss
/// below that, where the auxiliary-basis setup is not repaid. The crossover
/// depends on the molecule and the device, so the engine's automatic choice is
/// offered as one option rather than being the only one.
enum DensityFitChoice: String, CaseIterable, Identifiable {
    case automatic
    case on
    case off

    var id: String { rawValue }

    /// Passed to the engine as `densityFit`; `nil` means "decide from the basis
    /// size", which is what the engine does when the key is absent.
    var requested: Bool? {
        switch self {
        case .automatic: return nil
        case .on: return true
        case .off: return false
        }
    }

    var label: String {
        switch self {
        case .automatic: return L("densityFit.automatic")
        case .on: return L("densityFit.on")
        case .off: return L("densityFit.off")
        }
    }

    var blurb: String {
        switch self {
        case .automatic: return L("densityFit.automatic.blurb")
        case .on: return L("densityFit.on.blurb")
        case .off: return L("densityFit.off.blurb")
        }
    }
}

/// Navigation destinations for the iPad/iPhone split view.
enum Screen: String, CaseIterable, Identifiable {
    case builder = "Builder"
    case results = "Results"
    case history = "History"
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
        case .history: return "clock.arrow.circlepath"
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
    /// Requests the intrinsic localisation (Pipek-Mezey by default).
    @Published var wantLocalization: Bool = false
    /// The orbital the viewer is drawing, or nil for none yet.
    @Published var viewedOrbital: Int?
    /// What ``viewedOrbital`` indexes: ``"mo"`` for a canonical molecular
    /// orbital, or an intrinsic localisation method for a localised one.
    @Published var orbitalSource: String = "mo"
    /// The isosurface for ``viewedOrbital``, once fetched.
    @Published var orbitalSurface: OrbitalSurface?
    /// The amplitude the envelope is drawn at, as a fraction of the orbital's
    /// peak.  The familiar pictures use something near a twentieth.
    @Published var isovalueFraction: Double = 0.05
    /// Whether the envelope is drawn, so the molecule can be inspected alone.
    @Published var showsOrbital: Bool = true
    /// How opaque the envelope is drawn, 0.05 to 1.  A render property only:
    /// it is applied to the existing material rather than refetching the
    /// surface, so dragging the slider does not recompute anything.
    @Published var orbitalOpacity: Double = MoleculeLayout.defaultOrbitalOpacity
    /// Set while the orbital isosurface is being computed.
    @Published var isLoadingOrbital: Bool = false
    /// Identifies the newest orbital request, so a slow earlier one cannot
    /// overwrite the answer the user is waiting for.
    private var orbitalRequestToken = 0
    /// Identifies the newest pending isovalue redraw, so a drag issues one.
    private var orbitalRedrawToken = 0
    @Published var scanI: Int = 0
    @Published var scanJ: Int = 1
    @Published var maxOptimisationSteps: Int = 40
    @Published var relaxationAccuracy: RelaxationAccuracy = .balanced
    @Published var densityFit: DensityFitChoice = .automatic

    /// OpenMP thread count, or nil for "let the runtime decide". Mirrored into
    /// UserDefaults so the choice survives a relaunch: it is a preference about
    /// the device, not about one calculation.
    @Published var threadOverride: Int? {
        didSet {
            guard !isRestoringThreads else { return }
            let defaults = UserDefaults.standard
            if let value = threadOverride {
                defaults.set(value, forKey: Self.threadsKey)
            } else {
                defaults.removeObject(forKey: Self.threadsKey)
            }
        }
    }

    private static let threadsKey = "pyscf.threads.override"
    private var isRestoringThreads = false

    @Published var capabilities: Capabilities?
    @Published var catalog = PresetCatalog(JSONObject([:]))
    @Published var elements: [Element] = []
    @Published var geometry: GeometryDescription?
    @Published var result: ScfResult?
    @Published var scan: BondScanResult?
    @Published var optimisation: OptimisationResult?

    @Published var isBusy = false
    @Published var busyLabel = ""
    @Published var errorMessage: String?
    @Published var logText = ""
    @Published var diagnostics: String = ""
    @Published var logLocations: [String] = []
    @Published var deviceLog: String = ""
    @Published var openmpReport: String = ""

    private let engine = PySCFEngine()
    private var didBootstrap = false

    // MARK: - History

    /// Saved calculations, newest first.
    @Published var history: [HistoryEntry] = []

    /// The store behind ``history``.
    ///
    /// Lazy so the Documents directory is only touched when history is first
    /// read or written, and not during the interpreter's boot.
    private lazy var historyStore = HistoryStore.applicationStore()

    /// Reads the saved calculations from disk.
    ///
    /// Called once at bootstrap and after every mutation, rather than kept in
    /// sync incrementally: the store is the source of truth, and a list that
    /// drifts from it would show entries that are not there.
    func refreshHistory() {
        history = historyStore.load()
    }

    /// Deletes one saved calculation.
    func deleteHistory(_ entry: HistoryEntry) {
        historyStore.remove(entry.id)
        history = historyStore.load()
        log("deleted history entry \(entry.kind.rawValue)/\(entry.basis)")
    }

    /// Deletes every saved calculation.
    func deleteAllHistory() {
        historyStore.removeAll()
        history = []
        log("deleted all history")
    }

    /// The text export of one entry.
    func historyText(for entry: HistoryEntry) -> String {
        HistoryReport.text(for: entry)
    }

    /// The text export of the whole history, newest first.
    func historyText() -> String {
        HistoryReport.text(for: history)
    }

    /// Records the result of a completed run.
    ///
    /// Called from the run path after the result is published, so a run that
    /// fails records nothing.
    private func recordHistory(kind: HistoryKind,
                               method: String,
                               basis: String,
                               functional: String?,
                               atoms: String,
                               charge: Int,
                               spin: Int,
                               energy: Double,
                               converged: Bool,
                               wallTimeMs: Double,
                               summary: String,
                               payload: JSONObject) {
        let entry = HistoryEntry(
            kind: kind,
            method: method,
            basis: basis,
            functional: functional,
            atoms: atoms,
            charge: charge,
            spin: spin,
            energy: energy,
            converged: converged,
            wallTimeMs: wallTimeMs,
            summary: summary,
            payload: HistoryStore.stripped(payload))
        history = historyStore.add(entry)
    }

    /// The history kind matching a picker selection.
    ///
    /// Separate from ``CalculationKind`` because the two serve different
    /// lifetimes: this one also names scans, and an old entry must keep
    /// decoding after a case is removed from the picker.
    private func historyKind(for calculation: CalculationKind) -> HistoryKind {
        switch calculation {
        case .scf: return .scf
        case .dft: return .dft
        case .optimise: return .optimise
        case .mp2: return .mp2
        case .ccsd: return .ccsd
        }
    }

    // MARK: - Charge and spin

    /// Electrons the current molecule would have, or nil while the geometry has
    /// not parsed yet.
    var electronCount: Int? {
        guard let geometry = geometry, !geometry.atoms.isEmpty else { return nil }
        let bySymbol = Dictionary(uniqueKeysWithValues: elements.map { ($0.symbol, $0.z) })
        var total = 0
        for atom in geometry.atoms {
            guard let z = bySymbol[atom.element] else { return nil }
            total += z
        }
        return total - charge
    }

    /// Why the current charge and spin cannot be used together, or nil if they
    /// are fine.
    ///
    /// The engine rejects the same combinations, but it only gets a chance once
    /// the user presses Compute. Checking here lets the reason appear under the
    /// controls that cause it, before the run is attempted. PySCF's own message
    /// names neither number, which is what makes the pair hard to fix blind.
    var chargeSpinProblem: String? {
        guard let electrons = electronCount else { return nil }
        if electrons < 0 {
            return LF("builder.chargeSpin.tooMany", charge)
        }
        if (electrons - spin) % 2 != 0 {
            // 2S = N_alpha - N_beta and N_alpha + N_beta = N, so N and 2S share
            // a parity: the allowed spin values are the ones matching N.
            // Mirrors the engine's suggestion, stepping down where possible so
            // the value stays inside the stepper's range.
            let suggestion = spin - 1 >= 0 ? spin - 1 : spin + 1
            return LF("builder.chargeSpin.parity", electrons, spin, suggestion)
        }
        if spin > electrons {
            return LF("builder.chargeSpin.tooMuchSpin", spin, electrons)
        }
        return nil
    }

    // MARK: - Bootstrap

    /// Boots Python and loads the static tables.  Safe to call repeatedly.
    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        DiagnosticsLog.shared.write("app launch, log destinations: "
            + "\(DiagnosticsLog.shared.writableDestinations())", tag: "app")
        // Loaded before the engine, which can take seconds to boot: history is
        // on disk and has no reason to wait for the interpreter.
        refreshHistory()
        log("history: \(history.count) saved calculation(s)")
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
            await restoreThreadPreference()
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

    /// Reloads the on-device log into the UI.
    ///
    /// The log is written as the calculation runs, so this is how the run that
    /// crashed is inspected afterwards: relaunch, open Diagnostics, and the
    /// final lines name the step that was in progress.
    func refreshDeviceLog() {
        deviceLog = DiagnosticsLog.shared.tail()
    }

    /// Runs the OpenMP canary.
    ///
    /// Worth doing before a geometry optimisation, because it is the difference
    /// between "the runtime is loaded" and "the runtime can run a parallel
    /// region". The reported thread count cannot tell those apart.
    func probeOpenMP() async {
        do {
            let report = try await engine.openmp()
            openmpReport = report.prettyPrinted()
            DiagnosticsLog.shared.writeBlock(openmpReport, tag: "openmp")
        } catch {
            openmpReport = "probe failed: "
                + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            DiagnosticsLog.shared.write(openmpReport, tag: "openmp")
        }
        refreshDeviceLog()
    }

    func clearDeviceLog() {
        DiagnosticsLog.shared.clear()
        refreshDeviceLog()
    }

    // MARK: - OpenMP threads

    /// Pushes the stored thread preference into the runtime at launch.
    ///
    /// Only runs when a choice was saved; the default is left alone so a fresh
    /// install uses whatever the runtime would have picked.
    private func restoreThreadPreference() async {
        let saved = UserDefaults.standard.object(forKey: Self.threadsKey) as? Int
        guard let saved = saved, saved > 0 else { return }
        isRestoringThreads = true
        threadOverride = saved
        isRestoringThreads = false
        await applyThreads(saved)
    }

    /// Applies a thread count, or restores the default when ``n`` is nil.
    ///
    /// The engine sets this on the runtime directly, so the next calculation
    /// picks it up; a run already in progress keeps the count it began with.
    func applyThreads(_ n: Int?) async {
        do {
            let setting = try await engine.setThreads(n)
            threadOverride = setting.overrideValue
            log("OpenMP threads: \(setting.threads) of \(setting.cores ?? 0) cores"
                + (setting.overrideValue == nil ? " (automatic)" : ""))
            // The footer reads the thread count out of the capabilities snapshot,
            // so it has to be refreshed for the change to be visible there.
            if let caps = try? await engine.capabilities() {
                capabilities = caps
            }
        } catch {
            report(error)
        }
    }

    /// Number of cores the device reports, for the picker's upper bound.
    var availableCores: Int {
        capabilities?.engine.cores ?? ProcessInfo.processInfo.processorCount
    }

    func apply(_ preset: MoleculePreset) {
        atomSpec = preset.atoms
        result = nil
        scan = nil
        optimisation = nil
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
        if wantLocalization { include.append("localization") }
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
            case .optimise:
                // Geometry relaxation returns its own payload (coordinates,
                // trajectory) and its panel shows no orbital data, so it is
                // handled before the shared ScfResult path and asks for nothing
                // extra.
                await runOptimisation()
                return
            case .mp2:
                output = try await engine.mp2(
                    atoms: spec, reference: spin > 0 ? "ROHF" : "RHF",
                    basis: basis, charge: charge, spin: spin, include: include)
            case .ccsd:
                output = try await engine.ccsd(
                    atoms: spec, reference: spin > 0 ? "ROHF" : "RHF",
                    basis: basis, charge: charge, spin: spin, include: include)
            }
            result = output
            scan = nil
            optimisation = nil
            // A new run invalidates the orbital the viewer was drawing: the
            // cube belongs to the old wavefunction.
            viewedOrbital = nil
            orbitalSurface = nil
            logText = output.log
            screen = .results
            recordHistory(kind: historyKind(for: calculation),
                          method: output.method,
                          basis: basis,
                          functional: calculation.usesFunctional ? functional : nil,
                          atoms: spec,
                          charge: charge,
                          spin: spin,
                          energy: output.energy,
                          converged: output.converged,
                          wallTimeMs: output.wallTimeMs,
                          summary: output.converged
                              ? "converged in \(output.cycles) cycles"
                              : "not converged",
                          payload: output.json)
            log("\(output.method): E = \(String(format: "%.8f", output.energy)) Ha "
                + "in \(Int(output.wallTimeMs)) ms")
            if output.converged == false {
                log("warning: SCF did not converge in \(output.cycles) cycles")
            }
        } catch {
            report(error)
        }
    }

    /// Fetches the isosurface of one orbital and shows it.
    ///
    /// Kept out of ``run`` because it is a second round trip: the orbital the
    /// user wants is not known until they pick one from the ladder, and
    /// computing a surface for every orbital up front would be many times the
    /// cost of the run that produced them.
    ///
    /// ``source`` selects a canonical MO or a localised orbital.  Localisation
    /// is re-run on the engine side for a localised pick, which is why switching
    /// source reloads rather than reusing the MO it was derived from.
    func loadOrbital(_ index: Int, source: String? = nil) async {
        guard result != nil else { return }
        // The viewer draws the orbital on the molecule, so the geometry has to
        // be present even if the builder never refreshed it.
        if geometry == nil { await refreshGeometry() }
        let chosen = source ?? orbitalSource

        // Each request is a mean-field solve, and the requests do not finish in
        // the order they were made: a fast one started later can overtake a slow
        // one started earlier, which would leave the viewer showing an orbital
        // the user has already moved past.  Tag every request and keep only the
        // newest answer.
        orbitalRequestToken += 1
        let token = orbitalRequestToken
        isLoadingOrbital = true
        defer { if token == orbitalRequestToken { isLoadingOrbital = false } }
        do {
            let surface = try await engine.orbitalSurface(
                atoms: atomSpec,
                index: index,
                source: chosen,
                method: calculation.usesFunctional
                    ? (spin > 0 ? "UKS" : "RKS") : (spin > 0 ? "ROHF" : "RHF"),
                basis: basis,
                xc: functional,
                charge: charge,
                spin: spin,
                isovalue: isovalueFraction)
            guard token == orbitalRequestToken else { return }
            orbitalSource = chosen
            viewedOrbital = index
            orbitalSurface = surface
            if !surface.hasGeometry {
                log("\(surface.label): no envelope at this isovalue; raise it to shrink the surface")
            }
        } catch {
            guard token == orbitalRequestToken else { return }
            report(error)
        }
    }

    /// Redraws the current orbital at the current isovalue.
    func redrawOrbital() async {
        guard let index = viewedOrbital else { return }
        await loadOrbital(index, source: orbitalSource)
    }

    /// Redraws the current orbital once the isovalue has settled.
    ///
    /// The slider fires on every step of a drag, and each step would otherwise
    /// start its own solve and queue behind the ones before it.  Only the value
    /// the user stops on is wanted, so the request is deferred until the changes
    /// pause and dropped if another arrives first.
    func scheduleOrbitalRedraw() {
        guard viewedOrbital != nil else { return }
        orbitalRedrawToken += 1
        let token = orbitalRedrawToken
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard token == orbitalRedrawToken else { return }
            await redrawOrbital()
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
                method: spin > 0 ? "ROHF" : "RHF", basis: basis,
                charge: charge, spin: spin)
            scan = output
            optimisation = nil
            screen = .results
            recordHistory(kind: .scan,
                          method: output.label,
                          basis: basis,
                          functional: nil,
                          atoms: atomSpec,
                          charge: charge,
                          spin: spin,
                          energy: output.minimumEnergy ?? 0,
                          converged: output.minimumEnergy != nil,
                          wallTimeMs: 0,
                          summary: output.minimumR.map {
                              String(format: "minimum at %.3f Å", $0)
                          } ?? "no minimum found",
                          payload: output.json)
            if let r = output.minimumR, let e = output.minimumEnergy {
                log("\(output.label) scan: minimum at \(String(format: "%.3f", r)) Å, "
                    + "\(String(format: "%.6f", e)) Ha")
            }
        } catch {
            report(error)
        }
    }

    /// Relaxes the geometry and, on success, leaves the optimised structure in
    /// the builder so the user can copy it out or run a single point on it.
    func runOptimisation(include: [String] = []) async {
        isBusy = true
        busyLabel = LF("busy.optimising", basis)
        errorMessage = nil
        defer { isBusy = false }
        do {
            let output = try await engine.optimise(
                atoms: atomSpec, method: spin > 0 ? "UKS" : "RKS", basis: basis, xc: functional,
                charge: charge, spin: spin, maxSteps: maxOptimisationSteps,
                gridLevel: relaxationAccuracy.gridLevel,
                relaxGridLevel: relaxationAccuracy.forcesProductionGrid
                    ? relaxationAccuracy.gridLevel : relaxationAccuracy.relaxGridLevel,
                densityFit: densityFit.requested,
                include: include)
            optimisation = output
            scan = nil
            logText = output.log
            screen = .results
            recordHistory(kind: .optimise,
                          method: output.method,
                          basis: basis,
                          functional: output.functional ?? functional,
                          atoms: atomSpec,
                          charge: charge,
                          spin: spin,
                          energy: output.energy,
                          converged: output.converged,
                          wallTimeMs: output.wallTimeMs,
                          summary: output.converged
                              ? "relaxed in \(output.steps) steps"
                              : "not converged",
                          payload: output.json)
            log("\(output.method): optimised in \(output.steps) steps, "
                + "E = \(String(format: "%.8f", output.energy)) Ha, "
                + "max|grad| = \(String(format: "%.2e", output.maxGradient))")
            if output.converged {
                log("optimised geometry: \(output.optimisedAtoms)")
            } else {
                log("warning: relaxation did not converge — \(output.message)")
            }
        } catch {
            report(error)
        }
    }

    /// Puts the optimised coordinates back into the builder's atom field.
    func adoptOptimisedGeometry() {
        guard let output = optimisation else { return }
        atomSpec = output.optimisedAtoms
        result = nil
        scan = nil
        Task { await refreshGeometry() }
        log("loaded the optimised geometry into the builder")
    }

    /// Records in the log that the coordinates reached the clipboard, so the
    /// action is visible even though the pasteboard is silent.
    func noteCoordinatesCopied() {
        log("optimised coordinates copied to the clipboard")
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
