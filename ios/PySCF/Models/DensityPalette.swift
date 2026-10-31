// DensityPalette.swift
//
// The colour ramp the density surface is drawn in, and the mapping from a
// vertex's density to a position on it.
//
// Foundation only, and no reference to SwiftUI or SceneKit: the host test
// compiles this file against the plain Linux Swift toolchain to check the ramp
// and the mapping, and neither framework exists there.  A wrong ramp is not
// visible in the model layer -- it renders as a perfectly valid picture in the
// wrong colours -- which is why the mapping is pinned by test rather than
// eyeballed on a device.
//
// The ramp runs red -> orange -> yellow -> green -> blue, high density first,
// with every neighbouring pair of stops interpolated so there is no banding
// between them.

import Foundation

/// The red-to-blue ramp the density surface is drawn in.
///
/// The stops are the familiar rainbow, high density at the red end.  They are
/// stored as RGB triples rather than platform colours so the arithmetic is
/// identical on the build host and on the device.
enum DensityPalette {

    /// One stop of the ramp: a position from 0 to 1, and its colour.
    struct Stop: Equatable {
        let position: Double
        let red: Double
        let green: Double
        let blue: Double

        init(_ position: Double, _ red: Double, _ green: Double, _ blue: Double) {
            self.position = position
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// The ramp, ascending in position.
    ///
    /// Chosen so the five named colours are evenly spaced and the steps between
    /// them are perceptually similar: red at the densest region, then orange,
    /// yellow and green through the bonding region, and blue for the diffuse
    /// cloud that reaches furthest out.
    static let stops: [Stop] = [
        Stop(0.00, 0.55, 0.05, 0.06),  // deep red
        Stop(0.25, 0.93, 0.35, 0.05),  // orange
        Stop(0.50, 0.97, 0.82, 0.12),  // yellow
        Stop(0.75, 0.20, 0.72, 0.28),  // green
        Stop(1.00, 0.12, 0.34, 0.85),  // blue
    ]

    /// The ramp's colour at ``position``, clamped to its ends.
    ///
    /// Interpolates between the two bracketing stops, so every value between
    /// them is drawn and the ramp has no visible banding.
    static func colour(at position: Double) -> (red: Double, green: Double, blue: Double) {
        let value = position.isFinite ? min(max(position, 0), 1) : 0
        for index in 1..<stops.count where value <= stops[index].position {
            let low = stops[index - 1]
            let high = stops[index]
            let span = high.position - low.position
            let t = span > 0 ? (value - low.position) / span : 0
            return (
                red: low.red + (high.red - low.red) * t,
                green: low.green + (high.green - low.green) * t,
                blue: low.blue + (high.blue - low.blue) * t
            )
        }
        let last = stops[stops.count - 1]
        return (red: last.red, green: last.green, blue: last.blue)
    }

    /// Where a density sits on the ramp, 0 at the densest end and 1 at the
    /// diffuse end.
    ///
    /// The densities being shown are the ones at the nuclei, and those span
    /// orders of magnitude -- the O nucleus of water carries 193 e/bohr^3 and
    /// its H nucleus 0.24 -- so the position is taken from the logarithm, not
    /// the value.  A linear mapping would put every light atom in the first
    /// percent of the ramp and draw the whole surface red, which is exactly the
    /// information the picture is meant to carry.
    ///
    /// ``low`` and ``high`` are the extremes *on this surface*, not fixed
    /// absolute values: the interesting contrast is between the atoms of the
    /// molecule in front of the user, and the same hydrogen should read cool in
    /// water and in a heavy-metal complex.  A degenerate range collapses to the
    /// dense end rather than dividing by zero.
    static func position(of density: Double, low: Double, high: Double) -> Double {
        guard density > 0, low > 0, high > low else { return 0 }
        let logValue = log(density)
        let logLow = log(low)
        let logHigh = log(high)
        let span = logHigh - logLow
        guard span > 0 else { return 0 }
        // Highest density is at position 0, so the ramp is entered from its red
        // end as the density rises.
        return min(max((logHigh - logValue) / span, 0), 1)
    }
}
