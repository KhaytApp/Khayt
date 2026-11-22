import Foundation
import SwiftUI
import Testing
import KhaytCore
@testable import KhaytApp

/// Profit per printer hour, where the shop reads it: the Catalogue's column,
/// the Reports card and the Web Store sheet's suggestions.
@MainActor
struct ProfitPerHourAppTests {

    static func row(_ id: String, _ name: String) -> KhaytEngine.CatalogueRow {
        KhaytEngine.CatalogueRow(id: id, name: name, description: "", base: 0, final: 0,
                                 source: "base", reason: "pe.price_is_base", margin: nil,
                                 printHours: nil, weightGrams: nil, material: "", parts: 0)
    }

    static func rate(_ id: String, _ perHour: Double?, underpriced: Bool = false) -> KhaytEngine.ProfitPerHour.Row {
        KhaytEngine.ProfitPerHour.Row(
            productId: id, name: id, price: perHour == nil ? nil : 100, cost: 50,
            hours: perHour == nil ? nil : 2, profit: perHour == nil ? nil : 50,
            perHour: perHour, missing: perHour == nil ? "hours" : nil,
            underpriced: underpriced, suggestedPrice: underpriced ? 140 : nil)
    }

    static func report(_ rows: [KhaytEngine.ProfitPerHour.Row],
                       best: [KhaytEngine.ProfitPerHour.Row] = [],
                       under: [KhaytEngine.ProfitPerHour.Row] = []) -> KhaytEngine.ProfitPerHour {
        KhaytEngine.ProfitPerHour(
            rows: rows,
            totals: .init(ranked: rows.count { $0.perHour != nil },
                          noHours: rows.count { $0.perHour == nil }, noPrice: 0,
                          averagePerHour: 20, actualPerHour: nil,
                          best: rows.first?.productId, underpriced: under.count),
            storeBest: best, storeUnderpriced: under)
    }

    @Test("the rate lands on each catalogue row, and a product with none sorts last")
    func stampsTheCatalogue() {
        let shop = Shop()
        shop.setCatalogueForTesting([Self.row("a", "A"), Self.row("b", "B"), Self.row("c", "C")])
        shop.stampPerHour(Self.report([Self.rate("b", 30), Self.rate("a", -5), Self.rate("c", nil)]))
        let byId = Dictionary(uniqueKeysWithValues: shop.catalogueRows.map { ($0.id, $0) })
        #expect(byId["a"]?.perHour == -5)
        #expect(byId["b"]?.perHour == 30)
        #expect(byId["c"]?.perHour == nil)
        let sorted = shop.catalogueRows.sorted(using: KeyPathComparator(\.perHourSort, order: .reverse))
        #expect(sorted.map(\.id) == ["b", "a", "c"], "no rate is unknown, not below a loss")

        // Cleared with the report, rather than left from the last book.
        shop.stampPerHour(nil)
        #expect(shop.catalogueRows.allSatisfy { $0.perHour == nil })
        #expect(shop.profitPerHour == nil)
    }

    @Test("no rate reads as a dash, never as zero")
    func dash() {
        let shop = Shop()
        #expect(PerHour.text(nil, shop) == "—")
        #expect(PerHour.text(12.5, shop) != "—")
    }

    @Test("the web store only offers suggestions when it has some")
    func hintsOnlyWhenAny() {
        #expect(!WebStorePerHourHints.hasAnything(nil))
        #expect(!WebStorePerHourHints.hasAnything(Self.report([Self.rate("a", 10)])))
        #expect(WebStorePerHourHints.hasAnything(
            Self.report([Self.rate("a", 10)], under: [Self.rate("a", 10, underpriced: true)])))
    }

    @Test("the sample book is ranked on load")
    func sampleBook() async {
        let shop = Shop()
        await shop.load(.sample)
        guard let report = shop.profitPerHour else {
            Issue.record("the sample book was not ranked"); return
        }
        #expect(report.rows.count == shop.productRows.count)
        for row in shop.catalogueRows {
            #expect(row.perHour == report.row(row.id)?.perHour, "\(row.id)")
        }
        // Ranked rows first, best first.
        let rates = report.rows.compactMap(\.perHour)
        #expect(rates == rates.sorted(by: >))
    }

    @Test("the card and the hints draw, in both languages")
    func draws() {
        let shop = Shop()
        let report = Self.report([Self.rate("a", 30), Self.rate("b", 5, underpriced: true), Self.rate("c", nil)],
                                 best: [Self.rate("a", 30), Self.rate("b", 5)],
                                 under: [Self.rate("b", 5, underpriced: true)])
        for view in [AnyView(BestUseOfPrinterCard(shop: shop, report: report).frame(width: 520)),
                     AnyView(BestUseOfPrinterCard(shop: shop, report: nil).frame(width: 520)),
                     AnyView(Form { WebStorePerHourHints(shop: shop, report: report) }.frame(width: 520, height: 400))] {
            let renderer = ImageRenderer(content: view)
            #expect(renderer.nsImage != nil)
        }
    }
}
