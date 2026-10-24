// DiagnosticsLog.swift
//
// On-device log file.
//
// The iOS build cannot be reproduced on the host: the extension modules are
// arm64-iOS and will not load in a desktop interpreter, so the only way to see
// why the engine fails to start is to record what happened on the device.
//
// The log is written to several places, because the one that works depends on
// how the app was installed. TrollStore apps run with broad filesystem access,
// so /var/mobile is tried first; a normally sandboxed app can still write to its
// own Documents directory, which is exposed in the Files app because the
// Info.plist sets UIFileSharingEnabled.

import Foundation

/// Append-only text log, safe to call from any thread.
final class DiagnosticsLog: @unchecked Sendable {

    static let shared = DiagnosticsLog()

    /// Paths that were writable, most preferred first. Populated on first use.
    private(set) var destinations: [URL] = []

    private let queue = DispatchQueue(label: "dev.pyscf.mobile.log")
    private let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private init() {
        queue.sync { self.destinations = Self.resolveDestinations() }
    }

    /// Candidate log locations, in preference order.
    ///
    /// `/var/mobile/Documents` is outside the app container and only writable
    /// for a TrollStore-style install, so its absence is not an error. The
    /// container's Documents directory always works and is visible in the Files
    /// app when `UIFileSharingEnabled` is set.
    private static func resolveDestinations() -> [URL] {
        var candidates: [URL] = [
            URL(fileURLWithPath: "/var/mobile/Documents/PySCF.log"),
            URL(fileURLWithPath: "/var/mobile/PySCF.log"),
        ]
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            candidates.append(documents.appendingPathComponent("PySCF.log"))
        }
        if let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            candidates.append(library.appendingPathComponent("PySCF.log"))
        }
        if let temporary = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            candidates.append(temporary.appendingPathComponent("PySCF.log"))
        }
        // A path is only usable if its directory exists and accepts writes.
        // /var/mobile/Documents often needs creating, and only a TrollStore
        // install has the rights to do so; failure here is expected and fine.
        for url in candidates {
            let directory = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
        return candidates
    }

    /// Records one line, prefixed with a timestamp and a tag.
    func write(_ message: String, tag: String = "app") {
        let line = "[\(stamp.string(from: Date()))] [\(tag)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        queue.async {
            for url in self.destinations {
                guard let data = line.data(using: .utf8) else { continue }
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                } else {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
    }

    /// Writes a block of text verbatim, for a dumped JSON report.
    func writeBlock(_ text: String, tag: String = "report") {
        write("----- \(tag) -----\n\(text)\n----- end \(tag) -----", tag: tag)
    }

    /// The locations that are actually writable, for display in the UI.
    func writableDestinations() -> [String] {
        queue.sync {
            destinations
                .filter { FileManager.default.isWritableFile(atPath: $0.deletingLastPathComponent().path) }
                .map(\.path)
        }
    }
}
