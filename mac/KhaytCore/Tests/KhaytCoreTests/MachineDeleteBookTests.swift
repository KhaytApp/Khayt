import Foundation
import Testing
@testable import KhaytCore

/// "May this printer be deleted?" gives the same answer on the book cut down
/// to what it reads (`MachineDeleteBook.trimmed`) as on the whole book.
///
/// The real `lib/machine-status.js` runs on both. If the rule ever reads a
/// field the trimming leaves out, the two answers part here.
@MainActor
struct MachineDeleteBookTests {

    private func js() throws -> JSModule { try JSModule(["machine-status"]) }

    private static func o(_ pairs: [String: JSONValue]) -> JSONValue { .object(pairs) }
    private static func named(_ id: JSONValue, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        var r: [String: JSONValue] = ["machineId": id, "name": .string("a record"), "notes": .string(String(repeating: "n", count: 40))]
        for (k, v) in extra { r[k] = v }
        return .object(r)
    }

    /// A book with every shape the rule tests for, and plenty it never reads.
    static func book() -> [String: JSONValue] {
        let inner: (String) -> JSONValue = { .object(["machineId": .string($0), "grams": .number(12)]) }
        return [
            "machines": .array([
                o(["id": .string("M-A"), "name": .string("Alpha"), "printerApi": o(["host": .string("10.0.0.2")])]),
                o(["id": .string("M-N"), "name": .string("Nobody names me")]),
                o(["id": .string(" M-SP "), "name": .string("id with spaces")]),
                o(["id": .number(7), "name": .string("a numeric id")]),
                o(["id": .string("M-NEST")]), o(["id": .string("M-RUNS")]), o(["id": .string("M-CACHE")]),
                o(["id": .string("M-OLD")]), o(["id": .string("M-NULL")]), o(["id": .string("M-TOMB")]),
                o(["id": .string("M-SELF"), "machineId": .string("M-N")]),
                o(["id": .string("M-ARR")]), o(["id": .string("M-STR")]), o(["id": .string("M-SET")]),
                o(["id": .string("constructor")]), o(["id": .string("toString")]),
                o(["id": .string("true")]), o(["id": .string("1,2")]), o(["id": .string("[object Object]")]),
                o(["id": .string("M-DUP")]), o(["id": .string("M-DUP"), "name": .string("the same id twice")]),
                o(["name": .string("no id at all")]),
                .null, .string("M-TEXT"), .number(3), .array([o(["id": .string("M-INARRAY")])]), .bool(true),
            ]),
            "printLog": .array([
                named(.string("M-A"), ["status": .string("queued")]),
                named(.string("M-A"), ["status": .string("completed")]),
                named(.string("  M-SP  ")),
                named(.number(7)),
                named(.bool(true)),
                named(.array([.number(1), .number(2)])),
                named(.object(["id": .string("M-A")])),
                named(.null),
                named(.string("")),
                o(["id": .string("J-1"), "client": .string("nobody")]),
                o(["id": .string("J-2"), "parts": .array([inner("M-NEST"), inner("M-NEST"), .null, .string("M-STR"),
                                                         o(["name": .string("no machine")])])]),
                o(["id": .string("J-3"), "printRuns": .array([inner("M-RUNS")]), "runs": .array([inner("M-RUNS")]),
                   "setups": .array([inner("M-A")]), "attempts": .array([inner("M-DUP")])]),
                // A nested list that is not a list, and one the rule does not know.
                o(["id": .string("J-4"), "parts": o(["machineId": .string("M-N")]),
                   "runs": .string("M-N"), "plates": .array([inner("M-N")])]),
                // Named twice by one record: the record counts once.
                named(.string("M-DUP"), ["parts": .array([inner("M-DUP")])]),
                .null, .string("M-STR"), .number(7), .array([named(.string("M-ARR"))]),
            ]),
            "machMaintLog": .array([named(.string("M-A")), named(.string("M-A")), named(.string("M-DUP"))]),
            "wasteLog": .array([named(.string("M-RUNS"))]),
            "printFiles": .array((0..<50).map { i in
                o(["id": .string("f\(i)"), "name": .string("model \(i)"), "category": .string("Busts"),
                   "thumb": .string(String(repeating: "A", count: 200))])
            }),
            // Skipped by name, even though it names one.
            "tombstones": .array([named(.string("M-TOMB")), o(["collection": .string("machines"), "id": .string("M-TOMB")])]),
            "someNewCollection": .array([named(.string("M-A"))]),
            "emptyList": .array([]),
            // The finished-print cache, where both apps write it.
            "printerCompletions": o(["M-CACHE": o(["filename": .string("a.gcode"), "grams": .number(31)]),
                                     "M-NULL": .null, "M-A": .bool(false), "M-N2": .number(0)]),
            // And where older books kept it, beside everything else settings holds.
            "settings": o(["bizLogo": .string("data:image/png;base64," + String(repeating: "A", count: 300)),
                           "printerCompletions": o(["M-OLD": o(["filename": .string("b.gcode")]), "M-NULL": .null]),
                           "printLibrary": o(["linked": .array([])]),
                           "machineId": .string("M-SET")]),
            // Not arrays, so never scanned.
            "version": .number(4), "label": .string("M-STR"), "flag": .bool(true), "nothing": .null,
            "printers": o(["machineId": .string("M-N")]),
        ]
    }

    static let ids: [JSONValue] = [
        "M-A", "M-N", " M-SP ", "M-SP", "7", "M-NEST", "M-RUNS", "M-CACHE", "M-OLD", "M-NULL", "M-TOMB",
        "M-SELF", "M-ARR", "M-STR", "M-SET", "constructor", "toString", "__proto__", "true", "1,2",
        "[object Object]", "M-DUP", "M-TEXT", "M-INARRAY", "M-N2", "nope", "", "   ",
    ].map(JSONValue.string) + [.number(7), .null, .bool(true), .array([.number(1), .number(2)])]

    /// Other books: the shapes a whole book can take.
    static func otherBooks() -> [[String: JSONValue]] {
        var noMachines = book(); noMachines["machines"] = nil
        var machinesNotAList = book(); machinesNotAList["machines"] = o(["id": .string("M-A")])
        var cacheIsAList = book()
        cacheIsAList["printerCompletions"] = .array([named(.string("M-N")), .null])
        var settingsIsAList = book()
        settingsIsAList["settings"] = .array([named(.string("M-N")), o(["printerCompletions": o(["M-A": .bool(true)])])])
        var oldCacheNotAnObject = book()
        oldCacheNotAnObject["settings"] = o(["printerCompletions": .array([o(["M-N": .bool(true)])])])
        var emptyCaches = book()
        emptyCaches["printerCompletions"] = o([:])
        emptyCaches["settings"] = o(["printerCompletions": o([:])])
        var noCaches = book(); noCaches["printerCompletions"] = nil; noCaches["settings"] = nil
        return [noMachines, machinesNotAList, cacheIsAList, settingsIsAList, oldCacheNotAnObject,
                emptyCaches, noCaches, [:]]
    }

    @Test("the same verdict for every machine, trimmed or whole")
    func sameVerdicts() throws {
        let js = try js()
        var refused = 0, allowed = 0, missing = 0
        for (n, book) in ([Self.book()] + Self.otherBooks()).enumerated() {
            let small = MachineDeleteBook.trimmed(book)
            for id in Self.ids {
                let whole = try js.value("KhaytMachineStatus.canDelete(ARG0, ARG1)", [.object(book), id])
                let cut = try js.value("KhaytMachineStatus.canDelete(ARG0, ARG1)", [.object(small), id])
                #expect(whole == cut, Comment(rawValue: "book \(n), machine \(id)\n  whole \(whole)\n  cut   \(cut)"))
                let refs = try js.value("KhaytMachineStatus.references(ARG0, ARG1)", [.object(book), id])
                let refsCut = try js.value("KhaytMachineStatus.references(ARG0, ARG1)", [.object(small), id])
                #expect(refs == refsCut, Comment(rawValue: "references: book \(n), machine \(id)"))
                if case .object(let v) = whole {
                    if v["ok"] == .bool(true) { allowed += 1 }
                    else if v["reason"] == .string("missing") { missing += 1 }
                    else { refused += 1 }
                }
            }
        }
        // The books really do reach all three answers; a fixture that only
        // ever said "missing" would agree with anything.
        #expect(refused > 20 && allowed > 5 && missing > 20, "refused \(refused), allowed \(allowed), missing \(missing)")
    }

    @Test("the verdicts the fixture is built to give, so a broken rule is not agreed with twice")
    func knownAnswers() throws {
        let js = try js()
        let small = JSONValue.object(MachineDeleteBook.trimmed(Self.book()))
        func verdict(_ id: String) throws -> [String: JSONValue] {
            guard case .object(let v) = try js.value("KhaytMachineStatus.canDelete(ARG0, ARG1)", [small, .string(id)])
            else { return [:] }
            return v
        }
        #expect(try verdict("M-N")["ok"] == .bool(true))
        #expect(try verdict("M-TOMB")["ok"] == .bool(true), "a tombstone is not history")
        #expect(try verdict("nope")["reason"] == .string("missing"))
        let a = try verdict("M-A")
        #expect(a["reason"] == .string("has_history"))
        #expect(a["by"] == .object(["printLog": .number(3), "machMaintLog": .number(2),
                                    "someNewCollection": .number(1), "printerCompletions": .number(1)]))
        #expect(try verdict("M-NEST")["by"] == .object(["printLog": .number(1)]))
        #expect(try verdict("M-CACHE")["by"] == .object(["printerCompletions": .number(1)]))
        #expect(try verdict("M-OLD")["by"] == .object(["printerCompletions": .number(1)]))
        #expect(try verdict("M-NULL")["ok"] == .bool(true), "a null cache entry is not one")
    }

    @Test("what is handed over is a small part of the book")
    func itIsSmaller() throws {
        var book = Self.book()
        book["printFiles"] = .array((0..<2_000).map { i in
            Self.o(["id": .string("f\(i)"), "name": .string("model \(i)"),
                    "thumb": .string(String(repeating: "A", count: 2_000))])
        })
        let whole = try JSONValue.encode(.object(book)).count
        let cut = try JSONValue.encode(.object(MachineDeleteBook.trimmed(book))).count
        #expect(cut * 50 < whole, "trimmed \(cut) bytes of \(whole)")
        // And nothing the rule does not read is in it.
        let text = String(decoding: try JSONValue.encode(.object(MachineDeleteBook.trimmed(book))), as: UTF8.self)
        for word in ["bizLogo", "thumb", "notes", "printLibrary", "tombstones", "name"] {
            #expect(!text.contains("\"\(word)\""), "\(word) was handed over")
        }
    }

    @Test("the engine hands the rule the trimmed book")
    func engineTrims() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytCore/KhaytEngine.swift"), encoding: .utf8)
        let calls = source.components(separatedBy: "KhaytMachineStatus.canDelete(").dropFirst()
        #expect(calls.count == 2, "a new caller of canDelete: hand it MachineDeleteBook.trimmed, or say why not")
        for call in calls {
            #expect(call.prefix(400).contains("MachineDeleteBook.trimmed(book)"))
        }
    }
}
