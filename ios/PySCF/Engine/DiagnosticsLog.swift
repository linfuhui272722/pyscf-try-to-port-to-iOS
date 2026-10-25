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
    ///
    /// The write is synchronous and fsync'd, and that is deliberate: the whole
    /// point of this log is the last line before the process dies. Dispatching
    /// the write asynchronously loses exactly that line, because the queue is
    /// still holding it when the process is killed. The cost of a synchronous
    /// append is irrelevant next to the SCF calls being logged.
    func write(_ message: String, tag: String = "app") {
        let line = "[\(stamp.string(from: Date()))] [\(tag)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        guard let data = line.data(using: .utf8) else { return }
        queue.sync {
            for url in self.destinations {
                Self.append(data, to: url)
            }
        }
    }

    /// Appends bytes with a single `O_APPEND` write, then fsyncs.
    ///
    /// `O_APPEND` matters because the embedded Python logger writes to the same
    /// file. Its handle appends atomically; a seek-then-write here would not, so
    /// the two would overwrite each other's lines. One `write(2)` on an
    /// `O_APPEND` descriptor cannot interleave with another.
    private static func append(_ data: Data, to url: URL) {
        // `Darwin.` is required: this type has a method named `write`, which
        // shadows the global one inside a static member.
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < data.count {
                let n = Darwin.write(fd, base.advanced(by: written), data.count - written)
                if n <= 0 { break }
                written += n
            }
        }
        // Without this the bytes sit in the page cache and a jetsam kill takes
        // them with it.
        fsync(fd)
    }

    /// The tail of the log, for the in-app viewer.
    ///
    /// Reading from the device's own file is the only way to see the log
    /// without a Mac: the app cannot be debugged over a cable in this setup.
    func tail(maxBytes: Int = 96 * 1024) -> String {
        queue.sync {
            // Prefer the destination ``write(_:tag:)`` is actually using, so the
            // viewer shows the same file the run is being recorded to. The
            // remaining candidates are still checked, because an older install
            // may have left its log in one of them.
            let ordered = destinations.filter {
                FileManager.default.isWritableFile(atPath: $0.deletingLastPathComponent().path)
            } + destinations
            for url in ordered {
                guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
                let slice = data.count > maxBytes ? data.suffix(maxBytes) : data
                return String(decoding: slice, as: UTF8.self)
            }
            return ""
        }
    }

    /// Removes the log from every writable destination.
    func clear() {
        queue.sync {
            for url in destinations {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// All destination paths, whether or not they are currently writable.
    var allDestinations: [String] {
        queue.sync { destinations.map(\.path) }
    }

    /// The destination new lines are written to, if any.
    ///
    /// Handed to the embedded Python logger so both halves of the record land in
    /// one file. The two sides would otherwise resolve their own preferred
    /// location independently and could disagree, splitting the log so that each
    /// file is missing the lines that explain the other.
    ///
    /// This is the first *writable* destination rather than the first candidate,
    /// matching what ``write(_:tag:)`` actually reaches and what the Python side
    /// picks. On a sandboxed install the leading ``/var/mobile`` candidates are
    /// unwritable, so returning one of those would send Python down its own
    /// fallback list while Swift wrote somewhere else.
    var primaryDestination: String? {
        queue.sync {
            destinations.first {
                FileManager.default.isWritableFile(atPath: $0.deletingLastPathComponent().path)
            }?.path
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
