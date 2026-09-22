import AppKit
import Foundation
import Testing
@testable import KhaytApp

/// A phone number reads the same in both languages.
///
/// ── THE DEFECT ────────────────────────────────────────────────────────────
///
/// In an Arabic window `+966 50 000 0000` was drawn as `0000 000 50 966+`.
/// The value was never wrong — it is stored, exported and printed on the
/// invoice correctly — but the bidi algorithm applied the paragraph's
/// right-to-left direction to the whole run: `+` is NEUTRAL so it takes the
/// paragraph's side and lands at the far end, and digits are WEAK so the
/// groups reorder around it. A shop was shown a different telephone number
/// from the one it had typed.
///
/// ── AND WHY THE FIX IS APPKIT'S ───────────────────────────────────────────
///
/// Three SwiftUI attempts failed first. `Direction.swift` says why in advance:
/// this app's right-to-left is `NSForceRightToLeftWritingDirection`, set on
/// AppKit before `main()`, because the SwiftUI environment version sends
/// `NavigationSplitView` into an unbounded layout loop on macOS 26. SwiftUI is
/// never asked to mirror anything here, so writing to `layoutDirection` does
/// nothing and `.multilineTextAlignment` never reaches the control.
@MainActor
struct LatinFieldTests {

    /// What the algorithm does to this string in each direction — asked of
    /// the same machinery that lays out the control, rather than asserted.
    static func drawn(_ text: String, rightToLeft: Bool) -> String {
        let paragraph = NSMutableParagraphStyle()
        paragraph.baseWritingDirection = rightToLeft ? .rightToLeft : .leftToRight
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [.paragraphStyle: paragraph,
                                       .font: NSFont.systemFont(ofSize: 13)]))
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return text }
        // The runs in the order they are DRAWN, each mapped back to the
        // characters it came from.
        var out = ""
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
            let scalars = Array(text)
            for i in indices where i >= 0 && i < scalars.count { out.append(scalars[i]) }
        }
        return out
    }

    /// THE ONE THAT SHIPPED. This is the bug, reproduced, so the test fails
    /// for the real reason rather than because somebody renamed a type.
    @Test("a right-to-left paragraph reorders a phone number")
    func theBugIsReal() {
        let number = "+966 50 000 0000"
        #expect(Self.drawn(number, rightToLeft: false) == number)
        #expect(Self.drawn(number, rightToLeft: true) != number, """
            the reordering no longer happens, so either this Mac's bidi \
            changed or the fixture stopped exercising it
            """)
    }

    /// And fixing the paragraph's direction is what stops it — which is
    /// exactly what `LatinField` sets on its control.
    @Test("a left-to-right paragraph keeps it as typed")
    func theFixIsTheDirection() {
        for value in ["+966 50 000 0000", "hello@tuwaiq.example",
                      "SA03 8000 0000 6080 1016 7519", "300123456700003", "1010123456"] {
            #expect(Self.drawn(value, rightToLeft: false) == value,
                    Comment(rawValue: "\(value) came out as \(Self.drawn(value, rightToLeft: false))"))
        }
    }

    /// The control carries the direction, and carries it AFTER a value
    /// arrives: AppKit resets a cell's direction when its string is replaced,
    /// so a number loaded from the book would undo it.
    @Test("the field keeps its direction when its value changes")
    func directionSurvivesAValue() {
        let control = NSTextField(string: "+966 50 000 0000")
        LatinField.harden(control, placeholder: "", monospaced: false)
        #expect(control.baseWritingDirection == .leftToRight)
        #expect(control.alignment == .left)

        // What SwiftUI does on every update: the value arrives from the book.
        control.stringValue = "+966 55 111 2222"
        LatinField.harden(control, placeholder: "", monospaced: false)
        #expect(control.baseWritingDirection == .leftToRight, """
            the direction was lost when the value changed — which is how this \
            comes back on a book that already has a number in it
            """)
        #expect(control.alignment == .left)
    }

    /// The IBAN asks for a monospaced face; nothing else does.
    @Test("only the field that asks for it is monospaced")
    func monospacedIsOptedInto() {
        let plain = NSTextField(string: "")
        LatinField.harden(plain, placeholder: "", monospaced: false)
        let fixed = NSTextField(string: "")
        LatinField.harden(fixed, placeholder: "", monospaced: true)
        #expect(plain.font?.fontName != fixed.font?.fontName)
        #expect(fixed.baseWritingDirection == .leftToRight, "the IBAN lost its direction")
    }
}
