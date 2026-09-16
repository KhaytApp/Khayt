import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// What the shop is still owed.
///
/// THE DEFECT THIS EXISTS FOR: `Order.owed` was `max(0, price - paidAmount)`,
/// and the comment above it said money was not a Swift opinion while being
/// exactly that. It is short by a credit note and by a gift card — both of
/// which pay an order down in `lib/order-money.js` — and that number is in the
/// title bar, the customers table, the jobs table and on the kanban card.
///
/// Neither book on this machine carries either field, which is why nothing
/// showed. A shop that issues one credit note would have been chasing money it
/// had already given back, with the Receivables page (which does ask the
/// engine) quietly disagreeing on the next screen.
@MainActor
struct OwedTests {

    static func job(_ id: String, price: Double, paid: Double,
                    credit: Double? = nil, giftCard: Double? = nil) -> JSONValue {
        var row: [String: JSONValue] = [
            "id": .string(id), "price": .number(price), "paidAmount": .number(paid),
            "status": .string("completed"),
            // `date` and `project` are required by the decoder — a row without
            // them is a job the app would not show at all.
            "date": .string("2026-09-01"), "project": .string("Lid"),
            "paymentStatus": .string("unpaid"), "printTime": .number(1),
            "priority": .bool(false), "notes": .string(""), "client": .string("A shop"),
        ]
        if let credit { row["creditNotes"] = .array([.object(["amount": .number(credit)])]) }
        if let giftCard { row["giftCardDiscount"] = .number(giftCard) }
        return .object(row)
    }

    static func owed(_ rows: [JSONValue]) async throws -> [String: Double] {
        try await KhaytEngine().owedByOrder(rows, settings: ["currency": .string("SAR")],
                                            clients: [], currencies: [:])
    }

    @Test("a credit note pays the job down")
    func creditNote() async throws {
        let out = try await Self.owed([Self.job("O-1", price: 1000, paid: 0, credit: 300)])
        #expect(out["O-1"] == 700, "the Mac was chasing the whole 1,000")
    }

    @Test("a gift card pays the job down")
    func giftCard() async throws {
        let out = try await Self.owed([Self.job("O-2", price: 1000, paid: 0, giftCard: 400)])
        #expect(out["O-2"] == 600)
    }

    @Test("an ordinary half-paid job is unchanged")
    func ordinary() async throws {
        // The case that was always right, and the reason the bug was invisible.
        let out = try await Self.owed([Self.job("O-3", price: 1000, paid: 400)])
        #expect(out["O-3"] == 600)
    }

    @Test("a job cannot owe a negative amount")
    func overpaid() async throws {
        let out = try await Self.owed([Self.job("O-4", price: 100, paid: 250)])
        #expect(out["O-4"] == 0)
    }

    @Test("the row carries the shared answer, and sorts on it")
    func theRowUsesIt() throws {
        var job = try JSONDecoder().decode(
            Order.self, from: JSONEncoder().encode(Self.job("O-5", price: 1000, paid: 0, credit: 300)))
        #expect(job.owed == 1000, "unresolved, this is the subtraction — and it is wrong")
        job.owedResolved = 700
        #expect(job.owed == 700)
        #expect(!job.isSettled)
        job.owedResolved = 0
        #expect(job.isSettled, "settled follows the shared answer, not the subtraction")
    }

    @Test("a dead engine leaves a number on the screen, not a blank")
    func fallsBack() throws {
        // The money column going empty because the runtime failed would be a
        // worse screen than one that is short by a credit note.
        let job = try JSONDecoder().decode(
            Order.self, from: JSONEncoder().encode(Self.job("O-6", price: 900, paid: 100)))
        #expect(job.owedResolved == nil)
        #expect(job.owed == 800)
    }

    @Test("the book resolves it on load")
    func theBookIsWired() throws {
        // A source guard: `load` is one long async function and there is no
        // seam. It catches the regression that matters — dropping the call and
        // going back to a subtraction on every screen.
        let shop = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Shop.swift"), encoding: .utf8)
        #expect(shop.contains("await resolveOwed(root)"))
        #expect(shop.contains("engine.owedByOrder("))
        // …and after the settings tables, because the rule resolves an order's
        // currency against them.
        guard let tables = shop.range(of: "await readSettingsTables(root)"),
              let resolve = shop.range(of: "await resolveOwed(root)") else {
            Issue.record("the load sequence has changed"); return
        }
        #expect(tables.lowerBound < resolve.lowerBound)
    }
}

/// Which jobs are late.
///
/// THE DEFECT THIS EXISTS FOR: the badges, the kanban card and the title bar
/// asked `isOverdue()` — "not settled and past its due date" — while the
/// dashboard's Late tile asked the attention engine. Two numbers about one
/// book, on screen at the same time: eleven and two on the sample shop.
///
/// The Swift rule answers a DIFFERENT question. A job completed and delivered
/// is not late because its invoice is unpaid, and a quote has no deadline to
/// miss at all — those were nine of the eleven.
@MainActor
struct LateTests {

    static func job(_ id: String, status: String, due: String,
                    price: Double = 1000, paid: Double = 0) -> JSONValue {
        .object([
            "id": .string(id), "date": .string("2026-08-01"), "status": .string(status),
            "project": .string("Lid"), "client": .string("A shop"),
            "price": .number(price), "paidAmount": .number(paid),
            "paymentStatus": .string(paid >= price ? "paid" : "unpaid"),
            "printTime": .number(1), "priority": .bool(false), "notes": .string(""),
            "dueDate": .string(due),
        ])
    }

    static let now = Date(timeIntervalSince1970: 1_788_566_400)   // 2026-09-05

    @Test("a job still on the floor and past its date is late")
    func genuinelyLate() async throws {
        let late = try await KhaytEngine().lateOrders(
            [Self.job("O-1", status: "printing", due: "2026-08-25")],
            machines: [], settings: [:], now: Self.now)
        #expect(late.contains("O-1"))
    }

    @Test("a completed job is not late, whatever its invoice says")
    func completedIsNotLate() async throws {
        // Most of the difference between eleven and two. A job the shop has
        // finished is not late work; the money being outstanding is the
        // receivables screen's business, and it has an aged one.
        let late = try await KhaytEngine().lateOrders(
            [Self.job("O-2", status: "completed", due: "2026-08-25")],
            machines: [], settings: [:], now: Self.now)
        #expect(late.isEmpty, "a job that is done was being badged as late work")
    }

    @Test("a job under the older `delivered` status is finished, and not late either")
    func deliveredIsNotLate() async throws {
        // This used to pin the opposite — "recorded rather than argued with":
        // `attention` treated a legacy `delivered` row as open work past its
        // date while treating `completed` as not, which read oddly beside the
        // case above. It WAS odd: `delivered` is the older spelling of the
        // same finished state (`order-status.js` keeps a handed-over job at
        // `completed` + deliveredAt), and a job handed over months ago was
        // badged late for ever. Changed deliberately on 2026-09-16 with seven
        // other rules that treated the older spelling as unfinished.
        let late = try await KhaytEngine().lateOrders(
            [Self.job("O-3", status: "delivered", due: "2026-08-20")],
            machines: [], settings: [:], now: Self.now)
        #expect(late.isEmpty, "a job the shop handed over is not late work")
    }

    @Test("a quote has no deadline to miss")
    func quotesAreNotLate() async throws {
        let late = try await KhaytEngine().lateOrders(
            [Self.job("O-4", status: "quote", due: "2026-08-25")],
            machines: [], settings: [:], now: Self.now)
        #expect(late.isEmpty)
    }

    @Test("the row carries the engine's answer")
    func theRowUsesIt() throws {
        var job = try JSONDecoder().decode(
            Order.self, from: JSONEncoder().encode(Self.job("O-5", status: "completed", due: "2026-08-25")))
        #expect(job.isOverdue(now: Self.now), "unresolved, this is the old rule — and it says late")
        job.isLateResolved = false
        #expect(!job.isOverdue(now: Self.now))
        job.isLateResolved = true
        #expect(job.isOverdue(now: Self.now))
    }

    @Test("with no engine a badge is still possible, by the older rule")
    func fallsBack() throws {
        let job = try JSONDecoder().decode(
            Order.self, from: JSONEncoder().encode(Self.job("O-6", status: "printing", due: "2026-08-25")))
        #expect(job.isLateResolved == nil)
        #expect(job.isOverdue(now: Self.now))
    }

    @Test("the book resolves it on load")
    func theBookIsWired() throws {
        let shop = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Shop.swift"), encoding: .utf8)
        #expect(shop.contains("await resolveLate(root)"))
        #expect(shop.contains("engine.lateOrders("))
    }
}
