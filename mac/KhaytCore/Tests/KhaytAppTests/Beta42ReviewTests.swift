import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The beta.42 release reviews' small fixes: each pinned here.
@MainActor
@Suite struct Beta42ReviewTests {

    /// Data review LOW3: a draft whose costing failed (`rates` nil) keeps the
    /// rates its part was costed at; one with rates writes the sheet's.
    @Test("partRows keeps a part's own rates when the draft has none")
    func ratesKeptWhenCostingFailed() {
        var failed = NewJobSheet.Draft()
        failed.name = "Hinge"; failed.grams = "10"; failed.hours = "1"; failed.qty = 2; failed.cost = 0
        failed.raw = ["laborRate": .number(90), "prepTime": .number(0.25)]
        failed.rates = nil
        guard case .object(let kept)? = Shop.partRows([failed], spools: [], unnamed: "Part").first else {
            Issue.record("no row"); return
        }
        #expect(kept["laborRate"] == .number(90))
        #expect(kept["prepTime"] == .number(0.25))
    }

    /// Data review LOW2: Recalculate charges the JOB's own overhead rate, never
    /// the shop's today (an online or shelf job priced without overhead must
    /// not gain it).
    @Test("Recalculate passes no overhead rate of its own")
    func repriceUsesTheJobsOverhead() {
        #expect(Shop.repriceOverhead == nil)
        let src = MenuCoverageTests.source("Shop+Reprice.swift")
        // Both ways in (the preview and the save) hand the rule this, and
        // neither hands it the shop's `overheadPerHour`.
        #expect(src.contains("settings: settingsDict, overheadPerHour: Self.repriceOverhead"))
        #expect(src.contains("let overhead = Self.repriceOverhead"))
        #expect(!src.contains("overheadPerHour: overheadPerHour,\n                                   engine: engine, refusals: Self.repriceRefusalWords"))
    }

    /// Stability review LOW5: a markup that is not a number is said, not
    /// previewed at the default; Arabic digits and a decimal comma are numbers.
    @Test("an unreadable markup is caught; typed digits of either script are not")
    func markupUnreadable() {
        #expect(RecalculateSheet.markupUnreadable("abc"))
        #expect(RecalculateSheet.markupUnreadable("30%%"))
        #expect(!RecalculateSheet.markupUnreadable(""))
        #expect(!RecalculateSheet.markupUnreadable("30"))
        #expect(!RecalculateSheet.markupUnreadable("٣٠"))
        #expect(!RecalculateSheet.markupUnreadable("12,5"))
    }
}
