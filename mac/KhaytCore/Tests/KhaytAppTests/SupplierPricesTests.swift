import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// What a material has cost, and what may honestly be compared with what.
///
/// ── THE FAULT THE RULE EXISTS FOR ─────────────────────────────────────────
///
/// A purchase records an amount, a quantity and a UNIT the shop picked from a
/// list. The material is free text, so the same word — "PLA" — is attached to
/// a spool bought for 75 and, a month later, a kilogram bought for 22. The
/// other app's chart once put both on one trend line, badged the move between
/// them as a price change, and named a "best price" supplier by sorting the
/// mixed numbers. All three are meaningless: the shop selling by the gram wins
/// every comparison against the shop selling by the spool.
///
/// So the grouping is by material AND unit family, and these tests are about
/// this app never flattening that.
@MainActor
struct SupplierPricesTests {

    static func supplier(_ name: String, _ purchases: [JSONValue]) -> JSONValue {
        .object(["id": .string("SUP-" + name), "name": .string(name),
                 "purchases": .array(purchases)])
    }

    static func bought(_ material: String, unit: String, qty: Double,
                       amount: Double, date: String, unitPrice: Double? = nil) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(material + date), "date": .string(date),
            "amount": .number(amount), "quantity": .number(qty),
            "unit": .string(unit), "materialType": .string(material),
        ]
        if let unitPrice { o["unitPrice"] = .number(unitPrice) }
        return .object(o)
    }

    @Test("the same material bought two ways is two groups, not one trend")
    func spoolsAndKilosDoNotMix() async throws {
        let engine = try KhaytEngine()
        let sup = Self.supplier("Tuwaiq", [
            Self.bought("PLA", unit: "spool", qty: 4, amount: 300, date: "2026-05-01"),
            Self.bought("PLA", unit: "kg", qty: 5, amount: 110, date: "2026-07-01"),
        ])
        let groups = try await engine.supplierPriceGroups([sup], untagged: "Untagged")
        #expect(groups.count == 2, "a spool price and a kilo price were compared")
        #expect(Set(groups.map(\.unit)) == ["spool", "kg"])
        // And neither claims a MOVE, because neither has a second reading in
        // its own unit to compare with. The rule answers 0 rather than nil
        // there, and 0 is below the threshold the card badges at — which is
        // the behaviour that matters: a group of one draws no arrow.
        #expect(groups.allSatisfy { ($0.pctChange ?? 0) == 0 })
    }

    @Test("grams and kilograms ARE one group, converted to the family's base")
    func massConverts() async throws {
        // A price per gram converts into a price per kilogram exactly, which
        // is what makes them comparable at all — and the group says it
        // converted so a shop is not shown a figure it did not type.
        let engine = try KhaytEngine()
        let sup = Self.supplier("Tuwaiq", [
            Self.bought("PETG", unit: "kg", qty: 1, amount: 85, date: "2026-05-01"),
            Self.bought("PETG", unit: "g", qty: 1000, amount: 90, date: "2026-07-01"),
        ])
        let groups = try await engine.supplierPriceGroups([sup], untagged: "Untagged")
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(group.unit == "kg")
        #expect(group.converted, "the card cannot say the figures were converted")
        // 90 for 1,000 g is 0.09 a gram, which is 90 a kilogram.
        #expect(abs((group.latest?.price ?? 0) - 90) < 0.005)
    }

    @Test("a purchase with no material named is not filed under another one")
    func untaggedStandsApart() async throws {
        let engine = try KhaytEngine()
        let sup = Self.supplier("Jeddah", [
            Self.bought("", unit: "piece", qty: 200, amount: 120, date: "2026-09-05"),
        ])
        let groups = try await engine.supplierPriceGroups([sup], untagged: "Untagged")
        #expect(groups.first?.material == "Untagged")
    }

    @Test("the cheapest is the cheapest within one unit, and it says who")
    func bestIsWithinAUnit() async throws {
        let engine = try KhaytEngine()
        let groups = try await engine.supplierPriceGroups([
            Self.supplier("Tuwaiq", [Self.bought("ASA", unit: "kg", qty: 1, amount: 95,
                                                 date: "2026-05-01")]),
            Self.supplier("Jeddah", [Self.bought("ASA", unit: "kg", qty: 1, amount: 80,
                                                 date: "2026-06-01")]),
        ], untagged: "Untagged")
        let group = try #require(groups.first)
        #expect(group.best?.supplier == "Jeddah")
        #expect(group.worst?.supplier == "Tuwaiq")
        #expect(group.count == 2)
    }

    @Test("an explicit unit price wins over the amount spread across the quantity")
    func explicitPriceWins() async throws {
        // Both are in the book and they can disagree — a delivery charge lands
        // in `amount` and not in `unitPrice`. The rule prefers what the shop
        // typed as the price.
        let engine = try KhaytEngine()
        let sup = Self.supplier("Tuwaiq", [
            Self.bought("PLA+", unit: "kg", qty: 2, amount: 200, date: "2026-05-01",
                        unitPrice: 85),
        ])
        let groups = try await engine.supplierPriceGroups([sup], untagged: "Untagged")
        #expect(groups.first?.latest?.price == 85, "the rule divided the amount instead")
    }

    // MARK: - The wiring

    @Test("a shop with no purchase log is shown no card at all")
    func noLogNoCard() async throws {
        let shop = Shop()
        await shop.load(.sample)
        // The sample DOES carry a log, so this proves the accessor works
        // rather than that it returns nothing.
        let groups = await shop.supplierPrices()
        #expect(!groups.isEmpty, "the sample book stopped carrying purchases")

        let floor = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/ShopFloor.swift"), encoding: .utf8)
        #expect(floor.contains("if !supplierPrices.isEmpty"),
                "a shop that has logged nothing is shown an empty frame")
        #expect(floor.contains("SupplierPricesCard(shop: shop, groups: supplierPrices)"),
                "the card is on no screen")
    }

    @Test("the sample book reaches the case the rule exists for")
    func theSampleSpansIt() async throws {
        // Spools and kilograms of the same material, which is the whole reason
        // the grouping is what it is. A sample that cannot reach it leaves the
        // two-card case undrawn.
        let shop = Shop()
        await shop.load(.sample)
        let groups = await shop.supplierPrices()
        let byMaterial = Dictionary(grouping: groups, by: \.material)
        #expect(groups.count >= 2)
        #expect(byMaterial.values.contains { $0.count > 1 }
                || Set(groups.map(\.unit)).count > 1,
                "every sample purchase is counted the same way, so nothing is ever grouped apart")
    }
}
