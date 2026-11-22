import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Maintenance crossing into the engine and back.
///
/// The rule is `lib/maintenance.js` and `test/maintenance.test.js` pins the
/// arithmetic. These are about the CROSSING: that the shape decodes, that the
/// hour meter counts the same jobs on this side as it does in the renderer,
/// and that the two figures a shop acts on — which task is due, and how far
/// past due it is — survive the trip.
@MainActor
struct MaintenanceTests {

    static let now = Date(timeIntervalSince1970: 1_788_000_000)

    static func job(_ id: String, machine: String, hours: Double,
                    status: String = "completed") -> JSONValue {
        .object([
            "id": .string(id), "machineId": .string(machine),
            "printTime": .number(hours), "status": .string(status),
        ])
    }

    static func task(_ id: String, machine: String, name: String,
                     everyHours: Double? = nil, everyDays: Double? = nil,
                     lastDoneHours: Double = 0, lastDoneAt: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "machineId": .string(machine), "name": .string(name),
            "lastDoneHours": .number(lastDoneHours),
        ]
        if let everyHours { o["intervalHours"] = .number(everyHours) }
        if let everyDays { o["intervalDays"] = .number(everyDays) }
        if let lastDoneAt { o["lastDoneAt"] = .string(lastDoneAt) }
        return .object(o)
    }

    static func card(tasks: [JSONValue], jobs: [JSONValue],
                     machineId: String = "M1") async throws -> KhaytEngine.MaintenanceCard {
        try await KhaytEngine().maintenance(
            machineId: machineId, tasks: tasks, jobs: jobs,
            machine: .object(["id": .string(machineId)]), now: Self.now)
    }

    @Test("the card decodes, and the meter counts completed jobs only")
    func meter() async throws {
        let c = try await Self.card(
            tasks: [Self.task("T1", machine: "M1", name: "Replace nozzle", everyHours: 100)],
            jobs: [
                Self.job("J1", machine: "M1", hours: 30),
                // Cancelled: it used some hours in reality, but the log has no
                // honest figure for how many, and counting its full estimate
                // would bring services forward on the machines that fail most.
                Self.job("J2", machine: "M1", hours: 40, status: "cancelled"),
                // A different machine's hours are not this machine's.
                Self.job("J3", machine: "M2", hours: 50),
            ])
        #expect(c.hours == 30)
        #expect(c.tasks.count == 1)
        #expect(c.tasks[0].name == "Replace nozzle")
        #expect(c.tasks[0].status == "ok")
    }

    @Test("only this machine's tasks come back")
    func mine() async throws {
        let c = try await Self.card(
            tasks: [
                Self.task("T1", machine: "M1", name: "Mine", everyHours: 100),
                Self.task("T2", machine: "M2", name: "Someone else's", everyHours: 100),
            ],
            jobs: [])
        #expect(c.tasks.map(\.id) == ["T1"])
    }

    @Test("the four statuses arrive as the shared rule names them")
    func statuses() async throws {
        // One machine, one meter, four tasks whose last completion puts each of
        // them at a different point in the same 100-hour interval.
        let jobs = [Self.job("J1", machine: "M1", hours: 100)]
        let c = try await Self.card(
            tasks: [
                Self.task("ok", machine: "M1", name: "ok", everyHours: 100, lastDoneHours: 50),
                Self.task("warn", machine: "M1", name: "warn", everyHours: 100, lastDoneHours: 10),
                Self.task("due", machine: "M1", name: "due", everyHours: 100, lastDoneHours: 0),
                Self.task("over", machine: "M1", name: "over", everyHours: 50, lastDoneHours: 0),
            ],
            jobs: jobs)
        let by = Dictionary(uniqueKeysWithValues: c.tasks.map { ($0.id, $0.status) })
        #expect(by["ok"] == "ok")            // 50 of 100
        #expect(by["warn"] == "warning")     // 90 of 100, the 0.9 threshold
        #expect(by["due"] == "due")          // 100 of 100
        #expect(by["over"] == "overdue")     // 100 of 50, past 1.5x
    }

    @Test("how far past due survives the crossing, not just that it is due")
    func fraction() async throws {
        // A shop with three overdue machines needs to know which is worst; a
        // status alone cannot say, and rounding it to a bool here would lose
        // the only figure that ranks them.
        let c = try await Self.card(
            tasks: [Self.task("T1", machine: "M1", name: "Belts", everyHours: 40)],
            jobs: [Self.job("J1", machine: "M1", hours: 100)])
        #expect(c.tasks[0].status == "overdue")
        // 100 hours run against a 40-hour interval: 60 hours PAST due, which
        // the rule reports as a negative remainder rather than clamping to 0.
        #expect(c.tasks[0].hoursRemaining == -60)
        #expect(c.tasks[0].intervalHours == 40)
        // The date clock does not drive this task, so it is nil — which is a
        // different thing from "0 days remaining".
        #expect(c.tasks[0].daysRemaining == nil)
        #expect(c.tasks[0].intervalDays == nil)
    }

    @Test("a date-driven task is measured on the calendar, not the meter")
    func byDate() async throws {
        // 30 days before `now`, on a 30-day interval: exactly due, and the
        // machine having run no hours at all must not make it look fine.
        let iso = ISO8601DateFormatter()
        let thirtyDaysAgo = iso.string(from: Self.now.addingTimeInterval(-30 * 86_400))
        let c = try await Self.card(
            tasks: [Self.task("T1", machine: "M1", name: "Lubricate",
                              everyDays: 30, lastDoneAt: thirtyDaysAgo)],
            jobs: [])
        #expect(c.hours == 0)
        #expect(c.tasks[0].status == "due")
        #expect(c.tasks[0].intervalDays == 30)
        #expect(c.tasks[0].intervalHours == nil)
        #expect(c.tasks[0].hoursRemaining == nil)
        if let days = c.tasks[0].daysRemaining { #expect(abs(days) < 0.01) }
    }

    @Test("nothing recorded is an answer, not a throw")
    func empty() async throws {
        let c = try await Self.card(tasks: [], jobs: [])
        #expect(c.hours == 0)
        #expect(c.tasks.isEmpty)
    }

    @Test("marking a task done hands back the fields the other app reads")
    func markDone() async throws {
        let patch = try await KhaytEngine().markMaintenanceDone(
            task: Self.task("T1", machine: "M1", name: "Belts", everyHours: 40),
            hours: 100, at: Self.now)
        // The patch is the shared rule's, not one assembled in Swift: the
        // Electron app reads these same records back.
        #expect(patch["lastDoneHours"] == .number(100))
        if case .string(let at)? = patch["lastDoneAt"] {
            #expect(!at.isEmpty)
        } else {
            Issue.record("lastDoneAt is missing from the completion patch")
        }
    }

    @Test("a task done at the meter's current reading is no longer due")
    func doneClearsIt() async throws {
        let jobs = [Self.job("J1", machine: "M1", hours: 100)]
        let before = try await Self.card(
            tasks: [Self.task("T1", machine: "M1", name: "Belts", everyHours: 40)], jobs: jobs)
        #expect(before.status(of: "T1") == "overdue")

        let patch = try await KhaytEngine().markMaintenanceDone(
            task: Self.task("T1", machine: "M1", name: "Belts", everyHours: 40),
            hours: before.hours, at: Self.now)
        var done: [String: JSONValue] = [
            "id": .string("T1"), "machineId": .string("M1"),
            "name": .string("Belts"), "intervalHours": .number(40),
        ]
        for (k, v) in patch { done[k] = v }

        let after = try await Self.card(tasks: [.object(done)], jobs: jobs)
        #expect(after.status(of: "T1") == "ok")
    }
}

private extension KhaytEngine.MaintenanceCard {
    func status(of id: String) -> String? { tasks.first { $0.id == id }?.status }
}
