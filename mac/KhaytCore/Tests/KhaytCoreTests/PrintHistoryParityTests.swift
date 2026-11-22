import Foundation
import Testing
@testable import KhaytCore

/// Times printed and last printed off the jobs, against `lib/print-history.js`.
///
/// The desktop's phone library (`lib/lan-library.js`) and the Mac's library,
/// its phone payload and its MCP server all answer "how often have I made
/// this" — and before this rule existed the Mac answered "never" for every
/// model. The corpus is about the edges: which statuses count, a quantity
/// that is not a number, a part listed twice, a date that will not parse, a
/// failure on an open job, and a voided one.
@MainActor
struct PrintHistoryParityTests {

    private func js() throws -> JSModule { try JSModule(["print-history"]) }

    private func theirs(_ js: JSModule, _ orders: [JSONValue]) throws -> [String: PrintHistory.Entry] {
        guard case .object(let o) = try js.value("globalThis.KhaytPrintHistory.byFile(ARG0)", [.array(orders)]) else {
            Issue.record("not an object"); return [:]
        }
        func int(_ v: JSONValue?) -> Int { if case .number(let n)? = v { return Int(n) }; return -1 }
        func text(_ v: JSONValue?) -> String? { if case .string(let s)? = v { return s }; return nil }
        return o.compactMapValues { row in
            guard case .object(let e) = row else { return nil }
            return PrintHistory.Entry(timesPrinted: int(e["timesPrinted"]), copies: int(e["copies"]),
                                      timesFailed: int(e["timesFailed"]), lastPrinted: text(e["lastPrinted"]),
                                      lastJobId: text(e["lastJobId"]))
        }
    }

    private func job(_ id: String, _ status: JSONValue, parts: [JSONValue],
                     extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "status": status, "parts": .array(parts),
                                      "date": .string("2026-09-01"),
                                      "completedAt": .string("2026-09-03T10:00:00.000Z")]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }
    private func part(_ id: JSONValue, qty: JSONValue? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["printFileId": id]
        if let qty { o["qty"] = qty }
        return .object(o)
    }

    @Test("every status, and the ones nobody has heard of")
    func statuses() throws {
        let js = try js()
        let names: [JSONValue] = [.string("quote"), .string("pending"), .string("queued"), .string("printing"), .string("post"), .string("qc"), .string("completed"),
                                  .string("delivered"), .string("shipped"), .string("cancelled"), .string("Completed"), .string(" completed"), .string(""),
                                  .null, .bool(true), .number(1), .string("constructor"), .string("__proto__")]

        let orders = names.enumerated().map { i, s in job("J\(i)", s, parts: [part(.string("PF-\(i % 3)"))]) }
        #expect(PrintHistory.byFile(orders) == (try theirs(js, orders)))
    }

    @Test("quantities that are not whole numbers, or not numbers")
    func quantities() throws {
        let js = try js()
        let qtys: [JSONValue] = Awkward.numbers.filter { abs($0) < 1e15 }.map(JSONValue.number) + Awkward.notNumbers
        for q in qtys {
            let orders = [job("J", .string("completed"), parts: [part(.string("PF-a"), qty: q), part(.string("PF-a"), qty: q), part(.string("PF-b"), qty: q)])]
            let mine = PrintHistory.byFile(orders), theirs = try theirs(js, orders)
            #expect(mine == theirs, Comment(rawValue: "qty \(q): swift \(mine) js \(theirs)"))
        }
    }

    @Test("dates: newest finish wins, unreadable ones fall through")
    func dates() throws {
        let js = try js()
        let whens: [[String: JSONValue]] = [
            ["completedAt": .string("2026-10-01T08:00:00+03:00")], ["completedAt": .string("2026-09-30T23:00:00Z")],
            ["completedAt": .string("not a date"), "date": .string("2026-08-01")],
            ["completedAt": .null, "deliveredAt": .string("2026-09-04T09:00:00")],
            ["completedAt": .number(1_790_000_000_000), "shippedAt": .string("2026-09-05")],
            ["completedAt": .string(""), "date": .string("")], ["completedAt": .string("2026-09-30T23:00:00.000Z")],
        ]
        var orders: [JSONValue] = []
        for (i, w) in whens.enumerated() {
            orders.append(job("J\(i)", .string("completed"), parts: [part(.string("PF-a")), part(.string("PF-\(i)"))], extra: w))
            let one = [orders.last!]
            #expect(PrintHistory.byFile(one) == (try theirs(js, one)), Comment(rawValue: "\(w)"))
        }
        #expect(PrintHistory.byFile(orders) == (try theirs(js, orders)))
        #expect(PrintHistory.byFile(orders.reversed()) == (try theirs(js, orders.reversed())))
    }

    @Test("failures, voids, and rows that are not jobs")
    func failuresAndNonsense() throws {
        let js = try js()
        let orders: [JSONValue] = [
            job("F1", .string("pending"), parts: [part(.string("PF-a"))],
                extra: ["qcStatus": .string("fail"), "defects": .array([.object(["type": .string("warping")]), .null, .array([]), .object([:])])]),
            job("F2", .string("pending"), parts: [part(.string("PF-a"))], extra: ["qcFailedAt": .string("2026-09-02T00:00:00Z")]),
            job("F3", .string("pending"), parts: [part(.string("PF-a"))], extra: ["qcFailedAt": .string("2026-09-02T00:00:00Z"), "qcPassedAt": .string("x")]),
            job("F4", .string("completed"), parts: [part(.string("PF-a"))], extra: ["qcStatus": .string("pass"), "defects": .array([.object([:])])]),
            job("V", .string("completed"), parts: [part(.string("PF-a"))], extra: ["voidedAt": .string("2026-09-09T00:00:00Z")]),
            job("V0", .string("completed"), parts: [part(.string("PF-a"))], extra: ["voidedAt": .bool(false)]),
            job("", .string("completed"), parts: [part(.string("PF-b"))], extra: ["completedAt": .string("2027-01-01T00:00:00Z")]),
            job("N", .string("completed"), parts: [part(.number(7)), part(.string("")), part(.null), .null, .array([]), .string("PF-a")]),
            .null, .number(3), .string("x"), .array([]),
            .object(["status": .string("completed"), "parts": .string("PF-a")]),
            job("P", .string("completed"), parts: [part(.string("__proto__")), part(.string("constructor")), part(.string("toString"))]),
        ]
        let mine = PrintHistory.byFile(orders), theirs = try theirs(js, orders)
        #expect(mine == theirs, Comment(rawValue: "swift \(mine)\njs \(theirs)"))
        #expect(mine["PF-a"]?.timesFailed == 4)
        // F4 and V0 (a `voidedAt` of false is no void); N names it only as a bare string.
        #expect(mine["PF-a"]?.timesPrinted == 2)
    }

    @Test("merge: the larger counter, the later date")
    func merge() throws {
        let js = try js()
        let entries: [PrintHistory.Entry?] = [
            nil, PrintHistory.Entry(timesPrinted: 2, copies: 5, timesFailed: 1,
                                    lastPrinted: "2026-09-03T10:00:00.000Z", lastJobId: "J"),
            PrintHistory.Entry(timesPrinted: 0, copies: 0, timesFailed: 3, lastPrinted: nil, lastJobId: nil),
        ]
        let counts: [JSONValue?] = [nil, .number(0), .number(5), .number(2.7), .number(-1), .string("9"), .null]
        let lasts: [JSONValue?] = [nil, .string(""), .string("garbage"), .string("2026-01-01T00:00:00Z"), .string("2026-12-01"), .number(5)]
        for entry in entries {
            let e: JSONValue = try entry.map { try JSONValue.decode(JSONValue.self, from: JSONEncoder().encode($0)) } ?? .null
            for c in counts {
                for l in lasts {
                    var r: [String: JSONValue] = [:]
                    if let c { r["timesPrinted"] = c; r["timesFailed"] = c }
                    if let l { r["lastPrinted"] = l }
                    let mine = PrintHistory.merge(record: .object(r), entry: entry)
                    guard case .object(let t) = try js.value("globalThis.KhaytPrintHistory.merge(ARG0, ARG1)",
                                                              [.object(r), e]) else {
                        Issue.record("not an object"); continue
                    }
                    var last: String?
                    if case .string(let s)? = t["lastPrinted"] { last = s }
                    var n = -1, f = -1
                    if case .number(let x)? = t["timesPrinted"] { n = Int(x) }
                    if case .number(let x)? = t["timesFailed"] { f = Int(x) }
                    #expect(mine == PrintHistory.Merged(timesPrinted: n, timesFailed: f, lastPrinted: last),
                            Comment(rawValue: "\(r) + \(String(describing: entry))"))
                }
            }
        }
    }
}
