// DensityView.swift
//
// The Density screen: the molecule in 3D with its electron density drawn around
// it as one closed surface, coloured by which atom dominates each point on it.
//
// This is the same picture the orbital viewer draws -- a translucent envelope
// over the ball-and-stick model -- but for the total density rather than a
// single orbital.  The density is a positive field, so there are no two phases
// to colour; what it has instead is an owner at every point, and the colour says
// which atom's electrons dominate the density there.
//
// The meshes come from ``PySCFEngine/densitySurface`` on demand rather than
// riding along with the run, so a run that never opens this screen never pays
// for the surface.
//
// ``DensitySliceView`` below is the older plane-through-the-cube renderer.  It
// is kept because the cube still arrives with a run when the builder's "Density
// cube" switch is on, and a slice answers a different question -- what the
// density looks like on a cut plane -- which the surface cannot.

import SwiftUI

/// Heatmap of a single plane through the density cube.
///
/// The cube is flattened C-order over (nx, ny, nz), so a fixed z index yields
/// one xy-plane that maps directly onto a bitmap.
struct DensitySliceView: View {
    let grid: DensityGrid
    /// Plane index along the fastest-varying axis (z).
    let zIndex: Int

    private var image: UIImage? {
        guard grid.shape.count == 3 else { return nil }
        let (nx, ny, nz) = (grid.shape[0], grid.shape[1], grid.shape[2])
        guard nx > 0, ny > 0, nz > 0, zIndex >= 0, zIndex < nz else { return nil }
        let peak = grid.values.max() ?? 1
        guard peak > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: nx * ny * 4)
        for x in 0..<nx {
            for y in 0..<ny {
                // Flip y so the origin sits at the bottom-left of the view.
                let sourceY = ny - 1 - y
                let value = grid.value(x: x, y: sourceY, z: zIndex) ?? 0
                let (r, g, b, a) = DensitySliceView.colour(for: value / peak)
                let offset = (y * nx + x) * 4
                pixels[offset] = r
                pixels[offset + 1] = g
                pixels[offset + 2] = b
                pixels[offset + 3] = a
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                width: nx, height: ny,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: nx * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil,
                shouldInterpolate: true, intent: .defaultIntent
              )
        else { return nil }
        return UIImage(cgImage: cgImage)
    }

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(CGFloat(grid.shape[0]) / CGFloat(max(grid.shape[1], 1)), contentMode: .fit)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Text(L("density.noCube"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
    }

    /// Maps a normalised intensity to an RGB tuple, through a heat ramp.
    ///
    /// The slice draws the *value* of the density across a plane, which is a
    /// different question from the 3D surface's "whose electrons are these", so
    /// it carries its own ramp rather than sharing the atom colours.  The ramp
    /// runs dark at zero because the slice draws the whole plane including the
    /// empty space between molecules, which the surface never shows.
    static func colour(for intensity: Double) -> (UInt8, UInt8, UInt8, UInt8) {
        let value = min(max(intensity, 0), 1)
        if value <= 0.001 { return (2, 2, 12, 255) }
        let rgb = ramp(at: value)
        return (UInt8(rgb.0 * 255), UInt8(rgb.1 * 255), UInt8(rgb.2 * 255), 255)
    }

    /// The slice's heat ramp: dark blue through cyan, green and yellow to red.
    ///
    /// Interpolated between fixed stops rather than evaluated from a formula, so
    /// the same value always maps to the same colour.
    static func ramp(at position: Double) -> (Double, Double, Double) {
        let stops: [(Double, Double, Double, Double)] = [
            (0.00, 0.05, 0.05, 0.35),
            (0.25, 0.05, 0.55, 0.85),
            (0.50, 0.15, 0.80, 0.35),
            (0.75, 0.95, 0.85, 0.15),
            (1.00, 0.90, 0.15, 0.10),
        ]
        let clamped = min(max(position, 0), 1)
        for index in 1..<stops.count where clamped <= stops[index].0 {
            let lower = stops[index - 1]
            let upper = stops[index]
            let span = upper.0 - lower.0
            let t = span > 0 ? (clamped - lower.0) / span : 0
            return (lower.1 + (upper.1 - lower.1) * t,
                    lower.2 + (upper.2 - lower.2) * t,
                    lower.3 + (upper.3 - lower.3) * t)
        }
        let last = stops[stops.count - 1]
        return (last.1, last.2, last.3)
    }
}

/// The 3D density picture: the molecule with its density cloud around it.
struct DensityScreen: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if model.result != nil {
                    cloudPanel
                } else {
                    Panel(title: L("density.title"), systemImage: "circle.hexagongrid") {
                        Text(L("density.empty"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L("screen.density"))
        .task {
            // The cloud is fetched when the screen appears rather than with the
            // run: it is a second round trip, and a run that never opens this
            // screen should not pay for the mesh.
            if model.densitySurface == nil, !model.isLoadingDensity {
                await model.loadDensitySurface()
            }
        }
    }

    // MARK: - Panels

    private var cloudPanel: some View {
        Panel(title: L("density.title"), systemImage: "circle.hexagongrid") {
            Text(L("density.blurb"))
                .font(.caption)
                .foregroundStyle(.secondary)

            MoleculeView(
                geometry: model.geometry,
                elementTable: model.elements,
                density: model.densitySurface,
                showsDensity: model.showsDensity,
                densityOpacity: model.densityOpacity)
                .frame(minHeight: 340)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            notices

            Group {
                detailControls
                opacityControls
            }

            surfaceDetail
            legend
        }
    }

    /// What the screen has to say about the request in flight, or the cloud on
    /// screen.  Grouped because the panel is at the ten-view builder limit.
    @ViewBuilder
    private var notices: some View {
        if model.isLoadingDensity {
            HStack(spacing: 8) {
                ProgressView()
                Text(L("density.loading"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if let message = model.errorMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        // A cloud the grid could not contain is cut off at the box wall, which
        // reads as the density filling the whole view rather than as a cloud
        // around the molecule.  Say so rather than let it look like a shape.
        if let surface = model.densitySurface, surface.clipped {
            Text(L("density.clipped"))
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let surface = model.densitySurface, !surface.hasGeometry {
            Text(L("density.emptySurface"))
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Which absolute contour the surface is drawn at.
    ///
    /// A discrete choice rather than a slider: each step is a full mean-field
    /// solve and a fresh mesh, so a continuous control would queue requests
    /// faster than they can be answered.
    @ViewBuilder
    private var detailControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("density.detail"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(L("density.detail"), selection: Binding(
                get: { model.densityDetailIndex },
                set: { index in
                    model.selectDensityLevel(AppModel.densityLevelChoices[index].level)
                }
            )) {
                ForEach(Array(AppModel.densityLevelChoices.enumerated()), id: \.offset) { index, choice in
                    Text(L(choice.label)).tag(index)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(LF("density.detail.contour", model.densityLevel))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// The cloud's transparency, and whether it is drawn at all.
    @ViewBuilder
    private var opacityControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(L("density.show"), isOn: $model.showsDensity)
                .font(.caption)
            HStack(spacing: 8) {
                Image(systemName: "circle.dotted")
                    .foregroundStyle(.secondary)
                Slider(
                    value: $model.densityOpacity,
                    in: MoleculeLayout.minimumDensityOpacity...MoleculeLayout.maximumDensityOpacity)
                Image(systemName: "circle.fill")
                    .foregroundStyle(.secondary)
            }
            .disabled(!model.showsDensity)
        }
    }

    /// The numbers for the cloud on screen.
    @ViewBuilder
    private var surfaceDetail: some View {
        if let surface = model.densitySurface {
            MetricRow(label: L("density.method"), value: surface.method)
            MetricRow(
                label: L("density.cube"),
                value: "\(surface.gridPointsPerAxis)³ · "
                    + String(format: "%.3f", surface.gridStep) + " Å")
            MetricRow(
                label: L("density.surface"),
                value: LF("density.surfaceDetail", surface.triangleCount))
            MetricRow(
                label: L("density.peak"),
                value: String(format: "%.4f e/bohr³", surface.peak))
            MetricRow(
                label: L("density.levels"),
                value: String(format: "%.4f e/bohr³", surface.level))
            Text(L("density.note"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The colour key: which element each colour on the surface is.
    ///
    /// Ordered by how much of the surface the atom dominates, so the atoms that
    /// matter in the picture come first; a hydrogen buried inside a molecule can
    /// own no visible surface at all and is left out rather than listed as a
    /// colour the user will never find.
    @ViewBuilder
    private var legend: some View {
        if let surface = model.densitySurface, !surface.atoms.isEmpty {
            let counts = surface.vertexCounts
            let shown = surface.atoms
                .filter { (counts[$0.index] ?? 0) > 0 }
                .sorted { (counts[$0.index] ?? 0) > (counts[$1.index] ?? 0) }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("density.legend"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(shown) { atom in
                    HStack(spacing: 8) {
                        let colour = DensityPalette.parse(atom.colorHex)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(red: colour.red, green: colour.green, blue: colour.blue))
                            .frame(width: 22, height: 12)
                        Text(atom.element)
                            .font(.caption.monospacedDigit())
                        Spacer(minLength: 8)
                        Text(LF("density.legend.vertices", counts[atom.index] ?? 0))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}
