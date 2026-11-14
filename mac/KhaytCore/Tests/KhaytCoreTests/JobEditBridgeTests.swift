import Foundation
import Testing
@testable import KhaytCore

/// `lib/order-edit.js` partsLock / marginOf / applyJobEdit through the engine.
/// The rule's cases are `test/order-parts-edit.test.js`; this holds the
/// crossing, and that a refusal hands the job back untouched.
struct JobEditBridgeTests {

    static func part(_ id: String, _ cost: Double) -> JSONValue {
        .object(["id": .string(id), "name": .string("Part \(id)"), "material": .string("PLA"),
                 "printWeight": .number(100), "printTime": .number(2), "qty": .number(1),
                 "unitCost": .number(cost), "baseCost": .number(cost)])
    }

    /// Two parts costing 80 and 40 at a 50% margin: 180.
    static func job(_ extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string("J1"), "status": .string("pending"), "project": .string("Bracket"),
            "parts": .array([part("A", 80), part("B", 40)]), "price": .number(180),
            "discountPct": .number(0), "shippingCost": .number(0), "paidAmount": .number(0)]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    static func price(_ order: JSONValue) -> Double? {
        if case .object(let o) = order, case .number(let p)? = o["price"] { return p }
        return nil
    }

    @Test("the lock and the margin cross as the rule gave them")
    func lockAndMargin() async throws {
        let engine = try KhaytEngine()
        let open = try await engine.partsLock(Self.job())
        #expect(open.code == nil && open.edit && open.addRemove && !open.askPrice)
        #expect(try await engine.partsLock(Self.job(["status": .string("printing")])).askPrice)
        let done = try await engine.partsLock(Self.job(["status": .string("completed")]))
        #expect(done.code == "deducted" && done.nameOnly && !done.addRemove)
        #expect(try await engine.partsLock(Self.job(["zatcaUuid": .string("u")])).code == "zatca")
        #expect(try await engine.marginOf(Self.job()) == 50)
        #expect(try await engine.marginOf(Self.job(["price": .number(0)])) == nil)
        #expect(try await engine.marginOf(Self.job(["parts": .array([])])) == nil)
    }

    @Test("one edit: the name and the parts together, the price forward")
    func edit() async throws {
        let engine = try KhaytEngine()
        let r = try await engine.applyJobEdit(
            order: Self.job(),
            fields: ["project": .string("Bracket v2"),
                     "parts": .array([Self.part("A", 80), Self.part("B", 40), Self.part("", 20)])],
            newPartIds: ["P-new"], now: Date(timeIntervalSince1970: 1_800_000_000), editId: "e1", priceId: "e2")
        #expect(r.ok && r.changed && r.reason == nil)
        #expect(Self.price(r.order) == 210, "(80 + 40 + 20) at the job's own 50%")
        guard case .object(let o) = r.order, case .array(let parts)? = o["parts"] else { Issue.record("no parts"); return }
        #expect(o["project"] == .string("Bracket v2") && parts.count == 3)
    }

    @Test("a refusal names the rule and hands the job back untouched")
    func refused() async throws {
        let engine = try KhaytEngine()
        let paid = Self.job(["paidAmount": .number(150)])
        let r = try await engine.applyJobEdit(order: paid, fields: ["project": .string("X"), "parts": .array([Self.part("A", 80)])],
                                             now: Date(), editId: "e1", priceId: "e2")
        #expect(!r.ok && r.reason == "paid_exceeds_price" && r.step == "parts" && !r.changed)
        #expect(r.order == paid)
        let typed = try await engine.applyJobEdit(order: paid, fields: ["price": .number(100)], now: Date(), editId: "e1", priceId: "e2")
        #expect(typed.reason == "paid_exceeds_price" && typed.step == "price" && typed.order == paid)
        let same = try await engine.applyJobEdit(order: paid, fields: [:], now: Date(), editId: "e1", priceId: "e2")
        #expect(same.ok && !same.changed)
    }
}
