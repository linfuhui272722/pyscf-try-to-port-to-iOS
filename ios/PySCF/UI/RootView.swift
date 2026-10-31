// RootView.swift
//
// Split-view shell.  On iPad the sidebar stays visible; on iPhone the same
// structure collapses into a navigation stack.

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationView {
            List {
                ForEach(Screen.allCases) { screen in
                    Button {
                        model.screen = screen
                    } label: {
                        HStack {
                            Label(screen.title, systemImage: screen.systemImage)
                            Spacer()
                            if model.screen == screen {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(L("app.title"))
            .safeAreaInset(edge: .bottom) {
                statusFooter
            }

            detailView
        }
        .navigationViewStyle(.columns)
    }

    @ViewBuilder
    private var detailView: some View {
        Group {
            switch model.screen {
            case .builder: BuilderView()
            case .results: ResultsView()
            case .history: HistoryView()
            case .orbitals: OrbitalsScreen()
            case .density: DensityScreen()
            case .table: ElementsView()
            case .diagnostics: DiagnosticsScreen()
            }
        }
        .navigationTitle(model.screen.title)
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let caps = model.capabilities {
                Label(
                    caps.engine.available ? L("engine.online") : L("engine.unavailable"),
                    systemImage: caps.engine.available ? "checkmark.seal.fill" : "xmark.seal"
                )
                .foregroundStyle(caps.engine.available ? Color.green : Color.red)
                Text(LF("engine.versions", caps.engine.version, caps.engine.numpyVersion))
                Text(LF("engine.protocol", caps.protocolVersion, caps.packageVersion))
                if let threads = caps.engine.threads {
                    Text(LF("engine.threads", threads))
                } else if let reason = caps.engine.threadsError {
                    Text(LF("engine.threadsUnknown", reason))
                        .foregroundStyle(.orange)
                }
                if !caps.engine.available {
                    // Show why, rather than only that it failed. On a device this
                    // footer is often the only feedback available.
                    Text(caps.engine.error ?? L("engine.noReason"))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } else {
                Label(L("engine.starting"), systemImage: "hourglass")
                Text(L("engine.booting"))
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.bar)
    }
}

/// Shows the interpreter report and the log file locations.
///
/// Reached from the sidebar. The report is collected from inside the embedded
/// interpreter, which is the only way to see the runtime state on a device: the
/// iOS extension modules will not load on the build host.
struct DiagnosticsScreen: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Panel(title: L("diag.logFiles"), systemImage: "doc.text") {
                    VStack(alignment: .leading, spacing: 6) {
                        if model.logLocations.isEmpty {
                            Text(L("diag.noLogLocation"))
                        } else {
                            ForEach(model.logLocations, id: \.self) { path in
                                Text(path)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                Panel(title: L("diag.engineStatus"), systemImage: "stethoscope") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let caps = model.capabilities {
                            Text(LF("diag.available", caps.engine.available ? L("common.yes") : L("common.no")))
                            if let error = caps.engine.error {
                                Text(error).foregroundStyle(.red).textSelection(.enabled)
                            }
                            if let traceback = caps.engine.traceback {
                                Text(traceback)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        } else {
                            Text(L("diag.capsNotLoaded"))
                        }
                    }
                }

                Panel(title: L("diag.interpreterReport"), systemImage: "curlybraces") {
                    VStack(alignment: .leading, spacing: 8) {
                        Button(L("diag.collectAgain")) {
                            Task { await model.captureDiagnostics() }
                        }
                        if model.diagnostics.isEmpty {
                            Text(L("diag.notCollected"))
                        } else {
                            Text(model.diagnostics)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }

                Panel(title: L("diag.openmp"), systemImage: "cpu") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("diag.openmpHint"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button(L("diag.runProbe")) {
                                Task { await model.probeOpenMP() }
                            }
                            .disabled(model.isBusy)
                            Button(L("diag.reloadLog")) { model.refreshDeviceLog() }
                            Button(L("diag.clearLog"), role: .destructive) { model.clearDeviceLog() }
                        }
                        if model.openmpReport.isEmpty {
                            Text(L("diag.probeNotRun"))
                        } else {
                            Text(model.openmpReport)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }

                Panel(title: L("diag.deviceLog"), systemImage: "doc.plaintext") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("diag.deviceLogHint"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if model.deviceLog.isEmpty {
                            Text(L("diag.deviceLogEmpty"))
                        } else {
                            // Bottom-anchored: when a run crashes, the answer is
                            // in the last few lines, so they are shown first.
                            ScrollView {
                                Text(model.deviceLog)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 320)
                        }
                    }
                }
            }
            .padding()
        }
        .onAppear { model.refreshDeviceLog() }
    }
}

/// Dedicated orbital view, reachable from the sidebar independently of Results.
struct OrbitalsScreen: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let result = model.result {
                    Panel(title: LF("orbitals.ladder", result.method), systemImage: "waveform.path.ecg") {
                        OrbitalEnergyChart(
                            energies: result.orbitalEnergies,
                            occupations: result.occupations,
                            homo: result.homo,
                            lumo: result.lumo
                        )
                    }
                    Panel(title: L("orbitals.occupations"), systemImage: "circle.grid.2x2") {
                        ForEach(Array(result.occupations.enumerated()), id: \.offset) { index, occupation in
                            MetricRow(label: "MO \(index + 1)", value: String(format: "%.3f", occupation))
                        }
                    }
                    orbitalViewerPanel(result)
                } else {
                    Panel(title: L("orbitals.empty.title"), systemImage: "hourglass") {
                        Text(L("orbitals.empty.body"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L("screen.orbitals"))
    }

    /// The orbital viewer: the molecule in 3D with the orbital drawn into it.
    ///
    /// The picture is the familiar one: the whole molecule, with a translucent
    /// envelope around each lobe of the chosen orbital at its real position.
    /// The orbital is fetched on selection rather than with the run, so the
    /// selector is a list of buttons rather than a picker bound to the model:
    /// choosing one has to start a request, and a picker would appear to have
    /// already switched to a surface that has not arrived.
    @ViewBuilder
    private func orbitalViewerPanel(_ result: ScfResult) -> some View {
        Panel(title: L("orbitals.viewer"), systemImage: "cube.transparent") {
            if result.orbitalEnergies.isEmpty {
                Text(L("orbitals.viewer.unavailable"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(L("orbitals.viewer.hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                sourcePicker(result)

                valenceScopePicker(result)

                if model.orbitalSource == "mo" {
                    orbitalSelector(result)
                } else {
                    localisedSelector(result)
                }

                viewerNotices()

                // The molecule and the orbital share one scene, so the envelope
                // is drawn at its correct place in the molecule rather than in
                // a frame of its own.
                MoleculeView(
                    geometry: model.geometry,
                    elementTable: model.elements,
                    surface: model.orbitalSurface,
                    showsOrbital: model.showsOrbital,
                    orbitalOpacity: model.orbitalOpacity)
                    .frame(minHeight: 320)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                // The two sliders are grouped because a view builder takes at
                // most ten children and this panel is at the limit.
                Group {
                    isovalueControls()
                    opacityControls()
                }

                surfaceDetail()
            }
        }
    }

    /// What the viewer has to say about the request in flight, or about the
    /// surface on screen.
    ///
    /// Grouped into one child of the panel because the panel is at the ten-view
    /// limit of a builder, and these are the messages that come and go.
    @ViewBuilder
    private func viewerNotices() -> some View {
        if model.isLoadingOrbital {
            HStack(spacing: 8) {
                ProgressView()
                Text(L("orbitals.viewer.loading"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        // A localisation request that fails used to leave the viewer unchanged,
        // so a button that could not be served looked like one that did nothing
        // when tapped.  The message is shown here as well as on the builder page.
        if let message = model.errorMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }

        // A surface the grid could not contain is cut off at the box wall, which
        // reads as the orbital spilling over the molecule.  Say so rather than
        // let it look like a real shape.
        if let surface = model.orbitalSurface, surface.clipped {
            Text(L("orbitals.viewer.clipped"))
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The numbers for the surface on screen: which orbital, the mesh it was
    /// drawn as, and what it is made of.
    @ViewBuilder
    private func surfaceDetail() -> some View {
        if let surface = model.orbitalSurface {
            MetricRow(
                label: L("orbitals.viewer.orbital"),
                value: "\(surface.label) · "
                    + String(format: "%.5f", surface.orbitalEnergy)
                    + " Ha · " + String(format: "%.2f", surface.occupation) + " e")
            MetricRow(
                label: L("orbitals.viewer.surface"),
                value: LF("orbitals.viewer.surfaceDetail",
                          surface.triangleCount,
                          String(format: "%.4f", surface.isovalue))
            )
            compositionPanel(surface.composition)
            Text(L("orbitals.viewer.note"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Chooses between the canonical MOs and the localised orbitals.
    ///
    /// A localised orbital is the one that reads as a bond or a lone pair; the
    /// canonical MOs are the delocalised ones the ladder shows.  Both are drawn
    /// the same way, so this only changes which coefficients the envelope comes
    /// from.
    @ViewBuilder
    private func sourcePicker(_ result: ScfResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("orbitals.viewer.source"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(L("orbitals.viewer.source"), selection: Binding(
                get: { model.orbitalSource },
                set: { choice in
                    // Switching source changes what the index means, so the old
                    // selection is cleared rather than carried over.  The model
                    // does that and abandons any request still in flight for the
                    // previous source.
                    model.selectOrbitalSource(choice)
                }
            )) {
                Text(L("orbitals.viewer.source.mo")).tag("mo")
                Text(L("orbitals.viewer.source.pm")).tag("pm-mulliken")
                Text(L("orbitals.viewer.source.boys")).tag("boys")
                Text(L("orbitals.viewer.source.er")).tag("er")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// Chooses whether the list offers every orbital or only the valence ones.
    ///
    /// The two answers differ by the core orbitals: for water that is the
    /// oxygen 1s alone, and the valence list is the picture of the bonding.  The
    /// control is offered only when there is something to hide and the
    /// classification is known, so a molecule with no core -- hydrogen -- and a
    /// list the engine has not classified yet are not given a switch that would
    /// do nothing or, worse, claim a number it does not have.
    @ViewBuilder
    private func valenceScopePicker(_ result: ScfResult) -> some View {
        if let scope = valenceScope(result), scope.valence < scope.total {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("orbitals.viewer.scope"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(L("orbitals.viewer.scope"), selection: $model.showsValenceOnly) {
                    Text(L("orbitals.viewer.scope.all")).tag(false)
                    Text(L("orbitals.viewer.scope.valence")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(LF("orbitals.viewer.scope.hidden", scope.total - scope.valence))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// How many orbitals the current source offers, and how many are valence.
    ///
    /// ``nil`` when the source has not been classified, which is the localised
    /// case before anything has been drawn: those columns come out of a rotation
    /// the run payload does not describe, so they are classified by the surface
    /// the engine last drew.  Reporting a count of zero there would say every
    /// orbital is core, which is why the caller is given nothing to show rather
    /// than a number to trust.
    private func valenceScope(_ result: ScfResult) -> (total: Int, valence: Int)? {
        if model.orbitalSource == "mo" {
            guard let compositions = result.orbitalCompositions,
                  !compositions.valenceOrbitals.isEmpty else { return nil }
            return (compositions.orbitals.count, compositions.valenceOrbitals.count)
        }
        guard let surface = model.orbitalSurface,
              surface.source == model.orbitalSource,
              !surface.valenceOrbitals.isEmpty else { return nil }
        return (max(result.nLocalizedOrbitals, 0), surface.valenceOrbitals.count)
    }

    /// One orbital button, shared by both selectors.
    ///
    /// The two lists were separate before and only one of them checked the
    /// source it belonged to, so switching source left the highlight on a button
    /// of the list that was no longer shown, and a tap could look unanswered.
    /// Both now go through here, which decides the highlight from the source and
    /// the index together.
    ///
    /// The frame is given a 44-point minimum in both directions, the size a
    /// touch target needs to be, because the old label was a bare number and
    /// came out far smaller than that.
    ///
    /// The label arrives already built rather than as a builder closure, because
    /// this toolchain's Swift does not accept a result-builder attribute on a
    /// parameter of function type.
    private func orbitalButton<Label: View>(
        index: Int,
        source: String,
        action: @escaping () -> Void,
        label: Label
    ) -> some View {
        let isSelected = model.viewedOrbital == index && model.orbitalSource == source
        let isPending = model.pendingOrbital == index && model.pendingOrbitalSource == source
        return Button(action: action) {
            label
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(minWidth: 44, minHeight: 44)
                .background(
                    isPending ? Color.accentColor.opacity(0.4)
                        : (isSelected ? Color.accentColor.opacity(0.25)
                            : Color(.secondarySystemBackground)),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay {
                    // A ring while the surface is being computed, so the wait is
                    // visible on the button that was tapped rather than only in
                    // the progress row above the list.
                    if isPending {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.accentColor, lineWidth: 2)
                    }
                }
                // Without this the tap only lands on the drawn glyph, which is a
                // small fraction of the button's frame.
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(isPending)
    }

    /// The label of one canonical-orbital button.
    ///
    /// Split out of the list because the whole thing inlined is more than the
    /// compiler will type-check in a reasonable time: the composition branch
    /// alone nests three optional bindings inside a view builder.
    @ViewBuilder
    private func canonicalButtonLabel(
        index: Int,
        energy: Double,
        occupation: Double,
        composition: OrbitalComposition?
    ) -> some View {
        VStack(spacing: 2) {
            Text("\(index + 1)").font(.caption.monospacedDigit().bold())
            Text(String(format: "%.3f", energy))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            if let composition = composition, composition.isCore {
                // Marks the orbital the valence option hides, so "All" still
                // says which ones those are rather than leaving the difference
                // to be inferred.
                Text(L("orbitals.viewer.coreBadge"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if let composition = composition, let dominant = composition.dominant {
                Text(dominant)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let percent = composition.dominantPercent {
                    Text(String(format: "%.0f%%", percent))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            // A dot marks the occupied orbitals, so the virtual ones are not
            // mistaken for electrons.
            if occupation > 0.5 {
                Circle().fill(Color.accentColor)
                    .frame(width: 5, height: 5)
                    .padding(3)
            }
        }
    }

    /// The canonical molecular orbitals, in the ladder's own numbering.
    @ViewBuilder
    private func orbitalSelector(_ result: ScfResult) -> some View {
        let indices = result.orbitalCompositions?.indices(showingCore: !model.showsValenceOnly)
            ?? Array(result.orbitalEnergies.indices)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(indices, id: \.self) { index in
                    let energy = index < result.orbitalEnergies.count
                        ? result.orbitalEnergies[index] : 0
                    let occupation = index < result.occupations.count
                        ? result.occupations[index] : 0
                    // The composition travels with the run, so each button can
                    // say what the orbital is made of before it is drawn.  A
                    // payload that skipped the population analysis has none, and
                    // the button then shows the energy alone as it used to.
                    let composition = result.orbitalCompositions?.composition(of: index)
                    orbitalButton(
                        index: index,
                        source: "mo",
                        action: { Task { await model.loadOrbital(index, source: "mo") } },
                        label: canonicalButtonLabel(
                            index: index,
                            energy: energy,
                            occupation: occupation,
                            composition: composition))
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// The localised occupied orbitals, one button each.
    ///
    /// The count is one per occupied orbital, which is half the electron count
    /// only for a closed shell: an open-shell reference has a singly occupied
    /// orbital per unpaired electron as well.  The engine sends the count
    /// because it is the one that knows which of the occupied columns are
    /// localisable.
    @ViewBuilder
    private func localisedSelector(_ result: ScfResult) -> some View {
        let count = max(result.nLocalizedOrbitals, 0)
        if count == 0 {
            Text(L("orbitals.viewer.localisation.unavailable"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            // The valence columns of a localised source come from the surface
            // the engine last drew, because the run payload describes the
            // canonical ladder.  Until one has been drawn every column is
            // offered, which is what the list did before the filter existed.
            let surface = model.orbitalSurface?.source == model.orbitalSource
                ? model.orbitalSurface : nil
            let valence = Set(surface?.valenceOrbitals ?? [])
            let indices = (model.showsValenceOnly && !valence.isEmpty)
                ? (0..<count).filter { valence.contains($0) }
                : Array(0..<count)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(indices, id: \.self) { index in
                        orbitalButton(
                            index: index,
                            source: model.orbitalSource,
                            action: {
                                let source = model.orbitalSource
                                Task { await model.loadOrbital(index, source: source) }
                            },
                            label: Text("\(index + 1)")
                                .font(.caption.monospacedDigit().bold()))
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// The isovalue slider, which is what sets how much of the orbital is
    /// enclosed.
    ///
    /// The value is a fraction of the orbital's own peak rather than an absolute
    /// amplitude, so the same setting gives a comparable envelope whatever the
    /// basis set and however the orbital is scaled.  A larger fraction encloses
    /// less of the orbital and gives a tighter envelope.
    @ViewBuilder
    private func isovalueControls() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("orbitals.viewer.isovalue"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.3f", model.isovalueFraction))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Slider(value: $model.isovalueFraction, in: 0.01...0.2, step: 0.005) {
                    Text(L("orbitals.viewer.isovalue"))
                }
                .onChange(of: model.isovalueFraction) { _ in
                    model.scheduleOrbitalRedraw()
                }

                Toggle(L("orbitals.viewer.show"), isOn: $model.showsOrbital)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
    }

    /// The transparency slider for the orbital envelope.
    ///
    /// Purely a render setting: the value is applied to the material already on
    /// screen, so dragging it does not refetch the surface and the picture
    /// follows the finger.  The molecule sits inside the envelope, so the useful
    /// direction is towards transparent -- an opaque envelope hides the atoms it
    /// is meant to be placed around.
    @ViewBuilder
    private func opacityControls() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("orbitals.viewer.opacity"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", model.orbitalOpacity * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Image(systemName: "circle.dotted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(
                    value: $model.orbitalOpacity,
                    in: MoleculeLayout.minimumOrbitalOpacity...MoleculeLayout.maximumOrbitalOpacity
                ) {
                    Text(L("orbitals.viewer.opacity"))
                }
                Image(systemName: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What the drawn orbital is made of, strongest contribution first.
    ///
    /// The share is a signed Mulliken population, so an antibonding component is
    /// negative and is shown as such rather than as a magnitude: the sign is the
    /// bonding information.  The total is shown alongside as the reader's own
    /// check, because a correct orbital's shares sum to 100.
    @ViewBuilder
    private func compositionPanel(_ composition: OrbitalComposition?) -> some View {
        if let composition = composition, !composition.components.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L("orbitals.viewer.composition"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(LF("orbitals.viewer.compositionTotal",
                            String(format: "%.0f", composition.total)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ForEach(composition.components) { component in
                    HStack(spacing: 8) {
                        Text("\(component.element)\(component.atom + 1) \(component.angular)")
                            .font(.caption.monospacedDigit())
                        Spacer(minLength: 8)
                        // A bar makes the comparison between components visible
                        // without reading the numbers.  Width is the magnitude,
                        // colour carries the sign: a negative share is an
                        // antibonding contribution, not a small one.
                        Capsule()
                            .fill(component.percent < 0 ? Color.orange : Color.accentColor)
                            .frame(width: max(2, abs(component.percent) * 0.9), height: 6)
                        Text(String(format: "%+.1f%%", component.percent))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(L("orbitals.viewer.compositionNote"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
