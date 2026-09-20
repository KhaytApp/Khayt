import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Whose bill is sitting here — and the field nothing used to write.
///
/// `invoicePaid` was read by the other app's AP aging bar and written by
/// nothing, in either app; `test/po-cost-fields.test.js` carried it on a
/// known-unwritten list, which is now empty. Every order that had been billed
/// counted as owing forever, so the bar could only grow.
///
/// The Mac half is the surface: once an order was received it left the "still
/// to come" card and there was nowhere to reach it, so a bill that arrived a
/// week after the goods could not be recorded at all.
@MainActor
struct BillsToSettleTests {

    static func po(_ id: String, _ status: String,
                   billed: Bool = false, paid: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "itemName": .string("PLA"), "status": .string(status),
            "qty": .number(750), "unitPrice": .number(0.085)]
        if billed { o["supplierInvoice"] = .object(["number": .string("INV-1"),
                                                    "amount": .number(63.75),
                                                    "date": .string("2026-09-20")]) }
        if paid { o["invoicePaid"] = .bool(true) }
        return .object(o)
    }

    @Test("the list is arrived goods whose bill is not settled")
    func theList() async throws {
        let engine = try KhaytEngine()
        let rows = [Self.po("ordered", "ordered"),
                    Self.po("unbilled", "received"),
                    Self.po("unpaid", "received", billed: true),
                    Self.po("settled", "received", billed: true, paid: true),
                    Self.po("part", "partial")]
        let owing = try await engine.billsOwing(rows).compactMap { row -> String? in
            guard case .object(let o) = row else { return nil }
            return Shop.plainString(o["id"])
        }
        #expect(owing == ["unbilled", "unpaid", "part"], Comment(rawValue: "\(owing)"))
    }

    @Test("an order still on its way is not a bill to settle")
    func notYetArrived() async throws {
        // Where this parts company with the other app's aging bar, which also
        // counts money committed on orders that have not arrived. Two
        // questions; sharing one filter would have merged them.
        let engine = try KhaytEngine()
        #expect(try await engine.billsOwing([Self.po("d", "draft")]).isEmpty)
        #expect(try await engine.billsOwing([Self.po("o", "ordered")]).isEmpty)
    }

    @Test("settling writes a boolean, and un-settling writes the other one")
    func settling() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.settleBill(true) == ["invoicePaid": .bool(true)])
        #expect(try await engine.settleBill(false) == ["invoicePaid": .bool(false)],
                "a bill marked paid by mistake cannot be un-marked")
    }

    @Test("an order knows whether it has been billed, and whether that matched")
    func theOrderKnows() throws {
        let plain = try #require(PurchaseOrder(row: Self.po("a", "received")))
        #expect(!plain.hasBill)
        #expect(!plain.billMismatched)

        var row: [String: JSONValue] = [
            "id": .string("b"), "itemName": .string("PLA"), "status": .string("received"),
            "supplierInvoice": .object(["amount": .number(999)]),
            "invoiceDiscrepancy": .bool(true)]
        row["qty"] = .number(750)
        let wrong = try #require(PurchaseOrder(row: .object(row)))
        #expect(wrong.hasBill)
        #expect(wrong.billMismatched,
                "a bill that does not match is not flagged where it is about to be paid")
    }

    @Test("the card and the late-bill sheet are both reachable")
    func wired() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let floor = try String(contentsOf: sources.appending(path: "ShopFloor.swift"),
                               encoding: .utf8)
        #expect(floor.contains("BillsCard(shop: shop)"), "the card is never drawn")
        #expect(floor.contains("!shop.billsToSettle.isEmpty"), Comment(rawValue:
            "the card is drawn with nothing in it, and most shops most days have none"))
        let window = try String(contentsOf: sources.appending(path: "ShopWindow.swift"),
                                encoding: .utf8)
        #expect(window.contains("BillSheet(shop: shop, order: $0)"),
                "a bill that arrives after the goods still cannot be recorded")
        let card = try String(contentsOf: sources.appending(path: "BillsCard.swift"),
                              encoding: .utf8)
        #expect(card.contains("pay.mark_paid"), "there is no way to say a bill was paid")
        #expect(card.contains("po.ap_mismatch"), Comment(rawValue:
            "a mismatched bill is not flagged on the card where somebody decides to pay it"))
    }
}
