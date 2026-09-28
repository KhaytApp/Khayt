import Foundation
import Testing
@testable import KhaytCore

/// Machine depreciation and the learned failure allowance, through the engine.
///
/// `test/depreciation.test.js` and `test/failure-rate.test.js` pin the
/// arithmetic. These hold the Mac to the same rules: the wear rate a quote on
/// a machine is charged, the P&L line, and the suggestion beside the failure %.
@Suite struct DepreciationTests {

    static let perHour: JSONValue = .object([
        "id": .string("M1"), "name": .string("U1"),
        "depreciation": .object([
            "price": .number(6000), "residual": .number(1000), "life": .number(5000),
            "lifeUnit": .string("hours"), "method": .string("perHour"),
            "purchaseDate": .string("2026-01-01"),
        ]),
    ])

    static let straight: JSONValue = .object([
        "id": .string("M2"), "name": .string("X1C"),
        "depreciation": .object([
            "price": .number(5000), "residual": .number(1400), "life": .number(3),
            "lifeUnit": .string("years"), "method": .string("straightLine"),
            "purchaseDate": .string("2026-01-01"),
        ]),
    ])

    static func job(_ id: String, machine: String, date: String, hours: Double) -> JSONValue {
        .object(["id": .string(id), "machineId": .string(machine), "status": .string("completed"),
                 "date": .string(date), "printTime": .number(hours), "price": .number(100)])
    }

    @Test("a machine with depreciation charges its derived rate, not the flat one")
    func derivedWearRate() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.printRates(machine: Self.perHour)["wearRate"] == 1)
        let flat = try await engine.printRateDefaults()["wearRate"]
        #expect(try await engine.printRates(machine: .object(["id": .string("M3")]))["wearRate"] == flat)
        // A straight-line machine leans on its recent hours, carried on the row.
        guard case .object(var m) = Self.straight else { return }
        m["recentMonthlyHours"] = .number(100)
        #expect(try await engine.printRates(machine: .object(m))["wearRate"] == 1)
    }

    @Test("a part's own wear rate still wins over the machine's derived one")
    func partWins() async throws {
        let engine = try KhaytEngine()
        let part: JSONValue = .object(["printTime": .number(10), "wearRate": .number(0.2),
                                       "failureRate": .number(0), "laborRate": .number(0),
                                       "prepTime": .number(0), "postTime": .number(0),
                                       "powerDraw": .number(0)])
        let costed = try await engine.costPart(part, inventory: [], settings: [:], machine: Self.perHour)
        #expect(costed.rates.wearRate == 0.2)
        #expect(abs(costed.cost - 2) < 0.0001)
    }

    @Test("machine values: book value, to date and life left, from finished work")
    func values() async throws {
        let engine = try KhaytEngine()
        let values = try await engine.machineValues(
            machines: [Self.perHour, .object(["id": .string("M3")])],
            orders: [Self.job("a", machine: "M1", date: "2026-03-01", hours: 200)],
            today: "2026-03-10")
        #expect(values.keys.sorted() == ["M1"])
        let v = try #require(values["M1"])
        #expect(v.toDate == 200)
        #expect(v.bookValue == 5800)
        #expect(v.remainingHours == 4800)
        #expect(v.hourlyRate == 1)
        #expect(v.needs == nil)
    }

    @Test("the sheet's live preview answers nil without a price")
    func previewWithoutPrice() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.depreciationStatus(machine: .object(["id": .string("x")]),
                                                    today: "2026-03-10", hoursRun: 0) == nil)
        let v = try await engine.depreciationStatus(machine: Self.straight, today: "2027-01-01", hoursRun: 0)
        #expect(v?.monthly == 100)
    }

    @Test("the P&L carries a depreciation line, in net, and none for a book without it")
    func pnlLine() async throws {
        let engine = try KhaytEngine()
        let orders = [Self.job("a", machine: "M1", date: "2026-03-05", hours: 40)]
        let now = Calendar.book.date(from: DateComponents(year: 2026, month: 5, day: 15))!
        let plain = try await engine.pnlByPeriod(orders: orders, expenses: [], settings: [:],
                                                 clients: [], currencies: [:], now: now,
                                                 granularity: "month")
        let rows = try await engine.pnlByPeriod(orders: orders, expenses: [], settings: [:],
                                                clients: [], currencies: [:], now: now,
                                                granularity: "month", machines: [Self.perHour])
        let before = try #require(plain.first { $0.period == "2026-03" })
        let after = try #require(rows.first { $0.period == "2026-03" })
        #expect(before.depreciation == 0)
        #expect(after.depreciation == 40)
        #expect(abs(after.net - (before.net - 40)) < 0.001)
    }

    @Test("the machine P&L takes depreciation off that machine's net")
    func machinePL() async throws {
        let engine = try KhaytEngine()
        let report = try await engine.machineProfit(
            machines: [Self.perHour], completed: [Self.job("a", machine: "M1", date: "2026-03-05", hours: 40)],
            expenses: [], maintenance: [], settings: [:], clients: [], unassigned: "—",
            range: (from: "2026-03-01", to: "2026-03-31"))
        let row = try #require(report.rows.first)
        #expect(row.depreciation == 40)
        #expect(report.totals.depreciation == 40)
    }

    static func small(bought: String) -> JSONValue {
        .object([
            "id": .string("M1"), "name": .string("U1"),
            "depreciation": .object([
                "price": .number(600), "residual": .number(100), "life": .number(100),
                "lifeUnit": .string("hours"), "method": .string("perHour"),
                "purchaseDate": .string(bought),
            ]),
        ])
    }

    @Test("perHour in the machine P&L is the shop P&L's: past its life and before purchase charge nothing")
    func machinePLMatchesShopPL() async throws {
        let engine = try KhaytEngine()
        let now = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-21
        func both(_ machine: JSONValue, _ orders: [JSONValue], _ inRange: [JSONValue]) async throws -> (Double?, Double?) {
            let report = try await engine.machineProfit(
                machines: [machine], completed: inRange, expenses: [], maintenance: [],
                settings: [:], clients: [], unassigned: "—",
                range: (from: "2026-09-01", to: "2026-09-30"), orders: orders)
            let shop = try await engine.pnlByPeriod(orders: orders, expenses: [], settings: [:], clients: [],
                                                    currencies: [:], now: now, granularity: "month",
                                                    machines: [machine])
            return (report.rows.first?.depreciation, shop.first { $0.period == "2026-09" }?.depreciation)
        }
        // 100 h already printed on a 100 h life: September's 10 h is nothing more.
        let spent = [Self.job("old", machine: "M1", date: "2026-05-10", hours: 100),
                     Self.job("sep", machine: "M1", date: "2026-09-10", hours: 10)]
        let (a, b) = try await both(Self.small(bought: "2026-01-01"), spent, [spent[1]])
        #expect(a == 0)
        #expect(a == b)
        // Bought on the 20th: a job on the 10th is not its wear.
        let early = [Self.job("early", machine: "M1", date: "2026-09-10", hours: 10)]
        let (c, d) = try await both(Self.small(bought: "2026-09-20"), early, early)
        #expect(c == 0)
        #expect(c == (d ?? 0))
    }

    @Test("a failure allowance is suggested from the book, with how many prints it rests on")
    func failureSuggestion() async throws {
        let engine = try KhaytEngine()
        var orders: [JSONValue] = []
        for k in 0..<18 {
            orders.append(.object(["id": .string("J\(k)"), "machineId": .string("M1"),
                                   "material": .string("PLA"), "status": .string("completed"),
                                   "date": .string("2026-09-01")]))
        }
        let waste: [JSONValue] = [
            .object(["orderId": .string("J0"), "date": .string("2026-09-01")]),
            .object(["orderId": .string("J1"), "date": .string("2026-09-01")]),
        ]
        let s = try await engine.failureSuggestion(orders: orders, wasteLog: waste, today: "2026-09-28",
                                                   machineId: "M1", material: "PLA")
        #expect(s.enough)
        #expect(s.pct == 10)
        #expect(s.attempts == 20)
        #expect(s.scope == "machine_material")
        let thin = try await engine.failureSuggestion(orders: Array(orders.prefix(3)), wasteLog: [],
                                                      today: "2026-09-28")
        #expect(thin.enough == false)
        #expect(thin.pct == nil)
        #expect(thin.attempts == 3)
    }
}
