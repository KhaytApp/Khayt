import Foundation
import Testing
@testable import KhaytCore

/// A report a shop named and wants back, against the JavaScript it came from.
///
/// The two faults the module exists to fix are the cases worth pinning: saving
/// twice under one name must REPLACE, and a list read back has to survive a
/// store somebody edited by hand.
@MainActor
struct SavedReportsParityTests {

    private func js() throws -> JSModule { try JSModule(["saved-reports"]) }

    private func rows(_ v: JSONValue) -> [SavedReports.Report] {
        guard case .array(let list) = v else { return [] }
        return list.map { row in
            guard case .object(let r) = row else { return .init(id: "?", name: "?", fields: [],
                                                                statusIn: [], from: "", to: "") }
            func text(_ k: String) -> String {
                if case .string(let s)? = r[k] { return s }; return "<\(k)?>"
            }
            func list(_ k: String) -> [String] {
                guard case .array(let items)? = r[k] else { return ["<\(k)?>"] }
                return items.map { if case .string(let s) = $0 { return s } else { return "?" } }
            }
            return .init(id: text("id"), name: text("name"), fields: list("fields"),
                         statusIn: list("statusIn"), from: text("from"), to: text("to"))
        }
    }

    private func report(_ id: String, _ name: String, fields: [String] = ["id", "price"],
                        statusIn: [String] = [], from: String = "", to: String = "") -> JSONValue {
        .object(["id": .string(id), "name": .string(name),
                 "fields": .array(fields.map(JSONValue.string)),
                 "statusIn": .array(statusIn.map(JSONValue.string)),
                 "from": .string(from), "to": .string(to)])
    }

    private var stored: [JSONValue] {
        [report("r1", "Monthly VAT", from: "2026-01-01", to: "2026-12-31"),
         report("r2", "Unpaid", statusIn: ["completed"]),
         // A store edited by hand.
         report("", "No id"), report("r3", "  "), .null, .string("x"), .number(1),
         .array([]), .object([:]),
         .object(["id": .number(7), "name": .number(9)]),
         .object(["id": .string(" r4 "), "name": .string("  Padded  "),
                  "fields": .string("not a list"), "statusIn": .null,
                  "from": .string("2026-09-01T10:00:00Z"), "to": .number(20260930)]),
         // The same id twice: the first wins.
         report("r1", "A second Monthly VAT")]
    }

    @Test("what is really on the settings")
    func allMatches() throws {
        let js = try js()
        let settings: [String: JSONValue] = ["savedReports": .array(stored)]
        let mine = SavedReports.all(settings: settings)
        let theirs = rows(try js.value("KhaytSavedReports.savedReports(ARG0)", [.object(settings)]))
        #expect(mine == theirs, Comment(rawValue: "swift \(mine)\njs    \(theirs)"))
        // And the shapes a settings object can be in.
        for junk: JSONValue in [.null, .string("x"), .number(1), .object([:]), .array([])] {
            let s: [String: JSONValue] = ["savedReports": junk]
            let mine = SavedReports.all(settings: s)
            let theirs = rows(try js.value("KhaytSavedReports.savedReports(ARG0)", [.object(s)]))
            #expect(mine == theirs, Comment(rawValue: "savedReports of \(junk)"))
        }
        #expect(SavedReports.all(settings: [:]).isEmpty)
    }

    private func checkAdd(_ list: [JSONValue], _ spec: [String: JSONValue], _ id: String,
                          _ what: String, _ js: JSModule) throws {
        let mine = SavedReports.add(list, spec: spec, id: id)
        let theirs = rows(try js.value("KhaytSavedReports.addReport(ARG0, ARG1, ARG2)",
                                       [.array(list), .object(spec), .string(id)]))
        #expect(mine == theirs, Comment(rawValue: "\(what)\n  swift \(mine)\n  js    \(theirs)"))
    }

    @Test("saving under a name already used replaces it, in place")
    func addReplaces() throws {
        let js = try js()
        let list = [report("r1", "Monthly VAT"), report("r2", "Unpaid"),
                    report("r3", "Machines")]
        try checkAdd(list, ["name": .string("Monthly VAT"),
                            "fields": .array([.string("id"), .string("date")])],
                     "new-id", "the same name", js)
        // Case does not make a second report.
        try checkAdd(list, ["name": .string("monthly vat"), "fields": .array([])],
                     "new-id", "a different case", js)
        try checkAdd(list, ["name": .string("  Monthly VAT  ")], "new-id", "padded", js)
        try checkAdd(list, ["name": .string("Brand new"), "fields": .array([.string("id")])],
                     "new-id", "a new name", js)
    }

    @Test("a report with no name is not saved")
    func addRefusesTheNameless() throws {
        let js = try js()
        let list = [report("r1", "Monthly VAT")]
        for name: JSONValue in [.string(""), .string("   "), .null, .number(0), .bool(false)] {
            try checkAdd(list, ["name": name], "new-id", "a name of \(name)", js)
        }
        // A new report needs an id too, and an empty one is refused by `clean`.
        try checkAdd(list, ["name": .string("Nameless id")], "", "no id", js)
    }

    @Test("an id inside the spec wins over the one passed alongside it")
    func specOverridesId() throws {
        // `clean({ id, name, ...spec })` spreads the spec LAST. Not tidied
        // away: a caller that puts an id in the spec is choosing one, and the
        // two apps have to choose the same way.
        let js = try js()
        try checkAdd([report("r1", "Monthly VAT")],
                     ["name": .string("Brand new"), "id": .string("chosen")],
                     "passed-in", "an id in the spec", js)
        try checkAdd([report("r1", "Monthly VAT")],
                     ["name": .string("Monthly VAT"), "id": .string("chosen")],
                     "passed-in", "an id in the spec, replacing", js)
    }

    @Test("a list that is not a list, and rows that are not reports")
    func addSurvivesJunk() throws {
        let js = try js()
        try checkAdd(stored, ["name": .string("Added")], "new-id", "a junk list", js)
        try checkAdd([], ["name": .string("First")], "r1", "an empty list", js)
    }

    @Test("dropping one, and dropping one that is not there")
    func removeMatches() throws {
        let js = try js()
        for id in ["r1", "r2", "nope", "", " r4 ", "r4"] {
            let mine = SavedReports.remove(stored, id: id)
            let theirs = rows(try js.value("KhaytSavedReports.removeReport(ARG0, ARG1)",
                                           [.array(stored), .string(id)]))
            #expect(mine == theirs, Comment(rawValue: "removing \(id.debugDescription)"))
        }
    }

    @Test("finding one to load back")
    func findMatches() throws {
        let js = try js()
        for id in ["r1", "r2", "nope", "", "r4", " r4 "] {
            let mine = SavedReports.find(stored, id: id)
            let v = try js.value("KhaytSavedReports.findReport(ARG0, ARG1)",
                                 [.array(stored), .string(id)])
            let theirs = rows(.array(v == .null ? [] : [v])).first
            #expect(mine == theirs, Comment(rawValue: "finding \(id.debugDescription)"))
        }
    }
}
