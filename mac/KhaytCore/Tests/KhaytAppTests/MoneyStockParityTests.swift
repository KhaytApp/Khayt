import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The money, stock and settings the desktop had and this app did not
/// (Nov 2026 parity, batch B). Each write is driven through its static seam
/// on a book in memory and the SAME shared rule the desktop calls, so these
/// are the records both apps write.
@MainActor
struct MoneyStockParityTests {

    static func source(_ file: String) throws -> String { try LockRound3Tests.source(file) }

    // MARK: - 1. Recurring expenses come due

    static let rent: JSONValue = .object([
        "id": .string("EXP-1"), "date": .string("2026-10-05"), "category": .string("other"),
        "amount": .number(1150), "vatAmount": .number(150), "note": .string("Rent"),
        "recurring": .string("monthly"), "nextDue": .string("2026-11-05"), "locationId": .string("LOC-1"),
    ])

    @Test("a due recurring expense is found, and Add files its copy with the tax and the site")
    func recurringAdd() async throws {
        let engine = try KhaytEngine()
        let due = try await engine.expensesDue([Self.rent], today: "2026-11-05")
        #expect(due.count == 1)
        #expect(try await engine.expensesDue([Self.rent], today: "2026-11-04").isEmpty)

        var root: [String: JSONValue] = ["expenses": .array([Self.rent])]
        let wrote = try await Shop.answeringRecurring(&root, id: "EXP-1", add: true, engine: engine,
                                                      newId: "EXP-2", today: "2026-11-07")
        #expect(wrote)
        let rows = Shop.rows(root, "expenses")
        #expect(rows.count == 2)
        guard case .object(let copy) = rows[0], case .object(let original) = rows[1] else {
            Issue.record("rows are not records"); return
        }
        #expect(Shop.plainString(copy["id"]) == "EXP-2")
        #expect(Shop.plainString(copy["date"]) == "2026-11-07")
        #expect(Shop.plainNumber(copy["vatAmount"]) == 150, "the copy lost the reclaimable tax")
        #expect(Shop.plainString(copy["locationId"]) == "LOC-1", "the copy lost its site")
        #expect(copy["recurring"] == .null, "the copy must not itself recur")
        #expect(copy["updatedAt"] != nil, "a new row nobody stamped never syncs")
        #expect(Shop.plainString(original["nextDue"]) == "2026-12-05")
        #expect(original["updatedAt"] != nil)

        // Answered: asking again files nothing.
        #expect(try await !Shop.answeringRecurring(&root, id: "EXP-1", add: true, engine: engine,
                                                   newId: "EXP-3", today: "2026-11-07"))
        #expect(Shop.rows(root, "expenses").count == 2)
    }

    @Test("Skip moves the schedule on and files nothing")
    func recurringSkip() async throws {
        let engine = try KhaytEngine()
        var root: [String: JSONValue] = ["expenses": .array([Self.rent])]
        #expect(try await Shop.answeringRecurring(&root, id: "EXP-1", add: false, engine: engine,
                                                  newId: "X", today: "2026-11-05"))
        let rows = Shop.rows(root, "expenses")
        #expect(rows.count == 1)
        if case .object(let r) = rows[0] { #expect(Shop.plainString(r["nextDue"]) == "2026-12-05") }
    }

    @Test("the Expenses screen offers Add and Skip, gated like adding an expense")
    func recurringWired() throws {
        let screen = try Self.source("Spending.swift")
        #expect(screen.contains("DueRecurring(shop: shop)"))
        #expect(screen.contains("shop.answerRecurring(e.id, add: add)"))
        let shop = try Self.source("Shop+MoneyStock.swift")
        #expect(shop.contains("permitted(\"invoicing\", add ? \"create\" : \"edit\")"))
    }

    // MARK: - 2. Locations on expenses and spools; transfer

    @Test("an expense and a spool read the site they were kept at")
    func locationsDecode() throws {
        let expense = try JSONDecoder().decode(Expense.self, from: JSONEncoder().encode(Self.rent))
        #expect(expense.locationId == "LOC-1")
        let spool = try JSONDecoder().decode(Spool.self, from: Data(#"{"id":"S","material":"PLA","locationId":"LOC-2"}"#.utf8))
        #expect(spool.locationId == "LOC-2")
        let none = try JSONDecoder().decode(Spool.self, from: Data(#"{"id":"S","material":"PLA"}"#.utf8))
        #expect(none.locationId == nil)
    }

    @Test("the spool form sends its site, and the expense form sends one too")
    func locationsSent() throws {
        var form = SpoolSheet.Form()
        form.locationId = "LOC-2"
        #expect(form.input(isNew: true, reclaimsTax: false)["locationId"] == .string("LOC-2"))
        let sheet = try Self.source("SpendSheets.swift")
        #expect(sheet.contains("\"locationId\": .string(locationId)"))
    }

    @Test("a transfer splits the spool, and a refusal is said in the shop's words")
    func transfer() async throws {
        let engine = try KhaytEngine()
        let words = Words()
        let spool: JSONValue = .object(["id": .string("INV-1"), "material": .string("PLA"),
                                        "weight": .number(800), "locationId": .string("LOC-A"),
                                        "usageHistory": .array([.object(["weightUsed": .number(200)])])])
        var root: [String: JSONValue] = ["inventory": .array([spool])]
        try await Shop.transferring(&root, spoolId: "INV-1", dest: "LOC-B", qty: 300,
                                    engine: engine, words: words, newId: "INV-2")
        let shelf = Shop.rows(root, "inventory")
        #expect(shelf.count == 2)
        if case .object(let source) = shelf[0], case .object(let split) = shelf[1] {
            #expect(Shop.plainNumber(source["weight"]) == 500)
            #expect(Shop.plainString(split["id"]) == "INV-2")
            #expect(Shop.plainString(split["locationId"]) == "LOC-B")
            #expect(Shop.plainNumber(split["weight"]) == 300)
            #expect(split["usageHistory"] == .array([]))
        } else { Issue.record("not records") }

        do {
            try await Shop.transferring(&root, spoolId: "INV-1", dest: "LOC-A", qty: 10,
                                        engine: engine, words: words, newId: "INV-3")
            Issue.record("moving a spool to where it is was accepted")
        } catch let refusal as Shop.MoveRefused {
            #expect(refusal.sentence == words.callIt("inv.transfer_same"))
        }
    }

    // MARK: - 6. Stock adjustment and drying log

    @Test("an adjustment writes the desktop's row and moves the weight")
    func adjust() async throws {
        let engine = try KhaytEngine()
        var root: [String: JSONValue] = ["inventory": .array([.object([
            "id": .string("INV-1"), "material": .string("PLA"), "weight": .number(300)])])]
        try await Shop.adjustingStock(&root, spoolId: "INV-1",
                                      input: ["type": .string("remove"), "amount": .number(120),
                                              "reason": .string("Shelf count")],
                                      engine: engine, words: Words(), newId: "ADJ-1", today: "2026-11-05")
        guard case .object(let r) = Shop.rows(root, "inventory")[0],
              case .array(let log)? = r["adjustments"], case .object(let row)? = log.first else {
            Issue.record("no adjustment written"); return
        }
        #expect(Shop.plainNumber(r["weight"]) == 180)
        #expect(row == ["id": .string("ADJ-1"), "date": .string("2026-11-05"), "type": .string("remove"),
                        "amount": .number(120), "reason": .string("Shelf count")])
    }

    @Test("a drying session is the desktop's row; Dried today stays the date alone")
    func dryingRow() {
        let full = Shop.dryingEntry(id: "DRY-1", date: "2026-11-05", tempC: 65, hours: 4, notes: " box ")
        #expect(full == ["id": .string("DRY-1"), "date": .string("2026-11-05"), "tempC": .number(65),
                         "durationH": .number(4), "notes": .string("box")])
        let noTemp = Shop.dryingEntry(id: "D", date: "2026-11-05", tempC: nil, hours: 2, notes: "")
        #expect(noTemp["tempC"] == .null)
        #expect(Shop.dryingEntry(id: "D", date: "2026-11-05", tempC: nil, hours: nil, notes: "")
                == ["id": .string("D"), "date": .string("2026-11-05")])
        let logged = FilamentDryness.recordDrying(.object(["driedAt": .string("2026-11-01")]), entry: full)
        #expect(logged.driedAt == "2026-11-05")
    }

    @Test("the shelf offers the drying log, an adjustment and a transfer")
    func shelfWired() throws {
        let floor = try Self.source("ShopFloor.swift")
        #expect(floor.contains("shop.dryingLogFor = spool"))
        #expect(floor.contains("shop.adjustingSpool = spool"))
        #expect(floor.contains("shop.transferringSpool = spool"))
        let window = try Self.source("ShopWindow.swift")
        #expect(window.contains("DryingLogSheet(shop: shop, spool: $0)"))
        #expect(window.contains("StockAdjustSheet(shop: shop, spool: $0)"))
        #expect(window.contains("TransferStockSheet(shop: shop, spool: $0)"))
        let sheets = try Self.source("SpoolStockSheets.swift")
        #expect(sheets.contains("shop.markDried(spool.id, on: Shop.today(date)"))
    }

    // MARK: - 3. Exchange rates

    @Test("exchange rates are edited and fetched through the shared rule")
    func exchangeRates() async throws {
        let engine = try KhaytEngine()
        let settings: [String: JSONValue] = ["currency": .string("SAR"),
                                             "exchangeRates": .object(["USD": .number(3.75), "EUR": .number(4.1)])]
        let out = try await engine.exchangeRates(settings, edits: ["USD": .number(3.76), "EUR": .null],
                                                 base: "SAR", fetchedAt: nil)
        #expect(out["exchangeRates"] == .object(["USD": .number(3.76)]))
        #expect(ExchangeRatesSection.stored(out) == ["USD": 3.76])

        let feed = try await engine.ratesFromFeed(
            .object(["result": .string("success"), "time_last_update_utc": .string("today"),
                     "rates": .object(["USD": .number(0.25), "ZZZ": .number(2)])]),
            base: "SAR", known: ["USD": .object([:])])
        #expect(feed.rates == ["USD": 4])
        #expect(Shop.ratesURL(base: "sar")?.absoluteString == "https://open.er-api.com/v6/latest/SAR")
        #expect(Shop.ratesURL(base: "") == nil)
    }

    // MARK: - 4. Invoice numbering

    @Test("the invoice counter is set by its own rule, and the gaps are found")
    func invoiceNumbering() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.invoiceNumbering(["invNumNext": .number(9)],
                                                    form: ["prefix": .string("TAX"), "next": .number(42),
                                                           "format": .string("{prefix}-{seq4}")], year: 2026)
        #expect(out["invNumPrefix"] == .string("TAX"))
        #expect(out["invNumNext"] == .number(42))
        #expect(out["invNumFormat"] == .string("{prefix}-{seq4}"))
        let reset = try await engine.invoiceNumbering(out, form: ["reset": .bool(true)], year: 2027)
        #expect(reset["invNumNext"] == .number(1))
        #expect(reset["invNumYear"] == .number(2027))

        let gaps = try await engine.invoiceNumberGaps([.object(["id": .string("INV-2026-0001")]),
                                                       .object(["id": .string("INV-2026-0004")])])
        #expect(gaps == [2, 3])
        #expect(InvoiceNumberingSection.example("{prefix}-{year}-{seq4}", prefix: "INV", year: 2026, seq: 42)
                == "INV-2026-0042")
    }

    // MARK: - 5. Loyalty tiers

    @Test("loyalty tiers are saved clean, keeping what the editor does not show")
    func loyaltyTiers() async throws {
        let engine = try KhaytEngine()
        let stored: [String: JSONValue] = ["loyaltyTiers": .array([.object([
            "name": .string("Gold"), "minOrders": .number(10), "minSpend": .number(0),
            "discountPct": .number(5), "pointsMultiplier": .number(2)])])]
        var tiers = LoyaltyTiersSection.read(stored)
        #expect(tiers.count == 1)
        tiers[0].discountPct = 150
        tiers.append(.init())   // added and never named
        let clean = try await engine.cleanLoyaltyTiers(tiers.map { .object($0.record) })
        #expect(clean.count == 1)
        guard case .object(let gold) = clean[0] else { Issue.record("not a record"); return }
        #expect(gold["discountPct"] == .number(100))
        #expect(gold["pointsMultiplier"] == .number(2), "a field the editor does not show was dropped")
    }

    // MARK: - 7. Team activity log

    @Test("the activity log lists newest first, by member, at most three hundred")
    func activityLog() {
        var rows: [JSONValue] = []
        for i in 0..<320 {
            rows.append(.object(["id": .string("AL-\(i)"), "at": .string("2026-11-05T10:00:00Z"),
                                 "action": .string("status"), "detail": .string("job \(i)"),
                                 "operatorId": .string(i % 2 == 0 ? "OP-A" : "OP-B"),
                                 "operatorName": .string(i % 2 == 0 ? "Ali" : "Sara")]))
        }
        let all = ActivityLogSheet.entries(rows, member: "")
        #expect(all.count == ActivityLogSheet.shown)
        #expect(all.first?.id == "AL-319")
        let ali = ActivityLogSheet.entries(rows, member: "OP-A")
        #expect(ali.allSatisfy { $0.operatorId == "OP-A" })
        #expect(ali.first?.id == "AL-318")
        #expect(ActivityLogSheet.entries([.string("junk")], member: "").isEmpty)
    }

    @Test("the log is reached from the Book menu, behind the lock's logs area")
    func activityWired() throws {
        let menus = try Self.source("Menus.swift")
        #expect(menus.contains("shop.showingActivityLog = true"))
        #expect(menus.contains("lockAllows(\"logs\", \"view\")"))
        let lock = try Self.source("OperatorLock.swift")
        #expect(lock.contains("showingActivityLog = false"), "the log stays open across a sign-out")
    }

    // MARK: - 8. Waste against revenue

    @Test("the jobs that wasted most, and waste as a share of revenue")
    func waste() async throws {
        let engine = try KhaytEngine()
        let top = try await engine.wasteTopOrders([.object(["orderId": .string("A"), "cost": .number(10)]),
                                                   .object(["orderId": .string("B"), "cost": .number(30)]),
                                                   .object(["orderId": .string("A"), "cost": .number(25)])],
                                                  limit: 5)
        #expect(top.map(\.orderId) == ["A", "B"])
        #expect(top.first?.count == 2)
        let share = try await engine.wasteShare(cost: 3, revenue: 100)
        #expect(share?.pct == 3 && share?.tone == "warn")
        #expect(try await engine.wasteShare(cost: 3, revenue: 0) == nil)
        let screen = try Self.source("Spending.swift")
        #expect(screen.contains("waste.pct_revenue"))
        #expect(screen.contains("TopOrders(shop: shop, shown: shown)"))
    }

    // MARK: - 9. Revenue goal

    @Test("the goal reads the desktop's trade revenue, which is the month's KPI revenue")
    func goalAgrees() async throws {
        let engine = try KhaytEngine()
        let now = Date()
        let span = Shop.goalSpan(now)
        let today = DateRange.localDay(now)
        let settings: [String: JSONValue] = [
            "enableVat": .bool(true), "vatRate": .number(15),
            "tax": .object(["country": .string("SA"), "name": .string("VAT"), "mode": .string("inclusive"),
                            "rates": .array([.object(["id": .string("vat"), "label": .string("VAT"),
                                                      "percent": .number(15)])])]),
        ]
        let orders: [JSONValue] = [
            .object(["id": .string("a"), "price": .number(1150), "status": .string("completed"), "date": .string(today)]),
            .object(["id": .string("b"), "price": .number(575), "status": .string("completed"), "date": .string(today),
                     "voidedAt": .string("x")]),
            .object(["id": .string("c"), "price": .number(575), "status": .string("completed"), "date": .string(today),
                     "nonBusiness": .bool(true)]),
        ]
        let trade = try await engine.tradeRevenue(orders: orders, settings: settings, clients: [],
                                                  currencies: [:], from: span.from, to: span.to)
        #expect(trade == 1000, "net of VAT, voided and Not business left out")
        let kpis = try await engine.kpis(orders: orders, clients: [], settings: settings, range: "month",
                                         language: "en")
        #expect(kpis.revenue == trade, "the goal \(trade) and the month's KPI \(kpis.revenue) disagree")

        let pace = try await engine.goalPace(revenue: 1000, previous: 800, goal: 4000, day: 10, days: 30)
        #expect(pace.forecast == 3000)
        #expect(pace.deltaPct == 25)
    }

    @Test("the goal's months are the book's, and its bar shows the pace and the change")
    func goalSpanAndWiring() throws {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 1; parts.day = 15; parts.hour = 12
        let mid = try #require(Calendar.book.date(from: parts))
        let span = Shop.goalSpan(mid)
        #expect(span.from == "2026-01-01" && span.to == "2026-01-31")
        #expect(span.lastFrom == "2025-12-01" && span.lastTo == "2025-12-31")
        #expect(span.day == 15 && span.days == 31)
        let dash = try Self.source("Dashboard.swift")
        #expect(dash.contains("shop.monthGoal"))
        #expect(dash.contains("dash.forecast"))
        let shop = try Self.source("Shop.swift")
        #expect(shop.contains("engine.tradeRevenue("), "the goal does not read the shared rule")
    }

    // MARK: - 10. Search finds spools

    @Test("Go to… finds a spool and opens the shelf on it")
    func searchFindsSpools() async throws {
        let shop = await GoToTests.sample()
        let spool = try #require(shop.spools.first)
        let index = await shop.goToIndex()
        #expect(shop.goToKinds.contains(.spool))
        let hit = try #require(index.search(spool.material).groups.first { $0.kind == .spool }?.hits.first)
        shop.goTo(hit.entry)
        #expect(shop.shelf == .inventory)
        #expect(shop.spoolSelection == hit.entry.id)
    }
}
