// ViewRecords.swift
//
// The recipes a history entry stores for a 3D picture.
//
// A drawn orbital surface and a drawn density cloud are both large meshes -- up
// to a megabyte and several megabytes respectively -- and the history keeps a
// hundred entries.  Storing the meshes would put tens of megabytes in the app's
// Documents directory for pictures that cost a fraction of a second to rebuild,
// so an entry stores only what is needed to ask the engine for the same picture
// again: the molecule, the method, and the view's own parameters.
//
// Foundation only, and no reference to AppModel or SwiftUI: the host test
// compiles this file to check the round trip and that the encoding stays small,
// and neither exists on the build host.  The failure this guards against is
// silent on a device -- an entry that records the wrong index or level still
// lists, and only shows the wrong picture when it is opened.

import Foundation

/// What was drawn for an orbital-view entry.
///
/// The fields mirror the ``orbital_surface`` request, so replaying an entry is
/// a matter of passing them back to the engine unchanged.
struct OrbitalViewRecord {

    /// Which orbital of ``source`` was drawn.
    var index: Int
    /// ``"mo"`` for a canonical molecular orbital, or the localisation method.
    var source: String
    /// The isovalue as a fraction of the orbital's peak.
    var isovalue: Double
    /// The label the engine reported, kept for the entry's title.
    var label: String
    /// The mean-field reference the surface was built on, e.g. ``RHF``.
    var method: String

    private enum Key {
        static let index = "index"
        static let source = "source"
        static let isovalue = "isovalue"
        static let label = "label"
        static let method = "method"
        static let kind = "viewKind"
    }

    init(index: Int, source: String, isovalue: Double, label: String, method: String) {
        self.index = index
        self.source = source
        self.isovalue = isovalue
        self.label = label
        self.method = method
    }

    init(surface: OrbitalSurface, method: String) {
        self.init(index: surface.index, source: surface.source,
                  isovalue: surface.isovalueFraction, label: surface.label,
                  method: method)
    }

    init?(json: JSONObject) {
        guard json.value(Key.kind) as String? == "orbital" else { return nil }
        guard let index = json.integer(Key.index),
              let source = json.value(Key.source) as String?
        else { return nil }
        self.index = index
        self.source = source
        self.isovalue = json.number(Key.isovalue) ?? 0.05
        self.label = json.value(Key.label) as String? ?? "MO"
        self.method = json.value(Key.method) as String? ?? "RHF"
    }

    func encoded() -> JSONObject {
        JSONObject([
            Key.kind: "orbital",
            Key.index: index,
            Key.source: source,
            Key.isovalue: isovalue,
            Key.label: label,
            Key.method: method,
        ])
    }
}

/// What was drawn for a density-view entry.
struct DensityViewRecord {

    /// The absolute contour, in electrons per cubic Bohr, the surface was drawn
    /// at.  Zero means the engine's own default.
    var level: Double
    /// The mean-field reference the surface was built on.
    var method: String

    private enum Key {
        static let level = "level"
        static let method = "method"
        static let kind = "viewKind"
    }

    init(level: Double, method: String) {
        self.level = level
        self.method = method
    }

    init(surface: DensitySurface, method: String) {
        self.init(level: surface.level, method: method)
    }

    init?(json: JSONObject) {
        guard json.value(Key.kind) as String? == "density" else { return nil }
        level = json.number(Key.level) ?? 0
        method = json.value(Key.method) as String? ?? "RHF"
    }

    func encoded() -> JSONObject {
        JSONObject([
            Key.kind: "density",
            Key.level: level,
            Key.method: method,
        ])
    }
}

/// A stored view recipe, decoded from an entry's payload without knowing in
/// advance which kind it is.
///
/// The two are told apart by the payload's own ``viewKind`` marker rather than
/// by the entry's kind, so a payload and its label cannot disagree about what
/// it holds: a density payload written under the orbital label decodes as a
/// density recipe, and the caller can decide what to do about it.
enum ViewRecord {
    case orbital(OrbitalViewRecord)
    case density(DensityViewRecord)

    init?(_ json: JSONObject) {
        if let orbital = OrbitalViewRecord(json: json) {
            self = .orbital(orbital)
        } else if let density = DensityViewRecord(json: json) {
            self = .density(density)
        } else {
            return nil
        }
    }

    /// The mean-field reference the recipe was built on.
    var method: String {
        switch self {
        case .orbital(let record): return record.method
        case .density(let record): return record.method
        }
    }

    /// Whether the recipe can be replayed: a canonical orbital and a localised
    /// one both can, and a density cloud can, so the only thing that cannot is a
    /// record naming no source or an empty level list.
    var isReplayable: Bool {
        switch self {
        case .orbital(let record): return !record.source.isEmpty
        case .density: return true
        }
    }
}
