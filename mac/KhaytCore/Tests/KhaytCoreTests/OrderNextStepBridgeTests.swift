import Foundation
import Testing
@testable import KhaytCore

/// `lib/order-next-step.js` through the engine: the crossing the Mac and the
/// iPhone both make. The rule's own cases are `test/order-next-step.test.js`;
/// this holds the shape that comes back.
struct OrderNextStepBridgeTests {

    static func job(_ id: String, _ status: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(id), "status": .string(status),
                                      "price": .number(100), "paidAmount": .number(0)]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    @Test("every stage's step crosses the bridge as the rule gave it")
    func steps() async throws {
        let engine = try KhaytEngine()
        let book = [
            Self.job("Q", "quote"), Self.job("P", "pending"), Self.job("R", "printing"),
            Self.job("O", "post"), Self.job("C", "qc"), Self.job("D", "completed"),
            Self.job("H", "on_hold", ["statusHistory": .array([
                .object(["status": .string("printing"), "at": .string("2026-11-10T08:00:00Z")]),
                .object(["status": .string("on_hold"), "at": .string("2026-11-11T08:00:00Z")])])]),
            Self.job("V", "completed", ["deliveredAt": .string("2026-11-13T10:00:00Z")]),
            Self.job("X", "cancelled"),
        ]
        let all = try await engine.orderNextSteps(book, settings: [:], lateIds: ["R"])
        #expect(all.count == book.count)
        let want: [(String, String?, String?)] = [
            ("Q", "send_quote", nil), ("P", "start_printing", "printing"), ("R", "mark_printed", "post"),
            ("O", "send_to_check", "qc"), ("C", "mark_ready", "completed"), ("D", "hand_over", nil),
            ("H", "resume", "printing"), ("V", "record_payment", nil), ("X", nil, nil),
        ]
        for (id, code, to) in want {
            let s = try #require(all[id], "\(id)")
            #expect(s.primary?.code == code, "\(id)")
            #expect(s.primary?.to == to, "\(id)")
        }
        #expect(all["C"]?.primary?.asks == "actuals")
        #expect(all["Q"]?.secondary.map(\.code) == ["take_job"])
        #expect(all["H"]?.heldFrom == "printing" && all["H"]?.pill.tone == "purple")
        #expect(all["R"]?.late == true && all["P"]?.late == false)
        #expect(all["V"]?.owed == 100 && all["V"]?.stage == "delivered")
        #expect(all["R"]?.track.map(\.state) == ["done", "current", "todo", "todo", "todo", "todo"])
        #expect(all["R"]?.track.map(\.stage) == ["pending", "printing", "post", "qc", "completed", "delivered"])
        #expect(all["X"]?.pill.tone == "grey" && all["X"]?.secondary.isEmpty == true)
    }

    @Test("the gate's refusal and read-only arrive at the control")
    func blocked() async throws {
        let engine = try KhaytEngine()
        let paused = try await engine.orderNextSteps([Self.job("P", "pending")],
                                                     settings: ["productionPaused": .bool(true)], lateIds: [])
        #expect(paused["P"]?.primary?.blocked?.code == "production_paused")
        let ro = try await engine.orderNextSteps([Self.job("P", "pending")], settings: [:], lateIds: [], canWrite: false)
        #expect(ro["P"]?.primary?.blocked?.code == "read_only")
    }
}
