// DensityPalette.swift
//
// The colours the density surface is drawn in, and the mapping from a vertex's
// atom attribution to a colour.
//
// Foundation only, and no reference to SwiftUI or SceneKit: the host test
// compiles this file against the plain Linux Swift toolchain to check the
// mapping, and neither framework exists there.  A wrong colour is not visible
// in the model layer -- it renders as a perfectly valid picture in the wrong
// colours -- which is why the mapping is pinned by test rather than eyeballed
// on a device.
//
// The surface is coloured by *atom*, not by density: each vertex takes the
// colour of the atom whose electrons dominate the density there.  That is the
// picture that answers "whose electrons are these", which is what a chemist
// reads a density plot for.  Colouring by density value instead would say only
// "high here, low there", which the shape of the surface already shows.

import Foundation

/// Maps an atom attribution onto a colour for the density surface.
enum DensityPalette {

    /// An RGB triple, so the arithmetic is identical on the build host and on
    /// the device.
    struct Colour: Equatable {
        let red: Double
        let green: Double
        let blue: Double
    }

    /// The colour used when a vertex's atom is unknown.
    ///
    /// A neutral grey, chosen so it reads as "no attribution" rather than as one
    /// of the element colours: a payload missing its attribution must look
    /// unattributed, not look like it belongs to some element.
    static let fallback = Colour(red: 0.55, green: 0.55, blue: 0.58)

    /// Parses a ``#rrggbb`` string from the engine's CPK palette.
    ///
    /// Anything unparseable yields the fallback rather than black, so a bad
    /// hex string degrades to the "unattributed" colour instead of to a colour
    /// that looks deliberate.
    static func parse(_ hex: String) -> Colour {
        let text = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard text.count == 6, let value = UInt32(text, radix: 16) else {
            return fallback
        }
        return Colour(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }

    /// The colour a vertex is drawn in.
    ///
    /// ``share`` is the dominant atom's fraction of the local density.  A
    /// vertex sitting squarely on one atom has a share near 1 and takes that
    /// atom's colour; one on a bond has a lower share, and is mixed toward a
    /// neutral tone so the seam between two atoms reads as a blend rather than
    /// as a hard border belonging to one of them.
    ///
    /// The mix is deliberately shallow: the atom's own colour always dominates,
    /// because the point of the picture is which atom a region belongs to, and
    /// a heavy mix would wash every atom toward the same grey.
    static func colour(forAtom colour: Colour, share: Double) -> Colour {
        let weight = share.isFinite ? min(max(share, 0), 1) : 1
        // At share 1 the atom's colour is untouched; below it the colour moves
        // toward the neutral tone by at most this fraction.
        let maximumMix = 0.35
        let mix = (1.0 - weight) * maximumMix
        return Colour(
            red: colour.red + (fallback.red - colour.red) * mix,
            green: colour.green + (fallback.green - colour.green) * mix,
            blue: colour.blue + (fallback.blue - colour.blue) * mix
        )
    }
}
