import Foundation
import Testing
@testable import KhaytCore

/// First-pass yield, against the JavaScript it came from.
///
/// The module exists because pass rate is the easy figure and the less useful
/// one — a shop that reprints until it passes has a pass rate near 100% and a
/// quality problem. A port that miscounts a reprint chain gives that shop back
/// the flattering number, which is the whole thing this was written to stop.
@MainActor
struct QcMetricsParityTests {

    private func js() throws -> JSModule { try JSModule(["qc-metrics"]) }

    private func theirs(_ js: JSModule, _ orders: [JSONValue]) throws -> QcMetrics.Metrics {
        guard case .object(let o) = try js.value(
            "globalThis.KhaytQcMetrics.qcMetrics(ARG0)", [.array(orders)]) else {
            Issue.record("not an object")
            return QcMetrics.Metrics(qcd: -1, passed: -1, failed: -1, passRate: nil, roots: -1,
                                     firstPass: -1, firstPassYield: nil, defectsByType: [:],
                                     worstDefect: nil, rmaCount: -1, rmaCost: -1)
        }
        func int(_ v: JSONValue?) -> Int { if case .number(let n)? = v { return Int(n) }; return -1 }
        func dbl(_ v: JSONValue?) -> Double? { if case .number(let n)? = v { return n }; return nil }
        var defects: [String: Int] = [:]
        if case .object(let d)? = o["defectsByType"] {
            for (k, v) in d { defects[k] = int(v) }
        }
        var worst: QcMetrics.Defect?
        if case .object(let w)? = o["worstDefect"], case .string(let t)? = w["type"] {
            worst = QcMetrics.Defect(type: t, count: int(w["count"]))
        }
        return QcMetrics.Metrics(
            qcd: int(o["qcd"]), passed: int(o["passed"]), failed: int(o["failed"]),
            passRate: dbl(o["passRate"]), roots: int(o["roots"]),
            firstPass: int(o["firstPass"]), firstPassYield: dbl(o["firstPassYield"]),
            defectsByType: defects, worstDefect: worst,
            rmaCount: int(o["rmaCount"]), rmaCost: dbl(o["rmaCost"]) ?? -1)
    }

    private func check(_ orders: [JSONValue], _ what: String, _ js: JSModule) throws {
        let mine = QcMetrics.metrics(orders)
        let theirs = try theirs(js, orders)
        #expect(mine == theirs, Comment(rawValue: "\(what)\n  swift \(mine)\n  js    \(theirs)"))
    }

    private func job(_ f: [String: JSONValue]) -> JSONValue { .object(f) }

    @Test("a real month of inspections")
    func realMonth() throws {
        let js = try js()
        try check([
            job(["id": .string("O-1"), "qcStatus": .string("pass")]),
            job(["id": .string("O-2"), "qcStatus": .string("fail"),
                 "defects": .array([.object(["type": .string("layer shift")])])]),
            job(["id": .string("O-3"), "reprintOf": .string("O-2"),
                 "reprintChain": .string("O-2"), "qcStatus": .string("pass")]),
            job(["id": .string("O-4"), "status": .string("qc")]),
            job(["id": .string("O-5"), "qcPassedAt": .string("2026-09-10T00:00:00Z")]),
        ], "a month", js)
    }

    @Test("a shop that has never inspected anything gets null, not nought")
    func nothingInspectedIsNull() throws {
        // Nought renders as "everything failed" about a shop that has simply
        // not started.
        let js = try js()
        try check([], "no orders at all", js)
        try check([job(["id": .string("O-1")]), job(["id": .string("O-2"), "status": .string("qc")])],
                  "nothing inspected", js)
        #expect(QcMetrics.metrics([]).passRate == nil)
        #expect(QcMetrics.metrics([]).firstPassYield == nil)
    }

    @Test("a reprint chain is one job, however many times it was reprinted")
    func chainsCollapse() throws {
        let js = try js()
        try check([
            job(["id": .string("A"), "qcStatus": .string("fail")]),
            job(["id": .string("A2"), "reprintOf": .string("A"), "reprintChain": .string("A"),
                 "qcStatus": .string("fail")]),
            job(["id": .string("A3"), "reprintOf": .string("A2"), "reprintChain": .string("A"),
                 "qcStatus": .string("fail")]),
            job(["id": .string("A4"), "reprintOf": .string("A3"), "reprintChain": .string("A"),
                 "qcStatus": .string("pass")]),
        ], "one job reprinted three times", js)
        // Said outright: one root, and nothing passed first time.
        let m = QcMetrics.metrics([
            job(["id": .string("A"), "qcStatus": .string("fail")]),
            job(["id": .string("A4"), "reprintOf": .string("A"), "reprintChain": .string("A"),
                 "qcStatus": .string("pass")]),
        ])
        #expect(m.roots == 1)
        #expect(m.firstPass == 0, "a reprint was counted as a first-time pass")
        #expect(m.firstPassYield == 0)
    }

    @Test("a chain named with a number is not the chain named with that digit")
    func chainKeysKeepTheirType() throws {
        // The keys go into a `Set`, which compares by value AND type.
        let js = try js()
        try check([
            job(["id": .string("A"), "reprintChain": .number(7), "qcStatus": .string("pass")]),
            job(["id": .string("B"), "reprintChain": .string("7"), "qcStatus": .string("pass")]),
            job(["id": .number(7), "qcStatus": .string("pass")]),
            job(["id": .string("7"), "qcStatus": .string("fail")]),
        ], "numeric and string chain keys", js)
    }

    @Test("the worst defect obeys JavaScript's key order, not insertion order")
    func worstDefectKeyOrder() throws {
        // An object lists its ARRAY-INDEX-LIKE keys first, ascending, and only
        // then the rest in insertion order — so a defect type named "2" is
        // enumerated before "layer shift" however late it was added. With a
        // stable sort that decides ties.
        let js = try js()
        func withDefects(_ types: [String]) -> [JSONValue] {
            [job(["id": .string("O-1"), "qcStatus": .string("fail"),
                  "defects": .array(types.map { .object(["type": .string($0)]) })])]
        }
        try check(withDefects(["layer shift", "2"]), "a tie with a numeric name", js)
        try check(withDefects(["layer shift", "2", "10", "1"]), "several numeric names", js)
        try check(withDefects(["01", "1", "0", "007"]), "leading zeros are not indices", js)
        try check(withDefects(["warping", "warping", "stringing"]), "a clear winner", js)
        try check(withDefects(["a", "b", "a", "b"]), "a tie between two words", js)
        try check(withDefects(["4294967295", "4294967294", "x"]), "the index boundary", js)
        try check(withDefects([]), "no defects", js)
    }

    @Test("a defect with no type falls into the same bucket the editor uses")
    func untypedDefects() throws {
        let js = try js()
        try check([job(["id": .string("O-1"), "qcStatus": .string("fail"), "defects": .array([
            .object([:]), .object(["type": .null]), .object(["type": .string("")]),
            .object(["type": .string("other")]), .object(["type": .number(0)]),
            .object(["type": .bool(false)]), .object(["type": .number(3)]),
            .null, .string("x"), .number(1),
        ])])], "odd defects", js)
    }

    @Test("defects that are not a list are no defects")
    func oddDefectFields() throws {
        let js = try js()
        for value in [JSONValue.null, .string("layer shift"), .object([:]), .number(3), .bool(true)] {
            try check([job(["id": .string("O-1"), "qcStatus": .string("fail"), "defects": value])],
                      "defects = \(value)", js)
        }
    }

    @Test("a status nobody recognises is neither a pass nor a fail")
    func unknownStatuses() throws {
        let js = try js()
        for value in [JSONValue.string("passed"), .string("PASS"), .string("pending"),
                      .string(" pass"), .string(""), .null, .bool(true), .bool(false),
                      .number(0), .number(1), .array([]), .object([:])] {
            try check([job(["id": .string("O-1"), "qcStatus": value]),
                       job(["id": .string("O-2"), "qcStatus": .string("pass")])],
                      "qcStatus \(value)", js)
        }
    }

    @Test("the fields are read in order: status, then stamps, then the stage")
    func fieldPrecedence() throws {
        let js = try js()
        try check([
            job(["id": .string("A"), "qcStatus": .string("fail"),
                 "qcPassedAt": .string("2026-09-01"), "status": .string("qc")]),
            job(["id": .string("B"), "qcPassedAt": .string("2026-09-01"),
                 "qcFailedAt": .string("2026-09-02")]),
            job(["id": .string("C"), "qcFailedAt": .string("2026-09-02"), "status": .string("qc")]),
            job(["id": .string("D"), "status": .string("qc")]),
            job(["id": .string("E"), "qcPassedAt": .string(""), "status": .string("qc")]),
        ], "every precedence pair", js)
    }

    @Test("warranty cost is what the shop ate, and only for an rma reprint")
    func rmaCost() throws {
        let js = try js()
        try check([
            job(["id": .string("A"), "rma": .bool(true), "reprintReason": .string("rma"),
                 "costBasis": .number(231.31)]),
            job(["id": .string("B"), "reprintReason": .string("rma"), "costBasis": .number(18.005)]),
            job(["id": .string("C"), "reprintReason": .string("customer"), "costBasis": .number(999)]),
            job(["id": .string("D"), "rma": .bool(false), "reprintReason": .string("rma")]),
            job(["id": .string("E"), "rma": .string("yes"), "reprintReason": .string("RMA"),
                 "costBasis": .number(50)]),
        ], "warranty jobs", js)
    }

    @Test("a cost that is not a number")
    func oddCosts() throws {
        let js = try js()
        // `greatestFiniteMagnitude` is left out and tested on its own below:
        // both sides compute the same answer and only the BRIDGE loses it.
        let awkward = Awkward.numbers.filter(\.isFinite)
            .filter { $0 < 1e300 }.map { JSONValue.number($0) }
        for value in Awkward.notNumbers + awkward {
            try check([job(["id": .string("A"), "reprintReason": .string("rma"),
                            "costBasis": value])], "costBasis \(value)", js)
        }
    }

    /// ── WHERE THE BRIDGE LOSES AN ANSWER THE TWO RULES AGREE ON ───────────
    ///
    /// A `costBasis` near `Double`'s ceiling makes `Math.round(v * 100)`
    /// overflow, so BOTH sides compute `Infinity` — the rules agree exactly.
    /// **JSON cannot carry it**, so `JSON.stringify` writes `null`, and
    /// `KhaytEngine.QcMetrics.rmaCost` is a non-optional `Double`: the decode
    /// fails and the whole QC panel is lost rather than one figure.
    ///
    /// Running natively there is no bridge, so the figure survives. That is
    /// not a divergence in the rule; it is one fewer place the rule's answer
    /// can be dropped on the way to the screen.
    @Test("a cost past Double's ceiling survives natively, where the bridge dropped it")
    func infinityCrossesTheBridgeAsNull() throws {
        let js = try js()
        let book = [job(["id": .string("A"), "reprintReason": .string("rma"),
                         "costBasis": .number(.greatestFiniteMagnitude)])]
        #expect(QcMetrics.metrics(book).rmaCost.isInfinite,
                "the rule's own arithmetic overflows here")
        // And the JavaScript agrees, until JSON gets hold of it.
        guard case .object(let o) = try js.value(
            "globalThis.KhaytQcMetrics.qcMetrics(ARG0)", [.array(book)]) else {
            Issue.record("no answer"); return
        }
        #expect(o["rmaCost"] == .null,
                "JSON no longer drops it — this note can go")
        guard case .bool(true) = try js.value(
            "globalThis.KhaytQcMetrics.qcMetrics(ARG0).rmaCost === Infinity", [.array(book)])
        else { Issue.record("the two rules no longer agree"); return }
    }

    @Test("rows that are not orders")
    func degenerateRows() throws {
        let js = try js()
        try check([.null, .bool(false), .number(0), .string("")], "every falsy row", js)
        try check([.string("x"), .number(3), .array([]), .bool(true)], "truthy non-objects", js)
        try check([.null, job(["id": .string("A"), "qcStatus": .string("pass")]), .string("x")],
                  "a mix", js)
    }
}
