import Foundation
import Testing
@testable import KhaytCore

/// The owner's headline figures, against the JavaScript they came from.
///
/// These are the numbers a shop quotes at itself, so the cases that matter are
/// the ones where a plausible reading gives a plausible WRONG number: a period
/// with no promises in it, a tie in the top five, and a job that is not
/// finished.
@MainActor
struct KpiParityTests {

    private func js() throws -> JSModule { try JSModule(["kpi"]) }

    private func theirs(_ js: JSModule, _ rows: [JSONValue]) throws -> Kpi.Summary {
        let v = try js.value("KhaytKpi.computeKpis(ARG0)", [.array(rows)])
        guard case .object(let o) = v else { Issue.record("not an object"); throw CancellationError() }
        func num(_ k: String) -> Double { JSSemantics.number(o[k]) }
        func top(_ k: String) -> [Kpi.Top] {
            guard case .array(let rows)? = o[k] else { return [] }
            return rows.map { row in
                guard case .object(let r) = row else { return .init(name: "?", revenue: -1, count: -1) }
                return .init(name: JSSemantics.text(r["name"]),
                             revenue: JSSemantics.number(r["revenue"]),
                             count: Int(JSSemantics.number(r["count"])))
            }
        }
        var pct: Double?
        if case .number(let n)? = o["onTimePct"] { pct = n }
        return .init(orderCount: Int(num("orderCount")), completedCount: Int(num("completedCount")),
                     revenue: num("revenue"), cost: num("cost"), grossProfit: num("grossProfit"),
                     grossMargin: num("grossMargin"), avgOrderValue: num("avgOrderValue"),
                     onTimePct: pct, onTimeTotal: Int(num("onTimeTotal")),
                     outstanding: num("outstanding"),
                     topClients: top("topClients"), topProducts: top("topProducts"))
    }

    private func check(_ rows: [JSONValue], _ what: String, _ js: JSModule) throws {
        let mine = Kpi.compute(Kpi.rows(rows))
        let theirs = try theirs(js, rows)
        #expect(mine == theirs, Comment(rawValue: """
            \(what)
              swift \(mine)
              js    \(theirs)
            """))
    }

    private func row(revenue: Double, cost: Double = 0, completed: Bool = true,
                     onTime: JSONValue = .null, outstanding: Double = 0,
                     client: String = "", product: String = "") -> JSONValue {
        var o: [String: JSONValue] = ["revenue": .number(revenue), "cost": .number(cost),
                                      "completed": .bool(completed),
                                      "outstanding": .number(outstanding)]
        if case .null = onTime {} else { o["onTime"] = onTime }
        if !client.isEmpty { o["clientName"] = .string(client) }
        if !product.isEmpty { o["productName"] = .string(product) }
        return .object(o)
    }

    @Test("a quarter of a real book")
    func aRealQuarter() throws {
        let js = try js()
        try check([
            row(revenue: 1200, cost: 380, onTime: .bool(true), outstanding: 0,
                client: "Salem", product: "Dragon"),
            row(revenue: 450.5, cost: 120.25, onTime: .bool(false), outstanding: 450.5,
                client: "Salem", product: "Bracket"),
            row(revenue: 3000, cost: 900, onTime: .bool(true), client: "Aramco",
                product: "Dragon"),
            row(revenue: 200, cost: 500, onTime: .bool(true), client: "Noura",
                product: "Keychain"),
            // Still on the bench: counted in the order count and its money
            // owed, and in nothing else.
            row(revenue: 800, cost: 200, completed: false, outstanding: 400,
                client: "Salem", product: "Dragon"),
        ], "a quarter", js)
    }

    @Test("a period with nothing in it")
    func empty() throws {
        let js = try js()
        try check([], "no rows at all", js)
        try check([row(revenue: 0, completed: false)], "one unfinished row", js)
        // No promises kept and none broken is NOT nought per cent.
        let none = Kpi.compute(Kpi.rows([row(revenue: 100)]))
        #expect(none.onTimePct == nil, "a shop with no due dates was marked late")
        #expect(none.grossMargin == 100)
    }

    @Test("only a real boolean is a promise")
    func onTimeIsStrict() throws {
        let js = try js()
        for value: JSONValue in [.bool(true), .bool(false), .null, .number(1), .number(0),
                                 .string("true"), .string(""), .array([])] {
            try check([row(revenue: 100, onTime: value), row(revenue: 100, onTime: .bool(true))],
                      "onTime \(value)", js)
        }
    }

    @Test("a tie in the top five keeps the order the book mentioned them in")
    func tiesAreStable() throws {
        let js = try js()
        try check([row(revenue: 100, client: "Zahra"), row(revenue: 100, client: "Adel"),
                   row(revenue: 100, client: "Badr")], "three tied", js)
        // Seven clients, so the list is really cut at five.
        var rows: [JSONValue] = []
        for (i, name) in ["A", "B", "C", "D", "E", "F", "G"].enumerated() {
            rows.append(row(revenue: Double(100 - i * 10), client: name, product: name))
        }
        try check(rows, "seven clients", js)
        // …and seven all on the same revenue, where only the order decides.
        try check(["A", "B", "C", "D", "E", "F", "G"].map { row(revenue: 50, client: $0) },
                  "seven tied", js)
    }

    @Test("a loss is a negative margin, not a floor of nothing")
    func lossesMatch() throws {
        let js = try js()
        try check([row(revenue: 100, cost: 400, client: "Salem")], "a loss", js)
        try check([row(revenue: 0, cost: 400, client: "Salem")], "no revenue at all", js)
        try check([row(revenue: -50, cost: 10)], "a refund", js)
    }

    @Test("rows that are not rows, and figures that are not figures")
    func degenerateRows() throws {
        let js = try js()
        try check([.string("x"), .number(1), .bool(true), .array([]), .object([:])],
                  "not rows", js)
        // `null` is left out of the comparison on purpose: the original reads
        // `.revenue` straight off it and throws, taking the whole summary with
        // it. The port counts it as a row with nothing on it, which is what
        // every other non-row already gets.
        #expect((try? js.value("KhaytKpi.computeKpis([null])", [])) == nil,
                "the original survived a null row")
        #expect(Kpi.compute(Kpi.rows([.null, row(revenue: 100)])).orderCount == 2)
        #expect(Kpi.compute(Kpi.rows([.null, row(revenue: 100)])).revenue == 100)
        try check([.object(["revenue": .string("120"), "cost": .string("20"),
                            "completed": .number(1), "outstanding": .string("x"),
                            "clientName": .number(5), "productName": .bool(true)])],
                  "everything as the wrong type", js)
        try check([.object(["revenue": .string("abc"), "completed": .bool(true)])],
                  "revenue that is not a number", js)
    }

    @Test("money owed counts whether or not the job is finished")
    func outstandingCountsEverything() throws {
        let js = try js()
        try check([row(revenue: 100, completed: false, outstanding: 100),
                   row(revenue: 200, outstanding: 50)], "owed on both", js)
    }
}
