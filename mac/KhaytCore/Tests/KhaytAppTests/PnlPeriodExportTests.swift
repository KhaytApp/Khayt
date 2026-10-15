import Foundation
import SwiftUI
import Testing
import KhaytCore
@testable import KhaytApp

/// The Reports page's period picker, its export and its VAT summary, on the
/// Mac side of the bridge: the words exist in both languages, the labels name
/// the chosen period, the export asks the question the page asks, and the
/// card draws.
@Suite @MainActor struct PnlPeriodExportTests {

    static let keys = [
        "pnl.range_last_year", "pnl.no_data_period", "pnl.custom_invalid", "pnl.export",
        "pnl.export_csv", "pnl.export_pdf", "pnl.fixed", "pnl.costs", "pnl.currency",
        "pnl.vat_title", "pnl.vat_sales", "pnl.vat_output", "pnl.vat_input", "pnl.vat_net",
        "pnl.vat_refund", "pnl.vat_inclusive", "pnl.vat_exclusive", "pnl.vat_missing",
        "pnl.exported_as",
        // Borrowed from Khayt's own catalogue, so they must be there too.
        "an.range.month", "an.range.last_month", "an.range.quarter", "tax.last_quarter",
        "an.range.year", "tax.custom_range", "an.range.all",
    ]

    @Test("every word the picker, the export and the VAT card use is in English and Arabic")
    func words() async throws {
        let engine = try KhaytEngine()
        for language in ["en", "ar"] {
            let words = Words()
            await words.load(language, engine: engine)
            for key in Self.keys {
                let said = words.callIt(key)
                #expect(said != key, "\(key) has no \(language) word")
            }
            for kind in PnlRange.Kind.allCases {
                #expect(words.callIt(kind.key) != kind.key, "\(kind) has no \(language) name")
            }
        }
    }

    @Test("Arabic counts in Western digits")
    func westernDigits() async throws {
        let ar = Words()
        await ar.load("ar", engine: try KhaytEngine())
        let said = ar.callIt("pnl.vat_missing", ["n": .number(12)])
        #expect(said.contains("12"))
        let eastern = said.unicodeScalars.contains { (0x0660...0x0669).contains($0.value) }
        #expect(!eastern)
    }

    @Test("the net heading names the chosen period, and all time without one")
    func heading() async throws {
        let en = Words()
        await en.load("en", engine: try KhaytEngine())
        #expect(Reports.Totals.netHeading(en) == "Net Income · all time")
        #expect(Reports.Totals.netHeading(en, period: "Last month") == "Net Income · Last month")
    }

    @Test("a period's title: its name, or a custom range's own days")
    func titles() async throws {
        let en = Words()
        await en.load("en", engine: try KhaytEngine())
        #expect(Shop.pnlPeriodTitle(PnlRange(.last_quarter), words: en) == "Last quarter")
        #expect(Shop.pnlPeriodTitle(PnlRange(.last_year), words: en) == "Last year")
        let custom = Shop.pnlPeriodTitle(PnlRange(.custom, from: "2026-01-01", to: "2026-03-31"), words: en)
        #expect(custom.contains("2026-01-01") && custom.contains("2026-03-31"))
        // A custom range with no days yet is still called something.
        #expect(Shop.pnlPeriodTitle(PnlRange(.custom), words: en) == en.callIt("tax.custom_range"))
    }

    @Test("the export's file name carries the period, and the page and the file ask alike")
    func exportAsksWhatThePageAsks() async throws {
        let shop = Shop()
        await shop.load(.sample, asOf: SampleBook.anchor)
        let now = try #require(SampleBook.anchor)
        shop.pnlRange = PnlRange(.last_quarter)
        let name = shop.pnlFilename(.csv, now: now)
        let expected = "khayt-pnl-" + PnlRange(.last_quarter).fileStem(now: now) + ".csv"
        #expect(name == expected)
        #expect(shop.pnlFilename(.pdf, now: now).hasSuffix(".pdf"))

        let input = try #require(shop.pnlInputs(now: now))
        let bounds = PnlRange(.last_quarter).resolve(now: now).bounds
        #expect(input.from == bounds?.from)
        #expect(input.to == bounds?.to)

        // The page's rows and the file's are the same rows.
        let engine = try #require(shop.engine)
        let statement = try #require(await shop.pnlStatement(now: now))
        let docs = try await engine.pnlDocuments(input, labels: shop.pnlLabels(statement.vat),
                                                 periodLabel: "x", currency: shop.currency,
                                                 rightToLeft: false, language: "en", shopName: "")
        #expect(docs.csv.hasPrefix("\u{FEFF}"))
        for row in statement.rows {
            let name = row.isPartial ? "\"\(row.period) (" : "\"\(row.period)\","
            let found = docs.csv.contains(name)
            #expect(found, "\(row.period) is on the page and not in the file")
        }
    }

    @Test("an unreadable custom range asks nothing, rather than showing the whole book")
    func invalidRange() async throws {
        let shop = Shop()
        await shop.load(.sample, asOf: SampleBook.anchor)
        shop.pnlRange = PnlRange(.custom, from: "2026-13-01", to: "")
        #expect(shop.pnlInputs() == nil)
        let statement = await shop.pnlStatement()
        #expect(statement == nil)
    }

    /// LOOK at it, light and dark: the totals panel over a chosen period with
    /// the VAT card under it.
    @Test("the VAT summary card, photographed")
    func picture() async throws {
        let shop = Shop()
        await shop.load(.sample, asOf: SampleBook.anchor)
        let now = try #require(SampleBook.anchor)
        shop.pnlRange = PnlRange(.year)
        let statement = try #require(await shop.pnlStatement(now: now))
        let vat = statement.vat
        let snap = SnapshotTests()
        let totals = Reports.Totals(shop: shop, rows: statement.rows, floor: nil, vat: vat,
                                    period: shop.pnlPeriodTitle(now: now))
        try snap.render(totals.statement.frame(width: 300).background(Khayt.ground),
                        "pnl-period-vat", size: CGSize(width: 300, height: 900))
        try snap.renderDark(totals.statement.frame(width: 300),
                            "pnl-period-vat-dark", size: CGSize(width: 300, height: 900))
        if vat.applies {
            try snap.render(VatSummaryCard(shop: shop, vat: vat, period: "This year")
                                .frame(width: 300).padding(Metric.pane).background(Khayt.ground),
                            "pnl-vat-card", size: CGSize(width: 340, height: 320))
        }
    }
}
