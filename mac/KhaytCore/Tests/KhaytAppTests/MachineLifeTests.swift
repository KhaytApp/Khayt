import Foundation
import Testing
import SwiftUI
import KhaytCore
@testable import KhaytApp

/// A printer under service, retired, or deleted — the owner's "how do I delete
/// a printer? how do I mark it as under service or dumped?".
///
/// The rule is `lib/machine-status.js`; what is pinned here is what this app
/// puts around it: the wrappers, the writes (against a temp book, never a
/// shop's), which screens leave a retired printer out, and the words.
@MainActor
struct MachineLifeTests {

    // MARK: - Fixtures

    static func record(_ id: String, _ extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var m: [String: JSONValue] = [
            "id": .string(id), "name": .string("Printer \(id)"),
            "printerApi": .object(["type": .string("moonraker"), "host": .string("192.168.1.20"),
                                   "port": .number(7125)]),
        ]
        for (k, v) in extra { m[k] = v }
        return m
    }

    static func machine(_ row: [String: JSONValue]) throws -> Machine {
        try JSONDecoder().decode(Machine.self, from: JSONEncoder().encode(JSONValue.object(row)))
    }

    static let active = record("M-A")
    static let service = record("M-S", ["isOffline": .bool(true), "offlineReason": .string("Hotend on order"),
                                        "offlineSince": .string("2026-10-12")])
    static let retired = record("M-R", ["status": .string("retired"), "retiredAt": .string("2026-09-03"),
                                        "retiredReason": .string("Sold")])

    /// A book: one job queued and one finished on M-A, one service entry on
    /// M-A, nothing at all naming M-N.
    static func book() -> [String: JSONValue] {
        [
            "machines": .array([.object(active), .object(service), .object(retired), .object(record("M-N"))]),
            "printLog": .array([
                .object(["id": .string("J-1"), "project": .string("Queued"), "status": .string("printing"),
                         "machineId": .string("M-A")]),
                .object(["id": .string("J-2"), "project": .string("Done"), "status": .string("completed"),
                         "machineId": .string("M-A")]),
                .object(["id": .string("J-3"), "project": .string("Waiting"), "status": .string("pending"),
                         "machineId": .string("M-A")]),
            ]),
            "machMaintLog": .array([.object(["id": .string("S-1"), "machineId": .string("M-A"),
                                             "date": .string("2026-10-01")])]),
            "settings": .object([:]),
        ]
    }

    static func tempStore(_ root: [String: JSONValue]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-machine-life-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "khayt-store.json")
        try JSONEncoder().encode(root).write(to: url)
        return url
    }

    static func read(_ url: URL) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
    }

    static func row(_ root: [String: JSONValue], _ collection: String, _ id: String) -> [String: JSONValue]? {
        guard case .object(let o)? = Shop.rows(root, collection).first(where: { Shop.recordId($0) == id })
        else { return nil }
        return o
    }

    // MARK: - The wrappers

    @Test("the engine wrappers speak machine-status.js")
    func wrappers() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.machineState(.object(Self.active)) == "active")
        #expect(try await engine.machineState(.object(Self.service)) == "service")
        #expect(try await engine.machineState(.object(Self.retired)) == "retired")

        let on = try await engine.setUnderService(.object(Self.active), on: true, reason: "Belt", since: "2026-10-18")
        guard case .object(let o) = on else { Issue.record("not a record"); return }
        #expect(o["isOffline"] == .bool(true))
        #expect(o["offlineReason"] == .string("Belt"))
        #expect(o["offlineSince"] == .string("2026-10-18"))
        let off = try await engine.setUnderService(on, on: false, reason: nil, since: nil)
        guard case .object(let back) = off else { Issue.record("not a record"); return }
        #expect(back["isOffline"] == .bool(false))
        #expect(back["offlineReason"] == nil)

        let book = Self.book()
        let verdict = try await engine.machineCanDelete(book: book, id: "M-A")
        #expect(!verdict.ok)
        #expect(verdict.reason == "has_history")
        #expect(verdict.by["printLog"] == 3)
        #expect(verdict.by["machMaintLog"] == 1)
        #expect(try await engine.machineCanDelete(book: book, id: "M-N").ok)
        #expect(try await engine.machineCanDelete(book: book, id: "nope").reason == "missing")
        let all = try await engine.machineDeleteVerdicts(book: book, ids: ["M-A", "M-N"])
        #expect(all["M-A"]?.ok == false && all["M-N"]?.ok == true)

        let refused = try await engine.removeMachine(book: book, id: "M-A")
        #expect(!refused.ok && refused.removed == nil && refused.machines.count == 4)
        let removed = try await engine.removeMachine(book: book, id: "M-N")
        #expect(removed.ok && removed.index == 3 && removed.machines.count == 3)

        let out = try await engine.retireMachine(machines: Shop.rows(book, "machines"),
                                                 printLog: Shop.rows(book, "printLog"),
                                                 id: "M-A", at: "2026-10-18", reason: "Sold")
        #expect(out.ok)
        #expect(Set(out.unassigned) == ["J-1", "J-3"], "the finished job keeps its printer")
        guard case .object(let gone)? = out.machine else { Issue.record("no machine"); return }
        #expect(gone["status"] == .string("retired") && gone["retiredAt"] == .string("2026-10-18"))
        let returned = try await engine.unretireMachine(.object(gone))
        guard case .object(let r) = returned else { Issue.record("not a record"); return }
        #expect(r["status"] == nil && r["retiredAt"] == nil && r["retiredReason"] == nil)
    }

    @Test("the Machine model reads the states as the rule does, and leniently")
    func model() async throws {
        let engine = try KhaytEngine()
        let rows: [[String: JSONValue]] = [
            Self.active, Self.service, Self.retired,
            Self.record("X1", ["status": .string("offline")]),
            Self.record("X2", ["retiredAt": .string("2026-01-01")]),
            Self.record("X3", ["isOffline": .bool(true), "status": .string("retired")]),
            Self.record("X4", ["isOffline": .string("yes")]),     // wrong type: not offline
        ]
        for row in rows {
            let m = try Self.machine(row)
            let state = try await engine.machineState(.object(row))
            let mine = m.isRetired ? "retired" : m.isUnderService ? "service" : "active"
            #expect(mine == state, "\(m.id): Swift says \(mine), the rule says \(state)")
        }
        // A field of the wrong type costs that field, never the machine list.
        let odd = try Self.machine(Self.record("X5", ["offlineReason": .number(4), "retiredAt": .bool(true)]))
        #expect(odd.inService)
        let s = try Self.machine(Self.service)
        #expect(s.underServiceReason == "Hotend on order" && s.underServiceSince == "2026-10-12")
        let r = try Self.machine(Self.retired)
        #expect(r.retiredOn == "2026-09-03" && r.retiredBecause == "Sold")
    }

    // MARK: - The writes, against a temp book

    @Test("under service and back, written to the book on disk, and undone")
    func underService() async throws {
        let engine = try KhaytEngine()
        let url = try Self.tempStore(Self.book())
        var undo: [Shop.ChangedRecord] = []
        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            undo = try await Shop.writeUnderService(into: &root, id: "M-A", on: true, reason: "  Belt  ",
                                                    since: "2026-10-18", engine: engine)
            Shop.sealUndo(&undo, in: root)
        }
        var after = try Self.read(url)
        let m = try #require(Self.row(after, "machines", "M-A"))
        #expect(m["isOffline"] == .bool(true) && m["offlineReason"] == .string("Belt"))
        #expect(m["offlineSince"] == .string("2026-10-18"))
        #expect(m["rev"] != nil, "an unstamped edit never leaves this Mac")
        #expect(undo.count == 1)

        _ = Shop.undoing(undo, in: &after)
        let undone = try #require(Self.row(after, "machines", "M-A"))
        #expect(undone["isOffline"] == nil && undone["offlineReason"] == nil)

        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            _ = try await Shop.writeUnderService(into: &root, id: "M-S", on: false, reason: nil,
                                                 since: "2026-10-18", engine: engine)
        }
        let back = try #require(Self.row(try Self.read(url), "machines", "M-S"))
        #expect(back["isOffline"] == .bool(false) && back["offlineReason"] == nil)
    }

    @Test("retire takes the printer off unfinished jobs only, and undo puts it all back")
    func retire() async throws {
        let engine = try KhaytEngine()
        let url = try Self.tempStore(Self.book())
        var undo: [Shop.ChangedRecord] = []
        var unassigned = 0
        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            let out = try await Shop.writeRetire(into: &root, id: "M-A", at: "2026-10-18",
                                                 reason: "Sold", engine: engine)
            undo = out.undo; unassigned = out.unassigned
            Shop.sealUndo(&undo, in: root)
        }
        var after = try Self.read(url)
        let m = try #require(Self.row(after, "machines", "M-A"))
        #expect(m["status"] == .string("retired") && m["retiredAt"] == .string("2026-10-18"))
        #expect(m["retiredReason"] == .string("Sold"))
        #expect(unassigned == 2)
        #expect(Self.row(after, "printLog", "J-1")?["machineId"] == .null)
        #expect(Self.row(after, "printLog", "J-2")?["machineId"] == .string("M-A"))
        #expect(Self.row(after, "printLog", "J-3")?["machineId"] == .null)
        // Only what changed was stamped: the finished job is untouched.
        #expect(Self.row(after, "printLog", "J-2")?["rev"] == nil)
        // The other machines are as they were.
        #expect(Self.row(after, "machines", "M-N")?["rev"] == nil)

        _ = Shop.undoing(undo, in: &after)
        #expect(Self.row(after, "machines", "M-A")?["status"] == nil)
        #expect(Self.row(after, "printLog", "J-1")?["machineId"] == .string("M-A"))
        #expect(Self.row(after, "printLog", "J-3")?["machineId"] == .string("M-A"))

        // And back to service: the retirement undone, the jobs left alone.
        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            _ = try await Shop.writeUnretire(into: &root, id: "M-A", engine: engine)
        }
        let returned = try #require(Self.row(try Self.read(url), "machines", "M-A"))
        #expect(returned["status"] == nil && returned["retiredAt"] == nil)
    }

    @Test("delete is refused for a printer with history and allowed for one without")
    func delete() async throws {
        let engine = try KhaytEngine()
        let url = try Self.tempStore(Self.book())
        await #expect(throws: Shop.LifeRefused.self) {
            try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
                _ = try await Shop.writeDelete(into: &root, id: "M-A", engine: engine)
            }
        }
        #expect(Self.row(try Self.read(url), "machines", "M-A") != nil, "a printer with history was deleted")

        var undo: [Shop.ChangedRecord] = []
        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            undo = try await Shop.writeDelete(into: &root, id: "M-N", engine: engine)
        }
        var after = try Self.read(url)
        #expect(Self.row(after, "machines", "M-N") == nil)
        #expect(Shop.rows(after, "machines").count == 3)
        // The delete leaves a tombstone, so a sync does not bring it back.
        #expect(!Shop.rows(after, "tombstones").isEmpty)
        #expect(undo.first?.kind == .deleted && undo.first?.at == 3)
        _ = Shop.undoing(undo, in: &after)
        #expect(Shop.recordId(Shop.rows(after, "machines")[3]) == "M-N", "undo put it back where it was")
    }

    @Test("a greyed Delete says what still names the printer")
    func refusalSentence() async throws {
        let shop = Shop()
        let verdict = KhaytEngine.MachineDeleteVerdict(
            ok: false, reason: "has_history", total: 16,
            by: ["printLog": 12, "machMaintLog": 3, "someNewThing": 1])
        let said = shop.cannotDeleteSentence(verdict)
        #expect(said.contains("12 jobs"), "\(said)")
        #expect(said.contains("3 service entries"), "\(said)")
        #expect(said.contains("1 other record"), "\(said)")
        let one = shop.cannotDeleteSentence(.init(ok: false, reason: "has_history", total: 1, by: ["printLog": 1]))
        #expect(one.contains("1 job") && !one.contains("1 jobs"), "\(one)")
        #expect(shop.cannotDeleteSentence(.init(ok: false, reason: "missing", total: 0, by: [:]))
                == shop.words.callIt("mac.life_delete_missing"))
    }

    // MARK: - Out of day-to-day use

    @Test("a retired printer is left out of the pickers, polling and sending")
    func leftOut() throws {
        let shop = Shop()
        let a = try Self.machine(Self.active), s = try Self.machine(Self.service), r = try Self.machine(Self.retired)
        shop.machines = [a, s, r]
        shop.machineRows = [.object(Self.active), .object(Self.service), .object(Self.retired)]

        #expect(shop.machinesInUse.map(\.id) == ["M-A", "M-S"])
        #expect(shop.workingMachines.map(\.id) == ["M-A"])
        #expect(shop.retiredMachines.map(\.id) == ["M-R"])
        #expect(shop.machineRowsInUse.compactMap(Shop.recordId) == ["M-A", "M-S"])

        // Pickers: no retired printer — unless the record already names it.
        #expect(shop.machineChoices(keeping: nil).map(\.id) == ["M-A", "M-S"])
        #expect(shop.machineChoices(keeping: "M-A").map(\.id) == ["M-A", "M-S"])
        #expect(shop.machineChoices(keeping: "M-R").map(\.id) == ["M-A", "M-S", "M-R"])
        #expect(shop.machineChoiceLabel(r) == "Printer M-R " + shop.words.callIt("mac.life_retired_suffix"))
        #expect(shop.machineChoiceLabel(s).hasSuffix(shop.words.callIt("mac.life_service_suffix")))
        #expect(shop.machineChoiceLabel(a) == "Printer M-A")

        // Polling: neither is asked, and each says why.
        #expect(PrinterWatch.notWatched(a) == nil)
        #expect(PrinterWatch.notWatched(s) == .underService)
        #expect(PrinterWatch.notWatched(r) == .retired)
        #expect(shop.quiet(s) == .underService && shop.quiet(r) == .retired)

        // Sending: only a printer in service.
        #expect(shop.sendablePrinters.map(\.id) == ["M-A"])

        // A job naming a printer no longer in the book says so in words.
        #expect(shop.machineName(forId: "M-GONE") == shop.words.callIt("mac.life_deleted_printer"))
        #expect(shop.machineName(forId: "M-R") == "Printer M-R")
    }

    @Test("the dashboard fleet drops the retired and counts under service as down")
    func fleet() async throws {
        let engine = try KhaytEngine()
        let rows: [JSONValue] = [.object(Self.active), .object(Self.service), .object(Self.retired)]
        let cache: [String: JSONValue] = [
            "M-A": .object(["state": .string("printing")]),
            "M-R": .object(["state": .string("idle")]),
        ]
        let fleet = Shop.fleetForDashboard(rows, cache: cache)
        #expect(fleet.machines.compactMap(Shop.recordId) == ["M-A", "M-S"])
        let facts = try await engine.dashboardFacts(orders: [], machines: fleet.machines, settings: [:],
                                                    statusCache: fleet.cache)
        #expect(facts.fleet.total == 2)
        #expect(facts.fleet.live == 1)
        #expect(facts.fleet.offline == 1)
    }

    // MARK: - The words

    @Test("every new word is in English and Arabic, in Words.swift's own table")
    func words() async throws {
        let keys = Words.own.keys.filter { $0.hasPrefix("mac.life_") }
        #expect(keys.count > 60, "only \(keys.count) found — the scan is wrong")
        for key in keys {
            let row = try #require(Words.own[key])
            #expect(!(row["en"] ?? "").isEmpty, "\(key) has no English")
            #expect(!(row["ar"] ?? "").isEmpty, "\(key) has no Arabic")
        }
        // Every counted reference has its singular, both languages.
        for key in Shop.referenceKeys.values + ["mac.life_ref_other", "mac.life_retire_jobs",
                                                "mac.life_jobs_unassigned"] {
            for form in [key, key + "_one", key + "_two", key + "_few"] {
                #expect(Words.own[form]?["en"] != nil && Words.own[form]?["ar"] != nil, "\(form) is missing")
            }
        }
        // And nothing here is shadowed by a Khayt catalogue key of the same name.
        for language in Words.supported {
            let catalogue = try await KhaytEngine().translations(language: language)
            #expect(!catalogue.isEmpty, "the \(language) catalogue did not load")
            for key in keys { #expect(catalogue[key] == nil, "\(key) is also a Khayt key in \(language)") }
        }
    }
}
