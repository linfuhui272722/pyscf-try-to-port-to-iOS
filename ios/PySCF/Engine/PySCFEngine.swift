// PySCFEngine.swift
//
// Typed façade over the JSON-RPC bridge.  Every method encodes one request,
// hands it to ``PythonBridge``, and decodes the response into the model types.
//
// Calls are blocking (the embedded interpreter is synchronous), so the async
// wrappers hop onto a background queue and resume the caller on the main actor.

import Foundation

/// Identifies one request/response pair.
private final class RequestID {
    private var counter = 0
    func next() -> Int {
        counter += 1
        return counter
    }
}

struct PySCFEngine {

    private static let ids = RequestID()

    private let bridge: PythonBridge

    init(bridge: PythonBridge = .shared) {
        self.bridge = bridge
    }

    // MARK: - Request plumbing

    /// Sends a request and returns the decoded ``result`` object.
    func call(_ method: String, _ params: [String: Any] = [:]) throws -> JSONObject {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": Self.ids.next(),
            "method": method,
            "params": params,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let json = String(data: data, encoding: .utf8)
        else {
            throw RPCError.transport("could not encode the request for '\(method)'")
        }

        let response: String
        do {
            response = try bridge.call(json)
        } catch {
            throw RPCError.transport(error.localizedDescription)
        }

        switch try RPCResponse.decode(response) {
        case .result(let object):
            return object
        case .failure(let error):
            throw error
        }
    }

    /// Runs a blocking call off the main actor.
    func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Endpoints

    func capabilities() async throws -> Capabilities {
        try await run { Capabilities(try call("capabilities")) }
    }

    func status() async throws -> EngineStatus {
        try await run { EngineStatus(try call("status")) }
    }

    /// Fetches the interpreter report described by ``engine.diagnostics``.
    func diagnostics() async throws -> JSONObject {
        try await run { try call("diagnostics") }
    }

    /// Runs the OpenMP canary and returns its report.
    ///
    /// This is the one check that tells "libomp loaded" apart from "libomp can
    /// start worker threads", so it is exposed separately from
    /// ``diagnostics()`` rather than folded into it.
    func openmp() async throws -> JSONObject {
        try await run { try call("openmp") }
    }

    /// Reads the current OpenMP thread setting.
    func threads() async throws -> ThreadSetting {
        try await run { ThreadSetting(try call("threads")) }
    }

    /// Sets the OpenMP thread count, or restores the default when ``n`` is nil.
    ///
    /// The runtime applies this on its next parallel region, so a calculation
    /// already in flight keeps the count it started with.
    func setThreads(_ n: Int?) async throws -> ThreadSetting {
        try await run { ThreadSetting(try call("threads", ["threads": n ?? 0])) }
    }

    func elements() async throws -> [Element] {
        try await run { try call("elements").objects("elements").map(Element.init) }
    }

    func presets() async throws -> PresetCatalog {
        try await run { PresetCatalog(try call("presets")) }
    }

    func geometry(atoms: String) async throws -> GeometryDescription {
        try await run { GeometryDescription(try call("geometry", ["atoms": atoms])) }
    }

    /// Runs SCF/DFT.
    ///
    /// - Parameters:
    ///   - include: Extra payloads to request, e.g. ``["grid", "mo"]``.
    func scf(
        atoms: String,
        method: String = "RHF",
        basis: String = "sto-3g",
        xc: String = "b3lyp",
        charge: Int = 0,
        spin: Int = 0,
        include: [String] = []
    ) async throws -> ScfResult {
        try await run {
            ScfResult(try call("scf", [
                "atoms": atoms,
                "method": method,
                "basis": basis,
                "xc": xc,
                "charge": charge,
                "spin": spin,
                "include": include,
            ]))
        }
    }

    /// Runs DFT.
    ///
    /// A spin-polarised calculation needs the unrestricted driver, so ``method``
    /// defaults to nil and is then chosen from ``spin``. Sending ``spin > 0`` to
    /// the restricted driver does not produce a spin-polarised answer: the
    /// density stays closed-shell and the spin setting is quietly ignored.
    func dft(
        atoms: String,
        functional: String = "b3lyp",
        basis: String = "sto-3g",
        charge: Int = 0,
        spin: Int = 0,
        method: String? = nil,
        include: [String] = []
    ) async throws -> ScfResult {
        try await run {
            ScfResult(try call("dft", [
                "atoms": atoms,
                "method": method ?? (spin > 0 ? "UKS" : "RKS"),
                "xc": functional,
                "basis": basis,
                "charge": charge,
                "spin": spin,
                "include": include,
            ]))
        }
    }

    /// Evaluates the isosurface of one orbital, for the 3D viewer.
    ///
    /// ``source`` is ``"mo"`` for a canonical molecular orbital or one of the
    /// intrinsic localisation methods for a localised one; ``index`` counts
    /// from zero within that set.  ``isovalue`` is a fraction of the orbital's
    /// peak amplitude, so the same number gives a comparable envelope whatever
    /// the basis and the orbital's scale.
    func orbitalSurface(
        atoms: String,
        index: Int,
        source: String = "mo",
        method: String = "RHF",
        basis: String = "sto-3g",
        xc: String = "b3lyp",
        charge: Int = 0,
        spin: Int = 0,
        isovalue: Double = 0.05,
        pointsPerAxis: Int = 40
    ) async throws -> OrbitalSurface {
        try await run {
            OrbitalSurface(try call("orbital_surface", [
                "atoms": atoms,
                "method": method,
                "basis": basis,
                "xc": xc,
                "charge": charge,
                "spin": spin,
                "index": index,
                "source": source,
                "isovalue": isovalue,
                "pointsPerAxis": pointsPerAxis,
            ]))
        }
    }

    /// Runs MP2 on top of the requested reference.
    ///
    /// ``charge`` and ``spin`` describe the molecule, not the correlation
    /// treatment, so they must reach the reference SCF the same way they do for
    /// a plain SCF run. They are separate from ``reference``, which selects the
    /// reference wavefunction (RHF/UHF/ROHF).
    func mp2(
        atoms: String,
        reference: String = "RHF",
        basis: String = "sto-3g",
        charge: Int = 0,
        spin: Int = 0,
        include: [String] = []
    ) async throws -> ScfResult {
        try await run {
            ScfResult(try call("mp2", [
                "atoms": atoms,
                "reference": reference,
                "basis": basis,
                "charge": charge,
                "spin": spin,
                "include": include,
            ]))
        }
    }

    func ccsd(
        atoms: String,
        reference: String = "RHF",
        basis: String = "sto-3g",
        charge: Int = 0,
        spin: Int = 0,
        include: [String] = []
    ) async throws -> ScfResult {
        try await run {
            ScfResult(try call("ccsd", [
                "atoms": atoms,
                "reference": reference,
                "basis": basis,
                "charge": charge,
                "spin": spin,
                "include": include,
            ]))
        }
    }

    /// Relaxes the molecular geometry with analytic gradients.
    ///
    /// Every basis set in ``Capabilities.basisSets`` is supported, because the
    /// gradient driver comes from the mean-field object itself.
    func optimise(
        atoms: String,
        method: String = "RKS",
        basis: String = "sto-3g",
        xc: String = "b3lyp",
        charge: Int = 0,
        spin: Int = 0,
        maxSteps: Int = 40,
        gridLevel: Int? = nil,
        relaxGridLevel: Int? = nil,
        densityFit: Bool? = nil,
        include: [String] = []
    ) async throws -> OptimisationResult {
        var payload: [String: Any] = [
            "atoms": atoms,
            "method": method,
            "basis": basis,
            "xc": xc,
            "charge": charge,
            "spin": spin,
            "maxSteps": maxSteps,
            "include": include,
        ]
        // Left out when nil so the engine keeps its own default, which is the
        // coarse relaxation grid plus a production-grid refinement.
        if let level = gridLevel { payload["gridLevel"] = level }
        if let relax = relaxGridLevel { payload["relaxGridLevel"] = relax }
        // Left out when nil so the engine decides from the molecule size: it
        // turns density fitting on only once the molecule is large enough to
        // pay for the auxiliary basis, and small molecules run faster without.
        if let fit = densityFit { payload["densityFit"] = fit }
        return try await run {
            OptimisationResult(try call("optimise", payload))
        }
    }

    func bondScan(
        atoms: String,
        i: Int,
        j: Int,
        method: String = "RHF",
        basis: String = "sto-3g",
        charge: Int = 0,
        spin: Int = 0,
        steps: Int = 10,
        start: Double = 0.6,
        stop: Double = 2.5
    ) async throws -> BondScanResult {
        try await run {
            BondScanResult(try call("bond_scan", [
                "atoms": atoms,
                "i": i,
                "j": j,
                "method": method,
                "basis": basis,
                "charge": charge,
                "spin": spin,
                "steps": steps,
                "start": start,
                "stop": stop,
            ]))
        }
    }
}
