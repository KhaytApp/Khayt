import Foundation
import Testing
@testable import KhaytCore

/// Simple's four-column board, asked of `lib/order-status.js` through the
/// engine. The rule's own tests (test/order-status*.test.js) pin the cases;
/// this holds the crossing.
struct SimpleBoardBridgeTests {

    static func job(_ id: String, _ status: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "status": .string(status)]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    @Test("four columns, each stage filed where the shared rule files it")
    func filing() throws {
        let engine = try KhaytEngine()
        #expect(try engine.simpleColumns() == ["quote", "queued", "printing", "ready"])
        let cases: [(String, String, String?)] = [
            ("quote", "quote", nil), ("pending", "queued", nil), ("on_hold", "queued", "on_hold"),
            ("printing", "printing", nil), ("post", "printing", "post"), ("qc", "printing", "qc"),
            ("completed", "ready", nil),
        ]
        for (status, column, note) in cases {
            let s = try #require(try engine.simpleStage(of: Self.job("J", status)), "\(status)")
            #expect(s.column == column && s.note == note && s.stage == status, "\(status)")
        }
        // Shipped and delivered are date stamps on a completed job.
        let shipped = try #require(try engine.simpleStage(of: Self.job("J", "completed", ["shippedAt": .string("2026-11-12T10:00:00Z")])))
        #expect(shipped.column == "ready" && shipped.note == "shipped")
        #expect(try engine.simpleStage(of: Self.job("J", "cancelled")) == nil, "not on the board")
        // A job on hold says whether it had started printing.
        #expect(try engine.simpleStage(of: Self.job("J", "on_hold"))?.midPrint == false)
        #expect(try engine.simpleStage(of: Self.job("J", "on_hold", ["printingStartedAt": .string("2026-11-12T09:00:00Z")]))?.midPrint == true)
    }

    @Test("Ready is the newest first and cut; the live columns keep their order and are not cut")
    func columns() throws {
        let engine = try KhaytEngine()
        let orders = [
            Self.job("A", "completed", ["completedAt": .string("2026-11-01T00:00:00Z")]),
            Self.job("B", "pending"),
            Self.job("C", "completed", ["completedAt": .string("2026-11-10T00:00:00Z")]),
            Self.job("D", "completed", ["deliveredAt": .string("2026-11-12T00:00:00Z"), "completedAt": .string("2026-11-02T00:00:00Z")]),
            Self.job("E", "pending"),
        ]
        let ready = try engine.simpleColumn("ready", orders: orders, cap: 2)
        #expect(ready.indexes == [3, 2] && ready.more == 1, "D (delivered last) then C; A left out")
        let queued = try engine.simpleColumn("queued", orders: orders)
        #expect(queued.indexes == [1, 4] && queued.more == 0)
        #expect(try engine.simpleColumn("printing", orders: orders).indexes.isEmpty)
    }
}
