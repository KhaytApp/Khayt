import Foundation
import Testing
@testable import KhaytApp
import KhaytCore

/// Every screen that offers a search field must narrow something with it.
///
/// The repo already had this rule written down, on `shownExpenses`: *a search
/// field that does nothing on the screen you are looking at is worse than no
/// search field.* It was followed everywhere a list was added and could not be
/// enforced, because `.searchable` sat on the window and applied to all fifteen
/// shelves whether or not they had anything to filter.
///
/// So four screens that are not lists at all — the calculator, the colour
/// studio, the reports and the dashboard — carried a search field that could be
/// typed into and did nothing, labelled "Job, customer or number" because the
/// prompt fell through to the jobs one. The catalogue carried the same field
/// and the same wrong label while genuinely being a list.
@MainActor
struct SearchReachTests {

    /// `canSearch` is written the positive way round on purpose: a new shelf
    /// gets NO search box until somebody says it has one. This is that promise
    /// — every shelf is named, so adding one to the enum fails to compile here
    /// rather than silently inheriting a dead field.
    @Test("every shelf has decided whether it can be searched")
    func everyShelfDecides() {
        let shelves: [Shop.Shelf] = [
            .jobs(nil), .board, .library(nil), .customers, .inventory,
            .expenses, .waste, .portfolio, .giftCards, .catalogue,
            .dashboard, .machines, .reports, .colour, .calculator,
        ]
        let shop = Shop()
        var searchable: [Shop.Shelf] = []
        for shelf in shelves {
            shop.shelf = shelf
            if shop.canSearch { searchable.append(shelf) }
        }
        // The lists, and only the lists.
        #expect(searchable.count == 10, "searchable shelves: \(searchable)")
        for shelf in [Shop.Shelf.dashboard, .machines, .reports, .colour, .calculator] {
            shop.shelf = shelf
            #expect(!shop.canSearch, "\(shelf) offers a search field with nothing to search")
        }
    }

    /// The gap this pass closed.
    @Test("the catalogue narrows by name, description, material and group")
    func catalogueFilters() {
        let shop = Shop()
        shop.setCatalogueForTesting([
            row(id: "1", name: "Palm Vase", description: "tall", material: "PLA", group: "Vases"),
            row(id: "2", name: "King Faisal", description: "relief", material: "Resin", group: "Kings"),
        ])

        shop.search = ""
        #expect(shop.shownProducts.count == 2)

        shop.search = "palm"
        #expect(shop.shownProducts.map(\.id) == ["1"], "not matching on name")

        shop.search = "relief"
        #expect(shop.shownProducts.map(\.id) == ["2"], "not matching on description")

        shop.search = "resin"
        #expect(shop.shownProducts.map(\.id) == ["2"], "not matching on material")

        shop.search = "kings"
        #expect(shop.shownProducts.map(\.id) == ["2"], "not matching on group")

        // Case and stray spaces are how somebody actually types.
        shop.search = "  PALM  "
        #expect(shop.shownProducts.map(\.id) == ["1"])

        shop.search = "nothing here"
        #expect(shop.shownProducts.isEmpty)
    }

    private func row(id: String, name: String, description: String,
                     material: String, group: String) -> KhaytEngine.CatalogueRow {
        KhaytEngine.CatalogueRow(
            id: id, name: name, description: description, base: 10, final: 12,
            source: "calculated", reason: "pe.price_is_calculated", margin: 30,
            printHours: 1, weightGrams: 20, material: material, parts: 1,
            thumbnail: "", group: group)
    }
}
