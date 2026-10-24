// PlotViews.swift
//
// Lightweight SwiftUI charts.  PySCF's outputs here are small (tens of points),
// so plain ``Path`` drawing avoids pulling in a charting dependency.

import SwiftUI

/// Horizontal bar chart used for the orbital energy ladder.
struct OrbitalEnergyChart: View {
    let energies: [Double]
    let occupations: [Double]
    let homo: Double?
    let lumo: Double?

    private var range: ClosedRange<Double> {
        let values = energies.isEmpty ? [0.0] : energies
        let low = min(values.min() ?? 0, 0)
        let high = max(values.max() ?? 0, 0.01)
        let padding = (high - low) * 0.08
        return (low - padding)...(high + padding)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let bounds = range
                let rowHeight = max(6.0, min(16.0, geo.size.height / Double(max(energies.count, 1))))
                let zeroX = x(for: 0, in: geo.size.width, bounds: bounds)

                ZStack(alignment: .topLeading) {
                    // Zero line
                    Rectangle()
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 1)
                        .offset(x: zeroX)

                    ForEach(Array(energies.enumerated()), id: \.offset) { index, energy in
                        let occupied = index < occupations.count ? occupations[index] > 0 : false
                        let valueX = x(for: energy, in: geo.size.width, bounds: bounds)
                        let start = min(zeroX, valueX)
                        let width = max(abs(valueX - zeroX), 1)

                        RoundedRectangle(cornerRadius: 2)
                            .fill(color(for: energy, occupied: occupied))
                            .frame(width: width, height: rowHeight * 0.7)
                            .offset(x: start, y: Double(index) * rowHeight)
                    }
                }
            }
            .frame(height: CGFloat(energies.count) * 16 + 8)

            HStack(spacing: 14) {
                legend(color: .accentColor, text: "occupied")
                legend(color: .orange, text: "virtual")
                if let homo = homo, let lumo = lumo {
                    Text("HOMO \(String(format: "%.4f", homo)) · LUMO \(String(format: "%.4f", lumo))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func x(for energy: Double, in width: Double, bounds: ClosedRange<Double>) -> Double {
        let span = bounds.upperBound - bounds.lowerBound
        guard span > 0 else { return width / 2 }
        return (energy - bounds.lowerBound) / span * width
    }

    private func color(for energy: Double, occupied: Bool) -> Color {
        if occupied { return .accentColor }
        return .orange
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 8)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Potential-energy surface curve for a bond scan.
struct BondScanChart: View {
    let scan: BondScanResult

    private var usable: [(r: Double, e: Double)] {
        scan.points.compactMap { point in
            guard let energy = point.energy else { return nil }
            return (point.r, energy)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let points = usable
                if points.count >= 2 {
                    let xLow = points.first!.r
                    let xSpan = max(points.last!.r - xLow, 1e-9)
                    let energies = points.map(\.e)
                    let low = energies.min() ?? 0
                    let span = max((energies.max() ?? 1) - low, 1e-6)
                    let width = geo.size.width
                    let height = geo.size.height

                    ZStack(alignment: .topLeading) {
                        Path { path in
                            for (index, point) in points.enumerated() {
                                let position = plotPoint(r: point.r, e: point.e,
                                                         xLow: xLow, xSpan: xSpan,
                                                         low: low, span: span,
                                                         width: width, height: height)
                                if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
                            }
                        }
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineJoin: .round))

                        ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 5, height: 5)
                                .position(plotPoint(r: point.r, e: point.e,
                                                    xLow: xLow, xSpan: xSpan,
                                                    low: low, span: span,
                                                    width: width, height: height))
                        }

                        if let minimumR = scan.minimumR,
                           let minimumEnergy = scan.minimumEnergy {
                            Circle()
                                .stroke(Color.red, lineWidth: 2)
                                .frame(width: 11, height: 11)
                                .position(plotPoint(r: minimumR, e: minimumEnergy,
                                                    xLow: xLow, xSpan: xSpan,
                                                    low: low, span: span,
                                                    width: width, height: height))
                        }
                    }
                } else {
                    Text("Not enough converged points to plot")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 190)

            if let r = scan.minimumR, let e = scan.minimumEnergy {
                Text("Minimum: \(formatLength(r)) at \(formatHartree(e))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Maps a (distance, energy) pair to a view coordinate.
    private func plotPoint(
        r: Double, e: Double,
        xLow: Double, xSpan: Double,
        low: Double, span: Double,
        width: Double, height: Double
    ) -> CGPoint {
        let x = (r - xLow) / xSpan * width
        let y = height - (e - low) / span * (height * 0.9) - height * 0.05
        return CGPoint(x: x, y: y)
    }
}

/// Single-value gauge used for the HOMO–LUMO gap.
struct GapIndicator: View {
    let gap: Double?

    var body: some View {
        if let gap = gap {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.and.down")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("HOMO–LUMO gap").font(.caption).foregroundStyle(.secondary)
                    Text(formatEnergyDelta(gap)).font(.subheadline.monospacedDigit().bold())
                }
            }
        }
    }
}
