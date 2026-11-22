import Foundation
import Testing
@testable import KhaytApp

/// Which side of the line a colour falls on.
///
/// The outline is chosen from the FILL, not from the background, and this is
/// the only part of that with an answer a test can check. A white filament on
/// a white panel outlined in `.separator` was invisible — three of the four
/// swatches on this shop's Hulk helmet showed and the fourth showed a gap.
struct SwatchTests {

    static func pale(_ hex: (Double, Double, Double)) -> Bool {
        Swatch.isPale((r: hex.0, g: hex.1, b: hex.2))
    }

    @Test("white and near-white take a dark outline")
    func paleColours() {
        #expect(Self.pale((1, 1, 1)), "#FFFFFF — the one that was invisible")
        #expect(Self.pale((0.98, 0.97, 0.94)), "natural PLA")
        #expect(Self.pale((1, 1, 0)), "yellow is pale however saturated")
    }

    @Test("black and the dark colours take a pale one")
    func darkColours() {
        #expect(!Self.pale((0, 0, 0)))
        #expect(!Self.pale((0.41, 0.45, 0.30)), "the olive on the same helmet")
        #expect(!Self.pale((0.96, 0.35, 0.45)), "the pink on it too")
    }

    /// A flat average of the channels calls pure blue light and pure green
    /// dark, and both are wrong to an eye. The green coefficient is nearly ten
    /// times the blue one for a reason.
    @Test("brightness is weighted the way an eye weights it")
    func luminanceIsPerceptual() {
        #expect(!Self.pale((0, 0, 1)), "pure blue is dark")
        #expect(Self.pale((0, 1, 0)), "pure green is not")
        #expect(!Self.pale((1, 0, 0)), "and pure red is dark")
    }

    /// The boundary is a judgement, but it must not sit where common filament
    /// colours cluster — a mid grey either way is fine, a white must not be.
    @Test("the line is nowhere near white or black")
    func theBoundaryIsSafe() {
        #expect(Self.pale((0.85, 0.85, 0.85)), "light grey reads as pale")
        #expect(!Self.pale((0.3, 0.3, 0.3)), "dark grey does not")
    }
}
