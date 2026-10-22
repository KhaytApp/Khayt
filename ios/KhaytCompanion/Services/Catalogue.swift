import Foundation
import KhaytCore

/// One product as the phone shows it: the Mac's own catalogue row
/// (`KhaytEngine.catalogue`, so the price is the one the Mac shows) and
/// the counted stock, when the shop counts it.
struct CatalogueItem: Identifiable, Hashable {
    let row: KhaytEngine.CatalogueRow
    /// Nil is not stocked, which is not the same as 0 (`Shop.stockCount`).
    let stock: Int?
    var id: String { row.id }
}

struct CataloguePage {
    var items: [CatalogueItem] = []
    var currency: String?
    /// The phone holds every product (`BookScope`); false means a capped list.
    var whole = true
}

extension BookReader {

    /// The shop's catalogue, named in `language`, newest name first within
    /// each group as the Mac lists it.
    func catalogue(language: String) async throws -> CataloguePage {
        let store = try wholeBook()
        guard case .array(let products)? = store["products"] else { return CataloguePage() }
        let settings = Self.settings(store)
        let rows = try await sharedEngine().catalogue(products, language: language, settings: settings)
        var stock: [String: JSONValue] = [:]
        if case .object(let front)? = settings["storefront"], case .object(let qty)? = front["stockQty"] { stock = qty }
        let items = rows.map { row -> CatalogueItem in
            var count: Int?
            if case .number(let n)? = stock[row.id], n.isFinite { count = max(0, Int(n)) }
            return CatalogueItem(row: row, stock: count)
        }
        var currency: String?
        if case .string(let c)? = settings["currency"], !c.isEmpty { currency = c }
        return CataloguePage(items: items, currency: currency, whole: holdsAll("products"))
    }

    /// Search across name, description, group and material: every word must
    /// match, ignoring case and diacritics, as the library searches.
    nonisolated static func filter(_ items: [CatalogueItem], query: String) -> [CatalogueItem] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { item in
            let hay = [item.row.name, item.row.description, item.row.group, item.row.material].joined(separator: " ")
            return words.allSatisfy { hay.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}
