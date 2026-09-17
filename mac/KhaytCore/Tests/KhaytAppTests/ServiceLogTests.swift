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

    @Test("the log lives under the key the other app writes it to")
    func sameCollection() {
        // Not free to differ. `renderer/app-state.js` chose this name, and a
        // second spelling is a second log neither app can see all of.
        #expect(ServiceLogEdit.collection == "hub_maint_log_v1")
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
