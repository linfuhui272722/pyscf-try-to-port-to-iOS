// HistoryView.swift
//
// Past calculations: a list of saved runs, a detail view for one, per-entry
// deletion, and text export.
//
// The list is driven by ``AppModel/history``, which is reloaded from the store
// after every mutation, so the screen never shows an entry that is no longer on
// disk.

import SwiftUI
import UIKit

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel

    /// The sheet currently presented.
    ///
    /// One state rather than one per sheet: SwiftUI before iOS 16 is unreliable
    /// about several `.sheet` modifiers on the same view, and only one can be up
    /// at a time regardless.
    @State private var activeSheet: HistorySheet?

    /// Whether the "delete everything" confirmation is up.
    @State private var isConfirmingClear = false

    var body: some View {
        Group {
            if model.history.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L("screen.history"))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        exportAll()
                    } label: {
                        Label(L("history.export.all"), systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        isConfirmingClear = true
                    } label: {
                        Label(L("history.delete.all"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(model.history.isEmpty)
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .detail(let entry):
                NavigationView {
                    HistoryDetailView(entry: entry)
                        .environmentObject(model)
                }
            case .share(let url):
                ShareSheet(items: [url])
            }
        }
        .alert(L("history.delete.all.title"), isPresented: $isConfirmingClear) {
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("history.delete.all.confirm"), role: .destructive) {
                model.deleteAllHistory()
            }
        } message: {
            Text(L("history.delete.all.message"))
        }
    }

    // MARK: - List

    private var list: some View {
        List {
            ForEach(model.history) { entry in
                Button {
                    activeSheet = .detail(entry)
                } label: {
                    HistoryRow(entry: entry)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        model.deleteHistory(entry)
                    } label: {
                        Label(L("common.delete"), systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading) {
                    Button {
                        share(entry)
                    } label: {
                        Label(L("history.export.one"), systemImage: "square.and.arrow.up")
                    }
                    .tint(.blue)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 16) {
                Panel(title: L("history.empty.title"), systemImage: "clock.arrow.circlepath") {
                    Text(L("history.empty.body"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }

    // MARK: - Actions

    /// Writes one entry to a file and offers the share sheet.
    ///
    /// A file rather than a bare string: the export is meant to be kept, and a
    /// shared string arrives as a message body on some targets. The file is
    /// written to the temporary directory, which the system clears; the export
    /// is a hand-off, not a second copy of the history.
    private func share(_ entry: HistoryEntry) {
        let text = model.historyText(for: entry)
        if let url = writeTemporary(text: text, name: HistoryReport.fileName(for: entry)) {
            activeSheet = .share(url)
        }
    }

    /// Writes the whole history to a file and offers the share sheet.
    private func exportAll() {
        guard !model.history.isEmpty else { return }
        let text = model.historyText()
        if let url = writeTemporary(text: text, name: HistoryReport.fileName(count: model.history.count)) {
            activeSheet = .share(url)
        }
    }

    /// Writes ``text`` under the temporary directory and returns its URL.
    ///
    /// Returns nil rather than throwing: the share sheet is the only consumer,
    /// and a failed write leaves nothing to show it in.
    private func writeTemporary(text: String, name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

// MARK: - Row

/// One line in the history list: what was run, on what, and how it went.
private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.kind.rawValue)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(.tint)
                Text(entry.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(entry.date, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if !entry.formula.isEmpty {
                    Text(entry.formula)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(entry.date, style: .time)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text(formatHartree(entry.energy))
                    .font(.callout.monospacedDigit().bold())
                if !entry.converged {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 8)
                Text(entry.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Detail

/// One saved calculation, with its full result and its own export button.
struct HistoryDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let entry: HistoryEntry

    /// The file the share sheet is showing.
    ///
    /// Wrapped because `.sheet(item:)` needs an `Identifiable`, and `URL` is not
    /// one.
    @State private var shareFile: SharedFile?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                summaryPanel
                HistoryResultPanels(entry: entry)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(L("common.done")) { dismiss() }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    let text = model.historyText(for: entry)
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent(HistoryReport.fileName(for: entry))
                    if (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil {
                        shareFile = SharedFile(url: url)
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(item: $shareFile) { file in
            ShareSheet(items: [file.url])
        }
    }

    private var summaryPanel: some View {
        Panel(title: L("history.recorded"), systemImage: "clock") {
            MetricRow(label: L("history.kind"), value: entry.kind.rawValue)
            MetricRow(label: L("history.recordedAt"),
                      value: HistoryReportText.timestamp(entry.date))
            MetricRow(label: L("history.molecule"),
                      value: entry.formula.isEmpty ? entry.atoms : entry.formula)
            MetricRow(label: L("history.chargeSpin"),
                      value: "\(entry.charge) / \(entry.spin)")
            MetricRow(label: L("results.wallTime"), value: formatDuration(entry.wallTimeMs))
        }
    }
}

/// Renders a saved entry through the same panels the live Results screen uses.
///
/// Rebuilt from the stored payload, so a saved run and the run that produced it
/// show the same numbers. The optimisation panel drops its two buttons: acting
/// on a run from the past would overwrite the geometry being worked on.
///
/// A view entry -- an orbital surface or a density cloud -- has no result
/// panels, because the entry stores only the recipe and not the mesh.  It is
/// rebuilt by ``HistoryViewerView``, which asks the engine for the same picture
/// again.
struct HistoryResultPanels: View {
    let entry: HistoryEntry

    var body: some View {
        switch entry.kind {
        case .optimise:
            OptimisationPanel(optimisation: OptimisationResult(entry.payload))
        case .scan:
            BondScanPanel(scan: BondScanResult(entry.payload))
        case .orbitals, .density:
            HistoryViewerView(entry: entry)
        default:
            ScfResultPanels(result: ScfResult(entry.payload))
        }
    }
}

/// Rebuilds the 3D picture a view entry recorded.
///
/// The mesh was deliberately left out of the entry -- it is megabytes against a
/// hundred-entry cap -- so opening an entry replays its recipe through the
/// engine and shows the surface that comes back.  That is a real round trip and
/// it can fail, so the three states are all shown: rebuilding, drawn, or a
/// message saying why it could not be drawn.  Silently showing an empty panel
/// would read as a picture with no geometry rather than as a failed rebuild.
struct HistoryViewerView: View {
    @EnvironmentObject private var model: AppModel

    let entry: HistoryEntry

    @State private var surface: OrbitalSurface?
    @State private var cloud: DensitySurface?
    @State private var errorText: String?
    @State private var isRebuilding = false

    /// The recipe stored with the entry, or nil when the payload is not one.
    private var record: ViewRecord? { ViewRecord(entry.payload) }

    var body: some View {
        Panel(title: L("history.view.rebuilt"), systemImage: "cube.transparent") {
            if let record = record {
                Text(LF("history.view.recipe", record.method))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isRebuilding {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(L("history.view.rebuilding"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorText = errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                MoleculeView(
                    geometry: model.geometry,
                    elementTable: model.elements,
                    surface: surface,
                    showsOrbital: true,
                    orbitalOpacity: MoleculeLayout.defaultOrbitalOpacity,
                    density: cloud,
                    showsDensity: true,
                    densityOpacity: MoleculeLayout.defaultDensityOpacity)
                    .frame(minHeight: 320)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                detail
            } else {
                Text(L("history.view.unreadable"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .task { await rebuild() }
    }

    @ViewBuilder
    private var detail: some View {
        if let surface = surface {
            MetricRow(label: L("orbitals.viewer.orbital"),
                      value: "\(surface.label) · "
                          + String(format: "%.5f", surface.orbitalEnergy) + " Ha")
            MetricRow(label: L("orbitals.viewer.surface"),
                      value: LF("orbitals.viewer.surfaceDetail", surface.triangleCount,
                               String(format: "%.4f", surface.isovalue)))
        }
        if let cloud = cloud {
            MetricRow(label: L("density.method"), value: cloud.method)
            MetricRow(label: L("density.levels"),
                      value: cloud.levels.map { String(format: "%.3f", $0) }.joined(separator: ", "))
            MetricRow(label: L("density.surface"),
                      value: LF("density.surfaceDetail", cloud.triangleCount))
        }
    }

    /// Replays the recipe through the engine.
    ///
    /// The geometry has to be loaded first: an entry opened from a fresh launch
    /// has no molecule in the model, and the 3D scene needs one to draw the
    /// surface around.  The entry's own atom notation is used rather than
    /// whatever is in the builder, so the picture matches the record.
    private func rebuild() async {
        guard let record = record, record.isReplayable else { return }
        isRebuilding = true
        errorText = nil
        defer { isRebuilding = false }
        do {
            if model.geometry == nil || model.atomSpec != entry.atoms {
                await model.loadGeometry(atoms: entry.atoms)
            }
            switch record {
            case .orbital(let orbital):
                surface = try await model.rebuildOrbitalView(orbital, entry: entry)
            case .density(let density):
                cloud = try await model.rebuildDensityView(density, entry: entry)
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Sharing

/// The sheet the history screen is presenting.
///
/// One type for both sheets, because only one can be up at a time and SwiftUI
/// before iOS 16 does not reliably honour several `.sheet` modifiers on one
/// view.
enum HistorySheet: Identifiable {
    case detail(HistoryEntry)
    case share(URL)

    /// Fresh per presentation: the sheet is presented on assignment, so a stable
    /// identity across exports is not wanted.
    var id: String {
        switch self {
        case .detail(let entry): return "detail-\(entry.id)"
        case .share(let url): return "share-\(url.path)"
        }
    }
}

/// A file to hand to the share sheet.
///
/// Wrapped in an `Identifiable` type because `.sheet(item:)` needs one, and a
/// bare URL would be identified by its path, which changes on every export.
struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// The system share sheet.
///
/// `ShareLink` is iOS 16 and this app targets 15.6, so the activity controller
/// is presented through a representable instead.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Date formatting for the history detail, kept next to its only caller.
enum HistoryReportText {
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}
