// DensityView.swift
//
// The Density screen: the molecule in 3D with its electron density drawn around
// it as nested isosurfaces, coloured along one ramp.
//
// This is the same picture the orbital viewer draws -- a translucent envelope
// over the ball-and-stick model -- but for the total density rather than a
// single orbital.  The density is a positive field, so there are no two phases
// to colour: instead each absolute level the engine drew is a separate shell,
// and the ramp from red (densest) through orange, yellow and green to blue
// (most diffuse) is what turns the nesting into a readable gradient.
//
// The meshes come from ``PySCFEngine/densitySurface`` on demand rather than
// riding along with the run, so a run that never opens this screen never pays
// for the surface.
//
// ``DensitySliceView`` below is the older plane-through-the-cube renderer.  It
// is kept because the cube still arrives with a run when the builder's "Density
// cube" switch is on, and a slice answers a different question -- what the
// density looks like on a cut plane -- which the shells cannot.

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

    /// Maps a normalised intensity to an RGB tuple, through the shared ramp.
    ///
    /// Routed through ``DensityPalette`` rather than carrying its own stops, so
    /// the slice and the 3D shells colour the same value the same way.  The
    /// slice runs dark at zero, which the 3D ramp does not need to: a shell only
    /// exists where the density is above a level, while the slice draws the
    /// whole plane including the empty space between molecules.
    static func colour(for intensity: Double) -> (UInt8, UInt8, UInt8, UInt8) {
        let value = min(max(intensity, 0), 1)
        if value <= 0.001 { return (2, 2, 12, 255) }
        let rgb = DensityPalette.colour(at: value)
        return (UInt8(rgb.red * 255), UInt8(rgb.green * 255), UInt8(rgb.blue * 255), 255)
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
            Text(L("density.emptyShells"))
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// How many shells the picture is drawn with.
    ///
    /// A discrete choice rather than a slider: each step is a full mean-field
    /// solve and a fresh set of meshes, so a continuous control would queue
    /// requests faster than they can be answered.
    @ViewBuilder
    private var detailControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("density.detail"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(L("density.detail"), selection: Binding(
                get: { model.densityDetailIndex },
                set: { index in
                    model.selectDensityLevels(AppModel.densityLevelChoices[index].levels)
                }
            )) {
                ForEach(Array(AppModel.densityLevelChoices.enumerated()), id: \.offset) { index, choice in
                    Text(L(choice.label)).tag(index)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(LF("density.detail.shells", model.densityLevels.count))
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
                value: surface.levels.map { String(format: "%.3f", $0) }.joined(separator: ", "))
            Text(L("density.note"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The colour key: which shell is which density, densest first.
    @ViewBuilder
    private var legend: some View {
        if let surface = model.densitySurface, !surface.shells.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("density.legend"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Descending level, so the list reads from the densest core down
                // to the diffuse cloud -- the same order the ramp runs.
                ForEach(Array(surface.shells.reversed().enumerated()), id: \.offset) { _, shell in
                    HStack(spacing: 8) {
                        let colour = DensityPalette.colour(at: surface.palettePosition(of: shell))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(red: colour.red, green: colour.green, blue: colour.blue))
                            .frame(width: 22, height: 12)
                        Text(String(format: "%.3f e/bohr³", shell.level))
                            .font(.caption.monospacedDigit())
                        Spacer(minLength: 8)
                        Text(LF("density.legend.triangles", shell.triangleCount))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}
