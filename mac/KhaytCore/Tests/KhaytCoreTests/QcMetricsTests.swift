import Foundation
import Testing
@testable import KhaytCore

/// Quality, through the engine.
///
/// `test/qc-metrics.test.js` pins the rules. What matters here is that the
/// distinction survives: a shop that reprints until it passes has a pass rate
/// near 100% and a quality problem, and first-pass yield is what says so.
@Suite struct QcMetricsTests {

    static func order(_ id: String, qc: String? = nil, status: String = "completed",
                      reprintOf: String? = nil, chain: String? = nil,
                      defects: [String] = [], rma: Bool = false,
                      reprintReason: String? = nil, costBasis: Double? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "status": .string(status)]
        if let qc { o["qcStatus"] = .string(qc) }
        if let reprintOf { o["reprintOf"] = .string(reprintOf) }
        if let chain { o["reprintChain"] = .string(chain) }
        if !defects.isEmpty {
            o["defects"] = .array(defects.map { .object(["type": .string($0)]) })
        }
        if rma { o["rma"] = .object(["openedAt": .string("2026-09-01")]) }
        if let reprintReason { o["reprintReason"] = .string(reprintReason) }
        if let costBasis { o["costBasis"] = .number(costBasis) }
        return .object(o)
    }

    /// THE CORRECTION. Nought renders as "everything failed" about a shop that
    /// has simply not started.
    @Test("a shop that has inspected nothing has no rate, not a rate of nought")
    func nothingInspectedIsNotZero() async throws {
        let engine = try KhaytEngine()
        let m = try await engine.qcMetrics(orders: [Self.order("a", status: "printing")])
        #expect(m.passRate == nil)
        #expect(m.firstPassYield == nil)
        #expect(m.qcd == 0)
    }

    @Test("only inspected work is in the rate; pending and un-inspected are not")
    func onlyInspectedCounts() async throws {
        let engine = try KhaytEngine()
        let m = try await engine.qcMetrics(orders: [
            Self.order("a", qc: "pass"),
            Self.order("b", qc: "fail"),
            Self.order("c", status: "qc"),
            Self.order("d", status: "printing"),
        ])
        #expect(m.qcd == 2)
        #expect(m.passRate == 0.5)
    }

    /// The distinction the card exists for.
    @Test("a reprint chain is one job, so reprinting until it passes shows")
    func yieldSeesTheReprints() async throws {
        let engine = try KhaytEngine()
        let m = try await engine.qcMetrics(orders: [
            Self.order("a", qc: "fail"),
            Self.order("b", qc: "pass", reprintOf: "a", chain: "a"),
            Self.order("c", qc: "pass"),
        ])
        #expect(m.passRate == 2.0 / 3.0)
        #expect(m.roots == 2)
        #expect(m.firstPassYield == 0.5)
    }

    @Test("defects are counted by kind and the commonest is named")
    func defectsAreNamed() async throws {
        let engine = try KhaytEngine()
        let m = try await engine.qcMetrics(orders: [
            Self.order("a", qc: "fail", defects: ["layer_shift", "warping"]),
            Self.order("b", qc: "fail", defects: ["layer_shift"]),
        ])
        #expect(m.defectsByType["layer_shift"] == 2)
        #expect(m.worstDefect?.type == "layer_shift")
    }

    @Test("warranty work is counted at what the reprint cost the shop")
    func warrantyIsCosted() async throws {
        let engine = try KhaytEngine()
        let m = try await engine.qcMetrics(orders: [
            Self.order("a", rma: true),
            Self.order("b", reprintReason: "rma", costBasis: 120.456),
        ])
        #expect(m.rmaCount == 1)
        #expect(m.rmaCost == 120.46)
    }

    /// A screen can only have been reviewed against data that reaches it.
    @Test("the sample shop reaches this card, with the two rates differing")
    func theSampleReachesIt() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Resources/sample-shop.json")
        let root = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        guard case .object(let book) = root, case .array(let orders)? = book["printLog"] else {
            Issue.record("could not read the sample shop"); return
        }
        let engine = try KhaytEngine()
        let m = try await engine.qcMetrics(orders: orders)
        #expect(m.qcd > 0, "nothing is inspected, so only the empty state is drawn")
        #expect(m.failed > 0, "everything passes, so the card is half reviewed")
        let pass = try #require(m.passRate)
        let yield = try #require(m.firstPassYield)
        #expect(yield < pass, "the two rates agree, so the gap that is the point is undrawn")
        #expect(m.rmaCount > 0, "no warranty line is drawn")
    }
}
