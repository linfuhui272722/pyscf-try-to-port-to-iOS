// HistoryStore.swift
//
// On-disk store for past calculations.
//
// Foundation only, with the directory injected, so the host test can run it
// against a temporary directory. Not an ObservableObject: Combine does not
// exist on the build host, and the app only needs the loaded array, which
// AppModel publishes.
//
// One file per entry rather than one array file. An append then rewrites a
// single small file instead of the whole history, a truncated write can only
// lose the entry being written, and the directory is visible in the Files app
// because the bundle enables file sharing -- so a user can pull an entry out by
// hand without the export path.

import Foundation

final class HistoryStore {

    /// Directory holding one JSON file per entry.
    let directory: URL

    private let fileManager: FileManager

    /// Upper bound on stored entries. Oldest are dropped first.
    ///
    /// The cap is on count, not bytes, because an entry's size is dominated by
    /// the basis: a benzene def2-tzvp run is two orders of magnitude larger than
    /// a water STO-3G one. A byte cap would silently keep ten large entries or a
    /// thousand small ones; a count cap is predictable, and the stripped payload
    /// keeps even the large ones small (see ``stripped``).
    static let maximumEntries = 100

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    /// The store inside the app's Documents directory.
    ///
    /// Documents rather than Caches: the point of history is that it survives,
    /// and Caches is reclaimed by the system under disk pressure. It also puts
    /// the files where the Files app can reach them.
    static func applicationStore() -> HistoryStore {
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return HistoryStore(directory: documents.appendingPathComponent("History"))
    }

    // MARK: - Fields dropped before storing

    /// Payload keys that are not written to disk.
    ///
    /// ``grid`` is the density cube -- about 124 kB at every basis size, since
    /// it is fixed by the cube dimensions rather than the basis -- and it is
    /// read only by the Density screen's slice view, which renders the *current*
    /// result.  ``moCoefficients`` grows with the basis (about 1.1 MB for
    /// benzene in def2-tzvp) and no view reads it at all.
    ///
    /// Neither is needed to list an entry, reload its geometry, or compare its
    /// energy, so dropping them takes the worst case from over a megabyte to
    /// tens of kilobytes.  The cost is that a saved entry cannot drive the
    /// Density screen's slice; that screen has no history UI, and the density
    /// *cloud* a view entry records is rebuilt from its recipe rather than from
    /// the cube, so nothing regresses.
    static let droppedFields = ["grid", "moCoefficients"]

    /// The payload as stored, with the bulky unused fields removed.
    static func stripped(_ payload: JSONObject) -> JSONObject {
        var raw = payload.raw
        for key in droppedFields { raw.removeValue(forKey: key) }
        return JSONObject(raw)
    }

    /// Keys present in ``payload`` that ``stripped`` would remove.
    static func droppedKeys(in payload: JSONObject) -> [String] {
        droppedFields.filter { payload.raw[$0] != nil }
    }

    // MARK: - Reading

    /// Loads every readable entry, newest first.
    ///
    /// A file that fails to decode is left on disk and skipped: one damaged
    /// record must not hide the rest, and deleting it would destroy something
    /// the user may still want to inspect by hand.
    func load() -> [HistoryEntry] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        var entries: [HistoryEntry] = []
        for name in names where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let data = fileManager.contents(atPath: url.path),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let entry = HistoryEntry(json: json)
            else { continue }
            entries.append(entry)
        }
        return entries.sorted { $0.date > $1.date }
    }

    // MARK: - Writing

    /// Writes ``entry`` and returns the history after the cap is applied.
    ///
    /// Returns the reloaded array so the caller never has to guess what was
    /// evicted.
    @discardableResult
    func add(_ entry: HistoryEntry) -> [HistoryEntry] {
        write(entry)
        var entries = load()
        if entries.count > Self.maximumEntries {
            for stale in entries[Self.maximumEntries...] { remove(stale.id) }
            entries = Array(entries.prefix(Self.maximumEntries))
        }
        return entries
    }

    /// Writes one entry, atomically, creating the directory if needed.
    private func write(_ entry: HistoryEntry) {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: entry.encoded(),
                                                     options: [.sortedKeys])
        else { return }
        // `.atomic` writes a temporary file and renames it, so a crash mid-write
        // cannot leave a half-written entry behind.
        try? data.write(to: url(for: entry.id), options: .atomic)
    }

    /// Deletes one entry. Missing files are not an error.
    func remove(_ id: String) {
        try? fileManager.removeItem(at: url(for: id))
    }

    /// Deletes every entry, returning the emptied history.
    @discardableResult
    func removeAll() -> [HistoryEntry] {
        for entry in load() { remove(entry.id) }
        return []
    }

    private func url(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }
}
