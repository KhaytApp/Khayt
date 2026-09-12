import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The other shelf, crossing into the engine and back.
///
/// The rule is `lib/consumable-reorder.js` and `test/consumable-reorder.test.js`
/// pins the arithmetic. These are about the CROSSING — and one of them is about
/// a value that cannot cross at all: the rule reports `Infinity` days of cover
/// for an item nothing is consuming, JSON has no way to carry that, and an
/// `Infinity` that quietly became `0` would put a full shelf at the top of a
/// list sorted by urgency.
@MainActor
struct ConsumableNeedsTests {

    static let now = Date(timeIntervalSince1970: 1_788_000_000)

    static func item(_ id: String, _ name: String, stock: Double,
                     unit: String = "each", minStock: Double? = nil,
                     packaging: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "name": .string(name),
            "stock": .number(stock), "unit": .string(unit),
        ]
        if let minStock { o["minStock"] = .number(minStock) }
        if packaging { o["isPackaging"] = .bool(true) }
        return .object(o)
    }

    /// A finished job that deducted one of every packaging item.
    static func packedJob(_ id: String, daysAgo: Double) -> JSONValue {
        let iso = ISO8601DateFormatter()
        let when = Self.now.addingTimeInterval(-daysAgo * 86_400)
        return .object([
            "id": .string(id), "status": .string("completed"),
            "packagingDeducted": .bool(true),
            "completedAt": .string(iso.string(from: when)),
            "date": .string(String(iso.string(from: when).prefix(10))),
        ])
    }

    static func needs(_ consumables: [JSONValue],
                      _ orders: [JSONValue] = []) async throws -> [KhaytEngine.ConsumableNeed] {
        try await KhaytEngine().consumableNeeds(
            consumables: consumables, orders: orders, now: Self.now)
    }

    @Test("an empty shelf is reported, in the shop's own unit")
    func empty() async throws {
        let out = try await Self.needs([Self.item("C1", "Isopropyl alcohol",
                                                  stock: 0, unit: "L", minStock: 2)])
        let need = try #require(out.first)
        #expect(need.id == "C1")
        #expect(need.label == "Isopropyl alcohol")
        #expect(need.unit == "L", "the unit is the shop's, never assumed to be grams")
        #expect(need.stock == 0)
        #expect(need.low)
        // Empty NOW. The rate does not come into it, and reporting this as
        // "unknown" would sort the most urgent state below a fortnight of cover.
        #expect(need.daysLeft == 0)
    }

    @Test("a stocked item nothing consumes reports no forecast, not zero days")
    func infinityBecomesNil() async throws {
        // This is the crossing under test. The rule returns Infinity here;
        // JSON cannot carry it. If it arrived as 0 this item would sort as the
        // most urgent thing in the shop while sitting at three times its
        // minimum.
        let out = try await Self.needs([
            Self.item("C1", "Spare nozzles", stock: 30, unit: "each", minStock: 10),
            // Something genuinely low, so the list is not empty for the wrong reason.
            Self.item("C2", "Glue sticks", stock: 0, unit: "each", minStock: 5),
        ])
        #expect(out.contains { $0.id == "C2" }, "the low item must be listed")
        if let stocked = out.first(where: { $0.id == "C1" }) {
            #expect(stocked.daysLeft == nil,
                    "Infinity cover must arrive as nil, never as 0 days left")
        }
    }

    @Test("an item above its minimum with no consumption is not asked for")
    func notLow() async throws {
        let out = try await Self.needs([
            Self.item("C1", "Nitrile gloves", stock: 500, unit: "each", minStock: 100),
        ])
        #expect(out.isEmpty, "a full shelf is not a reorder suggestion")
    }

    @Test("consumption gives a rate, and the days left follow from it")
    func rate() async throws {
        // Ten packed jobs over the trailing 30 days deduct one bag each.
        let jobs = (0..<10).map { Self.packedJob("J\($0)", daysAgo: Double($0) + 1) }
        let out = try await Self.needs([
            Self.item("C1", "Mailing bags", stock: 6, unit: "each",
                      minStock: 20, packaging: true),
        ], jobs)
        let need = try #require(out.first)
        #expect(need.low, "6 against a minimum of 20 is low")
        #expect(need.perDay > 0, "ten deductions in the window is a measurable rate")
        let days = try #require(need.daysLeft)
        #expect(days > 0 && days.isFinite, "with a rate there is a real forecast")
        #expect(need.suggestQty > 0, "something low with a rate gets a quantity")
    }

    @Test("nothing on the shelf is an answer, not a throw")
    func nothing() async throws {
        #expect(try await Self.needs([]).isEmpty)
        #expect(try await Self.needs([], []).isEmpty)
    }

    @Test("a consumable with no minimum and no rate is not given an invented quantity")
    func noFigure() async throws {
        // Empty, so it is low and must be reported — but nothing in the book
        // says how much of it a shop gets through, and no minimum says how much
        // it likes to keep. A number here would be a guess on a purchase order.
        let out = try await Self.needs([Self.item("C1", "Odd bracket", stock: 0)])
        let need = try #require(out.first)
        #expect(need.low)
        #expect(need.suggestQty == 0)
        #expect(need.minStock == nil)
    }
}
