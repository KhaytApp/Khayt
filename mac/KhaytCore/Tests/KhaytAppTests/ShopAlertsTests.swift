import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The phones' morning digests and low-stock alerts: which jobs, once a day,
/// and an item told once per drop under its threshold.
@MainActor
struct ShopAlertsTests {
    static func job(_ id: String, status: String, due: String) -> Order {
        let row: JSONValue = .object(["id": .string(id), "date": .string("2026-10-01"), "status": .string(status),
                                      "project": .string(id), "dueDate": .string(due)])
        return try! JSONDecoder().decode(Order.self, from: JSONEncoder().encode(row))
    }

    @Test("late and due today are open work only; quotes, finished and cancelled jobs are neither")
    func digest() {
        let today = Calendar.book.startOfDay(for: Order.day("2026-11-03")!)
        let orders = [Self.job("late", status: "printing", due: "2026-11-01"),
                      Self.job("today", status: "pending", due: "2026-11-03"),
                      Self.job("later", status: "pending", due: "2026-11-09"),
                      Self.job("quote", status: "quote", due: "2026-11-01"),
                      Self.job("done", status: "completed", due: "2026-11-01"),
                      Self.job("gone", status: "cancelled", due: "2026-11-03")]
        let d = ShopAlerts.digest(orders, today: today, now: today.addingTimeInterval(9 * 3600))
        #expect(d.overdue == ["late"])
        #expect(d.dueToday == ["today"])
    }

    @Test("an item is told when it first runs low, not again while it stays low, and again after it recovers")
    func newlyLow() {
        #expect(ShopAlerts.newlyLow(["a": "PLA", "b": "PETG"], told: []).map(\.id) == ["b", "a"], "by name: PETG, PLA")
        #expect(ShopAlerts.newlyLow(["a": "PLA"], told: ["a"]).isEmpty)
        #expect(ShopAlerts.newlyLow(["a": "PLA", "c": "Boxes"], told: ["a"]).map(\.id) == ["c"])
    }
}
