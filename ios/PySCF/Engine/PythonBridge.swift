// PythonBridge.swift
//
// Embeds CPython inside the app process and exposes a single request/response
// entry point to Swift.  iOS forbids spawning helper processes, so the engine
// runs in-process and is driven through the CPython C API.
//
// The Python side lives in ``pyscf_mobile.bridge`` and is intentionally tiny:
// ``handle_json`` parses one JSON request, dispatches it, and always returns a
// JSON string (errors included), so nothing here has to translate exceptions.

import Foundation
import Python

/// Errors surfaced by the bridge before a request ever reaches Python.
enum PythonBridgeError: LocalizedError {
    case alreadyRunning
    case interpreterUnavailable(String)
    case missingEntryPoint(String)
    case encodingFailure

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "The embedded interpreter is already running."
        case .interpreterUnavailable(let detail):
            return "Could not start the embedded interpreter: \(detail)"
        case .missingEntryPoint(let name):
            return "The engine entry point \(name) was not found in the embedded runtime."
        case .encodingFailure:
            return "Could not encode the request as UTF-8."
        }
    }
}

/// Owns the embedded CPython interpreter and serialises access to it.
///
/// The interpreter is not thread-safe by default and the Python C API requires
/// the GIL for every call.  ``call(_:)`` funnels all traffic through a serial
/// queue and holds the GIL around each request, which keeps the SwiftUI layer
/// free to call it from any actor.
final class PythonBridge: @unchecked Sendable {

    static let shared = PythonBridge()

    private let queue = DispatchQueue(label: "dev.pyscf.mobile.bridge")
    private var isRunning = false
    private var handleJSON: UnsafeMutablePointer<PyObject>?

    /// The interpreter home directory, i.e. the resource folder holding
    /// ``lib/python3.13``.  Populated by the packaging script.
    private let pythonHome: URL?
    /// Extra import roots (vendored wheels plus the engine itself).
    private let sitePackages: [URL]

    private init() {
        // The runtime is staged at the top level of the .app. A top-level
        // `Resources` directory is a macOS bundle convention, and installing a
        // bundle that uses it fails: MobileInstallation rejects the package
        // during inspection, before registration. See probe-j and probe-k in
        // scripts/build-probes.py. Accept the old path too, so bundles built
        // before the move still launch.
        let bundle = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let candidates = [
            bundle.appendingPathComponent("python", isDirectory: true),
            bundle.appendingPathComponent("Resources/python", isDirectory: true),
        ]
        let home = candidates.first { FileManager.default.fileExists(atPath: $0.path) }
        self.pythonHome = home

        var roots: [URL] = []
        if let home = home {
            roots.append(home.appendingPathComponent("lib/python3.13/site-packages", isDirectory: true))
            roots.append(home.appendingPathComponent("site-packages", isDirectory: true))
        }
        self.sitePackages = roots.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Lifecycle

    /// Boots the interpreter once and caches the engine entry point.
    func start() throws {
        try queue.sync {
            guard !isRunning else { throw PythonBridgeError.alreadyRunning }
            try boot()
            isRunning = true
        }
    }

    var running: Bool {
        queue.sync { isRunning }
    }

    // MARK: - Requests

    /// Sends one JSON request and returns the JSON response.
    ///
    /// Safe to call from any thread or actor; calls are serialised internally.
    func call(_ requestJSON: String) throws -> String {
        try queue.sync {
            if !isRunning {
                try boot()
                isRunning = true
            }
            return try invoke(requestJSON)
        }
    }

    // MARK: - CPython plumbing

    // MARK: - OpenMP configuration

    /// Sets the OpenMP environment *before* libomp is first used.
    ///
    /// The runtime reads these once, when it initialises its thread pool, so
    /// they have to be in the environment before the first parallel region —
    /// which is why this runs at boot rather than being settable from the UI
    /// afterwards.
    ///
    /// ``OMP_STACKSIZE`` is the important one.  LLVM's libomp only defines a
    /// large default worker stack for x86 and x86_64 (2 MB and 4 MB); every
    /// other architecture, AArch64 included, falls through to a 1 MB default,
    /// and the x86_64-only ``KMP_BACKUP_STKSIZE`` fallback is absent too.  So on
    /// an arm64 device each OpenMP worker gets 1 MB, where the same code on a
    /// desktop gets 4 MB.  Whether that is enough is not knowable in advance —
    /// it depends on the depth of PySCF's integral-evaluation call chain under
    /// the worker's own frames — so it is set to the desktop value and the
    /// outcome is logged.
    ///
    /// This is consistent with the symptom that started the investigation:
    /// serial beta.17 relaxed geometries fine, and beta.18 changed only the
    /// threading, so the SCF that runs inside the second relaxation step now
    /// executes on worker threads rather than the main thread.  That is the
    /// first point at which a worker stack is used at all.
    ///
    /// The value is set only when the caller has not chosen one, so a user can
    /// still override it.
    private func configureOpenMP() {
        // Point the Python logger at the same file this side writes to, so the
        // two halves of the record are not split across destinations that only
        // one of them can see.
        if let destination = DiagnosticsLog.shared.primaryDestination, getenv("PYSCF_MOBILE_LOG") == nil {
            setenv("PYSCF_MOBILE_LOG", destination, 1)
            DiagnosticsLog.shared.write("log: PYSCF_MOBILE_LOG=\(destination)", tag: "bridge")
        }

        let defaults: [(String, String)] = [
            // 8 MB matches the x86_64 default and the usual Linux pthread stack,
            // so the same code paths get the room they are tested with.
            ("OMP_STACKSIZE", "8192K"),
            // Keep a worker's stack resident between parallel regions. Relaxation
            // enters a region every step; letting the pool tear down and rebuild
            // each time both costs time and re-runs the thread creation that is
            // under suspicion.
            ("KMP_BLOCKTIME", "200"),
        ]

        for (key, value) in defaults where getenv(key) == nil {
            setenv(key, value, 1)
            DiagnosticsLog.shared.write("openmp: \(key)=\(value) (default applied)", tag: "bridge")
        }
        for key in ["OMP_STACKSIZE", "KMP_BLOCKTIME", "OMP_NUM_THREADS"] {
            if let current = getenv(key) {
                DiagnosticsLog.shared.write("openmp: \(key)=\(String(cString: current)) (already set)", tag: "bridge")
            }
        }
    }

    private func boot() throws {
        DiagnosticsLog.shared.write("boot: pythonHome=\(pythonHome?.path ?? "nil")", tag: "bridge")
        DiagnosticsLog.shared.write("boot: sitePackages=\(sitePackages.map(\.path))", tag: "bridge")

        configureOpenMP()

        if let home = pythonHome, let cHome = Py_DecodeLocale(home.path, nil) {
            Py_SetPythonHome(cHome)
        }
        if Py_IsInitialized() == 0 {
            Py_Initialize()
            // Py_Initialize leaves the GIL held by the calling thread and never
            // releases it. Requests are dispatched onto the global concurrent
            // queue, so the second one can run on a different thread and blocks
            // forever inside PyGILState_Ensure: the first request succeeds and
            // every later one hangs. Release the GIL here so each request can
            // re-acquire it, which is the embedding pattern the C API documents.
            _ = PyEval_SaveThread()
        }
        guard Py_IsInitialized() != 0 else {
            DiagnosticsLog.shared.write("boot: Py_Initialize failed", tag: "bridge")
            throw PythonBridgeError.interpreterUnavailable("Py_Initialize did not report success")
        }

        let gil = PyGILState_Ensure()
        defer { PyGILState_Release(gil) }

        // Drop the default sys.path[0] (the app bundle) and prepend the
        // vendored roots so ``import pyscf_mobile`` resolves to our payload.
        var lines = ["import sys", "sys.path = [p for p in sys.path if p]"]
        for root in sitePackages {
            lines.append("sys.path.insert(0, \(pythonStringLiteral(root.path)))")
        }
        lines.append("sys.argv = ['PySCF']")
        guard PyRun_SimpleString(lines.joined(separator: "\n")) == 0 else {
            DiagnosticsLog.shared.write("boot: could not configure sys.path", tag: "bridge")
            PyErr_Print()
            throw PythonBridgeError.interpreterUnavailable("could not configure sys.path")
        }

        guard let module = PyImport_ImportModule("pyscf_mobile.bridge") else {
            let detail = drainPythonError()
            DiagnosticsLog.shared.write("boot: cannot import pyscf_mobile.bridge — \(detail)", tag: "bridge")
            throw PythonBridgeError.missingEntryPoint("pyscf_mobile.bridge (\(detail))")
        }
        defer { Py_DecRef(module) }

        guard let fn = PyObject_GetAttrString(module, "handle_json") else {
            let detail = drainPythonError()
            DiagnosticsLog.shared.write("boot: no handle_json — \(detail)", tag: "bridge")
            throw PythonBridgeError.missingEntryPoint("pyscf_mobile.bridge.handle_json (\(detail))")
        }
        handleJSON = fn
        DiagnosticsLog.shared.write("boot: interpreter ready", tag: "bridge")
    }

    /// Fetches and clears the pending Python exception as text.
    ///
    /// ``PyErr_Print`` writes to stderr, which is invisible once the app is
    /// installed on a device, so the message is captured instead. Only function
    /// calls are used here: the reference-counting macros in ``Python.h`` are
    /// not importable from Swift. The full traceback for engine failures comes
    /// from ``pyscf_mobile.engine``, which records it in pure Python.
    private func drainPythonError() -> String {
        guard PyErr_Occurred() != nil else { return "no Python error set" }
        var type: UnsafeMutablePointer<PyObject>?
        var value: UnsafeMutablePointer<PyObject>?
        var tb: UnsafeMutablePointer<PyObject>?
        PyErr_Fetch(&type, &value, &tb)
        PyErr_NormalizeException(&type, &value, &tb)

        var text = "unknown error"
        if let value = value, let rendered = PyObject_Str(value), let cString = PyUnicode_AsUTF8(rendered) {
            text = String(cString: cString)
            Py_DecRef(rendered)
        }
        if let type = type, let rendered = PyObject_Str(type), let cString = PyUnicode_AsUTF8(rendered) {
            text = "\(String(cString: cString)): \(text)"
            Py_DecRef(rendered)
        }
        if let type = type { Py_DecRef(type) }
        if let value = value { Py_DecRef(value) }
        if let tb = tb { Py_DecRef(tb) }
        return text
    }

    private func invoke(_ requestJSON: String) throws -> String {
        let gil = PyGILState_Ensure()
        defer { PyGILState_Release(gil) }

        guard let fn = handleJSON else {
            throw PythonBridgeError.missingEntryPoint("pyscf_mobile.bridge.handle_json")
        }
        guard let argument = PyUnicode_FromString(requestJSON) else {
            PyErr_Clear()
            throw PythonBridgeError.encodingFailure
        }
        defer { Py_DecRef(argument) }

        guard let result = PyObject_CallOneArg(fn, argument) else {
            PyErr_Print()
            throw PythonBridgeError.interpreterUnavailable("handle_json raised")
        }
        defer { Py_DecRef(result) }

        guard let cString = PyUnicode_AsUTF8(result) else {
            PyErr_Print()
            throw PythonBridgeError.encodingFailure
        }
        return String(cString: cString)
    }

    /// Renders a Swift string as a safe Python string literal.
    private func pythonStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "'\(escaped)'"
    }
}
