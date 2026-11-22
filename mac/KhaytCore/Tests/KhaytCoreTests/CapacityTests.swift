import Foundation
import Testing
@testable import KhaytCore

/// Whether the shop can take another job, through the engine.
///
/// `test/capacity.test.js` pins the rules. What matters here is that the
/// correction survives the trip — a machine booked three weeks over must not
/// come back as "100%", which is what the rule this replaces reported.
@Suite struct CapacityTests {

    static let machines: [JSONValue] = [
        .object(["id": .string("m1"), "name": .string("U1"),
                 "targetHoursPerDay": .number(12)]),
        .object(["id": .string("m2"), "name": .string("Prusa"),
                 "targetHoursPerDay": .number(8)]),
    ]

    static func job(_ machine: String?, _ status: String, hours: Double,
                    voided: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(status + "\(hours)"), "status": .string(status),
            "printTime": .number(hours),
        ]
        if let machine { o["machineId"] = .string(machine) }
        if voided { o["voidedAt"] = .string("2026-09-01") }
        return .object(o)
    }

    static func run(_ engine: KhaytEngine, _ orders: [JSONValue],
                    days: Int = 7) async throws -> KhaytEngine.Capacity {
        try await engine.capacity(machines: machines, orders: orders,
                                  days: days, unassigned: "Unassigned")
    }

    /// THE CORRECTION. "Full" means take no more today; "300%" means the shop
    /// is three weeks behind and somebody has to be told.
    @Test("a machine booked three weeks over does not report as merely full")
    func overbookedIsNotFull() async throws {
        let engine = try KhaytEngine()
        let full = try await Self.run(engine, [Self.job("m1", "printing", hours: 84)])
        let over = try await Self.run(engine, [Self.job("m1", "printing", hours: 252)])
        #expect(full.rows.first { $0.machineId == "m1" }?.loadPct == 100)
        #expect(full.rows.first { $0.machineId == "m1" }?.overbooked == false)
        #expect(over.rows.first { $0.machineId == "m1" }?.loadPct == 300)
        #expect(over.rows.first { $0.machineId == "m1" }?.overbooked == true)
    }

    /// A percentage is a fact; a date is a decision.
    @Test("the queue says when it clears")
    func itSaysWhenItClears() async throws {
        let engine = try KhaytEngine()
        let report = try await Self.run(engine, [Self.job("m1", "printing", hours: 60)])
        #expect(report.rows.first { $0.machineId == "m1" }?.daysToClear == 5)
        #expect(report.totals.daysToClear == 3)
    }

    @Test("a voided order does not book a machine, and neither does a quote")
    func onlyAgreedWorkBooks() async throws {
        let engine = try KhaytEngine()
        let report = try await Self.run(engine, [
            Self.job("m1", "pending", hours: 12),
            Self.job("m1", "pending", hours: 99, voided: true),
            Self.job("m1", "quote", hours: 50),
            Self.job("m1", "completed", hours: 50),
        ])
        #expect(report.rows.first { $0.machineId == "m1" }?.bookedHours == 12)
        #expect(report.rows.first { $0.machineId == "m1" }?.jobs == 1)
    }

    /// Dropping it is how a queue grows behind a panel reading 40%.
    @Test("work that names no machine is still work, and is held apart")
    func unassignedWorkIsVisible() async throws {
        let engine = try KhaytEngine()
        let report = try await Self.run(engine, [
            Self.job("m1", "pending", hours: 12),
            Self.job(nil, "pending", hours: 30),
        ])
        #expect(report.rows.first { $0.machineId == "__none__" }?.bookedHours == 30)
        #expect(report.totals.untargeted == 30)
        #expect(report.totals.bookedHours == 42)
        // Not folded into the load — it is a percentage of nothing. Doubles,
        // not integer literals: `12 / 140 * 100` in Swift is 0.
        #expect(report.totals.loadPct == 12.0 / 140.0 * 100.0)
    }

    @Test("an idle machine with a target is still an answer")
    func idleIsAnAnswer() async throws {
        let engine = try KhaytEngine()
        let report = try await Self.run(engine, [])
        #expect(report.rows.count == 2)
        #expect(report.rows.first { $0.machineId == "m1" }?.loadPct == 0)
        #expect(report.totals.noTargets == false)
    }

    @Test("no machine has a target at all, which is a thing to say")
    func noTargetsIsSaid() async throws {
        let engine = try KhaytEngine()
        let report = try await engine.capacity(
            machines: [.object(["id": .string("m3"), "name": .string("Old one")])],
            orders: [Self.job("m3", "pending", hours: 40)],
            days: 7, unassigned: "Unassigned")
        #expect(report.totals.noTargets == true)
        #expect(report.totals.loadPct == nil)
        #expect(report.totals.bookedHours == 40)
    }
}
