import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Care plans, "Not needed" and the parts buy list crossing into the engine
/// and back. The arithmetic is `test/care-plans.test.js` and
/// `test/maintenance-defer.test.js`; these are about the crossing and words.
@MainActor
struct CarePlanTests {

    static let now = Date(timeIntervalSince1970: 1_788_000_000)

    @Test("the catalogue decodes, and every task and part has Mac words")
    func catalogueIsNamed() async throws {
        let engine = try KhaytEngine()
        let plans = try await engine.carePlans()
        #expect(plans.contains { $0.id == "snapmaker-u1" })
        #expect(plans.allSatisfy { $0.source == "starter" || $0.source.hasPrefix("https://") })
        for plan in plans {
            for task in plan.tasks {
                #expect(Words.own["mac.mt_t_" + task.id] != nil, "mac.mt_t_\(task.id) has no words")
            }
        }
        for part in try await engine.careParts() {
            #expect(Words.own["mac.cp_part_" + part.id] != nil, "mac.cp_part_\(part.id) has no words")
        }
    }

    @Test("a machine record is matched to its plan")
    func match() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.matchCarePlan(vendor: "Bambu Lab", model: "A1 mini", name: nil) == "bambu-a1-mini")
        #expect(try await engine.matchCarePlan(vendor: nil, model: nil, name: "Bench printer") == nil)
    }

    @Test("applying keeps the other app's field names and adds optional ones")
    func applyShape() async throws {
        let engine = try KhaytEngine()
        let existing: JSONValue = .object([
            "id": .string("MTASK-1"), "machineId": .string("M1"), "name": .string("Fans"),
            "intervalHours": .number(300), "intervalDays": .number(90),
            "lastDoneHours": .number(5), "lastDoneAt": .string("2026-08-01T00:00:00.000Z"),
        ])
        let compared = try await engine.compareCarePlan(tasks: [existing], machineId: "M1",
                                                        planId: "bambu-p1", names: ["fans": "Fans"])
        #expect(compared.differ.map(\.recordId) == ["MTASK-1"])
        let out = try await engine.applyCarePlan(
            tasks: [existing], machineId: "M1", planId: "bambu-p1", names: ["fans": "Fans", "rods": "Rods"],
            ids: ["rods": "MTASK-R"], confirm: [], meter: 12, at: Self.now)
        #expect(out.changed == ["MTASK-1"])
        guard case .object(let fans)? = out.tasks.first,
              case .object(let rods)? = out.tasks.first(where: {
                  if case .object(let o) = $0 { return o["id"] == .string("MTASK-R") }; return false
              }) else { Issue.record("rows missing"); return }
        #expect(fans["intervalHours"] == .number(300), "not confirmed, so the shop's interval stays")
        #expect(fans["careTaskId"] == .string("fans"))
        for key in ["id", "machineId", "name", "intervalHours", "intervalDays", "lastDoneHours", "lastDoneAt"] {
            #expect(rods[key] != nil, "a new task lacks \(key)")
        }
        #expect(rods["intervalHours"] == .null)
        #expect(rods["lastDoneHours"] == .number(12))
    }

    @Test("Not needed pushes a task out without the fields markDone writes")
    func deferCrossing() async throws {
        let engine = try KhaytEngine()
        let task: JSONValue = .object([
            "id": .string("T"), "machineId": .string("M1"), "name": .string("Nozzle"),
            "intervalHours": .number(100), "lastDoneHours": .number(0),
            "lastDoneAt": .string("2026-01-01T00:00:00.000Z"),
        ])
        let patch = try await engine.deferMaintenance(task: task, hours: 120, at: Self.now)
        #expect(patch["lastDoneHours"] == nil && patch["lastDoneAt"] == nil)
        #expect(patch["deferUntilHours"] == .number(170))
        guard case .object(var merged) = task else { return }
        for (k, v) in patch { merged[k] = v }
        let card = try await engine.maintenance(
            machineId: "M1", tasks: [.object(merged)],
            jobs: [.object(["machineId": .string("M1"), "status": .string("completed"), "printTime": .number(120)])],
            machine: .object(["id": .string("M1")]), now: Self.now)
        #expect(card.tasks.first?.status == "ok")
        #expect(card.tasks.first?.deferred == true)
        #expect(card.tasks.first?.hoursRemaining == 50)
    }

    @Test("the buy list decodes, earliest order-by first")
    func buyList() async throws {
        let engine = try KhaytEngine()
        let day = 86_400.0
        let iso = ISO8601DateFormatter()
        let tasks: [JSONValue] = [
            .object(["id": .string("A"), "machineId": .string("M1"), "name": .string("Screws"),
                     "careTaskId": .string("leadscrew"), "carePlanId": .string("bambu-p1"),
                     "intervalDays": .number(90),
                     "lastDoneAt": .string(iso.string(from: Self.now.addingTimeInterval(-85 * day)))]),
            .object(["id": .string("B"), "machineId": .string("M1"), "name": .string("Filter"),
                     "parts": .array([.object(["id": .string("carbon_filter"), "qty": .number(1)])]),
                     "intervalDays": .number(90),
                     "lastDoneAt": .string(iso.string(from: Self.now.addingTimeInterval(-60 * day)))]),
        ]
        let rows = try await engine.partsBuyList(
            machines: [.object(["id": .string("M1"), "name": .string("P1S")])],
            tasks: tasks, jobs: [], now: Self.now)
        #expect(rows.map(\.partId) == ["grease", "carbon_filter"])
        #expect(rows.first?.late == true)
        #expect(rows.first?.machineName == "P1S")
    }
}
