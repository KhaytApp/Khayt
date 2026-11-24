import Foundation
import Testing
@testable import KhaytCore

/// `KhaytEngine.successRates` against the vectors the Windows/Linux app's own
/// test runs (`test/fixtures/printer-success-vectors.json`,
/// `test/printer-batch3.test.js`): the Mac and the phone count a printer's
/// prints exactly as the desktop does.
struct SuccessRatesTests {

    struct Case: Decodable {
        struct Input: Decodable { let machines: [JSONValue]; let orders: [JSONValue]; let from: String?; let to: String? }
        let why: String
        let input: Input
        let want: [KhaytEngine.SuccessRow]
    }
    struct Vectors: Decodable { let cases: [Case] }

    @Test("the desktop's vectors: worst first, cancelled and unknown outside the rate, too few is not enough, the date window")
    func vectors() async throws {
        let engine = try KhaytEngine()
        let file = try Data(contentsOf: CrossAppFixtureTests.fixture("printer-success-vectors.json"))
        let cases = try JSONDecoder().decode(Vectors.self, from: file).cases
        #expect(cases.count >= 2, "the fixture lost its cases")
        var sawWindow = false, sawNil = false, sawNotEnough = false
        for c in cases {
            let got = try await engine.successRates(orders: c.input.orders, machines: c.input.machines, from: c.input.from, to: c.input.to)
            #expect(got == c.want, Comment(rawValue: c.why))
            sawWindow = sawWindow || c.input.from != nil
            sawNil = sawNil || c.want.contains { $0.rate == nil }
            sawNotEnough = sawNotEnough || c.want.contains { !$0.enough && $0.decided > 0 }
        }
        // The vectors still cover what this test's name says.
        #expect(sawWindow && sawNil && sawNotEnough)
    }

    @Test("what the phone's line is made of: the counts, the rate, and how many runs are needed")
    func line() async throws {
        let engine = try KhaytEngine()
        let needed = try await engine.successRunsNeeded()
        #expect(needed == 5)
        func run(_ result: String?) -> JSONValue {
            var r: [String: JSONValue] = ["machineId": .string("U1"), "at": .string("2026-11-20")]
            if let result { r["result"] = .string(result); r["resultSource"] = .string("printer") }
            return .object(r)
        }
        func rows(_ results: [String?]) async throws -> [KhaytEngine.SuccessRow] {
            try await engine.successRates(orders: [.object(["id": .string("1"), "printRuns": .array(results.map(run))])],
                                          machines: [.object(["id": .string("U1")]), .object(["id": .string("idle")])])
        }
        // "23 finished, 2 failed · 3 cancelled not counted · 92%"
        let busy = try await rows(Array(repeating: "finished", count: 23) + ["failed", "failed", "cancelled", "cancelled", "cancelled", nil])
        let u1 = try #require(busy.first { $0.machineId == "U1" })
        #expect(u1 == .init(machineId: "U1", finished: 23, failed: 2, cancelled: 3, unknown: 1, rate: 0.92, enough: true))
        #expect(u1.decided == 25)
        // A machine with no runs still has a row, last, with no rate.
        #expect(busy.last == .init(machineId: "idle", finished: 0, failed: 0, cancelled: 0, unknown: 0, rate: nil, enough: false))
        // "Not enough prints yet: 3 of 5 needed": three decided runs, however many were cancelled.
        let few = try #require(try await rows(["finished", "finished", "failed", "cancelled", "cancelled", "cancelled"]).first { $0.machineId == "U1" })
        #expect(few.decided == 3 && !few.enough && few.decided < needed)
        // Exactly enough.
        #expect(try #require(try await rows(Array(repeating: "finished", count: 5)).first).enough)
        // A deleted job's runs are nobody's.
        let gone = try await engine.successRates(
            orders: [.object(["id": .string("1"), "deleted": .bool(true), "printRuns": .array([run("failed")])])],
            machines: [.object(["id": .string("U1")])])
        #expect(gone == [.init(machineId: "U1", finished: 0, failed: 0, cancelled: 0, unknown: 0, rate: nil, enough: false)])
    }
}
