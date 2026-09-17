import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Writing down what was done to a machine.
///
/// This app could read the service log and never wrote to it. So a shop that
/// ticked a nozzle change off here left no record of it: the history the other
/// app shows was missing every service done on this Mac, and every maintenance
/// figure — the machine P&L's subtraction, the Reports chart — counted none of
/// it. The schedule was being kept and the history was not.
@MainActor
struct ServiceLogTests {

    /// ── THIS TEST HELD THE BUG IN PLACE ───────────────────────────────────
    ///
    /// It asserted `hub_maint_log_v1`, with a comment saying
    /// `renderer/app-state.js` chose the name. It had — as that app's
    /// **localStorage** key, in the legacy fallback path, which `app-state.js`
    /// translates into `machMaintLog` before anything reads it. The store file
    /// has only ever held `machMaintLog`.
    ///
    /// So the test was green, the sample book had been written to match, and
    /// on a real book every service typed in here went into a field nothing
    /// reads — while the machine P&L charged zero maintenance however much a
    /// shop had spent.
    ///
    /// A literal is now checked against the other app's SOURCE, in
    /// `StoreKeysAreTheOtherAppsTests`, because a literal and a fixture can
    /// agree with each other while both are wrong.
    @Test("the log lives under the key the other app's STORE writes it to")
    func sameCollection() {
        #expect(ServiceLogEdit.collection == "machMaintLog")
    }

    @Test("an entry carries the five fields the other app reads back")
    func shape() {
        let entry = ServiceLogEdit.entry(machineId: "m1", day: "2026-09-17",
                                         note: "  Replace nozzle  ", cost: 95, id: "MAINT-1")
        #expect(entry["id"] == .string("MAINT-1"))
        #expect(entry["machineId"] == .string("m1"))
        #expect(entry["date"] == .string("2026-09-17"))
        #expect(entry["cost"] == .number(95))
        #expect(entry["note"] == .string("Replace nozzle"), "the note kept its typing whitespace")
        #expect(entry.count == 5, "an extra field is one the other app will not know to keep")
    }

    @Test("a refund is not a negative service")
    func costIsNeverNegative() {
        // A negative row would subtract from what a machine has cost, and the
        // chart would report a printer that had paid for itself in repairs.
        #expect(ServiceLogEdit.entry(machineId: "m1", day: "2026-09-17", note: "x",
                                     cost: -40, id: "E").pointee("cost") == 0)
    }

    @Test("a new service goes to the top, where the log is read from")
    func newestFirst() {
        let had: [JSONValue] = [.object(["id": .string("old")])]
        let next = ServiceLogEdit.appending(["id": .string("new")], to: had)
        #expect(next.count == 2)
        if case .object(let first)? = next.first { #expect(first["id"] == .string("new")) }
        else { Issue.record("the log lost its shape") }
    }

    @Test("deleting one entry leaves every other row exactly as it was")
    func removeOne() {
        let log: [JSONValue] = [
            .object(["id": .string("a"), "note": .string("first")]),
            // A row written by a newer Khayt, which this build cannot read.
            // It is still the shop's record and must survive an unrelated
            // delete untouched.
            .object(["id": .string("b"), "somethingNew": .string("kept")]),
            .object(["id": .string("c")]),
        ]
        let next = ServiceLogEdit.removing("a", from: log)
        #expect(next.count == 2)
        #expect(next.contains { row in
            if case .object(let o) = row { return o["somethingNew"] == .string("kept") }
            return false
        }, "a row this build does not understand was dropped")
        #expect(ServiceLogEdit.removing("nope", from: log).count == 3,
                "deleting an id that is not there removed something else")
    }

    @Test("a machine's services come back newest first, and only its own")
    func perMachine() {
        let log: [JSONValue] = [
            .object(["id": .string("a"), "machineId": .string("m1"),
                     "date": .string("2026-02-01"), "note": .string("older"), "cost": .number(10)]),
            .object(["id": .string("b"), "machineId": .string("m2"),
                     "date": .string("2026-09-01"), "note": .string("other machine")]),
            .object(["id": .string("c"), "machineId": .string("m1"),
                     "date": .string("2026-08-01"), "note": .string("newer"), "cost": .number(20)]),
        ]
        let mine = ServiceLogEdit.entries(of: "m1", in: log)
        #expect(mine.map(\.id) == ["c", "a"])
        #expect(mine.map(\.note) == ["newer", "older"])
        #expect(mine.reduce(0) { $0 + $1.cost } == 30)
    }

    @Test("an entry with no cost typed is not an entry that cost nothing")
    func missingCostIsZeroNotAbsent() throws {
        // Ticking a task off writes the service with no figure on it, because
        // the shop is at the machine and not holding a receipt. The row reads
        // as a dash on screen rather than as a free repair.
        let entry = try #require(ServiceEntry(raw: ["id": .string("a"),
                                                   "machineId": .string("m1"),
                                                   "date": .string("2026-09-17")]))
        #expect(entry.cost == 0)
        #expect(entry.note.isEmpty)
    }

    @Test("a row with no id is not a service")
    func idIsRequired() {
        // Everything that finds an entry again — deleting it, merging it on
        // sync — goes through the id. A row without one cannot be any of that.
        #expect(ServiceEntry(raw: ["machineId": .string("m1")]) == nil)
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    /// The number under a key, for a test that only cares about one field.
    func pointee(_ key: String) -> Double? {
        if case .number(let n)? = self[key] { return n }
        return nil
    }
}

/// Setting up what a machine is due for.
///
/// This app could read a shop's recurring tasks, show what each machine was due
/// for and tick one off — and could not create one, change an interval, or
/// delete one. Those lived only in the other app's machine editor, so a shop
/// whose only app is this one saw a schedule it had no way to write, which for
/// a Mac-only shop means no schedule at all.
@MainActor
struct MaintenanceTaskTests {

    @Test("the tasks live under the key the other app writes them to")
    func sameCollection() {
        #expect(MaintenanceTaskEdit.collection == "machMaintTasks")
    }

    @Test("a task with no interval at all is refused")
    func needsAnInterval() {
        // `lib/maintenance.js` reads a task with neither clock as NEVER DUE. It
        // would sit in the list looking scheduled and never ask for anything,
        // which is worse than refusing to save it.
        #expect(MaintenanceTaskEdit.problem(name: "Replace nozzle",
                                            intervalHours: 0, intervalDays: 0) == "maint.need_interval")
        #expect(MaintenanceTaskEdit.problem(name: "  ",
                                            intervalHours: 100, intervalDays: 0) == "maint.need_name")
        // Either clock on its own is enough, and both together is allowed: a
        // nozzle wears by hours, a filter ages by days.
        #expect(MaintenanceTaskEdit.problem(name: "Nozzle", intervalHours: 100, intervalDays: 0) == nil)
        #expect(MaintenanceTaskEdit.problem(name: "Filter", intervalHours: 0, intervalDays: 30) == nil)
        #expect(MaintenanceTaskEdit.problem(name: "Both", intervalHours: 100, intervalDays: 30) == nil)
    }

    @Test("a new task is counted from now, not from the machine's whole life")
    func countedFromNow() {
        // A printer that has run 2,000 hours must not have a task created this
        // morning open as twenty times overdue.
        let task = MaintenanceTaskEdit.record(
            machineId: "m1", name: "  Replace nozzle  ", intervalHours: 100, intervalDays: 0,
            hours: 2_000, nowIso: "2026-09-17T10:00:00.000Z", id: "MTASK-1")
        #expect(task["lastDoneHours"] == .number(2_000))
        #expect(task["lastDoneAt"] == .string("2026-09-17T10:00:00.000Z"))
        #expect(task["name"] == .string("Replace nozzle"), "the name kept its typing whitespace")
        #expect(task["machineId"] == .string("m1"))
    }

    @Test("the clock a task does not use is null, not zero")
    func unusedClockIsNull() {
        // The other app writes null and these records pass between the two.
        let hourly = MaintenanceTaskEdit.record(
            machineId: "m1", name: "Nozzle", intervalHours: 100, intervalDays: 0,
            hours: 0, nowIso: "x", id: "T")
        #expect(hourly["intervalHours"] == .number(100))
        #expect(hourly["intervalDays"] == .null)
    }

    @Test("changing an interval does NOT mark the task done")
    func editingKeepsTheHistory() async throws {
        // The trap. Restamping `lastDoneHours` on an edit would quietly clear a
        // task that is overdue at this moment — a shop tightening "every 100
        // hours" to "every 80" because a nozzle failed early would find the
        // warning gone, which is the opposite of what it asked for.
        let before: [String: JSONValue] = [
            "id": .string("T"), "machineId": .string("m1"), "name": .string("Nozzle"),
            "intervalHours": .number(100), "intervalDays": .null,
            "lastDoneHours": .number(10), "lastDoneAt": .string("2026-01-01T00:00:00.000Z"),
        ]
        let after = MaintenanceTaskEdit.edited(before, name: "Nozzle", intervalHours: 80, intervalDays: 0)
        #expect(after["intervalHours"] == .number(80))
        #expect(after["lastDoneHours"] == .number(10), "the edit restamped the meter")
        #expect(after["lastDoneAt"] == .string("2026-01-01T00:00:00.000Z"), "the edit restamped the clock")

        // And the shared rule still calls it overdue afterwards, which is the
        // thing the shop actually sees.
        let engine = try KhaytEngine()
        let card = try await engine.maintenance(
            machineId: "m1", tasks: [.object(after)],
            jobs: [.object(["machineId": .string("m1"), "status": .string("completed"),
                            "printTime": .number(500)])],
            machine: .object(["id": .string("m1")]), now: Date())
        #expect(card.tasks.first?.status == "overdue",
                Comment(rawValue: "got \(card.tasks.first?.status ?? "no task")"))
    }

    @Test("deleting one task leaves the others exactly as they were")
    func removeOne() {
        let tasks: [JSONValue] = [
            .object(["id": .string("a"), "name": .string("first")]),
            // A row from a newer Khayt this build cannot read.
            .object(["id": .string("b"), "somethingNew": .string("kept")]),
        ]
        let next = MaintenanceTaskEdit.removing("a", from: tasks)
        #expect(next.count == 1)
        #expect(MaintenanceTaskEdit.removing("nope", from: tasks).count == 2)
    }
}

/// The machine card redraws when a task changes.
///
/// `maintenanceSignature` is what `.task(id:)` watches. It captured each task's
/// id and its last-done stamps — everything this app could change, while the
/// schedule itself could only be written in the other app. The moment this app
/// could rename a task or tighten an interval, a signature blind to both meant
/// the card carried on showing the old one until something unrelated moved.
@MainActor
struct MaintenanceSignatureTests {

    private func shopWith(_ tasks: [JSONValue]) async -> (Shop, Machine) {
        let shop = Shop()
        await shop.load(.sample)
        shop.setMaintTaskRowsForTesting(tasks)
        return (shop, shop.machines.first!)
    }

    @Test("renaming a task moves the signature")
    func nameMoves() async throws {
        let base: [String: JSONValue] = [
            "id": .string("T"), "machineId": .string("MACH-u1"), "name": .string("Nozzle"),
            "intervalHours": .number(100), "lastDoneHours": .number(0),
            "lastDoneAt": .string("2026-01-01T00:00:00.000Z"),
        ]
        let (shop, _) = await shopWith([.object(base)])
        let machine = try #require(shop.machines.first { $0.id == "MACH-u1" })
        let before = shop.maintenanceSignature(for: machine)
        var renamed = base
        renamed["name"] = .string("Nozzle and bed")
        shop.setMaintTaskRowsForTesting([.object(renamed)])
        #expect(shop.maintenanceSignature(for: machine) != before,
                "a renamed task leaves the card drawing the old name")
    }

    @Test("tightening an interval moves the signature")
    func intervalMoves() async throws {
        let base: [String: JSONValue] = [
            "id": .string("T"), "machineId": .string("MACH-u1"), "name": .string("Nozzle"),
            "intervalHours": .number(100), "lastDoneHours": .number(0),
            "lastDoneAt": .string("2026-01-01T00:00:00.000Z"),
        ]
        let (shop, _) = await shopWith([.object(base)])
        let machine = try #require(shop.machines.first { $0.id == "MACH-u1" })
        let before = shop.maintenanceSignature(for: machine)
        var tighter = base
        tighter["intervalHours"] = .number(80)
        shop.setMaintTaskRowsForTesting([.object(tighter)])
        #expect(shop.maintenanceSignature(for: machine) != before,
                "a tightened interval leaves the card drawing the old one")
    }

    @Test("an unchanged task holds the signature still")
    func stableWhenNothingChanged() async throws {
        // The other half: a signature that moves on every read would recompute
        // the card constantly, which is what `.task(id:)` exists to avoid.
        let task: [String: JSONValue] = [
            "id": .string("T"), "machineId": .string("MACH-u1"), "name": .string("Nozzle"),
            "intervalHours": .number(100), "lastDoneHours": .number(0),
            "lastDoneAt": .string("2026-01-01T00:00:00.000Z"),
        ]
        let (shop, _) = await shopWith([.object(task)])
        let machine = try #require(shop.machines.first { $0.id == "MACH-u1" })
        #expect(shop.maintenanceSignature(for: machine) == shop.maintenanceSignature(for: machine))
    }
}
