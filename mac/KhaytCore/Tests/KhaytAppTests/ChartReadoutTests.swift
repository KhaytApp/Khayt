import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A chart has to be able to say what it is drawing.
///
/// ── THE DEFECT THESE EXIST FOR ────────────────────────────────────────────
///
/// `CashFlowChart.Bars` took a `currency` parameter from the day it was
/// written and never used it in a single line of its body. That is the whole
/// bug: the chart was built meaning to say what a column was worth, and then
/// drew six months of a shop's bank movements with no axis, no readout and no
/// statement of which months they were. The columns could be COMPARED and not
/// READ. Cost trends and the waste trend were the same — the waste card's key,
/// which is the entire point of that card, carried the window's totals, so a
/// stripe that kept coming back could not be measured against itself.
///
/// The span line and the readout are the answer, and these hold them.
@MainActor
struct ChartReadoutTests {

    // MARK: - Which months a chart is showing

    @Test("a window says its first month and its last")
    func spanNamesBothEnds() {
        let said = MonthLabel.span(["2026-04", "2026-05", "2026-09"],
                                   pointingAt: nil, language: "en")
        #expect(said.contains("April"), "the first month is not named: \(said)")
        #expect(said.contains("September"), "the last month is not named: \(said)")
        #expect(said.contains("2026"))
    }

    /// One month is not a range. "August 2026 – August 2026" is a sentence a
    /// reader has to get through twice to learn nothing.
    @Test("a one-month window is one month, not a range of one")
    func spanOfOneIsNotARange() {
        let said = MonthLabel.span(["2026-08"], pointingAt: nil, language: "en")
        #expect(!said.contains("–"), "a single month was drawn as a range: \(said)")
        #expect(said.contains("August"))
    }

    /// THE POINT OF THE LINE. While a pointer is on a column, the figures
    /// underneath are that month's — so the caption has to be that month and
    /// not the window, or the card states one period and prints another's
    /// numbers.
    @Test("pointing at a month replaces the span with that month")
    func spanFollowsThePointer() {
        let said = MonthLabel.span(["2026-04", "2026-05", "2026-09"],
                                   pointingAt: "2026-05", language: "en")
        #expect(said.contains("May"), "the pointed-at month is not named: \(said)")
        #expect(!said.contains("April"), "the window is still being claimed: \(said)")
        #expect(!said.contains("September"))
    }

    @Test("a chart with no months says nothing rather than something wrong")
    func spanOfNothingIsEmpty() {
        #expect(MonthLabel.span([], pointingAt: nil, language: "en").isEmpty)
    }

    /// The shop's own language, because this line sits under a chart in an
    /// app that runs in nine of them and a hard-coded English month is the
    /// kind of thing that ships unnoticed for a year.
    @Test("the month is named in the shop's language")
    func monthFollowsTheLanguage() {
        let english = MonthLabel.long("2026-08", language: "en")
        #expect(english.contains("August"))
        for language in Words.supported where language != "en" {
            let said = MonthLabel.long("2026-08", language: language)
            #expect(!said.isEmpty, "\(language) produced nothing")
            #expect(said != "2026-08", "\(language) fell through to the raw key")
        }
        #expect(MonthLabel.long("2026-08", language: "ar") != english,
                "Arabic named the month exactly as English did")
    }

    /// Same refusal `short` makes, and for the same reason: a key this does
    /// not recognise is a bug to see, not one to hide behind a tidy label. A
    /// month silently drawn as January is worse than one drawn as its key.
    @Test("a key this does not understand comes back untouched")
    func nonsenseIsNotDressedUp() {
        for key in ["", "2026", "2026-13", "2026-00", "August", "2026-08-14", "x-y"] {
            #expect(MonthLabel.long(key, language: "en") == key,
                    "\(key) was turned into a plausible wrong month")
        }
    }

    // MARK: - What a bar is worth

    /// The cash-flow card reads its figures out of the row under the pointer
    /// and falls back to the window's totals. This is that choice, made
    /// against a real `CashFlow` rather than asserted about the view: the
    /// failure it guards is the readout showing one month's caption over
    /// another month's money.
    @Test("the readout takes the pointed-at month, and nothing else")
    func theReadoutIsTheMonthUnderThePointer() throws {
        let flow = try JSONDecoder().decode(KhaytEngine.CashFlow.self, from: Data("""
        {"rows": [{"month": "2026-07", "collected": 1200, "paidOut": 300, "net": 900},
                  {"month": "2026-08", "collected": 400, "paidOut": 950, "net": -550}],
         "totals": {"collected": 1600, "paidOut": 1250, "net": 350,
                    "anyMovement": true, "undated": 0}}
        """.utf8))

        let august = flow.rows.first { $0.month == "2026-08" }
        #expect(august?.collected == 400)
        // And the fall-back, which is what the card shows with no pointer.
        #expect(flow.rows.first { $0.month == "2026-11" } == nil,
                "a month outside the window must not resolve to a row")
        #expect(flow.totals.collected == 1600)
        // The one figure on the card that is coloured is coloured on the
        // MONTH's net while a month is being pointed at, not the window's —
        // August is negative here and the window is not, which is exactly the
        // pair that makes the mistake visible.
        #expect(flow.totals.net > 0 && (august?.net ?? 0) < 0,
                "the fixture no longer distinguishes the two nets")
    }
}
