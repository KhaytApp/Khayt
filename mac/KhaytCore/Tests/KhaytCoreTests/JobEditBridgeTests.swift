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
        // A draft quote follows its parts by itself; once the customer has
        // seen the price (a shared quote, any accepted job) the sheet asks.
        let draft = try await engine.partsLock(Self.job(["status": .string("quote"), "quoteShareStamped": .bool(true)]))
        #expect(draft.code == nil && draft.edit && draft.addRemove && !draft.askPrice)
        #expect(try await engine.partsLock(Self.job(["status": .string("quote"), "quoteSharedAt": .string("2026-11-14T10:00:00Z")])).askPrice)
        #expect(try await engine.partsLock(Self.job()).askPrice, "an accepted job")
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
    // MARK: - What the next beta inherits from lib (#2523, #2524)

    /// A quote this app makes is known to be a draft (`quoteShareStamped`,
    /// written by `newOrder`), so its price follows its parts without asking,
    /// until it goes out. A quote WITHOUT the marker (made by an older build,
    /// which did not stamp `quoteSharedAt` when it sent one) always asks.
    @Test("a new quote is a known draft; sent, or from an older build, it asks")
    func newQuoteIsADraft() async throws {
        let engine = try KhaytEngine()
        let made = try await engine.newOrder(
            ["asQuote": .bool(true), "project": .string("Bracket"), "margin": .number(50),
             "parts": .array([Self.part("A", 80)])],
            orders: [], settings: [:], now: Date(timeIntervalSince1970: 1_800_000_000),
            tokens: (tracking: Array(repeating: 7, count: 16), quoteApproval: Array(repeating: 9, count: 16)))
        guard case .object(var quote) = made.order else { Issue.record("no order"); return }
        #expect(quote["status"] == .string("quote"))
        #expect(quote["quoteShareStamped"] == .bool(true), "newOrder marks every quote it makes")
        #expect(try await engine.partsLock(.object(quote)).askPrice == false, "a draft: the price follows")

        // The Mac stamps this where a quote leaves (`Shop.noteQuoteShared`).
        quote["quoteSharedAt"] = .string("2026-11-17T09:00:00.000Z")
        #expect(try await engine.partsLock(.object(quote)).askPrice, "sent: the customer has seen the price")

        // A job taken as a job is never marked: only quotes are.
        let job = try await engine.newOrder(
            ["project": .string("Bracket"), "margin": .number(50), "parts": .array([Self.part("A", 80)])],
            orders: [], settings: [:], now: Date(timeIntervalSince1970: 1_800_000_000),
            tokens: (tracking: Array(repeating: 7, count: 16), quoteApproval: Array(repeating: 9, count: 16)))
        if case .object(let o) = job.order { #expect(o["quoteShareStamped"] == nil) } else { Issue.record("no job") }

        // From before the marker: may have been sent with no stamp, so it asks.
        #expect(try await engine.partsLock(Self.job(["status": .string("quote")])).askPrice)
        for sign: [String: JSONValue] in [["quoteAcceptedAt": .string("2026-11-14")], ["quoteVersion": .number(2)],
                                          ["quoteRevisions": .array([.object(["v": .number(1)])])]] {
            var extra: [String: JSONValue] = ["status": .string("quote"), "quoteShareStamped": .bool(true)]
            for (k, v) in sign { extra[k] = v }
            #expect(try await engine.partsLock(Self.job(extra)).askPrice, "\(sign.keys.first ?? "")")
        }
    }

    /// A job whose earlier parts hold no cost (taken over the LAN, from a
    /// subscription or an inventory sale, or in an old book) was priced some
    /// other way. Adding a costed part used to drop its price to that part's
    /// bare cost: 200 became 50 (#2523). Through the Mac's own call, as Edit
    /// Job and Revise make it: no markup passed.
    @Test("adding a costed part to a job whose parts hold no cost keeps its price")
    func partsWithNoCostKeepThePrice() async throws {
        let engine = try KhaytEngine()
        let bare: JSONValue = .object(["id": .string("P1"), "name": .string("a"), "printWeight": .number(10), "qty": .number(1)])
        let added: JSONValue = .object(["name": .string("b"), "baseCost": .number(50), "unitCost": .number(50), "qty": .number(1)])
        for status in ["pending", "quote"] {
            var o: [String: JSONValue] = ["id": .string("J-L"), "status": .string(status), "price": .number(200),
                                          "paidAmount": .number(0), "parts": .array([bare])]
            if status == "quote" { o["quoteShareStamped"] = .bool(true) }
            let r = try await engine.applyJobEdit(order: .object(o), fields: ["parts": .array([bare, added])],
                                                 newPartIds: ["P-new"], now: Date(timeIntervalSince1970: 1_800_000_000),
                                                 editId: "e1", priceId: "e2")
            #expect(r.ok && r.changed, Comment(rawValue: status))
            #expect(Self.price(r.order) == 200, "\(status): the price stays, it does not fall to the new part's cost")
            guard case .object(let after) = r.order, case .array(let parts)? = after["parts"] else { Issue.record("no order"); continue }
            #expect(parts.count == 2)
            #expect(after["priceSource"] == .string("override"), "kept as a typed price")
            #expect(after["computedPrice"] == .number(50), "with the arithmetic beside it")
        }
        // A job with no price and nothing costed still takes the new part's cost.
        let empty: JSONValue = .object(["id": .string("J-Z"), "status": .string("pending"), "price": .number(0),
                                        "paidAmount": .number(0), "parts": .array([])])
        let z = try await engine.applyJobEdit(order: empty, fields: ["parts": .array([added])], newPartIds: ["P-new"],
                                             now: Date(timeIntervalSince1970: 1_800_000_000), editId: "e1", priceId: "e2")
        #expect(z.ok && Self.price(z.order) == 50)
    }
}
