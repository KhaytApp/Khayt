import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A customer paying a job off over months.
///
/// ── WHAT THIS SUITE IS GUARDING ───────────────────────────────────────────
///
/// Three rules with a history of destroying money, all of them shared and none
/// of them this app's to re-derive: what a job OWES, the schedule that covers
/// it, and what collecting a row does to the cash figures. This suite drives
/// each through the real engine — not a Swift restatement of what they ought to
/// return — and checks that the app reaches them.
@MainActor
struct PaymentPlanTests {

    static func order(_ id: String, price: Double, paid: Double = 0,
                      instalments: [JSONValue]? = nil, base: Double? = nil,
                      giftCardDiscount: Double? = nil) throws -> Order {
        var row: [String: JSONValue] = [
            "id": .string(id), "date": .string("2026-09-01"), "status": .string("pending"),
            "project": .string("P"), "client": .string("Acme"), "price": .number(price),
            "paidAmount": .number(paid), "paymentStatus": .string(paid > 0 ? "partial" : "unpaid"),
            "printTime": .number(1), "priority": .bool(false), "notes": .string(""),
        ]
        if let instalments { row["instalments"] = .array(instalments) }
        if let base { row["instalmentBase"] = .number(base) }
        if let giftCardDiscount { row["giftCardDiscount"] = .number(giftCardDiscount) }
        return try JSONDecoder().decode(Order.self, from: JSONEncoder().encode(row))
    }

    static func row(_ id: String, _ amount: Double, due: String, paid: Bool = false) -> JSONValue {
        .object(["id": .string(id), "amount": .number(amount), "dueDate": .string(due),
                 "note": .string(""), "paid": .bool(paid),
                 "paidAt": paid ? .string("2026-09-10") : .null])
    }

    // MARK: - The plan itself

    @Test("the offered plan splits what is owed, a month out then thirty days apart")
    func planCoversWhatIsOwed() async throws {
        let engine = try KhaytEngine()
        let plan = try await engine.monthlyPlan(owed: 900, today: "2026-05-10")
        #expect(plan.count == 3)
        #expect(plan.map(\.amount) == [300, 300, 300])
        #expect(plan.map(\.dueDate) == ["2026-06-10", "2026-07-10", "2026-08-09"])
        #expect(plan.allSatisfy { $0.paidAt == nil })
    }

    @Test("a plan made on the 31st does not skip February")
    func monthLengthIsClamped() async throws {
        // `new Date(2026, 1, 31)` is the 3rd of March, so the first payment
        // used to land two months out. The clamp is the shared rule's; this
        // asks for it through the binding the app actually calls.
        let engine = try KhaytEngine()
        #expect(try await engine.monthlyPlan(owed: 300, today: "2026-01-31")[0].dueDate == "2026-02-28")
        #expect(try await engine.monthlyPlan(owed: 300, today: "2028-01-31")[0].dueDate == "2028-02-29")
        #expect(try await engine.monthlyPlan(owed: 300, today: "2026-03-31")[0].dueDate == "2026-04-30")
    }

    @Test("an awkward split still adds up to what is owed, to the cent")
    func planSumsExactly() async throws {
        let engine = try KhaytEngine()
        let plan = try await engine.monthlyPlan(owed: 1000.03, today: "2026-05-10")
        #expect(plan.map(\.amount).reduce(0, +) == 1000.03)
    }

    @Test("nothing owed is no plan, not a plan of zeroes")
    func nothingOwedIsNoPlan() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.monthlyPlan(owed: 0, today: "2026-05-10").isEmpty)
    }

    // MARK: - What the plan is built ON

    @Test("what a job owes takes the gift card off as well as the cash")
    func owedIsTheSharedSubtraction() async throws {
        // A plan built on price − paidAmount bills a customer for a gift card
        // they have already been given. This app never does that subtraction
        // itself; it asks `orderOwedRaw`.
        let engine = try KhaytEngine()
        let job: JSONValue = .object([
            "id": .string("J1"), "status": .string("pending"), "price": .number(1000),
            "paidAmount": .number(250), "giftCardDiscount": .number(100),
        ])
        #expect(try await engine.owedRaw(order: job) == 650)
    }

    // MARK: - Collecting a payment

    @Test("collecting a row adds to the deposit rather than replacing it")
    func collectingKeepsTheDeposit() async throws {
        // The plan covers the BALANCE, so its rows are money on top of the
        // deposit. Replacing paidAmount with the collected total erased a
        // deposit with no ledger entry at all.
        let engine = try KhaytEngine()
        let rows = [Self.row("A", 666.67, due: "2026-10-01", paid: true),
                    Self.row("B", 666.67, due: "2026-10-31"),
                    Self.row("C", 666.66, due: "2026-11-30")]
        let out = try await engine.collectionTotals(price: 3000, paidAmount: 1000,
                                                    instalments: rows, instalmentBase: 1000)
        #expect(out.paidAmount == 1666.67)
        #expect(out.collected == 666.67)
        #expect(out.paymentStatus == "partial")
    }

    @Test("cash taken at the counter since the plan was made is never destroyed")
    func counterCashSurvives() async throws {
        let engine = try KhaytEngine()
        let rows = [Self.row("A", 500, due: "2026-10-01", paid: true)]
        let out = try await engine.collectionTotals(price: 3000, paidAmount: 2500,
                                                    instalments: rows, instalmentBase: 1000)
        #expect(out.paidAmount == 2500, "base + collected is 1500 — writing that back loses 1000")
    }

    @Test("a plan that does not cover the price cannot report the job settled")
    func settlesAgainstThePrice() async throws {
        // Instalment amounts are freely editable, and `paymentStatus` is what
        // the payment webhooks carry.
        let engine = try KhaytEngine()
        let rows = [Self.row("A", 100, due: "2026-10-01", paid: true),
                    Self.row("B", 100, due: "2026-10-31", paid: true)]
        let out = try await engine.collectionTotals(price: 2000, paidAmount: 0,
                                                    instalments: rows, instalmentBase: nil)
        #expect(out.paymentStatus == "partial")
    }

    @Test("a hand-built plan with no base keeps the older rule")
    func handBuiltPlansKeepTheOldRule() async throws {
        let engine = try KhaytEngine()
        let rows = [Self.row("A", 2000, due: "2026-10-01", paid: true)]
        let out = try await engine.collectionTotals(price: 2000, paidAmount: 500,
                                                    instalments: rows, instalmentBase: nil)
        #expect(out.paidAmount == 2000)
        #expect(out.paymentStatus == "paid")
    }

    // MARK: - Reading a plan off the book

    @Test("a job's plan is read off the record, rows and base")
    func planDecodes() throws {
        let job = try Self.order("J1", price: 3000, paid: 1000,
                                 instalments: [Self.row("A", 666.67, due: "2026-10-01", paid: true),
                                               Self.row("B", 666.67, due: "2026-10-31")],
                                 base: 1000)
        #expect(job.instalments.count == 2)
        #expect(job.instalments[0].paid)
        #expect(job.instalments[0].paidAt == "2026-09-10")
        #expect(job.instalments[1].dueDate == "2026-10-31")
        #expect(job.instalmentBase == 1000)
    }

    @Test("a job with no plan reads as no plan, not as a refusal to decode")
    func noPlanDecodes() throws {
        // Every job in a shop that has never agreed a plan takes this path, so
        // a strict decode here would have emptied the whole jobs screen.
        let job = try Self.order("J1", price: 100)
        #expect(job.instalments.isEmpty)
        #expect(job.instalmentBase == nil)
    }

    @Test("a row written by an older build still decodes")
    func partialRowDecodes() throws {
        // A row typed into a build before ids were minted, or before `paidAt`
        // existed. A plan that will not decode is a plan this app would drop on
        // the next save.
        let job = try Self.order("J1", price: 100,
                                 instalments: [.object(["amount": .number(50)])])
        #expect(job.instalments.count == 1)
        #expect(job.instalments[0].id == "")
        #expect(job.instalments[0].amount == 50)
        #expect(job.instalments[0].paid == false)
        #expect(job.instalments[0].dueDate == "")
    }

    @Test("a price the book holds as a string is still a price")
    func aStringPriceIsStillAPrice() {
        // An imported record can carry "1500" rather than 1500, and reading
        // only `.number` calls that job priceless — which would refuse a plan
        // on it with "Set an order price first".
        //
        // `plainNumber` is the app's ONE reader for this and already did it.
        // The first version of this feature added a second one beside it,
        // which is the fault this book keeps finding in other people's code.
        #expect(Shop.plainNumber(.string("1500")) == 1500)
        #expect(Shop.plainNumber(.number(1500)) == 1500)
        #expect(Shop.plainNumber(nil) == nil)
        #expect(Shop.plainNumber(.null) == nil)
    }

    // MARK: - Wiring

    @Test("the app actually offers it")
    func theAppReachesTheRule() throws {
        // The fault this feature exists to fix is a correct rule with no
        // caller: `buildSchedule` sat in the engine, tested, for a year while
        // no screen could reach it. Delete either line below and this fails.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let menus = try String(contentsOf: sources.appending(path: "Menus.swift"), encoding: .utf8)
        let window = try String(contentsOf: sources.appending(path: "ShopWindow.swift"), encoding: .utf8)
        #expect(menus.contains("shop.planFor = one"), "no menu item opens the plan sheet")
        #expect(window.contains("PaymentPlanSheet(shop: shop, job:"), "the sheet is never presented")
    }
}
