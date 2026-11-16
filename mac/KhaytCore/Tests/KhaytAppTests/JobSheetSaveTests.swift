import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// S1 B3b, stage 1: the job sheet's save is ONE edit — customer, name,
/// details, parts, a typed total and the Not business mark — through
/// `lib/order-edit.js applyJobEdit`, all or nothing.
@MainActor
struct JobSheetSaveTests {

    static let clients: [JSONValue] = [
        .object(["id": .string("C1"), "nameEn": .string("Najd Architects")]),
        .object(["id": .string("C2"), "nameEn": .string("Red Sea Global")]),
    ]

    static func saved(_ order: JSONValue, _ save: Shop.JobSave, shop: Shop, engine: KhaytEngine) async throws -> JSONValue {
        try await Shop.jobSaved(order, save, clients: clients, settings: [:], engine: engine,
                                refusals: Shop.jobSaveRefusalWords(shop.words), now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    static func field(_ order: JSONValue, _ key: String) -> JSONValue? {
        if case .object(let o) = order { return o[key] }
        return nil
    }

    @Test("everything the sheet changed lands in one edit")
    func together() async throws {
        let engine = try KhaytEngine()
        let shop = Shop()
        let order = JobPartsRuleTests.job(["status": .string("quote"), "quoteShareStamped": .bool(true)])
        var save = Shop.JobSave()
        save.fields = ["project": .string("Bracket v2"), "notes": .string("collects Sunday"),
                       "priorityLevel": .string("urgent"), "dueDate": .string("2026-12-01")]
        save.customer = .some("C1")
        save.parts = [JobPartsRuleTests.part("A", 80), JobPartsRuleTests.part("B", 40), JobPartsRuleTests.part("", 20)]
        save.nonBusiness = true
        let out = try await Self.saved(order, save, shop: shop, engine: engine)
        #expect(Self.field(out, "project") == .string("Bracket v2"))
        #expect(Self.field(out, "notes") == .string("collects Sunday"))
        #expect(Self.field(out, "clientId") == .string("C1"))
        #expect(Self.field(out, "dueDate") == .string("2026-12-01"))
        #expect(Self.field(out, "price") == .number(210), "a draft quote follows its parts: 140 at 50%")
        #expect(Self.field(out, "nonBusiness") == .bool(true))
        guard case .array(let parts)? = Self.field(out, "parts"), parts.count == 3,
              case .object(let added) = parts[2], case .string(let id)? = added["id"] else {
            Issue.record("three parts, the new one with an id"); return
        }
        #expect(!id.isEmpty)
    }

    @Test("a refusal anywhere writes nothing — not even the Not business mark")
    func allOrNothing() async throws {
        let engine = try KhaytEngine()
        let shop = Shop()
        let paid = JobPartsRuleTests.job(["paidAmount": .number(150)])
        var save = Shop.JobSave()
        save.fields = ["project": .string("Renamed"), "discountPct": .number(30)]
        save.nonBusiness = true
        do {
            _ = try await Self.saved(paid, save, shop: shop, engine: engine)
            Issue.record("a discount that drops the bill below what was paid was taken")
        } catch let refused as Shop.MoveRefused {
            #expect(refused.code == "paid_exceeds_price")
            #expect(refused.sentence == shop.words.callIt("mac.parts_paid_exceeds"))
        }
        // A customer the rule locks is said in the customer's words, not the parts'.
        var move = Shop.JobSave()
        move.customer = .some("C2")
        let withCustomer = JobPartsRuleTests.job(["clientId": .string("C1"), "client": .string("Najd Architects"),
                                                  "paidAmount": .number(50)])
        do {
            _ = try await Self.saved(withCustomer, move, shop: shop, engine: engine)
            Issue.record("a paid job changed customer")
        } catch let refused as Shop.MoveRefused {
            #expect(refused.sentence == shop.words.callIt("mac.job_customer_locked_paid"))
        }
    }

    @Test("the same customer again is not a refusal, and nothing changed writes nothing")
    func sameAndEmpty() async throws {
        let engine = try KhaytEngine()
        let shop = Shop()
        let order = JobPartsRuleTests.job(["clientId": .string("C1"), "client": .string("Najd Architects")])
        var save = Shop.JobSave()
        save.customer = .some("C1")
        save.fields = ["notes": .string("x")]
        let out = try await Self.saved(order, save, shop: shop, engine: engine)
        #expect(Self.field(out, "notes") == .string("x"))
        #expect(try await Self.saved(order, Shop.JobSave(), shop: shop, engine: engine) == order)
        #expect(Shop.JobSave().isEmpty)
    }

    // MARK: - A new markup (applyJobEdit `marginPct`)

    @Test("a changed markup is sent; an unchanged one, or one never read, is not")
    func markupField() {
        var opened = JobSheet.Form()
        opened.markup = "50"
        var now = opened
        #expect(JobSheet.fields(opened: opened, now: now)["marginPct"] == nil)
        now.markup = "25"
        #expect(JobSheet.fields(opened: opened, now: now)["marginPct"] == .number(25))
        now.markup = "٣٠"
        #expect(JobSheet.fields(opened: opened, now: now)["marginPct"] == .number(30), "Arabic digits are read")
        now.markup = "lots"
        #expect(JobSheet.fields(opened: opened, now: now)["marginPct"] == .string("lots"), "sent so the rule says why")
        var typed = JobSheet.Form()
        typed.price = "199"
        #expect(JobSheet.fields(opened: typed, now: typed)["marginPct"] == nil, "a typed price has no markup field")
    }

    @Test("a new markup reprices a draft quote; a seen price needs the shop's yes")
    func markupSaves() async throws {
        let engine = try KhaytEngine()
        let shop = Shop()
        var save = Shop.JobSave()
        save.fields = ["marginPct": .number(25)]
        let draft = JobPartsRuleTests.job(["status": .string("quote"), "quoteShareStamped": .bool(true)])
        let out = try await Self.saved(draft, save, shop: shop, engine: engine)
        #expect(Self.field(out, "price") == .number(150), "120 of cost at 25%")
        #expect(Self.field(out, "marginPct") == .number(25))

        let seen = JobPartsRuleTests.job()                     // pending: the customer has seen it
        do {
            _ = try await Self.saved(seen, save, shop: shop, engine: engine)
            Issue.record("a seen price moved without asking")
        } catch let refused as Shop.MoveRefused {
            #expect(refused.code == "ask_price")
        }
        save.priceSeenOk = true
        let agreed = try await Self.saved(seen, save, shop: shop, engine: engine)
        #expect(Self.field(agreed, "price") == .number(150))
    }

    @Test("a markup on a typed price is refused in the shop's words")
    func markupOnTypedPrice() async throws {
        let engine = try KhaytEngine()
        let shop = Shop()
        var save = Shop.JobSave()
        save.fields = ["marginPct": .number(25)]
        save.priceSeenOk = true
        let typed = JobPartsRuleTests.job(["priceSource": .string("override"), "priceOverride": .number(199),
                                           "price": .number(199), "computedPrice": .number(180)])
        do {
            _ = try await Self.saved(typed, save, shop: shop, engine: engine)
            Issue.record("a typed price moved")
        } catch let refused as Shop.MoveRefused {
            #expect(refused.code == "price_fixed")
            #expect(refused.sentence == shop.words.callIt("mac.js_markup_fixed"))
        }
    }

}
