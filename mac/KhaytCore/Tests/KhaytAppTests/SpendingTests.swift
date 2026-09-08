import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// What the shop spent, and what it threw away.
///
/// The RULES are `lib/expense-book.js`, `lib/waste-entry.js` and
/// `lib/date-range.js`, tested where they live against the originals they were
/// lifted from. What is tested here is that this app asks for them correctly,
/// writes down every collection they changed, and — for the one rule it had to
/// spell out in Swift — gives the same answer as the shared one.
@MainActor
struct SpendingTests {

    /// A shop with a shelf, so a waste entry has somewhere to deduct from.
    static func book(_ extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var root: [String: JSONValue] = [
            "printLog": .array([.object(["id": .string("ORD-1"), "project": .string("Bracket")])]),
            "inventory": .array([
                .object(["id": .string("S1"), "material": .string("PLA"), "weight": .number(800),
                         "cost": .number(90), "rev": .number(2)]),
                .object(["id": .string("S2"), "material": .string("PETG"), "weight": .number(500),
                         "cost": .number(120), "rev": .number(1)]),
            ]),
            "expenses": .array([]),
            "wasteLog": .array([]),
            "settings": .object(["currency": .string("SAR"),
                                 "expBudgets": .object(["filament": .number(500)])]),
        ]
        for (k, v) in extra { root[k] = v }
        return root
    }

    static func engine() throws -> KhaytEngine { try KhaytEngine() }

    static func rows(_ root: [String: JSONValue], _ collection: String) -> [[String: JSONValue]] {
        Shop.rows(root, collection).compactMap { if case .object(let o) = $0 { return o } else { return nil } }
    }
    static func string(_ v: JSONValue?) -> String? { Shop.plainString(v) }
    static func number(_ v: JSONValue?) -> Double? { Shop.plainNumber(v) }

    // MARK: - An expense

    @Test("an expense is written by the shared rule, trimmed and defaulted")
    func expense() async throws {
        let engine = try Self.engine()
        let made = try await engine.newExpense([
            "amount": .string(" 250 "), "category": .string("filament"),
            "date": .string("2026-09-04"), "note": .string("  6 spools  "),
            "orderId": .string(" ORD-1 "), "recurring": .string("monthly"),
        ], id: "EXP-1", today: "2026-09-04")
        let e = try #require(made.expense)
        guard case .object(let fields) = e else { Issue.record("not a record"); return }
        #expect(Self.number(fields["amount"]) == 250)
        #expect(Self.string(fields["note"]) == "6 spools", "trimmed")
        #expect(Self.string(fields["orderId"]) == "ORD-1")
        #expect(Self.string(fields["nextDue"]) == "2026-10-04", "a standing cost knows when it is next due")
    }

    @Test("an amount that is not positive is refused, and nothing is written")
    func refusedExpense() async throws {
        let engine = try Self.engine()
        for amount in ["", "0", "-5", "abc"] {
            let made = try await engine.newExpense(["amount": .string(amount)], id: "E", today: "2026-09-04")
            #expect(made.expense == nil, amount == "" ? "empty" : "\(amount)")
            #expect(made.refused == "amount_required")
        }
    }

    @Test("a month past its budget is said, with the figures, after the expense is in")
    func budget() async throws {
        let engine = try Self.engine()
        let month = "2026-09"
        let rows: [JSONValue] = [
            .object(["category": .string("filament"), "amount": .number(300), "date": .string("2026-09-01")]),
            .object(["category": .string("filament"), "amount": .number(260), "date": .string("2026-09-03")]),
            .object(["category": .string("filament"), "amount": .number(900), "date": .string("2026-08-20")]),
        ]
        let budgets: [String: JSONValue] = ["filament": .number(500)]
        let over = try #require(try await engine.overBudget(rows, category: "filament", month: month, budgets: budgets))
        #expect(over.spent == 560, "last month's 900 is not counted")
        #expect(over.budget == 500)
        #expect(try await engine.overBudget(rows, category: "filament", month: month,
                                            budgets: ["filament": .number(600)]) == nil)
        #expect(try await engine.overBudget(rows, category: "tools", month: month, budgets: budgets) == nil,
                "a category with no budget cannot go past one")
    }

    @Test("budget progress is one row per category that has a budget")
    func budgetRows() async throws {
        let engine = try Self.engine()
        let rows = try await engine.budgetProgress(["filament": 600, "tools": 10],
                                                   budgets: ["filament": .number(500), "tools": .number(100)])
        #expect(rows.map(\.category) == ["filament", "tools"], "in Khayt's own order")
        #expect(rows[0].over == true)
        #expect(rows[0].pct == 100, "capped, for a bar")
        #expect(rows[1].remaining == 90)
    }

    // MARK: - A failed print

    @Test("logging a failed print takes the grams off the shelf and remembers the spool")
    func waste() async throws {
        let engine = try Self.engine()
        var root = Self.book()
        // `reclaimsTax: false` — this book has no tax profile, so there is
        // nothing to reclaim and the plastic cost what it cost. S1 records no
        // `spoolWeight` either, so the 800 is all there is to divide by: the
        // legacy case, and the answer is the same as it always was.
        let cost = try await engine.wasteCost(material: "PLA", grams: 200,
                                              inventory: Shop.rows(root, "inventory"),
                                              reclaimsTax: false)
        #expect(cost == 22.5, "200g of a 90-riyal 800g spool")

        let made = try await engine.newWasteEntry([
            "material": .string("PLA"), "weight": .number(200), "cost": .number(cost),
            "failureType": .string("warping"), "deduct": .bool(true),
        ], id: "W-1", today: "2026-09-04", inventory: Shop.rows(root, "inventory"))
        let entry = try #require(made.entry)
        guard case .object(let fields) = entry else { Issue.record("not a record"); return }
        #expect(Self.string(fields["spoolId"]) == "S1",
                "which spool, so deleting the entry can put the grams back")
        root["inventory"] = .array(made.inventory)
        #expect(Self.number(Self.rows(root, "inventory")[0]["weight"]) == 600)
        #expect(Self.number(Self.rows(root, "inventory")[1]["weight"]) == 500, "and the PETG is untouched")
    }

    @Test("deleting an entry puts its grams back")
    func undoWaste() async throws {
        let engine = try Self.engine()
        var root = Self.book()
        let made = try await engine.newWasteEntry([
            "material": .string("PLA"), "weight": .number(200), "deduct": .bool(true),
        ], id: "W-1", today: "2026-09-04", inventory: Shop.rows(root, "inventory"))
        root["inventory"] = .array(made.inventory)
        root["wasteLog"] = .array([try #require(made.entry)])

        let out = try await engine.removeWasteEntry(Shop.rows(root, "wasteLog"), id: "W-1",
                                                    inventory: Shop.rows(root, "inventory"))
        #expect(out.removed)
        #expect(out.wasteLog.isEmpty)
        root["inventory"] = .array(out.inventory)
        #expect(Self.number(Self.rows(root, "inventory")[0]["weight"]) == 800)
    }

    @Test("an entry from before the spool was recorded is deleted, and restores nothing")
    func undoOldWaste() async throws {
        let engine = try Self.engine()
        let root = Self.book(["wasteLog": .array([
            .object(["id": .string("W-old"), "material": .string("PLA"), "weight": .number(150)]),
        ])])
        let out = try await engine.removeWasteEntry(Shop.rows(root, "wasteLog"), id: "W-old",
                                                    inventory: Shop.rows(root, "inventory"))
        #expect(out.removed, "it still goes — a row a shop cannot remove is worse")
        guard case .object(let spool) = out.inventory[0] else { Issue.record("no spool"); return }
        #expect(Self.number(spool["weight"]) == 800, "and nothing is invented about where it came from")
    }

    // MARK: - The write, on disk

    @Test("an expense reaches the file, and the rest of the book with it")
    func expenseOnDisk() async throws {
        let engine = try Self.engine()
        let url = try Self.tempStore(Self.book())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            let made = try await engine.newExpense(["amount": .number(250), "category": .string("filament")],
                                                   id: "EXP-1", today: "2026-09-04")
            var rows = Shop.rows(root, "expenses")
            rows.insert(try #require(made.expense), at: 0)
            root["expenses"] = .array(rows)
        }
        let back = try Self.read(url)
        #expect(Self.rows(back, "expenses").count == 1)
        #expect(Self.rows(back, "printLog").count == 1, "the jobs are untouched")
    }

    @Test("a waste entry and the shelf are written in one swap, and only the spool it touched is stamped")
    func wasteOnDisk() async throws {
        let engine = try Self.engine()
        let url = try Self.tempStore(Self.book())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            let before = Shop.rows(root, "inventory")
            let made = try await engine.newWasteEntry([
                "material": .string("PLA"), "weight": .number(200), "deduct": .bool(true),
            ], id: "W-1", today: "2026-09-04", inventory: before)
            root["wasteLog"] = .array([try #require(made.entry)])
            root["inventory"] = .array(Shop.stamping(made.inventory, against: before))
        }
        let back = try Self.read(url)
        let shelf = Self.rows(back, "inventory")
        #expect(Self.number(shelf[0]["weight"]) == 600)
        // `rev` is what the cloud's sync baseline reads: an unstamped edit
        // never leaves this Mac, and a stamped one that changed nothing sends
        // the whole shelf up on every deletion.
        #expect(Self.number(shelf[0]["rev"]) == 3, "the spool that lost grams is stamped")
        #expect(Self.number(shelf[1]["rev"]) == 1, "and the one that did not, is not")
        #expect(Self.rows(back, "wasteLog").count == 1)
    }

    @Test("the sample shop takes neither an expense nor a failed print, and says why")
    func sampleRefuses() async throws {
        let shop = Shop()
        await shop.load(.sample)
        await shop.addExpense(["amount": .number(10)])
        #expect(shop.spendProblem == shop.words.callIt("mac.move_sample"))
        #expect(shop.spendNote == nil)
        await shop.logWaste(["material": .string("PLA")])
        #expect(shop.spendProblem == shop.words.callIt("mac.move_sample"))
    }

    // MARK: - "This month" means the same thing in both runtimes

    /// `Shop.inPeriod` is the one shared rule this app spells out in Swift,
    /// because it decides whether to draw a row and is asked once per record
    /// while a list lays out. So it is checked against the shared one over
    /// every period and two years of dates, from several clocks.
    @Test("the Swift period filter agrees with lib/date-range.js")
    func periodParity() async throws {
        let engine = try Self.engine()
        let calendar = Calendar.current
        let clocks = [
            DateComponents(year: 2026, month: 9, day: 4),
            DateComponents(year: 2026, month: 1, day: 1),
            DateComponents(year: 2026, month: 12, day: 31),
            DateComponents(year: 2026, month: 3, day: 15),
        ].map { calendar.date(from: $0)! }

        var checked = 0
        for now in clocks {
            for period in Period.allCases {
                for monthsBack in 0..<24 {
                    let day = calendar.date(byAdding: .month, value: -monthsBack, to: now)!
                    for offset in [0, 13, 27] {
                        let d = calendar.date(byAdding: .day, value: offset, to: day)!
                        let date = Shop.today(d)
                        let mine = Shop.inPeriod(date, period: period, now: now)
                        let theirs = try await engine.inRange(date, period: period.rawValue, now: now)
                        #expect(mine == theirs, "\(date) in \(period.rawValue) at \(Shop.today(now))")
                        checked += 1
                    }
                }
            }
        }
        #expect(checked > 1000, "the parity run must actually have run")

        // And the awkward inputs, which is where a reimplementation drifts.
        for bad in ["", "not a date", "2026", "2026-13-40"] {
            for period in Period.allCases {
                #expect(Shop.inPeriod(bad, period: period, now: clocks[0])
                        == (try await engine.inRange(bad, period: period.rawValue, now: clocks[0])),
                        "\(bad) in \(period.rawValue)")
            }
        }
    }

    // MARK: -

    static func tempStore(_ root: [String: JSONValue]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-spend-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "khayt-store.json")
        try JSONEncoder().encode(root).write(to: url)
        return url
    }

    static func read(_ url: URL) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
    }
}

/// What the shop is owed, aged.
///
/// The RULE is `lib/receivables.js`, tested where it lives against the renderer
/// it was lifted from. What is tested here is that this app asks for it with
/// what it needs — the shop's currency table and the language it writes names
/// in — and gets rows a screen can act on.
@MainActor
struct ReceivablesTests {

    static let orders: [JSONValue] = [
        .object(["id": .string("NEW"), "date": .string("2026-09-01"), "project": .string("Bracket"),
                 "price": .number(500), "paidAmount": .number(0), "clientId": .string("C1")]),
        .object(["id": .string("OLD"), "date": .string("2025-01-01"), "project": .string("Rig"),
                 "price": .number(900), "paidAmount": .number(100)]),
        .object(["id": .string("VOID"), "date": .string("2025-01-01"), "price": .number(900),
                 "paidAmount": .number(0), "voidedAt": .string("2025-02-01")]),
        .object(["id": .string("PAID"), "date": .string("2026-08-01"), "price": .number(300),
                 "paidAmount": .number(300)]),
    ]

    @Test("the rows are what is still owed, oldest first, and a voided invoice is not one")
    func aged() async throws {
        let engine = try KhaytEngine()
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 6))!
        let out = try await engine.receivables(
            orders: Self.orders, settings: ["currency": .string("SAR")],
            clients: [.object(["id": .string("C1"), "nameEn": .string("Acme")])],
            currencies: [:], language: "en", now: now)

        #expect(out.rows.map(\.id) == ["OLD", "NEW"], "oldest first — that is what a shop chases")
        #expect(out.total == 1300, "800 still owed on OLD and 500 on NEW")
        #expect(out.rows[0].bucket == "90+")
        #expect(out.rows[0].days > 500)
        #expect(out.rows[1].client == "Acme", "the customer's name, from their record")
        #expect(!out.rows.contains { $0.id == "VOID" }, "a cancelled invoice is not a receivable")
        #expect(!out.rows.contains { $0.id == "PAID" })
    }

    @Test("the four buckets always come back, so a screen can draw them all")
    func buckets() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.receivables(orders: [], settings: [:], clients: [],
                                               currencies: [:], language: "en", now: Date())
        #expect(out.buckets.map(\.label) == ["0-30", "31-60", "61-90", "90+"])
        #expect(out.buckets.allSatisfy { $0.count == 0 && $0.total == 0 })
        #expect(out.rows.isEmpty)
        #expect(out.total == 0)
    }

    @Test("an instalment is aged by its own due date, and shows only its own amount")
    func instalments() async throws {
        let engine = try KhaytEngine()
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 6))!
        // A plan agreed in January with a payment due in August is not eight
        // months overdue; it is seventeen days overdue.
        let order: JSONValue = .object([
            "id": .string("P1"), "date": .string("2026-01-01"), "price": .number(1000),
            "paidAmount": .number(0),
            "instalments": .array([
                .object(["amount": .number(400), "dueDate": .string("2026-06-01"), "paid": .bool(true)]),
                .object(["amount": .number(600), "dueDate": .string("2026-08-20")]),
            ]),
        ])
        let out = try await engine.receivables(orders: [order], settings: [:], clients: [],
                                               currencies: [:], language: "en", now: now)
        #expect(out.rows.count == 1, "the paid instalment is not owed")
        #expect(out.rows[0].owed == 600)
        #expect(out.rows[0].days == 17)
        #expect(out.rows[0].instalment)
        #expect(out.rows[0].bucket == "0-30", "not 90+, which ageing by the order's date would give")
    }
}
