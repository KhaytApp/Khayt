import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Standing orders made on the Mac.
///
/// The RULE — what is due, what the job looks like — is `lib/recurring-orders.js`
/// and is tested where it lives, against both of the renderer functions it
/// replaced. What is tested here is that this app asks it inside the write and
/// puts back what it said: the job at the front, stamped; the schedule moved,
/// stamped; the invoice counter advanced; a line in the activity log; and
/// nothing written at all when nothing was due.
@MainActor
struct RecurringOrdersTests {

    static func book(nextDue: String, paused: Bool = false, endDate: String? = nil) -> [String: JSONValue] {
        var rec: [String: JSONValue] = [
            "enabled": .bool(true), "interval": .string("monthly"),
            "nextDue": .string(nextDue), "paused": .bool(paused),
        ]
        if let endDate { rec["endDate"] = .string(endDate) }
        return [
            "settings": .object(["invNumNext": .number(12), "invNumYear": .number(2026), "invPrefix": .string("INV")]),
            "clients": .array([
                .object(["id": .string("C-1"), "nameEn": .string("Tuwaiq"), "rev": .number(4), "recurring": .object(rec)]),
                .object(["id": .string("C-2"), "nameEn": .string("Nobody")]),
            ]),
            "printLog": .array([
                .object(["id": .string("ORD-2"), "clientId": .string("C-1"), "status": .string("pending"),
                         "date": .string("2026-09-10"), "project": .string("something else"), "price": .number(9)]),
                .object(["id": .string("ORD-1"), "clientId": .string("C-1"), "status": .string("completed"),
                         "date": .string("2026-08-01"), "project": .string("Monthly brackets"), "price": .number(240),
                         "parts": .array([.object(["name": .string("bracket"), "qty": .number(12)])]),
                         "paidAmount": .number(240), "paymentStatus": .string("paid"), "deliveredAt": .string("x")]),
            ]),
        ]
    }

    static func objects(_ root: [String: JSONValue], _ key: String) -> [[String: JSONValue]] {
        Shop.rows(root, key).compactMap { if case .object(let o) = $0 { return o } else { return nil } }
    }

    @Test("a schedule that is due makes its job, moves on, and is written down")
    func due() async throws {
        let engine = try KhaytEngine()
        var root = Self.book(nextDue: "2026-07-15")
        let now = Date()
        let out = try await RecurringOrders.run(&root, engine: engine, now: now)
        #expect(out.changed)
        #expect(out.created == ["INV-\(Calendar.current.component(.year, from: now))-0012"])

        let orders = Self.objects(root, "printLog")
        #expect(orders.count == 3)
        let job = orders[0]
        #expect(job["id"] == .string(out.created[0]), "at the FRONT, the way every screen reads the book")
        #expect(job["project"] == .string("Monthly brackets"), "the last COMPLETED job, not the last job")
        #expect(job["recurringCycle"] == .string("2026-07-15"))
        #expect(job["dueDate"] == .string("2026-07-15"))
        #expect(job["status"] == .string("pending"))
        #expect(job["paymentStatus"] == .string("unpaid"))
        #expect(job["paidAmount"] == .number(0))
        #expect(job["deliveredAt"] == .null)
        #expect(job["price"] == .number(240), "the price is the standing order's")
        #expect(job["rev"] == .number(1) && job["updatedAt"] != nil, "stamped, so it syncs")
        #expect(orders[1]["rev"] == nil, "the jobs already there are not touched")

        let clients = Self.objects(root, "clients")
        guard case .object(let rec)? = clients[0]["recurring"] else { Issue.record("no schedule"); return }
        #expect(rec["nextDue"] == .string("2026-08-15"), "one cycle on — one job per run, however far behind")
        #expect(clients[0]["rev"] == .number(5), "the moved schedule is stamped")
        #expect(clients[1]["rev"] == nil, "a customer with no schedule is not")

        #expect(Shop.settings(root)["invNumNext"] == .number(13), "the counter is saved WITH the job")
        let log = Self.objects(root, "auditLog")
        #expect(log.count == 1)
        #expect(log[0]["action"] == .string("order_created"))
        #expect(log[0]["ref"] == .string(out.created[0]))
    }

    @Test("nothing due is nothing written")
    func nothingDue() async throws {
        let engine = try KhaytEngine()
        for root0 in [Self.book(nextDue: "2999-01-01"), Self.book(nextDue: "2026-07-15", paused: true)] {
            var root = root0
            let out = try await RecurringOrders.run(&root, engine: engine)
            #expect(!out.changed && out.created.isEmpty)
            #expect(root == root0, "the book is exactly as it was")
        }
    }

    @Test("a schedule past its end is switched off — a change worth writing, with no job")
    func pastTheEnd() async throws {
        let engine = try KhaytEngine()
        var root = Self.book(nextDue: "2026-07-15", endDate: "2026-07-01")
        let out = try await RecurringOrders.run(&root, engine: engine)
        #expect(out.changed && out.created.isEmpty)
        #expect(Shop.rows(root, "printLog").count == 2)
        guard case .object(let rec)? = Self.objects(root, "clients")[0]["recurring"] else { Issue.record("no schedule"); return }
        #expect(rec["enabled"] == .bool(false))
    }

    @Test("a cycle that already has its job is not made twice")
    func idempotent() async throws {
        let engine = try KhaytEngine()
        var root = Self.book(nextDue: "2026-07-15")
        _ = try await RecurringOrders.run(&root, engine: engine)
        // Put the schedule back where it was, as if another machine had made
        // the job and synced it here before this Mac's schedule caught up.
        var clients = Shop.rows(root, "clients")
        if case .object(var c) = clients[0], case .object(var rec)? = c["recurring"] {
            rec["nextDue"] = .string("2026-07-15"); c["recurring"] = .object(rec); clients[0] = .object(c)
        }
        root["clients"] = .array(clients)
        let again = try await RecurringOrders.run(&root, engine: engine)
        #expect(again.created.isEmpty)
        #expect(Shop.rows(root, "printLog").count == 3)
    }

    /// The recurring bug in this repo is a correct module with no caller. The
    /// runner above is called from exactly one place — when a book has
    /// loaded, beside the re-measure pass — and this is the test that fails if
    /// that line goes.
    @Test("the runner is wired to the book opening")
    func wired() throws {
        let shop = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Shop.swift"), encoding: .utf8)
        #expect(shop.contains("            remeasureIfDue()\n            createRecurringIfDue()\n"),
                "createRecurringIfDue() is not called where the book finishes loading")
        #expect(shop.contains("RecurringOrders.run(&root, engine: engine)"),
                "the runner is not what the write asks")
    }

    @Test("the sheet's date arithmetic and the cart's agreed prices come from the rule")
    func bridge() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.nextCycle(after: "2026-01-31", interval: "monthly") == "2026-02-28")
        let prices = try await engine.agreedPrices(
            names: ["Wall bracket", "Lid", ""],
            priceList: [.object(["product": .string("bracket"), "price": .number(45)])])
        #expect(prices == [45, nil, nil])
    }
}
