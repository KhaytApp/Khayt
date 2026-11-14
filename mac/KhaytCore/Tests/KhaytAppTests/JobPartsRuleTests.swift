import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// S1 B3a: a part edited or removed on the Mac goes through the shared rule
/// (`lib/order-edit.js applyJobEdit`), so the job's price, time and material
/// follow — and the locks and the paid guard apply, in the shop's words.
@MainActor
struct JobPartsRuleTests {

    static func part(_ id: String, _ cost: Double, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        var p: [String: JSONValue] = ["id": .string(id), "name": .string("Part \(id)"), "material": .string("PLA"),
                                      "printWeight": .number(100), "printTime": .number(2), "qty": .number(1),
                                      "unitCost": .number(cost), "baseCost": .number(cost)]
        for (k, v) in extra { p[k] = v }
        return .object(p)
    }

    /// 80 + 40 at a 50% margin: 180.
    static func job(_ extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string("J1"), "status": .string("pending"), "project": .string("Bracket"),
            "parts": .array([part("A", 80), part("B", 40)]), "price": .number(180), "printTime": .number(4),
            "material": .string("PLA"), "discountPct": .number(0), "shippingCost": .number(0), "paidAmount": .number(0)]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    static func with(_ order: JSONValue, parts: [JSONValue]) -> JSONValue {
        guard case .object(var o) = order else { return order }
        o["parts"] = .array(parts)
        return .object(o)
    }

    static func number(_ order: JSONValue, _ key: String) -> Double? {
        if case .object(let o) = order, case .number(let n)? = o[key] { return n }
        return nil
    }

    @Test("an edited part moves the job's price, time and material together")
    func follows() async throws {
        let engine = try KhaytEngine()
        let shop = Shop()
        let order = Self.job()
        // Part B re-costed from 40 to 100 and made in PETG.
        let edited = Self.with(order, parts: [Self.part("A", 80), Self.part("B", 100, ["material": .string("PETG"),
                                                                                        "printWeight": .number(250), "printTime": .number(5)])])
        let out = try await Shop.jobWithParts(of: edited, on: order, keepPrice: false, settings: [:], engine: engine,
                                              refusals: Shop.partsRefusalWords(shop.words))
        #expect(Self.number(out.order, "price") == 270, "(80 + 100) at the job's own 50%")
        #expect(Self.number(out.order, "printTime") == 7)
        guard case .object(let o) = out.order else { Issue.record("no order"); return }
        #expect(o["material"] == .string("PLA, PETG"))
        // One history entry carrying both, so one undo restores them together.
        guard case .array(let history)? = o["editHistory"], history.count == 1,
              case .object(let entry) = history[0], case .object(let fields)? = entry["fields"] else {
            Issue.record("one history entry"); return
        }
        #expect(Set(fields.keys) == ["parts", "price"])
    }

    @Test("where the shop was asked, keeping the price keeps it and marks it typed")
    func keepsPrice() async throws {
        let engine = try KhaytEngine()
        let shop = Shop()
        let order = Self.job(["status": .string("printing")])
        #expect(try await engine.partsLock(order).askPrice)
        let edited = Self.with(order, parts: [Self.part("A", 80), Self.part("B", 100, ["printWeight": .number(250)])])
        let out = try await Shop.jobWithParts(of: edited, on: order, keepPrice: true, settings: [:], engine: engine,
                                              refusals: Shop.partsRefusalWords(shop.words))
        #expect(Self.number(out.order, "price") == 180)
        #expect(Self.number(out.order, "computedPrice") == 270)
        guard case .object(let o) = out.order else { return }
        #expect(o["priceSource"] == .string("override"))
    }

    @Test("a refusal is thrown in the shop's words and nothing is written")
    func refusals() async throws {
        let engine = try KhaytEngine()
        let shop = Shop()
        let words = Shop.partsRefusalWords(shop.words)
        func refused(_ order: JSONValue, _ parts: [JSONValue]) async -> Shop.MoveRefused? {
            do {
                _ = try await Shop.jobWithParts(of: Self.with(order, parts: parts), on: order, keepPrice: false,
                                                settings: [:], engine: engine, refusals: words)
                return nil
            } catch { return error as? Shop.MoveRefused }
        }
        // Below what was paid.
        let paid = await refused(Self.job(["paidAmount": .number(150)]), [Self.part("A", 80)])
        #expect(paid?.code == "paid_exceeds_price")
        #expect(paid?.sentence == shop.words.callIt("mac.parts_paid_exceeds"))
        // A finished job: more than a name.
        let done = Self.job(["status": .string("completed"), "costBasis": .number(120)])
        #expect(await refused(done, [Self.part("A", 80)])?.code == "name_only")
        // …and a name alone is taken.
        let renamed = try await Shop.jobWithParts(
            of: Self.with(done, parts: [Self.part("A", 80, ["name": .string("Body")]), Self.part("B", 40)]),
            on: done, keepPrice: false, settings: [:], engine: engine, refusals: words)
        #expect(Self.number(renamed.order, "price") == 180)
        // ZATCA, a delivered part, the last part.
        #expect(await refused(Self.job(["zatcaUuid": .string("u")]), [Self.part("A", 80)])?.sentence
                == shop.words.callIt("mac.parts_locked_zatca"))
        let delivered = Self.with(Self.job(), parts: [Self.part("A", 80, ["delivered": .bool(true)]), Self.part("B", 40)])
        #expect(await refused(delivered, [Self.part("B", 40)])?.code == "delivered_part")
        #expect(await refused(Self.job(), [])?.code == "no_parts")
        // Every reason the rule can give has a sentence, in every language.
        for reason in ["zatca", "voided", "credited", "cancelled", "deducted", "name_only", "delivered_part",
                       "paid_exceeds_price", "no_parts"] {
            let said = try #require(words[reason], "\(reason)")
            #expect(!said.isEmpty && !said.hasPrefix("mac."), "\(reason)")
        }
    }

    @Test("nothing moved, nothing written")
    func unchanged() async throws {
        let engine = try KhaytEngine()
        let shop = Shop()
        let order = Self.job()
        let out = try await Shop.jobWithParts(of: order, on: order, keepPrice: false, settings: [:], engine: engine,
                                              refusals: Shop.partsRefusalWords(shop.words))
        #expect(out.order == order)
    }

    @Test("the sheet asks, says the lock, offers Remove, and stays open on a refusal")
    func sheetIsWired() {
        let sheet = MenuCoverageTests.source("EditPartSheet.swift")
        #expect(sheet.contains("if lock?.askPrice == true, costMoved { askingPrice = true } else { save(keepPrice: false) }"))
        #expect(sheet.contains("mac.parts_keep_price") && sheet.contains("mac.parts_use_new_price"))
        #expect(sheet.contains("if wrote { dismiss() } else { refused = shop.moveProblem }"))
        #expect(sheet.contains("shop.removePart(orderId, partId: part.id, keepPrice: keepPrice)"))
        #expect(sheet.contains(".disabled(saving || !shop.canMoveJobs || lock?.edit == false)"))
        let money = MenuCoverageTests.source("Shop+Money.swift")
        #expect(money.contains("try await Self.jobWithParts(of: edited, on: order, keepPrice: keepPrice"))
    }
}
