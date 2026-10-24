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

    func dft(
        atoms: String,
        functional: String = "b3lyp",
        basis: String = "sto-3g",
        charge: Int = 0,
        spin: Int = 0,
        include: [String] = []
    ) async throws -> ScfResult {
        try await run {
            ScfResult(try call("dft", [
                "atoms": atoms,
                "method": "RKS",
                "xc": functional,
                "basis": basis,
                "charge": charge,
                "spin": spin,
                "include": include,
            ]))
        }
    }

    func mp2(
        atoms: String,
        reference: String = "RHF",
        basis: String = "sto-3g",
        include: [String] = []
    ) async throws -> ScfResult {
        try await run {
            ScfResult(try call("mp2", [
                "atoms": atoms,
                "reference": reference,
                "basis": basis,
                "include": include,
            ]))
        }
    }

    func ccsd(
        atoms: String,
        reference: String = "RHF",
        basis: String = "sto-3g",
        include: [String] = []
    ) async throws -> ScfResult {
        try await run {
            ScfResult(try call("ccsd", [
                "atoms": atoms,
                "reference": reference,
                "basis": basis,
                "include": include,
            ]))
        }
    }

    func bondScan(
        atoms: String,
        i: Int,
        j: Int,
        method: String = "RHF",
        basis: String = "sto-3g",
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
                "steps": steps,
                "start": start,
                "stop": stop,
            ]))
        }
    }
}
