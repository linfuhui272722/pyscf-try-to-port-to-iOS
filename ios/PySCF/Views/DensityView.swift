// DensityView.swift
//
// Renders a slice of the electron-density cube the engine returns for
// ``include: ["grid"]``.  The cube is flattened C-order over (nx, ny, nz), so a
// fixed z index yields one xy-plane that maps directly onto a bitmap.

import SwiftUI

/// Heatmap of a single plane through the density cube.
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

    /// Maps a normalised intensity to an RGB tuple (dark blue → cyan → yellow → red).
    private static func colour(for intensity: Double) -> (UInt8, UInt8, UInt8, UInt8) {
        let value = min(max(intensity, 0), 1)
        let stops: [(Double, (Double, Double, Double))] = [
            (0.00, (0.02, 0.02, 0.12)),
            (0.25, (0.05, 0.25, 0.75)),
            (0.50, (0.10, 0.75, 0.80)),
            (0.75, (0.95, 0.85, 0.20)),
            (1.00, (0.95, 0.20, 0.10)),
        ]
        for index in 1..<stops.count where value <= stops[index].0 {
            let (lowT, lowC) = stops[index - 1]
            let (highT, highC) = stops[index]
            let t = (value - lowT) / max(highT - lowT, 1e-9)
            let r = lowC.0 + (highC.0 - lowC.0) * t
            let g = lowC.1 + (highC.1 - lowC.1) * t
            let b = lowC.2 + (highC.2 - lowC.2) * t
            return (UInt8(r * 255), UInt8(g * 255), UInt8(b * 255), 255)
        }
        let last = stops[stops.count - 1].1
        return (UInt8(last.0 * 255), UInt8(last.1 * 255), UInt8(last.2 * 255), 255)
    }
}

/// A single plane through an orbital cube, coloured by phase.
///
/// An orbital differs from the density in that it is signed: the two lobes are
/// opposite phases, and a picture that coloured them the same would be
/// misleading.  So the two signs get contrasting hues and the magnitude sets
/// the saturation, with a near-zero band left transparent so the node planes
/// are visible rather than painted over.
struct OrbitalSliceView: View {
    let cube: OrbitalCube
    let zIndex: Int

    private var image: UIImage? {
        let shape = cube.grid.shape
        guard shape.count == 3 else { return nil }
        let (nx, ny, nz) = (shape[0], shape[1], shape[2])
        guard nx > 0, ny > 0, nz > 0, zIndex >= 0, zIndex < nz else { return nil }

        var pixels = [UInt8](repeating: 0, count: nx * ny * 4)
        for x in 0..<nx {
            for y in 0..<ny {
                // Flip y so the origin sits at the bottom-left of the view.
                let sourceY = ny - 1 - y
                let amplitude = cube.amplitude(x: x, y: sourceY, z: zIndex) ?? 0
                let (r, g, b, a) = OrbitalSliceView.colour(forAmplitude: amplitude)
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
                    .aspectRatio(CGFloat(cube.grid.shape[0]) / CGFloat(max(cube.grid.shape[1], 1)),
                                 contentMode: .fit)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Text(L("orbitals.noCube"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
    }

    /// Maps a signed amplitude in -1...1 to a premultiplied RGBA tuple.
    ///
    /// Positive phase is red, negative is blue.  Below ``nodeThreshold`` the
    /// alpha fades out, so a slice through a node plane shows the atom rather
    /// than a flat wash of colour.
    static func colour(forAmplitude amplitude: Double) -> (UInt8, UInt8, UInt8, UInt8) {
        let clamped = min(max(amplitude, -1), 1)
        let magnitude = abs(clamped)
        let nodeThreshold = 0.08
        guard magnitude > nodeThreshold else { return (0, 0, 0, 0) }
        // Ramp from the threshold to full, so the lobes have a visible edge
        // instead of appearing at full strength one voxel out from the node.
        let ramp = (magnitude - nodeThreshold) / (1 - nodeThreshold)
        let intensity = min(max(ramp, 0), 1)
        let alpha = UInt8(intensity * 255)
        if clamped > 0 {
            return (UInt8(220 * intensity), UInt8(60 * intensity), UInt8(60 * intensity), alpha)
        }
        return (UInt8(60 * intensity), UInt8(90 * intensity), UInt8(230 * intensity), alpha)
    }
}

/// Slice selector plus the rendered plane.
struct DensityScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var zIndex: Double = 0

    private var grid: DensityGrid? { model.result?.grid }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let grid = grid, grid.shape.count == 3 {
                    Panel(title: L("density.title"), systemImage: "square.grid.3x3") {
                        DensitySliceView(grid: grid, zIndex: Int(zIndex))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LF("density.plane", Int(zIndex) + 1, grid.shape[2]))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Slider(value: $zIndex, in: 0...Double(max(grid.shape[2] - 1, 1)), step: 1)
                        }
                        Divider()
                        MetricRow(label: L("density.cube"), value: "\(grid.shape[0]) × \(grid.shape[1]) × \(grid.shape[2])")
                        MetricRow(label: L("density.voxels"), value: "\(grid.count)")
                        MetricRow(label: L("density.peak"), value: String(format: "%.4f", grid.values.max() ?? 0))
                        MetricRow(label: L("density.origin"), value: grid.origin.map { String(format: "%.2f", $0) }.joined(separator: ", "))
                        MetricRow(label: L("density.step"), value: grid.step.map { String(format: "%.3f", $0) }.joined(separator: ", "))
                    }
                } else {
                    Panel(title: L("density.title"), systemImage: "square.grid.3x3") {
                        DensitySliceView(grid: DensityGrid(JSONObject([:])), zIndex: 0)
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L("screen.density"))
    }
}
