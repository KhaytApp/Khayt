import AppKit
import CoreText
import Foundation
import Testing
@testable import KhaytApp

/// The state marks, asked of the font rather than of a character map.
///
/// ── WHAT MEASURING THEM FOUND ─────────────────────────────────────────────
///
/// Of the fifteen glyphs `ShopState` used, SEVEN were in the system face. The
/// other eight fell back to seven different typefaces — `◔`, `◷` and `✉` to
/// **Menlo**, `⊘` to Apple Symbols, `◌` to SF Arabic, `◑` to Hiragino, `◇` to
/// the CJK fallback and `✕` to Zapf Dingbats. So a row of chips was set in up
/// to eight cuts at once.
///
/// Nobody had looked, because a character map says a glyph EXISTS and says
/// nothing about which face will draw it. This is the same defect `RiyalMark`
/// was written for: the figure face had no riyal sign, the mark was taken from
/// the label face beside it, and on screen it read as borrowed — which it was.
///
/// ── THE TWO RULES THAT CAME OUT OF IT ─────────────────────────────────────
///
/// Both are RELATIVE, deliberately: no face is named here. The fallback chain
/// belongs to macOS and will move under this app, and a test pinning
/// "AppleSymbols" would fail on an OS change while saying nothing true about
/// the design.
@MainActor
struct StateGlyphTests {

    /// The size a chip is actually set at — `StateChip` uses `TypeScale.label(10)`.
    /// Asking at 17pt would answer a question nobody is looking at.
    static let sizes: [CGFloat] = [10, 12]

    static func face(drawing glyph: String, at size: CGFloat,
                     named: String? = nil) -> String? {
        let font = named.flatMap { NSFont(name: $0, size: size) }
            ?? NSFont.systemFont(ofSize: size, weight: .semibold)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: glyph, attributes: [.font: font]))
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], let run = runs.first,
              let used = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName]
        else { return nil }
        // swiftlint:disable:next force_cast
        return CTFontCopyPostScriptName(used as! CTFont) as String
    }

    /// Does the mark DRAW something? A codepoint no face has comes back as
    /// `.notdef` — the tofu box — and a tofu box in a chip is a state that
    /// reads as a rendering fault.
    static func draws(_ glyph: String, at size: CGFloat) -> Bool {
        let font = NSFont.systemFont(ofSize: size, weight: .semibold) as CTFont
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: glyph, attributes: [.font: font as NSFont]))
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], let run = runs.first else {
            return false
        }
        let count = CTRunGetGlyphCount(run)
        guard count > 0 else { return false }
        var ids = [CGGlyph](repeating: 0, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: count), &ids)
        // `.notdef` is glyph 0 in every font, and a path of nothing is a space.
        guard ids.allSatisfy({ $0 != 0 }) else { return false }
        let used = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName]
        // swiftlint:disable:next force_cast
        let face = used as! CTFont
        return ids.contains { CTFontCreatePathForGlyph(face, $0, nil) != nil }
    }

    @Test("every state's mark draws something, at the size a chip is set in")
    func nothingIsTofu() {
        for state in ShopState.allCases {
            for size in Self.sizes {
                #expect(Self.draws(state.glyph, at: size), Comment(rawValue: """
                    \(state) draws \(state.glyph) as nothing at \(size)pt — a chip \
                    showing a tofu box reads as a broken screen, not as a state
                    """))
            }
        }
    }

    /// THE RULE THAT WOULD HAVE CAUGHT `⊘` BESIDE `◔`.
    ///
    /// A kind's two marks are meant to be one silhouette in two fills — ■/□,
    /// ▼/▽. Two marks pulled from two different faces are not that whatever
    /// their shapes: they arrive at different weights, different optical
    /// sizes, and different ideas of where the baseline is, and the pair stops
    /// reading as a pair. The nozzle kind was Apple Symbols beside Menlo, and
    /// the order kind was the system face beside Menlo.
    @Test("the two marks of one kind come from one face")
    func aKindIsSetInOneFace() {
        let kinds: [(String, ShopState, ShopState)] = [
            ("order", .orderLate, .orderToday),
            ("machine", .machineStopped, .machineCheck),
            ("nozzle", .nozzleBlocked, .nozzleWorn),
            ("stock", .stockOut, .stockLow),
        ]
        for (kind, crit, warn) in kinds {
            for size in Self.sizes {
                let a = Self.face(drawing: crit.glyph, at: size)
                let b = Self.face(drawing: warn.glyph, at: size)
                #expect(a == b, Comment(rawValue: """
                    the \(kind) kind is drawn in two faces at \(size)pt — \
                    \(crit.glyph) by \(a ?? "nothing") and \(warn.glyph) by \
                    \(b ?? "nothing"). One kind, one silhouette, one cut.
                    """))
            }
        }
    }

    /// `of(kind:severity:)` is the only way the shared rule's states get in,
    /// so every kind it names has to land on the pair above rather than on the
    /// `default`. Guessing a severity once put the due-today glyph on nine
    /// late jobs; guessing a KIND would put a machine's mark on a nozzle.
    @Test("every kind the shared rule can name has its own pair")
    func everyKindIsMapped() {
        for kind in ["order", "machine", "nozzle", "stock"] {
            let crit = ShopState.of(kind: kind, severity: "crit")
            let warn = ShopState.of(kind: kind, severity: "warn")
            #expect(crit != warn, Comment(rawValue: "\(kind) reads the same at both severities"))
            #expect(crit != .machineCheck || kind == "machine",
                    Comment(rawValue: "\(kind) fell through to the default"))
            #expect(crit.isAttention && warn.isAttention,
                    Comment(rawValue: "\(kind) produced a lifecycle state"))
        }
        // An unlisted severity is the warning, never silently critical.
        #expect(ShopState.of(kind: "stock", severity: "high") == .stockLow)
    }

    /// ── THE WHOLE SET COMES FROM TWO FACES, AND BOTH ARE CHOSEN ─────────
    ///
    /// The defect this suite was written for was SEVEN typefaces in one row of
    /// chips, arrived at by a fallback chain choosing per character. `face`
    /// names the cut for every mark, so the answer is a decision rather than
    /// whatever macOS reached for — and this holds it to two: the system face
    /// wherever it has the mark, and one named family for the rest.
    ///
    /// Not one face, and that is deliberate: the system face carries about
    /// twenty usable geometric marks against fourteen meanings, so forcing it
    /// buys a star standing for a quote. A mark that has to be learnt is worse
    /// than one drawn a quarter-point light.
    @Test("every mark comes from the system face or from one named family")
    func twoFacesAndNoMore() {
        var fallbacks: Set<String> = []
        for state in ShopState.allCases {
            for size in Self.sizes {
                let drawn = Self.face(drawing: state.glyph, at: size, named: state.face)
                if let want = state.face {
                    #expect(drawn?.isEmpty == false, Comment(rawValue: "\(state) drew nothing"))
                    fallbacks.insert(want)
                } else {
                    // No face named means the system face must actually have
                    // it — otherwise this is the old bug wearing a comment.
                    #expect(drawn?.hasPrefix(".SFNS") == true, Comment(rawValue: """
                        \(state) claims the system face and is drawn by \(drawn ?? "nothing")                         at \(size)pt — name its face or choose a mark the system has
                        """))
                }
            }
        }
        #expect(fallbacks.count <= 1, Comment(rawValue: """
            the set is drawn in \(fallbacks.count + 1) faces — \(fallbacks.sorted())             beside the system one. Seven was the defect; two is the rule.
            """))
    }

    /// A named face has to be installed, or the mark silently falls back again
    /// and the naming has bought nothing.
    @Test("a named face is one this Mac actually has")
    func namedFacesExist() {
        for name in Set(ShopState.allCases.compactMap(\.face)) {
            #expect(NSFont(name: name, size: 10) != nil,
                    Comment(rawValue: "\(name) is not installed, so its marks fall back"))
        }
    }

    /// A cancelled job is not asking for anything, so its mark must not be one
    /// of the ones that does. The attention list and the lifecycle list are
    /// kept apart on purpose — "lifecycle never competes for the eye".
    @Test("a cancelled job is lifecycle, and is quiet")
    func cancelledIsQuiet() {
        #expect(!ShopState.cancelled.isAttention)
        #expect(ShopState.cancelled.ground == nil,
                "a cancelled row carries a coloured ground, so it shouts like a fault")
        #expect(ShopState.cancelled.tint == Role.text3,
                "a cancelled job is over; it must be as quiet as a quote")
    }
}

/// A promise date stops being a deadline once the thing is made.
///
/// The ledger counted down on every row, so a job the shop FINISHED in April
/// read "−144d" — a hundred and forty-four days late, about something that is
/// done — and a cancelled job did the same, which is not late and never will
/// be. On this book a quarter of the unsettled rows are finished work, so it
/// was a column of warnings about the past.
@MainActor
struct LedgerDueWordsTests {

    static func rows() async -> [Shop.LedgerLine] {
        let shop = Shop()
        await shop.load(.sample)
        shop.ledgerFilter = .all
        return shop.ledgerRows
    }

    @Test("a finished or cancelled row says WHEN, and does not count down")
    func historyIsADate() async {
        let rows = await Self.rows()
        let over = rows.filter { $0.state == .done || $0.state == .cancelled }
        #expect(!over.isEmpty, "the sample book no longer reaches this at all")
        for row in over {
            #expect(!row.due.hasPrefix("−"), """
                \(row.title) is \(row.state) and its due column reads "\(row.due)" — \
                a countdown about work that is over
                """)
        }
    }

    /// And work still in flight keeps its countdown, which is the whole point
    /// of the column: a job due in two days and one that was due a week ago
    /// are the two things a shop is looking for.
    @Test("work still in flight still counts")
    func liveWorkStillCounts() async {
        let rows = await Self.rows()
        let live = rows.filter { $0.state != .done && $0.state != .cancelled }
        #expect(!live.isEmpty)
        #expect(live.contains { $0.due.hasPrefix("−") }, """
            nothing in flight is counting down any more — the fix reached rows \
            it should not have
            """)
    }
}
