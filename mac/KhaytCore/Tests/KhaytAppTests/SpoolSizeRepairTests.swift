import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A part is costed on its spool's SIZE, and products costed on the grams
/// left are repaired once, on open.
@MainActor
struct SpoolSizeRepairTests {

    @Test("a part carrying the grams left is given the spool's size; one already right is left")
    func fixesOnlyWhatIsWrong() throws {
        let parts: [JSONValue] = [
            .object(["filamentId": .string("S1"), "spoolWeight": .number(859)]),
            .object(["filamentId": .string("S2"), "spoolWeight": .number(750)]),
            .object(["printWeight": .number(10)]),
        ]
        let fixed = try #require(Shop.spoolSizesFixed(parts, sizes: ["S1": 1000, "S2": 750]))
        guard case .object(let a) = fixed[0], case .object(let b) = fixed[1] else { Issue.record("shape"); return }
        #expect(a["spoolWeight"] == .number(1000))
        #expect(b["spoolWeight"] == .number(750))
        #expect(fixed[2] == parts[2])
        #expect(Shop.spoolSizesFixed(fixed, sizes: ["S1": 1000, "S2": 750]) == nil, "not idempotent")
    }

    @Test("every place a part takes a spool uses its size, and an open only COUNTS what the repair would change")
    func wired() throws {
        let shop = try QuoteSheetStatusTests.source("Shop.swift")
        let sheet = try QuoteSheetStatusTests.source("ProductSheet.swift")
        #expect(!shop.contains("spool.weight ?? 1000"))
        #expect(!sheet.contains("spool.weight ?? 1000"))
        // The repair that re-priced the catalogue on every open is gone; the
        // open counts, and the catalogue offers a review.
        #expect(!shop.contains("repairSpoolSizes"))
        #expect(shop.contains("Self.spoolRepairCount(products: productRows, sizes: spoolSizes)"))
        let catalogue = try QuoteSheetStatusTests.source("Catalogue.swift")
        #expect(catalogue.contains("SpoolRepairSheet(shop: shop)"))
        #expect(catalogue.contains("shop.showingSpoolRepair = true"))
        let sheetSrc = try QuoteSheetStatusTests.source("SpoolRepairSheet.swift")
        #expect(sheetSrc.contains("await shop.spoolRepairPreview()"))
        #expect(sheetSrc.contains("await shop.applySpoolRepair(changes)"))
    }

    // MARK: - The sample book, with a spool's size changed

    /// The sample book with its first three products costed on `sp-1` at
    /// 1000 g — the shape of the shop's real catalogue (every product on one
    /// spool) — and `sp-1` since re-sized to 750 g.
    static func resizedSample() throws -> (root: [String: JSONValue], sizes: [String: Double], ids: [String]) {
        let url = try #require(Bundle.module.url(forResource: "sample-shop", withExtension: "json"))
        var root = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        var rows = Shop.rows(root, "products")
        var ids: [String] = []
        for i in 0..<3 {
            guard case .object(var p) = rows[i], case .array(let parts)? = p["parts"] else { continue }
            p["parts"] = .array(parts.map { part in
                guard case .object(var o) = part else { return part }
                o["filamentId"] = .string("sp-1")
                o["spoolWeight"] = .number(1000)
                o["spoolCost"] = .number(75)
                return .object(o)
            })
            rows[i] = .object(p)
            if let id = Shop.recordId(rows[i]) { ids.append(id) }
        }
        root["products"] = .array(rows)
        return (root, ["sp-1": 750], ids)
    }

    static func plan(_ root: [String: JSONValue], sizes: [String: Double],
                     engine: KhaytEngine) async -> [Shop.SpoolRepairChange] {
        let inventory = Shop.rows(root, "inventory"), settings = Shop.settings(root)
        let consumables = Shop.rows(root, "consumables")
        return await Shop.spoolRepairPlan(products: Shop.rows(root, "products"), sizes: sizes) { input in
            try? await engine.productPricingFields(.object(input), inventory: inventory,
                                                   settings: settings, consumables: consumables)
        }
    }

    @Test("a spool's size changed: the open counts three products and changes not one byte of them")
    func sizeChangeTouchesNothing() async throws {
        let (root, sizes, ids) = try Self.resizedSample()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(root["products"])
        #expect(Shop.spoolRepairCount(products: Shop.rows(root, "products"), sizes: sizes) == ids.count)
        // The preview reads; it writes nothing either.
        let engine = try KhaytEngine()
        let plan = await Self.plan(root, sizes: sizes, engine: engine)
        #expect(plan.map(\.id) == ids)
        #expect(try encoder.encode(root["products"]) == before, "the catalogue moved without the shop")
    }

    @Test("the review shows each price before and after, and writes only what was shown")
    func reviewPath() async throws {
        let (root, sizes, ids) = try Self.resizedSample()
        let engine = try KhaytEngine()
        let plan = await Self.plan(root, sizes: sizes, engine: engine)
        try #require(plan.count == 3)
        // Every price the review shows is one the open used to write on its
        // own. The sample's stored prices were not made by today's rule, so
        // they move a lot (104.98 → 25 on the first) — a book whose prices
        // drifted from the rule is exactly the one an automatic re-price hurts.
        #expect(plan.contains { $0.priceNow != $0.priceWas },
                "no price would change: \(plan.map { ($0.priceWas, $0.priceNow) })")

        // A product edited after the preview was shown is left as edited.
        var book = root
        var rows = Shop.rows(book, "products")
        guard case .object(var edited) = rows[1] else { Issue.record("shape"); return }
        edited["basePrice"] = .number(999)
        rows[1] = .object(edited)
        book["products"] = .array(rows)

        let done = Shop.applySpoolRepair(plan, to: &book)
        #expect(done == [ids[0], ids[2]])
        let after = Shop.rows(book, "products")
        guard case .object(let first) = after[0], case .object(let second) = after[1],
              case .object(let fourth) = after[3] else { Issue.record("shape"); return }
        #expect(Shop.listedPrice(first) == plan[0].priceNow)
        #expect(second["basePrice"] == .number(999), "an edit made meanwhile was overwritten")
        #expect(after[3] == Shop.rows(root, "products")[3], "a product the review did not list moved")
        _ = fourth
        // The second time there is nothing left to repair.
        #expect(Shop.spoolRepairCount(products: [after[0], after[2]], sizes: sizes) == 0)
    }
}
