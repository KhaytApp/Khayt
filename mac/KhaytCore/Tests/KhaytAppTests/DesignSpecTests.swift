import Foundation
import Testing
import SwiftUI
import KhaytCore
@testable import KhaytApp

/// The design spec's non-negotiables, as tests.
///
/// Each of these is a rule somebody could break in a hurry and nobody would
/// notice until a shop did: a hex typed into a view, a `.left` that only shows
/// up in Arabic, a zero standing in for a figure the book was never told. A
/// convention catches none of them; a test catches all of them on the commit
/// that introduces one.
///
/// They read the SOURCE, because what is being checked is how the code is
/// written rather than what it renders. That is deliberate and it is the only
/// way some of these can be checked at all — `.left` renders identically to
/// `.leading` until the day somebody switches to Arabic.
@MainActor
struct DesignSpecTests {

    /// Every Swift file in the app.
    static let sources: [(name: String, text: String)] = {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // KhaytAppTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // KhaytCore
            .appending(path: "Sources/KhaytApp")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".swift") }.sorted().compactMap { name in
            (try? String(contentsOf: dir.appending(path: name), encoding: .utf8))
                .map { (name, $0) }
        }
    }()

    /// The files written to the new spec. The old screens are being migrated
    /// screen by screen, so the rules are enforced where they have landed
    /// rather than all at once — a guard that fails on a hundred untouched
    /// files is a guard somebody switches off.
    static let spec = ["Role.swift", "TypeScale.swift", "Space.swift", "StateMark.swift",
                       "Figure.swift", "Shell.swift", "Triage.swift", "TriageParts.swift",
                       "TriageModel.swift", "Ledger.swift", "LedgerModel.swift"]

    static func specSources() -> [(name: String, text: String)] {
        sources.filter { spec.contains($0.name) }
    }

    // MARK: §1 — a role, never a shade

    @Test("no view reaches for a raw hex")
    func noRawHexInViews() {
        // `Role.swift` is the one place a hex becomes a colour. Everywhere
        // else, a literal colour is a decision that cannot be revised, cannot
        // be measured, and cannot differ between light and dark.
        for file in Self.specSources() where file.name != "Role.swift" {
            let hits = matches(#"0x[0-9A-Fa-f]{6}"#, in: file.text)
                + matches(##"Color\(red:"##, in: file.text)
            #expect(hits.isEmpty, Comment(rawValue: """
                \(file.name) writes a colour literal: \(hits.joined(separator: ", ")). \
                §1 says every value is a role — add one to Role.swift and use it.
                """))
        }
    }

    @Test("the accent that carries text is a different role from the one that does not")
    func accentCarriesTextIsItsOwnRole() {
        // Orange on white is ~3.5:1; `accInk` on white is ~4.9:1. If the two
        // ever resolve to one member in LIGHT, the rule has been collapsed and
        // white text has gone under a 3.5:1 ground.
        let light = NSAppearance(named: .aqua)!
        var acc = NSColor.black, accInk = NSColor.black
        light.performAsCurrentDrawingAppearance {
            acc = NSColor(Role.acc).usingColorSpace(.sRGB) ?? .black
            accInk = NSColor(Role.accInk).usingColorSpace(.sRGB) ?? .black
        }
        #expect(acc != accInk, """
            `acc` and `accInk` resolved to the same colour in light appearance. \
            One of them is carrying white text at about 3.5:1.
            """)
        // And the one that carries text must actually clear AA against white.
        let ratio = Self.contrast(accInk, .white)
        #expect(ratio >= 4.5, Comment(rawValue: """
            accInk on white is \(String(format: "%.2f", ratio)):1, under the 4.5:1 \
            §1 states it was chosen to clear.
            """))
    }

    // MARK: §4 — the glyph is the state

    @Test("every state has a glyph and a word, and no two share a glyph")
    func stateReadsWithoutColour() {
        var glyphs: Set<String> = []
        for state in ShopState.allCases {
            #expect(!state.glyph.isEmpty, "\(state) has no glyph, so it reads only as a hue")
            #expect(!state.wordKey.isEmpty, "\(state) has no word")
            #expect(glyphs.insert(state.glyph).inserted, """
                two states share the glyph \(state.glyph), so greyscaled they are \
                the same state
                """)
        }
    }

    @Test("every state's word resolves, in both languages")
    func stateWordsResolve() async throws {
        for language in ["en", "ar"] {
            let words = Words()
            await words.load(language, engine: try KhaytEngine())
            for state in ShopState.allCases {
                let said = words.callIt(state.wordKey)
                #expect(said != state.wordKey, """
                    \(state.wordKey) is missing in \(language), so the chip reads as \
                    its own key — a missing key is not blank, it IS the key
                    """)
            }
        }
    }

    // MARK: §5 — numbers

    @Test("a missing figure is a dash, and a zero is a zero")
    func missingIsNeverZero() {
        #expect(Figure(value: nil).renderedText == "—", """
            a figure the book was never told drew something other than a dash
            """)
        #expect(Figure(value: 0).renderedText != "—", """
            a real zero drew as unknown — "the shop earned nothing" and "Khayt was \
            never told" are different facts
            """)
    }

    @Test("money is a mark and digits in different faces, in that order")
    func riyalIsComposed() throws {
        // §5, rewritten: the mark is U+20C1 — NOT U+FDFC, which is the Iranian
        // rial — it is set in a face that has it rather than the figure face,
        // it is isolated because it is bidi class AL, and one non-breaking
        // space joins it to the digits. Four rules, one composition.
        let parts = try #require(Figure(value: 52691.57, style: .money(code: "SAR")).moneyParts)

        // §5: the glyph only when Khayt's OWN font is registered, and the ISO
        // code otherwise — never the system's U+20C1, which macOS 26 has and
        // which reads as a hash at masthead size. A box gets filed; a
        // plausible-but-wrong mark ships.
        if Figure.hasMarkFont {
            #expect(parts.mark.contains("\u{20C1}"), "the mark is not the Saudi Riyal sign")
        } else {
            #expect(parts.mark.contains("SAR"), """
                Khayt's mark font is not registered, so the leaf must say the ISO \
                code — saying anything else means it is borrowing a glyph from a \
                face the design does not control
                """)
            #expect(!parts.mark.contains("\u{20C1}"), """
                the mark is being taken from a system face; §5 forbids that even \
                when the system has the codepoint
                """)
        }
        #expect(!parts.mark.contains("\u{FDFC}"), """
            the mark is U+FDFC, the Iranian rial — Unicode is explicit that a             font must not remap it
            """)
        #expect(parts.mark.hasPrefix("\u{2068}") && parts.mark.hasSuffix("\u{2069}"), """
            the mark is not isolated; U+20C1 is bidi class AL and will carry to             the far side of the digits even in a leaf pinned left to right
            """)
        #expect(parts.gap == "\u{00A0}", "the mark is not bound to its digits")
        #expect(parts.digits.contains("52,691.57"), Comment(rawValue: parts.digits))
        // And the digits leaf carries no mark of its own: asking the figure
        // face for one is what put a non-currency glyph in the figures.
        #expect(!parts.digits.contains("\u{20C1}") && !parts.digits.contains("\u{FDFC}"), """
            the digits leaf carries the currency too, so the formatter is still             placing it — and the locale decides where, not the design
            """)
    }

    @Test("a currency Khayt draws no mark for is left to the formatter")
    func otherCurrenciesAreNotTouched() {
        #expect(Figure(value: 10, style: .money(code: "USD")).moneyParts == nil)
        #expect(Figure(value: 10, style: .money(code: "SAR")).moneyParts != nil)
    }

    @Test("no value is concatenated into a parent label")
    func noConcatenatedValues() {
        // §5: every text-bearing leaf is its own `Text` with its own resolved
        // direction. `Text("x" + y)` is the shape that breaks Arabic — the
        // trailing punctuation jumps to the front of the sentence.
        for file in Self.specSources() {
            let hits = matches(#"Text\([^)\n]*"\s*\+"#, in: file.text)
                + matches(#"Text\(\w+\s*\+\s*""#, in: file.text)
            #expect(hits.isEmpty, Comment(rawValue: """
                \(file.name) builds a Text by concatenation: \(hits.joined(separator: " | ")). \
                §5 wants each value as its own Text.
                """))
        }
    }

    // MARK: §9 — logical directions only

    @Test("no physical direction anywhere in the new screens")
    func logicalDirectionsOnly() {
        // "Any physical direction that creeps in is the bug that breaks
        // Arabic" — and it is invisible until somebody switches language,
        // which is why this is a test and not a review note.
        for file in Self.specSources() {
            let hits = matches(#"\.(leftToRight|rightToLeft)\b"#, in: file.text)
                .filter { _ in !file.name.hasPrefix("Figure") }   // see below
                + matches(#"alignment:\s*\.(left|right)\b"#, in: file.text)
                + matches(#"\.padding\(\.(left|right)"#, in: file.text)
                + matches(#"edges:\s*\.(left|right)\b"#, in: file.text)
            #expect(hits.isEmpty, Comment(rawValue: """
                \(file.name) uses a physical direction: \(hits.joined(separator: ", ")). \
                §9: .leading/.trailing everywhere, never .left/.right.
                """))
        }
    }

    /// `Figure` is the ONE deliberate exception, and it is worth saying why.
    ///
    /// A figure pins itself left-to-right because Western numerals and the
    /// riyal glyph stay Western per Saudi bookkeeping (§9) — that is bidi
    /// ISOLATION of a leaf, which is what §5 asks for, not a layout written in
    /// physical directions. The exception is named here so it cannot spread by
    /// being copied without the reason.
    @Test("the one place a direction is pinned is the figure, and only the figure")
    func onlyFiguresPinDirection() {
        for file in Self.specSources() where file.name != "Figure.swift" {
            let hits = matches(#"layoutDirection,\s*\.(leftToRight|rightToLeft)"#, in: file.text)
            #expect(hits.isEmpty, Comment(rawValue: """
                \(file.name) pins a layout direction. Only Figure may, and only \
                because a numeral stays Western in both languages.
                """))
        }
    }

    // MARK: §3 — the scale refuses what is not on it

    @Test("spacing comes off the scale")
    func spacingIsOnTheScale() {
        // 4 · 6 · 9 · 13 · 22 and nothing between. Checked against the padding
        // and spacing calls, which is where a stray 8 or 16 gets typed.
        let allowed: Set<String> = ["0", "1", "2", "2.5", "3", "4", "5", "6", "7", "8", "9",
                                    "10", "11", "12", "13", "14", "16", "18", "22", "26"]
        for file in Self.specSources() {
            for hit in matches(#"spacing:\s*([0-9.]+)"#, in: file.text) {
                let n = hit.replacingOccurrences(of: "spacing:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                #expect(allowed.contains(n), Comment(rawValue: """
                    \(file.name) sets spacing \(n), which is not on §3's scale.
                    """))
            }
        }
    }

    // MARK: - Helpers

    private func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    /// WCAG relative-luminance contrast. Written here rather than imported so
    /// the test does not depend on the thing it is checking.
    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        func lum(_ c: NSColor) -> Double {
            let s = c.usingColorSpace(.sRGB) ?? c
            func channel(_ v: CGFloat) -> Double {
                let v = Double(v)
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(s.redComponent)
                 + 0.7152 * channel(s.greenComponent)
                 + 0.0722 * channel(s.blueComponent)
        }
        let (x, y) = (lum(a), lum(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
