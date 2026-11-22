import Foundation
import Testing
@testable import KhaytCore

/// Which machine is costing the shop, through the engine.
///
/// `test/machine-reliability.test.js` pins the rules. What matters here is that
/// the ranking survives: worst RATE, not most grams — ranking by grams always
/// names the busiest machine, which is the wrong printer to sell.
@Suite struct MachineReliabilityTests {

    static let machines: [JSONValue] = [
        .object(["id": .string("m1"), "name": .string("Old one")]),
        .object(["id": .string("m2"), "name": .string("New one")]),
    ]

    static func job(_ id: String, _ machine: String, grams: Double,
                    status: String = "completed", date: String = "2026-09-01") -> JSONValue {
        .object([
            "id": .string(id), "machineId": .string(machine),
            "status": .string(status), "date": .string(date),
            "parts": .array([.object(["printWeight": .number(grams),
                                      "qty": .number(1), "printTime": .number(1)])]),
        ])
    }

    static func scrap(_ machine: String?, grams: Double, fault: String,
                      date: String = "2026-09-01") -> JSONValue {
        var o: [String: JSONValue] = [
            "weight": .number(grams), "failureType": .string(fault),
            "date": .string(date), "cost": .number(grams / 10),
        ]
        if let machine { o["machineId"] = .string(machine) }
        return .object(o)
    }

    static func run(_ engine: KhaytEngine, _ orders: [JSONValue],
                    _ waste: [JSONValue]) async throws -> KhaytEngine.MachineReliability {
        try await engine.machineReliability(machines: machines, orders: orders,
                                            waste: waste, from: "", to: "",
                                            unassigned: "Unassigned")
    }

    /// A printer that ran nine hundred hours and scrapped two kilos is doing
    /// better than one that ran ninety and scrapped one.
    @Test("the worst machine is the worst rate, not the one that scrapped the most")
    func worstIsTheRate() async throws {
        let engine = try KhaytEngine()
        let report = try await Self.run(engine, [
            Self.job("a", "m1", grams: 1000), Self.job("b", "m1", grams: 1000),
            Self.job("c", "m2", grams: 100), Self.job("d", "m2", grams: 100),
        ], [
            Self.scrap("m1", grams: 200, fault: "warping"),
            Self.scrap("m2", grams: 100, fault: "nozzle_jam"),
        ])
        #expect(report.rows.first?.machineId == "m2")
        #expect(report.totals.worst?.machineId == "m2")
        // And the worst machine scrapped FEWER grams, which is the whole point.
        let m1 = try #require(report.rows.first { $0.machineId == "m1" })
        let m2 = try #require(report.rows.first { $0.machineId == "m2" })
        #expect(m2.scrapGrams < m1.scrapGrams)
    }

    @Test("each machine reports what it keeps doing wrong")
    func theFaultIsNamed() async throws {
        let engine = try KhaytEngine()
        let report = try await Self.run(engine, [Self.job("a", "m1", grams: 1000)], [
            Self.scrap("m1", grams: 50, fault: "stringing"),
            Self.scrap("m1", grams: 300, fault: "warping"),
        ])
        let row = try #require(report.rows.first { $0.machineId == "m1" })
        #expect(row.worstFault?.type == "warping")
        #expect(row.worstFault?.grams == 300)
        #expect(row.scraps == 2)
    }

    /// Hiding it makes the shop's total look better than it is.
    @Test("scrap that names no machine is still in the shop total")
    func unassignedScrapCounts() async throws {
        let engine = try KhaytEngine()
        let report = try await Self.run(engine, [Self.job("a", "m1", grams: 1000)],
                                        [Self.scrap(nil, grams: 500, fault: "warping")])
        #expect(report.rows.first { $0.machineId == "__none__" }?.scrapGrams == 500)
        #expect(report.totals.scrapGrams == 500)
    }

    /// One scrapped print on a machine that has run twice is not evidence.
    @Test("the machine to look at needs enough history to mean anything")
    func oneJobIsNotARate() async throws {
        let engine = try KhaytEngine()
        let barely = try await Self.run(engine, [Self.job("a", "m1", grams: 10)],
                                        [Self.scrap("m1", grams: 500, fault: "warping")])
        #expect(barely.totals.worst == nil)
    }

    /// A screen can only have been reviewed against data that reaches it.
    @Test("the sample shop reaches this card, with more than one machine scrapping")
    func theSampleReachesIt() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Resources/sample-shop.json")
        let root = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        guard case .object(let book) = root,
              case .array(let orders)? = book["printLog"],
              case .array(let machines)? = book["machines"],
              case .array(let waste)? = book["wasteLog"] else {
            Issue.record("could not read the sample shop"); return
        }
        let engine = try KhaytEngine()
        let report = try await engine.machineReliability(
            machines: machines, orders: orders, waste: waste,
            from: "", to: "", unassigned: "Unassigned")
        #expect(report.rows.filter { $0.scraps > 0 }.count > 1,
                "only one machine scraps anything, so the ranking shows nothing")
        #expect(report.totals.worst?.worstFault != nil,
                "the sentence naming the fault is undrawn")
    }
}
