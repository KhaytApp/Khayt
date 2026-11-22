import Foundation
import Testing
@testable import KhaytCore

/// What the shelf costs, through the engine.
///
/// `test/material-cost.test.js` pins the rules. What matters here is that the
/// two that make it correct survive: the quantity is what the item HELD, and
/// each item is priced in its own unit.
@Suite struct MaterialCostTests {

    static func spool(_ id: String, _ material: String, cost: Double,
                      held: Double, at: String, left: Double? = nil,
                      unit: String = "g") -> JSONValue {
        .object([
            "id": .string(id), "material": .string(material),
            "cost": .number(cost), "spoolWeight": .number(held),
            "weight": .number(left ?? held), "openedAt": .string(at),
            "unit": .string(unit),
        ])
    }

    static func run(_ engine: KhaytEngine,
                    _ inventory: [JSONValue]) async throws -> KhaytEngine.MaterialCost {
        try await engine.materialCost(inventory: inventory, minimum: 2)
    }

    /// Dividing by what is LEFT makes the figure a shop compares suppliers on
    /// climb as the roll empties, worst on the item about to be reordered.
    @Test("the rate is what the item held when it arrived, not what is left")
    func theRateUsesTheOriginal() async throws {
        let engine = try KhaytEngine()
        let full = try await Self.run(engine, [
            Self.spool("a", "PLA", cost: 75, held: 1000, at: "2026-01-01"),
        ])
        let nearlyGone = try await Self.run(engine, [
            Self.spool("b", "PLA", cost: 75, held: 1000, at: "2026-01-01", left: 40),
        ])
        #expect(full.rows.first?.perUnit == 75)
        #expect(nearlyGone.rows.first?.perUnit == 75)
    }

    /// A per-kilo figure for everything reported the sample shop's acrylic at
    /// 42,000, because a sheet is not weighed.
    @Test("each item is priced in its own unit")
    func eachInItsOwnUnit() async throws {
        let engine = try KhaytEngine()
        let report = try await Self.run(engine, [
            Self.spool("a", "PLA", cost: 75, held: 1000, at: "2026-01-01"),
            Self.spool("b", "Resin", cost: 360, held: 1000, at: "2026-01-01", unit: "ml"),
            Self.spool("c", "Acrylic", cost: 42, held: 1, at: "2026-01-01", unit: "sheet"),
        ])
        #expect(report.rows.first { $0.material == "PLA" }?.rate == "kg")
        #expect(report.rows.first { $0.material == "Resin" }?.rate == "L")
        #expect(report.rows.first { $0.material == "Acrylic" }?.rate == "sheet")
        #expect(report.rows.first { $0.material == "Acrylic" }?.perUnit == 42)
    }

    /// Two rolls a month apart from different sellers is noise, not a trend.
    @Test("a change needs more than one purchase, and is first against last")
    func changeNeedsHistory() async throws {
        let engine = try KhaytEngine()
        let once = try await Self.run(engine, [
            Self.spool("a", "PLA", cost: 75, held: 1000, at: "2026-01-01"),
        ])
        #expect(once.rows.first?.changePct == nil)
        #expect(once.totals.anyChangeKnown == false)

        let thrice = try await Self.run(engine, [
            Self.spool("a", "PLA", cost: 60, held: 1000, at: "2026-01-01"),
            Self.spool("b", "PLA", cost: 90, held: 1000, at: "2026-03-01"),
            Self.spool("c", "PLA", cost: 75, held: 1000, at: "2026-08-01"),
        ])
        #expect(thrice.rows.first?.perUnit == 75, "the current rate is the latest bought")
        #expect(thrice.rows.first?.changePct == 25)
    }

    @Test("a fall is not the steepest rise")
    func onlyARiseIsSteepest() async throws {
        let engine = try KhaytEngine()
        let report = try await Self.run(engine, [
            Self.spool("a", "PETG", cost: 100, held: 1000, at: "2026-01-01"),
            Self.spool("b", "PETG", cost: 80, held: 1000, at: "2026-08-01"),
            Self.spool("c", "PLA", cost: 60, held: 1000, at: "2026-01-01"),
            Self.spool("d", "PLA", cost: 72, held: 1000, at: "2026-08-01"),
        ])
        #expect(report.rows.first { $0.material == "PETG" }?.changePct == -20)
        #expect(report.totals.steepest?.material == "PLA")
    }

    /// A screen can only have been reviewed against data that reaches it.
    @Test("the sample shop reaches this card, in both directions")
    func theSampleReachesIt() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Resources/sample-shop.json")
        let root = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        guard case .object(let book) = root, case .array(let inventory)? = book["inventory"] else {
            Issue.record("could not read the sample shop"); return
        }
        let engine = try KhaytEngine()
        let report = try await Self.run(engine, inventory)
        #expect(report.totals.anyChangeKnown,
                "nothing is bought twice, so no price change is ever drawn")
        #expect(report.rows.contains { ($0.changePct ?? 0) > 0 }, "no rise is drawn")
        #expect(report.rows.contains { ($0.changePct ?? 0) < 0 }, "no fall is drawn")
        // And more than one unit, so the grouping is exercised.
        #expect(Set(report.rows.map(\.rate)).count > 1)
    }
}
