import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// What the shop has on order.
///
/// ── WHAT THIS SUITE IS GUARDING ───────────────────────────────────────────
///
/// Receiving goods moves FOUR records — the order, the spool or the consumable,
/// that spool's history line, and an expense — and both faults this chain has
/// carried were one of the four going missing on its own. The rule is
/// `lib/purchase-orders.js`, driven here through the bundle rather than
/// restated in Swift.
@MainActor
struct PurchaseOrderTests {

    static func order(_ id: String, qty: Double = 1000, price: Double? = 0.085,
                      consumable: Bool = false, received: Double = 0,
                      status: String = "ordered") -> JSONValue {
        var row: [String: JSONValue] = [
            "id": .string(id), "itemId": .string(consumable ? "c-1" : "sp-1"),
            "itemName": .string(consumable ? "Kapton tape" : "PLA+"),
            "supplierName": .string("Tuwaiq Supply"),
            "qty": .number(qty), "status": .string(status),
            "orderedAt": .string("2026-09-01"), "receivedAt": .null,
            "receivedSoFar": .number(received),
        ]
        if let price { row["unitPrice"] = .number(price) }
        if consumable { row["kind"] = .string("consumable"); row["unit"] = .string("roll") }
        return .object(row)
    }

    // MARK: - Reading one off the book

    @Test("an order says what is still to come, not what was ordered")
    func outstandingIsWhatIsLeft() throws {
        let po = try #require(PurchaseOrder(row: Self.order("PO-1", qty: 1000, received: 400)))
        #expect(po.qty == 1000)
        #expect(po.receivedSoFar == 400)
        #expect(po.outstanding == 600)
        #expect(po.total == 85, "1,000 g at 0.085 a gram")
    }

    @Test("an order with no price has no total, rather than a total of nothing")
    func pricelessOrdersHaveNoTotal() throws {
        let po = try #require(PurchaseOrder(row: Self.order("PO-1", price: nil)))
        #expect(po.unitPrice == nil)
        #expect(po.total == nil)
    }

    @Test("a row with no id is not an order")
    func idIsRequired() {
        #expect(PurchaseOrder(row: .object(["qty": .number(5)])) == nil)
    }

    @Test("an order that has arrived is not what the shop is waiting for")
    func receivedOrdersAreNotOpen() async throws {
        // A received order is history. The card answers what is COMING — so
        // nothing it lists is already in.
        let shop = Shop()
        await shop.load(.sample)
        #expect(!shop.openOrders.isEmpty, "the sample book stopped carrying any order")
        #expect(shop.openOrders.allSatisfy { $0.status != "received" },
                "a delivered order is still being waited for")

        // Oldest first: the one waited on longest is the one to chase.
        let dates = shop.openOrders.map(\.orderedAt)
        #expect(dates == dates.sorted(), "the list is not in the order a shop would chase it")
    }

    @Test("a draft has not been ordered, and the row does not say it has")
    func draftsAreNotOrders() throws {
        // Khayt's batch generator writes `status: 'draft'` for a shop to look
        // over before it sends anything. Drawing "Ordered 2026-09-12" against
        // one asserts something the shop has not done.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let card = try String(contentsOf: sources.appending(path: "OnOrder.swift"), encoding: .utf8)
        #expect(card.contains("order.status == \"draft\""),
                "a draft order is captioned as ordered again")

        // And a draft is still SHOWN: it is work the shop has to decide about,
        // which is exactly what this card is for.
        let draft = try #require(PurchaseOrder(row: Self.order("PO-d", status: "draft")))
        #expect(draft.status == "draft")
    }

    // MARK: - Receiving, through the rule

    @Test("receiving filament restocks the spool, books the spend, and logs it")
    func filamentReceipt() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.receiveGoods(
            order: Self.order("PO-1", qty: 1000),
            item: .object(["id": .string("sp-1"), "weight": .number(200),
                           "usageHistory": .array([])]),
            consumable: nil, quantity: 1000, notes: "box",
            today: "2026-09-19", expenseId: "EXP-1", expenseLabel: "Mark received")
        #expect(out.ok)
        #expect(out.complete == true)

        guard case .object(let po)? = out.po, case .object(let item)? = out.item,
              case .object(let expense)? = out.expense else {
            Issue.record("a receipt came back without all of its records"); return
        }
        #expect(po["status"] == .string("received"))
        #expect(po["receivedAt"] == .string("2026-09-19"))
        #expect(item["weight"] == .number(1200))
        // 1,000 g at 0.085 a gram is 85 — not 0.085, which is what the /1000
        // produced, and not nothing, which is what it actually booked.
        #expect(expense["amount"] == .number(85))
        #expect(expense["category"] == .string("filament"))
    }

    @Test("receiving a consumable restocks the consumable, and touches no spool")
    func consumableReceipt() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.receiveGoods(
            order: Self.order("PO-2", qty: 5, price: 12, consumable: true),
            item: nil,
            consumable: .object(["id": .string("c-1"), "stock": .number(1)]),
            quantity: 5, notes: "", today: "2026-09-19",
            expenseId: "EXP-2", expenseLabel: "Mark received")
        guard case .object(let bit)? = out.consumable, case .object(let expense)? = out.expense else {
            Issue.record("the consumable was not restocked"); return
        }
        #expect(bit["stock"] == .number(6))
        #expect(out.item == nil, "a consumable receipt moved a spool")
        #expect(expense["category"] == .string("other"), "glue is not filament")
    }

    @Test("a part delivery stays open")
    func partialReceipt() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.receiveGoods(
            order: Self.order("PO-3", qty: 1000), item: nil, consumable: nil,
            quantity: 400, notes: "", today: "T", expenseId: "E", expenseLabel: "R")
        guard case .object(let po)? = out.po else { Issue.record("no order back"); return }
        #expect(po["status"] == .string("partial"))
        #expect(po["receivedSoFar"] == .number(400))
        #expect(out.complete == false)
    }

    @Test("receiving nothing is refused")
    func nothingIsRefused() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.receiveGoods(
            order: Self.order("PO-4"), item: nil, consumable: nil,
            quantity: 0, notes: "", today: "T", expenseId: "E", expenseLabel: "R")
        #expect(!out.ok)
        #expect(out.reason == "no_quantity")
    }

    @Test("an order written before consumables existed reads as filament")
    func oldOrdersAreFilament() async throws {
        // Absent `kind` decides which collection is restocked. Reading it as a
        // consumable would look a spool up among the glue and restock nothing.
        let engine = try KhaytEngine()
        #expect(try await engine.isConsumableOrder(.object(["id": .string("PO-old")])) == false)
        #expect(try await engine.isConsumableOrder(Self.order("PO-new", consumable: true)) == true)
    }

    @Test("closing by hand says when")
    func closingByHand() async throws {
        let engine = try KhaytEngine()
        let closed = try await engine.closeOrder(Self.order("PO-5", status: "partial"),
                                                 today: "2026-09-19")
        guard case .object(let po) = closed else { Issue.record("no order back"); return }
        #expect(po["status"] == .string("received"))
        #expect(po["receivedAt"] == .string("2026-09-19"))
    }

    // MARK: - Drafting one

    @Test("a drafted filament order asks for a spool, priced per gram")
    func draftingFilament() async throws {
        let engine = try KhaytEngine()
        let item: JSONValue = .object(["id": .string("sp-1"), "material": .string("PLA+"),
                                       "cost": .number(85), "spoolWeight": .number(1000)])
        let price = try await engine.perGramPrice(item: item, suppliers: [])
        #expect(price.perG == 0.085, "an 85 SAR spool of 1,000 g")

        let drafted = try await engine.draftOrder(
            item: item, ask: ["status": .string("draft"), "unitPrice": .number(price.perG)],
            id: "PO-1", today: "2026-09-19", supplierName: "")
        guard case .object(let po) = drafted else { Issue.record("no order"); return }
        #expect(po["qty"] == .number(1000), "a spool, where the item names no reorder quantity")
        #expect(po["unitPrice"] == .number(0.085))
        #expect(po["status"] == .string("draft"), "drafted, not ordered")
        #expect(po["itemName"] == .string("PLA+"))
        #expect(po["kind"] == nil, "a filament order carries no kind")

        // The whole order, which is what the audit would have read as 63,750.
        #expect(((po["qty"].flatMap { if case .number(let n) = $0 { return n } else { return nil } } ?? 0)
                 * 0.085) == 85)
    }

    @Test("a drafted consumable order asks for one, in the shop's own unit")
    func draftingConsumable() async throws {
        let engine = try KhaytEngine()
        let drafted = try await engine.draftOrder(
            item: .object(["id": .string("c-1"), "name": .string("Kapton tape"),
                           "unit": .string("roll")]),
            ask: ["status": .string("draft"), "kind": .string("consumable")],
            id: "PO-2", today: "2026-09-19", supplierName: "")
        guard case .object(let po) = drafted else { Issue.record("no order"); return }
        #expect(po["qty"] == .number(1), "1,000 is a spool; it is not a default for tape")
        #expect(po["unit"] == .string("roll"))
        #expect(po["itemName"] == .string("Kapton tape"), "a consumable is named, not described")
        #expect(po["unitPrice"] == nil, "nothing priced it, so it carries no price")
    }

    @Test("a material nothing prices is drafted without a price")
    func unpricedMaterialsDraftWithoutOne() async throws {
        // A price of zero would read as free to every reader downstream —
        // including the expense a receipt books.
        let engine = try KhaytEngine()
        let price = try await engine.perGramPrice(
            item: .object(["id": .string("sp-9"), "material": .string("Nylon")]), suppliers: [])
        #expect(price.perG == 0)
    }

    @Test("a supplier's quoted price wins, and is per kilo")
    func supplierPriceWins() async throws {
        let engine = try KhaytEngine()
        let price = try await engine.perGramPrice(
            item: .object(["id": .string("sp-1"), "material": .string("PLA+"),
                           "cost": .number(85), "spoolWeight": .number(1000)]),
            suppliers: [.object(["id": .string("S1"), "name": .string("Tuwaiq"),
                                 "priceList": .array([.object([
                                     "material": .string("PLA+"),
                                     "pricePerKg": .number(70)])])])])
        #expect(price.perG == 0.07, "70 a kilo is 0.07 a gram")
        #expect(price.supplierId == "S1")
        #expect(price.supplierName == "Tuwaiq")
    }

    // MARK: - The thousandfold orders

    @Test("an order priced per spool is found, with both figures")
    func suspectsAreFound() async throws {
        // 750 g of an 85 SAR/kg spool asking for 63,750 instead of 63.75.
        let engine = try KhaytEngine()
        let suspects = try await engine.suspectOrders(
            [Self.order("PO-1", qty: 750, price: 85)],
            inventory: [.object(["id": .string("sp-1"), "cost": .number(85),
                                 "spoolWeight": .number(1000)])])
        #expect(suspects.count == 1)
        #expect(suspects[0].currentTotal == 750 * 85)
        #expect(suspects[0].suggestedTotal == 63.75)
        #expect(suspects[0].itemName == "PLA+")
    }

    @Test("a correctly priced order is not flagged")
    func sanePricesAreLeftAlone() async throws {
        let engine = try KhaytEngine()
        let suspects = try await engine.suspectOrders(
            [Self.order("PO-1", qty: 750, price: 0.085)],
            inventory: [.object(["id": .string("sp-1"), "cost": .number(85),
                                 "spoolWeight": .number(1000)])])
        #expect(suspects.isEmpty)
    }

    @Test("correcting one hands back the order to write, with the rule's figure")
    func correctionComesBack() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.correctOrderPrice(
            orders: [Self.order("PO-1", qty: 750, price: 85)],
            inventory: [.object(["id": .string("sp-1"), "cost": .number(85),
                                 "spoolWeight": .number(1000)])],
            orderId: "PO-1")
        #expect(out.ok)
        #expect(out.before == 85)
        #expect(out.after == 0.085)
        guard case .object(let po)? = out.po else { Issue.record("no order back"); return }
        #expect(po["unitPrice"] == .number(0.085))
    }

    @Test("an order that no longer looks over-priced is refused")
    func staleCorrectionIsRefused() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.correctOrderPrice(
            orders: [Self.order("PO-1", qty: 750, price: 0.085)],
            inventory: [.object(["id": .string("sp-1"), "cost": .number(85),
                                 "spoolWeight": .number(1000)])],
            orderId: "PO-1")
        #expect(!out.ok)
        #expect(out.error == "gone")
        #expect(out.po == nil)
    }

    // MARK: - Wiring

    @Test("the app actually shows it")
    func theAppReachesTheRule() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let floor = try String(contentsOf: sources.appending(path: "ShopFloor.swift"), encoding: .utf8)
        let window = try String(contentsOf: sources.appending(path: "ShopWindow.swift"), encoding: .utf8)
        #expect(floor.contains("OnOrderCard(shop: shop)"), "nothing shows what is on order")
        #expect(floor.contains("SuspectOrdersCard(shop: shop)"),
                "the thousandfold orders are found and never shown")
        #expect(window.contains("ReceiveSheet(shop: shop, order:"), "nothing can be received")
        #expect(floor.contains("shop.draftOrder(") , "nothing can be ordered")
        #expect(floor.contains("mac.draft_an_order"),
                "the action promises to order rather than to draft")
    }
}
