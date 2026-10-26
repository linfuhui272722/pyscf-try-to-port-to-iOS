// PySCFModels.swift
//
// Swift mirrors of the JSON payloads produced by ``pyscf_mobile.bridge``.
//
// The Python side emits plain JSON objects, so decoding goes through
// JSONSerialization and a small set of typed accessors rather than Codable.
// That keeps the Swift types tolerant of the optional fields the engine adds
// only when they were requested (``grid``, ``moCoefficients``, ...).

import Foundation

// MARK: - JSON helpers

/// A JSON object with typed, failure-reporting field access.
struct JSONObject {
    let raw: [String: Any]

    init(_ raw: [String: Any]) {
        self.raw = raw
    }

    func value<T>(_ key: String) -> T? {
        raw[key] as? T
    }

    func required<T>(_ key: String, _ type: T.Type) throws -> T {
        guard let value = raw[key] as? T else {
            throw RPCError.malformedResponse("missing or mistyped field '\(key)'")
        }
        return value
    }

    func number(_ key: String) -> Double? {
        if let d = raw[key] as? Double { return d }
        if let i = raw[key] as? Int { return Double(i) }
        if let n = raw[key] as? NSNumber { return n.doubleValue }
        return nil
    }

    func integer(_ key: String) -> Int? {
        if let i = raw[key] as? Int { return i }
        if let n = raw[key] as? NSNumber { return n.intValue }
        return nil
    }

    func doubles(_ key: String) -> [Double] {
        (raw[key] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
    }

    func integers(_ key: String) -> [Int] {
        (raw[key] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
    }

    func strings(_ key: String) -> [String] {
        raw[key] as? [String] ?? []
    }

    func object(_ key: String) -> JSONObject? {
        (raw[key] as? [String: Any]).map(JSONObject.init)
    }

    func objects(_ key: String) -> [JSONObject] {
        (raw[key] as? [[String: Any]])?.map(JSONObject.init) ?? []
    }

    func doubleMap(_ key: String) -> [String: Double] {
        guard let dict = raw[key] as? [String: Any] else { return [:] }
        return dict.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    func boolMap(_ key: String) -> [String: Bool] {
        guard let dict = raw[key] as? [String: Any] else { return [:] }
        return dict.compactMapValues { $0 as? Bool }
    }

    /// Renders the whole object as indented JSON, for the diagnostics screen.
    func prettyPrinted() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: raw,
                                                      options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return "\(raw)"
        }
        return text
    }

    /// Renders the ``data`` field of an error object as text.
    ///
    /// The engine sends a string for simple failures and an object carrying a
    /// kind or a traceback for richer ones. Both must survive, because the
    /// traceback is the only clue when the interpreter fails to boot.
    func detailString() -> String? {
        if let text = raw["data"] as? String { return text }
        if let dict = raw["data"] as? [String: Any] {
            for key in ["traceback", "message", "kind", "error"] {
                if let text = dict[key] as? String, !text.isEmpty { return text }
            }
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
        }
        return nil
    }
}

// MARK: - Errors

enum RPCError: LocalizedError {
    case transport(String)
    case malformedResponse(String)
    case engine(code: Int, message: String, detail: String?)

    var errorDescription: String? {
        switch self {
        case .transport(let detail):
            return detail
        case .malformedResponse(let detail):
            return "Malformed engine response: \(detail)"
        case .engine(_, let message, let detail):
            return detail.map { "\(message) — \($0)" } ?? message
        }
    }
}

// MARK: - Envelope

/// One decoded JSON-RPC response.
enum RPCResponse {
    case result(JSONObject)
    case failure(RPCError)

    /// Decodes the envelope produced by ``bridge.handle_json``.
    ///
    /// The engine always nests the payload under ``result``, e.g.
    /// ``{"jsonrpc": "2.0", "id": 1, "result": {...}}``. Callers read the
    /// payload's own fields, so unwrap that level here.
    static func decode(_ json: String) throws -> RPCResponse {
        guard let data = json.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw RPCError.malformedResponse("response was not a JSON object")
        }
        let object = JSONObject(root)
        if let error = object.object("error") {
            throw RPCError.engine(
                code: error.integer("code") ?? -32603,
                message: error.value("message") as String? ?? "unknown engine error",
                detail: error.detailString()
            )
        }
        guard let result = object.object("result") else {
            throw RPCError.malformedResponse("response has neither 'result' nor 'error'")
        }
        return .result(result)
    }
}

// MARK: - Engine status

struct EngineStatus {
    var available: Bool
    var error: String?
    var traceback: String?
    var version: String
    var numpyVersion: String
    var libraries: [String: Bool]
    /// Worker threads PySCF will use. 1 means the build is serial; the UI shows
    /// it so OpenMP can be confirmed on device, where the build host cannot.
    var threads: Int?
    var threadsError: String?
    /// The user's chosen thread count, or nil when the runtime decides. Kept
    /// apart from ``threads`` so the picker can show "automatic" as its own
    /// state instead of the number that state resolves to.
    var threadOverride: Int?
    var maxThreads: Int?
    var cores: Int?

    init(_ json: JSONObject) {
        available = json.value("available") as Bool? ?? false
        error = json.value("error") as String?
        traceback = json.value("traceback") as String?
        version = json.value("version") as String? ?? "unknown"
        numpyVersion = json.value("numpy") as String? ?? "unknown"
        libraries = json.boolMap("libraries")
        threads = json.integer("threads")
        threadsError = json.value("threadsError") as String?
        threadOverride = json.integer("threadOverride")
        maxThreads = json.integer("maxThreads")
        cores = json.integer("cores")
    }
}

/// Result of reading or writing the OpenMP thread setting.
struct ThreadSetting {
    /// What the runtime reports, which equals the override once one is set and
    /// the core count otherwise.
    var threads: Int
    /// The user's choice, or nil when the runtime decides. Named ``overrideValue``
    /// because ``override`` is a declaration keyword in Swift.
    var overrideValue: Int?
    var maxThreads: Int
    var cores: Int?

    init(_ json: JSONObject) {
        threads = json.integer("threads") ?? 1
        overrideValue = json.integer("override")
        maxThreads = json.integer("maxThreads") ?? 64
        cores = json.integer("cores")
    }
}

/// Static description of the API surface, fetched once at launch.
struct Capabilities {
    var protocolVersion: Int
    var packageVersion: String
    var engine: EngineStatus
    var methods: [String]
    var basisSets: [String]
    var functionals: [String]
    var availableMethods: [String]

    init(_ json: JSONObject) {
        protocolVersion = json.integer("protocolVersion") ?? 0
        packageVersion = json.value("packageVersion") as String? ?? "0.0.0"
        engine = EngineStatus(json.object("engine") ?? JSONObject([:]))
        methods = json.strings("methods")
        basisSets = json.strings("basisSets")
        functionals = json.strings("functionals")
        availableMethods = json.strings("methodsAvailable")
    }
}

// MARK: - Periodic table

struct Element: Identifiable, Hashable {
    var z: Int
    var symbol: String
    var name: String
    var mass: Double
    var covalentRadius: Double
    var electronegativity: Double
    /// Hex string such as ``#ff0d0d`` from the engine's CPK palette.
    var colorHex: String

    var id: Int { z }

    init(_ json: JSONObject) {
        z = json.integer("z") ?? 0
        symbol = json.value("symbol") as String? ?? "?"
        name = json.value("name") as String? ?? "Unknown"
        mass = json.number("mass") ?? 0
        covalentRadius = json.number("covalentRadius") ?? 0
        electronegativity = json.number("electronegativity") ?? 0
        colorHex = json.value("color") as String? ?? "#808080"
    }
}

// MARK: - Presets

struct MoleculePreset: Identifiable, Hashable {
    var id: String
    var name: String
    var atoms: String
    var formula: String

    init(_ json: JSONObject) {
        id = json.value("id") as String? ?? UUID().uuidString
        name = json.value("name") as String? ?? "Molecule"
        atoms = json.value("atoms") as String? ?? ""
        formula = json.value("formula") as String? ?? ""
    }
}

/// Presets plus the method/basis/functional menus offered by the engine.
struct PresetCatalog {
    var presets: [MoleculePreset] = []
    var basisSets: [String] = []
    var functionals: [String] = []
    var methods: [String] = []

    init(_ json: JSONObject) {
        presets = json.objects("presets").map(MoleculePreset.init)
        basisSets = json.strings("basisSets")
        functionals = json.strings("functionals")
        methods = json.strings("methods")
    }
}

// MARK: - Geometry

struct Bond: Identifiable, Hashable {
    var i: Int
    var j: Int
    var a: String
    var b: String
    var length: Double

    var id: String { "\(i)-\(j)" }

    init(_ json: JSONObject) {
        i = json.integer("i") ?? 0
        j = json.integer("j") ?? 0
        a = json.value("a") as String? ?? "?"
        b = json.value("b") as String? ?? "?"
        length = json.number("length") ?? 0
    }
}

struct BondAngle: Identifiable, Hashable {
    var centre: Int
    var i: Int
    var j: Int
    var label: String
    var angle: Double

    var id: String { "\(i)-\(centre)-\(j)" }

    init(_ json: JSONObject) {
        centre = json.integer("centre") ?? 0
        i = json.integer("i") ?? 0
        j = json.integer("j") ?? 0
        label = json.value("label") as String? ?? ""
        angle = json.number("angle") ?? 0
    }
}

struct RotationalInertia {
    /// Principal moments in atomic units.
    var moments: [Double]
    /// Rotational constants in gigahertz.
    var rotationalConstantsGHz: [Double]

    init(_ json: JSONObject) {
        moments = json.doubles("moments")
        rotationalConstantsGHz = json.doubles("rotationalConstantsGHz")
    }
}

struct PlacedAtom: Identifiable, Hashable {
    var index: Int
    var element: String
    var xyz: [Double]

    var id: Int { index }

    init(_ json: JSONObject) {
        index = json.integer("index") ?? 0
        element = json.value("element") as String? ?? "?"
        xyz = json.doubles("xyz")
    }
}

struct GeometryDescription {
    var formula: String
    var atomCount: Int
    var mass: Double
    var centreOfMass: [Double]
    var atoms: [PlacedAtom]
    var bonds: [Bond]
    var angles: [BondAngle]
    var inertia: RotationalInertia

    init(_ json: JSONObject) {
        formula = json.value("formula") as String? ?? ""
        atomCount = json.integer("atomCount") ?? 0
        mass = json.number("mass") ?? 0
        centreOfMass = json.doubles("centreOfMass")
        atoms = json.objects("atoms").map(PlacedAtom.init)
        bonds = json.objects("bonds").map(Bond.init)
        angles = json.objects("angles").map(BondAngle.init)
        inertia = RotationalInertia(json.object("inertia") ?? JSONObject([:]))
    }
}

// MARK: - Results

struct Dipole {
    var vector: [Double]
    var magnitude: Double

    init(_ json: JSONObject) {
        vector = json.doubles("vector")
        magnitude = json.number("magnitude") ?? 0
    }
}

struct AtomCharge: Identifiable, Hashable {
    var index: Int
    var element: String
    var charge: Double

    var id: Int { index }

    init(_ json: JSONObject) {
        index = json.integer("index") ?? 0
        element = json.value("element") as String? ?? "?"
        charge = json.number("charge") ?? 0
    }
}

struct MullikenAnalysis {
    var perAtom: [AtomCharge]
    var perElement: [String: Double]

    init(_ json: JSONObject) {
        perAtom = json.objects("perAtom").map(AtomCharge.init)
        perElement = json.doubleMap("perElement")
    }
}

/// Natural population analysis (NPA), the population half of NBO theory.
///
/// The natural atomic orbitals are the eigenvectors of the atomic blocks of the
/// density, so these charges depend far less on the basis set than Mulliken's
/// do: water's oxygen is near -0.95 in 6-31G, 6-31G* and cc-pVDZ alike, where
/// Mulliken moves by more than half an electron over the same three bases. Both
/// are shown for that reason.
///
/// The engine reports NPA only. It does not report NBO orbitals or the
/// second-order perturbation energies E(2) that the NBO program produces,
/// because those require the iterative NBO transformation whose reference
/// implementation is licensed software; see `src/pyscf_mobile/nbo.py`.
struct NaturalPopulationAnalysis {
    var perAtom: [NaturalAtom]
    var perElement: [String: Double]
    var nElectrons: Int
    var totalPopulation: Double
    var sumRuleOk: Bool
    var analysisMethod: String

    init(_ json: JSONObject) {
        perAtom = json.objects("perAtom").map(NaturalAtom.init)
        perElement = json.doubleMap("perElement")
        nElectrons = json.integer("nElectrons") ?? 0
        totalPopulation = json.number("totalPopulation") ?? 0
        sumRuleOk = json.value("sumRuleOk") as Bool? ?? false
        analysisMethod = json.value("analysisMethod") as String? ?? ""
    }
}

/// One atom's natural charge, occupancy and natural electron configuration.
struct NaturalAtom: Identifiable, Hashable {
    var index: Int
    var element: String
    var population: Double
    var charge: Double
    /// Shell populations such as `["1s": 2.0, "2s": 1.77, "2p": 5.18]`.
    var configuration: [String: Double]
    var orbitals: [NaturalOrbital]

    var id: Int { index }

    init(_ json: JSONObject) {
        index = json.integer("index") ?? 0
        element = json.value("element") as String? ?? "?"
        population = json.number("population") ?? 0
        charge = json.number("charge") ?? 0
        configuration = json.doubleMap("configuration")
        orbitals = json.objects("orbitals").map(NaturalOrbital.init)
    }

    /// The configuration as a single line, in shell order.
    var configurationText: String {
        configuration
            .sorted { lhs, rhs in
                let left = Self.shellOrder(lhs.key)
                let right = Self.shellOrder(rhs.key)
                return left == right ? lhs.key < rhs.key : left < right
            }
            .map { String(format: "%@ %.2f", $0.key, $0.value) }
            .joined(separator: "  ")
    }

    /// Sorts `2p` before `2s` before `3s`, by principal number then angular
    /// momentum, so the printed configuration reads the way it is written by
    /// hand rather than alphabetically.
    private static func shellOrder(_ shell: String) -> (Int, Int) {
        let digits = shell.prefix { $0.isNumber }
        let principal = Int(digits) ?? 99
        let letters = "spdfgh"
        let letter = shell.first { $0.isLetter }.map { $0.lowercased() } ?? "s"
        let angular = letters.firstIndex(of: Character(letter)).map { letters.distance(from: letters.startIndex, to: $0) } ?? 0
        return (principal, angular)
    }
}

/// One natural atomic orbital.
struct NaturalOrbital: Identifiable, Hashable {
    var label: String
    var shell: String
    var occupation: Double
    var character: String

    var id: String { label }

    init(_ json: JSONObject) {
        label = json.value("label") as String? ?? ""
        shell = json.value("shell") as String? ?? ""
        occupation = json.number("occupation") ?? 0
        character = json.value("character") as String? ?? ""
    }
}

/// One bond with its Mayer bond order.
struct MayerBond: Identifiable, Hashable {
    var i: Int
    var j: Int
    var a: String
    var b: String
    var order: Double

    var id: String { "\(i)-\(j)" }
    var label: String { "\(a)\(i + 1)-\(b)\(j + 1)" }

    init(_ json: JSONObject) {
        i = json.integer("i") ?? 0
        j = json.integer("j") ?? 0
        a = json.value("a") as String? ?? "?"
        b = json.value("b") as String? ?? "?"
        order = json.number("order") ?? 0
    }
}

/// Mayer bond orders plus the sum rule that validates them.
///
/// ``total`` sums every B_AB over all atom pairs including the diagonal terms,
/// and must equal ``expectedTotal`` (twice the electron count). The two are
/// carried together so the UI can flag a mismatch rather than presenting a
/// plausible-looking number that is actually wrong.
struct MayerAnalysis {
    var bonds: [MayerBond]
    var total: Double
    var expectedTotal: Double

    var isValid: Bool { abs(total - expectedTotal) < 1e-4 }

    init(_ json: JSONObject) {
        bonds = json.objects("bonds").map(MayerBond.init)
        total = json.number("total") ?? 0
        expectedTotal = json.number("expectedTotal") ?? 0
    }
}

/// Electron-density cube produced when ``include: ["grid"]`` is requested.
///
/// ``values`` is flattened C-order over ``shape`` with x slowest and z fastest,
/// matching the numpy ``indexing="ij"`` layout the engine uses.
struct DensityGrid {
    var shape: [Int]
    var origin: [Double]
    var step: [Double]
    var values: [Double]

    var count: Int { values.count }

    init(_ json: JSONObject) {
        shape = json.integers("shape")
        origin = json.doubles("origin")
        let scalarStep = json.number("step")
        step = json.doubles("step")
        if step.isEmpty, let scalarStep = scalarStep {
            step = [Double](repeating: scalarStep, count: max(shape.count, 3))
        }
        values = json.doubles("values")
    }

    /// Looks up a voxel, returning ``nil`` for out-of-range indices.
    func value(x: Int, y: Int, z: Int) -> Double? {
        guard shape.count == 3 else { return nil }
        let (nx, ny, nz) = (shape[0], shape[1], shape[2])
        guard x >= 0, x < nx, y >= 0, y < ny, z >= 0, z < nz else { return nil }
        return values[(x * ny + y) * nz + z]
    }
}

/// The shared result shape returned by scf/dft/mp2/ccsd.
struct ScfResult {
    var method: String
    var energy: Double
    var converged: Bool
    var cycles: Int
    var nElectrons: Int
    var nBasis: Int
    var nAlpha: Int
    var nBeta: Int
    var homo: Double?
    var lumo: Double?
    var gap: Double?
    var orbitalEnergies: [Double]
    var occupations: [Double]
    var dipole: Dipole
    var mulliken: MullikenAnalysis
    var npa: NaturalPopulationAnalysis?
    var mayer: MayerAnalysis?
    var wallTimeMs: Double
    var log: String
    var correlationEnergy: Double?
    var scfEnergy: Double?
    var grid: DensityGrid?
    var moCoefficients: [[Double]]?

    init(_ json: JSONObject) {
        method = json.value("method") as String? ?? ""
        energy = json.number("energy") ?? 0
        converged = json.value("converged") as Bool? ?? false
        cycles = json.integer("cycles") ?? 0
        nElectrons = json.integer("nElectrons") ?? 0
        nBasis = json.integer("nBasis") ?? 0
        nAlpha = json.integer("nAlpha") ?? 0
        nBeta = json.integer("nBeta") ?? 0
        homo = json.number("homo")
        lumo = json.number("lumo")
        gap = json.number("gap")
        orbitalEnergies = json.doubles("orbitalEnergies")
        occupations = json.doubles("occupations")
        dipole = Dipole(json.object("dipole") ?? JSONObject([:]))
        mulliken = MullikenAnalysis(json.object("mulliken") ?? JSONObject([:]))
        npa = json.object("npa").map(NaturalPopulationAnalysis.init)
        mayer = json.object("mayer").map(MayerAnalysis.init)
        wallTimeMs = json.number("wallTimeMs") ?? 0
        log = json.value("log") as String? ?? ""
        correlationEnergy = json.number("correlationEnergy")
        scfEnergy = json.number("scfEnergy")
        grid = json.object("grid").map(DensityGrid.init)
        moCoefficients = (json.raw["moCoefficients"] as? [[Any]])?
            .map { $0.compactMap { ($0 as? NSNumber)?.doubleValue } }
    }
}

struct ScanPoint: Identifiable, Hashable {
    var r: Double
    var energy: Double?
    var error: String?

    var id: Double { r }

    init(_ json: JSONObject) {
        r = json.number("r") ?? 0
        energy = json.number("energy")
        error = json.value("error") as String?
    }
}

struct BondScanResult {
    var i: Int
    var j: Int
    var label: String
    var points: [ScanPoint]
    var minimumR: Double?
    var minimumEnergy: Double?

    init(_ json: JSONObject) {
        i = json.integer("i") ?? 0
        j = json.integer("j") ?? 0
        label = json.value("label") as String? ?? ""
        points = json.objects("points").map(ScanPoint.init)
        if let minimum = json.object("minimum") {
            minimumR = minimum.number("r")
            minimumEnergy = minimum.number("energy")
        }
    }
}

// MARK: - Geometry optimisation

/// One relaxation step: the energy and gradient norm after that step.
struct OptimisationStep: Identifiable, Hashable {
    var step: Int
    var energy: Double
    var maxGrad: Double
    var rmsGrad: Double
    var deltaE: Double?

    var id: Int { step }

    init(_ json: JSONObject) {
        step = json.integer("step") ?? 0
        energy = json.number("energy") ?? 0
        maxGrad = json.number("maxGrad") ?? 0
        rmsGrad = json.number("rmsGrad") ?? 0
        deltaE = json.number("deltaE")
    }
}

/// Result of relaxing a molecular geometry.
struct OptimisationResult {
    var method: String
    var functional: String?
    var converged: Bool
    var message: String
    var steps: Int
    var maxSteps: Int
    var wallTimeMs: Double
    var energy: Double
    var maxGradient: Double
    var rmsGradient: Double
    var convTolGrad: Double
    var gridLevel: Int?
    var relaxGridLevel: Int?
    var initialAtoms: String
    var optimisedAtoms: String
    var geometry: GeometryDescription
    var trajectory: [OptimisationStep]
    var log: String

    /// The optimised structure in the form the builder's atom field expects,
    /// so the user can copy it straight back into the editor.
    var coordinates: String { optimisedAtoms }

    init(_ json: JSONObject) {
        method = json.value("method") as String? ?? ""
        functional = json.value("functional") as String?
        converged = json.value("converged") as Bool? ?? false
        message = json.value("message") as String? ?? ""
        steps = json.integer("steps") ?? 0
        maxSteps = json.integer("maxSteps") ?? 0
        wallTimeMs = json.number("wallTimeMs") ?? 0
        energy = json.number("energy") ?? 0
        maxGradient = json.number("maxGradient") ?? 0
        rmsGradient = json.number("rmsGradient") ?? 0
        convTolGrad = json.number("convTolGrad") ?? 0
        gridLevel = json.integer("gridLevel")
        relaxGridLevel = json.integer("relaxGridLevel")
        initialAtoms = json.value("initialAtoms") as String? ?? ""
        optimisedAtoms = json.value("optimisedAtoms") as String? ?? ""
        geometry = GeometryDescription(json.object("geometry") ?? JSONObject([:]))
        trajectory = json.objects("trajectory").map(OptimisationStep.init)
        log = json.value("log") as String? ?? ""
    }
}

