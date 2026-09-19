import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Deposits an old defect took off the book.
///
/// Saving an order that had a payment plan used to write the collected
/// instalment total straight over `paidAmount`, erasing the deposit the shop
/// had already taken. The code is fixed; the books written before it are not —
/// and until now this app showed nothing at all, so a shop working here was
/// chasing customers for money they had handed over.
@MainActor
struct DepositAuditTests {

    static func affected(_ id: String, deposit: Double, paid: Double, price: Double = 3000,
                         rows: [(Double, Bool)] = [(1000, false)]) -> JSONValue {
        .object([
            "id": .string(id), "project": .string("P-" + id), "status": .string("pending"),
            "price": .number(price), "paidAmount": .number(paid),
            "depositAmount": .number(deposit), "paymentStatus": .string("unpaid"),
            "date": .string("2026-09-01"),
            "instalments": .array(rows.map { amount, paid in
                .object(["amount": .number(amount), "paid": .bool(paid)])
            }),
        ])
    }

    // MARK: - Finding them

    @Test("an order whose deposit was erased is found, with both figures")
    func findsTheGap() async throws {
        let engine = try KhaytEngine()
        let hits = try await engine.erasedDeposits(orders: [
            Self.affected("A", deposit: 500, paid: 0),
        ])
        #expect(hits.count == 1)
        #expect(hits[0].deposit == 500)
        #expect(hits[0].currentPaid == 0)
        #expect(hits[0].recovered == 500, "the deposit, plus nothing collected yet")
        #expect(hits[0].lost == 500)
        #expect(hits[0].id == "A")
        #expect(hits[0].project == "P-A")
    }

    @Test("instalments already collected are part of what should be there")
    func collectedRowsCount() async throws {
        // Both are real cash the shop received; the figure put back is the sum.
        let engine = try KhaytEngine()
        let hits = try await engine.erasedDeposits(orders: [
            Self.affected("A", deposit: 500, paid: 0, rows: [(1000, true), (1000, false)]),
        ])
        #expect(hits[0].recovered == 1500)
    }

    @Test("an order with no plan is not affected, whatever its deposit")
    func planlessOrdersAreNotAffected() async throws {
        // The defect had one door: the save path that wrote over paidAmount,
        // which only orders with instalments took.
        let engine = try KhaytEngine()
        let order: JSONValue = .object([
            "id": .string("A"), "status": .string("pending"), "price": .number(3000),
            "paidAmount": .number(0), "depositAmount": .number(500),
        ])
        #expect(try await engine.erasedDeposits(orders: [order]).isEmpty)
    }

    @Test("an order already holding its deposit is left alone")
    func healthyOrdersAreNotFlagged() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.erasedDeposits(orders: [
            Self.affected("A", deposit: 500, paid: 500),
        ]).isEmpty)
        #expect(try await engine.erasedDeposits(orders: [
            Self.affected("A", deposit: 500, paid: 1500),
        ]).isEmpty, "a shop that has taken more since is not missing anything")
    }

    @Test("the worst loss is first — it is the one most likely already chased")
    func worstFirst() async throws {
        let engine = try KhaytEngine()
        let hits = try await engine.erasedDeposits(orders: [
            Self.affected("SMALL", deposit: 100, paid: 0),
            Self.affected("BIG", deposit: 2000, paid: 0),
        ])
        #expect(hits.map(\.id) == ["BIG", "SMALL"])
    }

    // MARK: - Putting one back

    @Test("a repair returns the order to write, with the figure the rule chose")
    func repairComesBack() async throws {
        // The rule mutates the record it is handed, and a mutation does not
        // survive the bridge — so the repaired order has to come BACK.
        let engine = try KhaytEngine()
        let orders = [Self.affected("A", deposit: 500, paid: 0, rows: [(1000, true)])]
        let out = try await engine.restoreDeposit(orders: orders, orderId: "A")
        #expect(out.ok)
        #expect(out.before == 0)
        #expect(out.after == 1500)
        guard case .object(let repaired)? = out.order else {
            Issue.record("no order came back to write"); return
        }
        #expect(repaired["paidAmount"] == .number(1500))
        // And the status is recomputed, or the order sits at 'unpaid' with
        // money against it.
        #expect(repaired["paymentStatus"] == .string("partial"))
    }

    @Test("a repair that settles the order says so")
    func repairCanSettle() async throws {
        let engine = try KhaytEngine()
        let orders = [Self.affected("A", deposit: 3000, paid: 0, price: 3000)]
        let out = try await engine.restoreDeposit(orders: orders, orderId: "A")
        guard case .object(let repaired)? = out.order else {
            Issue.record("no order came back"); return
        }
        #expect(repaired["paymentStatus"] == .string("paid"))
    }

    @Test("an order that is no longer affected is refused, not repaired twice")
    func staleListIsHarmless() async throws {
        // The list a shop is looking at was read a minute ago. Another Mac may
        // have put this one back since.
        let engine = try KhaytEngine()
        let out = try await engine.restoreDeposit(
            orders: [Self.affected("A", deposit: 500, paid: 500)], orderId: "A")
        #expect(!out.ok)
        #expect(out.order == nil)
    }

    @Test("an order that is not in the book at all is refused")
    func missingOrderIsRefused() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.restoreDeposit(orders: [], orderId: "A")
        #expect(!out.ok)
        #expect(out.error == "gone")
    }

    // MARK: - Wiring

    @Test("the app actually says so")
    func theAppReachesTheRule() throws {
        // A report nobody sees is the fault this closes: the rule has existed
        // since the fix and this app drew nothing.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let banners = try String(contentsOf: sources.appending(path: "Banners.swift"), encoding: .utf8)
        let window = try String(contentsOf: sources.appending(path: "ShopWindow.swift"), encoding: .utf8)
        #expect(banners.contains("shop.erasedDeposits.isEmpty"), "nothing tells the shop")
        #expect(window.contains("DepositAuditSheet(shop: shop)"), "the review sheet is never presented")
    }
}
