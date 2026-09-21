import Foundation
import SwiftUI
import Testing
@testable import KhaytApp

/// One Riyal mark, on the paper and on the screen.
///
/// §5 of the design spec says the mark is drawn from a glyph this design
/// controls and never borrowed from a system face — "a plausible-but-wrong
/// mark ships" — and named `KhaytRiyal` as the way to do it. That font was
/// never cut, so `Figure.hasOwnFace` has been false since the day it was
/// written and every figure fell back to the LABEL face beside the tabular
/// one: the one character in the figure set in a different cut.
///
/// The mark was already drawn elsewhere in this product. `lib/invoice-document.js`
/// carries it as an SVG path, because ZATCA made the glyph something that has
/// to be certain on a document. `RiyalMark` is that same outline, so there is
/// now one mark rather than two, and these tests are what stop it becoming two
/// again.
@MainActor
struct RiyalMarkTests {

    /// The outline is the invoice's outline, character for character.
    ///
    /// Copied rather than generated — there is no build step between a Swift
    /// app and a JavaScript module — so this comparison is the only thing
    /// holding them together. A mark that differs between a shop's screen and
    /// the invoice it sends is worse than either one alone.
    @Test("the drawn mark is the same outline the invoice prints")
    func sameOutlineAsTheInvoice() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // KhaytAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // KhaytCore
            .deletingLastPathComponent()   // mac
            .deletingLastPathComponent()   // the repository
        let source = try String(contentsOf: root.appending(path: "lib/invoice-document.js"),
                                encoding: .utf8)

        // Every `d="…"` inside the RIYAL_SVG block, in order.
        let block = try #require(source.range(of: "const RIYAL_SVG ="))
        let end = try #require(source.range(of: "';", range: block.upperBound..<source.endIndex))
        let svg = String(source[block.upperBound..<end.lowerBound])

        var drawn: [String] = []
        var rest = Substring(svg)
        while let open = rest.range(of: "d=\"") {
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "\"") else { break }
            drawn.append(String(after[..<close.lowerBound]))
            rest = after[close.upperBound...]
        }

        #expect(drawn.count == 2, "the invoice's mark is no longer two subpaths: \(drawn.count)")
        #expect(drawn == RiyalMark.subpaths, """
            the drawn mark and the invoice's have drifted apart. They are one \
            mark: change both, or neither.
            """)
        // And the box they are drawn in, which decides the proportions.
        #expect(svg.contains("viewBox=\"0 0 1124.14 1256.39\""),
                "the invoice's viewBox moved; RiyalMark.viewBox must follow")
    }

    /// The parser understands everything this outline uses.
    ///
    /// It is deliberately strict — it traps on a command it does not know
    /// rather than drawing something nearly right — so this is the test that
    /// says the data and the parser still match.
    @Test("every command in the outline is one the parser draws")
    func parserCoversTheOutline() {
        let known = Set("MmLlHhVvCcZz")
        for subpath in RiyalMark.subpaths {
            let letters = Set(subpath.filter { $0.isLetter })
            let unknown = letters.subtracting(known)
            #expect(unknown.isEmpty,
                    Comment(rawValue: "the outline uses \(unknown.sorted()), which SvgPath does not draw"))
        }
    }

    /// It produces a real shape, not an empty path.
    ///
    /// The parser could silently produce nothing — a trap only fires in a
    /// debug build, and an empty `Path` draws perfectly happily.
    @Test("the mark has a shape, and it fills its box")
    func theMarkIsDrawn() {
        let box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let path = RiyalMark().path(in: box)
        #expect(!path.isEmpty, "the outline parsed to nothing")

        let bounds = path.boundingRect
        // Fitted to the box's smaller side, centred, and not squashed: the
        // viewBox is taller than it is wide, so height is what fills.
        #expect(bounds.height > 95 && bounds.height <= 100,
                "the mark does not fill its box: \(bounds)")
        let ratio = bounds.width / bounds.height
        let want = RiyalMark.viewBox.width / RiyalMark.viewBox.height
        #expect(abs(ratio - want) < 0.02,
                "the mark is distorted: \(ratio) against \(want)")
    }

    /// A figure in riyals draws the mark rather than setting it.
    ///
    /// The view cannot be inspected directly, so this holds the decision that
    /// drives it: the currency this app draws its own mark for, and only that
    /// one. Every other currency keeps its ISO code, which is what stops the
    /// one symbol this shop uses becoming an assumption about the rest.
    @Test("only the riyal is drawn; every other currency keeps its code")
    func onlyTheRiyalIsDrawn() {
        #expect(Figure.drawnMark("SAR"))
        #expect(Figure.drawnMark("sar"), "the check must not depend on case")
        for other in ["USD", "EUR", "GBP", "AED", "KWD", "", "SARX"] {
            #expect(!Figure.drawnMark(other), "\(other) is not drawn here")
        }
    }
}
