import Foundation
import Testing
@testable import KhaytCore

/// The shop's working week, against the JavaScript it came from.
///
/// These hours feed the due-date suggestion, the machine queue-clear date and
/// the schedule projection. A port that read the default a day short would put
/// every promised date further out, quietly and everywhere — which is exactly
/// the fault the module was written to fix in the first place.
@MainActor
struct WorkingWeekParityTests {

    private func js() throws -> JSModule { try JSModule(["working-week"]) }

    private func theirs(_ js: JSModule, _ settings: JSONValue) throws -> [String: Double] {
        guard case .object(let o) = try js.value(
            "globalThis.KhaytWorkingWeek.workingHours(ARG0)", [settings]) else { return [:] }
        return o.reduce(into: [:]) { out, pair in
            if case .number(let n) = pair.value { out[pair.key] = n }
        }
    }

    /// Every shape a stored `workingHours` has ever come back as.
    private var books: [JSONValue] {
        var out: [JSONValue] = [
            .object([:]), .null, .string("x"), .number(1), .bool(true), .array([]),
            .object(["workingHours": .null]),
            .object(["workingHours": .string("mon")]),
            .object(["workingHours": .number(8)]),
            .object(["workingHours": .array([.number(8)])]),
            .object(["workingHours": .object([:])]),
            // A shop that edited its week and left days out. Those days are
            // CLOSED, not "at the default's hours".
            .object(["workingHours": .object(["mon": .number(6), "tue": .number(6)])]),
            .object(["workingHours": .object(["sun": .number(8), "mon": .number(8),
                                              "tue": .number(8), "wed": .number(8),
                                              "thu": .number(8), "fri": .number(0),
                                              "sat": .number(0)])]),
            // The four-day literal the module exists to replace.
            .object(["workingHours": .object(["mon": .number(8), "tue": .number(8),
                                              "wed": .number(8), "thu": .number(8),
                                              "fri": .number(0), "sat": .number(0),
                                              "sun": .number(0)])]),
            // A stray key nothing reads, and a day past 24.
            .object(["workingHours": .object(["mon": .number(8), "holiday": .number(99),
                                              "tue": .number(40)])]),
        ]
        // Every day, holding every value that is not obviously a number.
        for odd in Awkward.notNumbers + Awkward.numbers.map({ JSONValue.number($0) }) {
            out.append(.object(["workingHours": .object(["wed": odd])]))
        }
        return out
    }

    @Test("the hours come out the same for every book shape")
    func hoursMatch() throws {
        let js = try js()
        for book in books {
            let mine = WorkingWeek.hours(settings: book)
            let theirs = try theirs(js, book)
            #expect(mine == theirs, Comment(rawValue: "\(book)\n  swift \(mine.sorted { $0.key < $1.key })\n  js    \(theirs.sorted { $0.key < $1.key })"))
        }
    }

    @Test("the default is Sunday to Thursday, in both languages")
    func defaultIsTheGulfWeek() throws {
        let js = try js()
        #expect(WorkingWeek.defaultHours == (try theirs(js, .object([:]))))
        // Said outright, because agreeing on the wrong week is still wrong.
        #expect(WorkingWeek.defaultHours["sun"] == 8, "Sunday is a working day")
        #expect(WorkingWeek.defaultHours["fri"] == 0)
        #expect(WorkingWeek.defaultHours["sat"] == 0)
        #expect(WorkingWeek.workingDaysPerWeek(settings: .object([:])) == 5)
    }

    @Test("the day keys are the same list in the same order")
    func keysMatch() throws {
        // The order is `getDay()`'s, so a reordered list would silently move
        // the whole week by a day.
        #expect(WorkingWeek.dayKeys == (try js().strings("globalThis.KhaytWorkingWeek.DAY_KEYS")))
    }

    @Test("hours on a day agree, including the indexes that wrap")
    func dayIndexesMatch() throws {
        let js = try js()
        let book = JSONValue.object(["workingHours": .object(
            ["sun": .number(3), "mon": .number(4), "sat": .number(5)])])
        for index in [-14.0, -8, -1, 0, 1, 6, 7, 13, 0.5, -0.5, 6.9] {
            let mine = WorkingWeek.hoursOnDay(settings: book, dayIndex: index)
            guard case .number(let theirs) = try js.value(
                "globalThis.KhaytWorkingWeek.hoursOnDay(ARG0, ARG1)", [book, .number(index)])
            else { Issue.record("no answer for \(index)"); continue }
            #expect(mine == theirs, Comment(rawValue: "day \(index): \(mine) vs \(theirs)"))
        }
    }

    @Test("days per week agrees for every book")
    func daysPerWeekMatches() throws {
        let js = try js()
        for book in books {
            let mine = WorkingWeek.workingDaysPerWeek(settings: book)
            let theirs = try js.int("globalThis.KhaytWorkingWeek.workingDaysPerWeek(ARG0)", [book])
            #expect(mine == theirs, Comment(rawValue: "\(book): \(mine) vs \(theirs ?? -1)"))
        }
    }

    @Test("the two figures the engine used to build in JavaScript agree too")
    func derivedFiguresMatch() throws {
        // `dailyWorkingHours` and `openDays` were expressions inside the Swift
        // engine rather than part of the module. They move here with it, so
        // they are compared against the same expressions.
        let js = try js()
        for book in books {
            let mineDaily = WorkingWeek.dailyWorkingHours(settings: book)
            guard case .number(let theirsDaily) = try js.value("""
                (function (settings) {
                  const wh = globalThis.KhaytWorkingWeek.workingHours(settings);
                  const total = Object.values(wh).reduce((s, h) => s + (h > 0 ? h : 0), 0);
                  return total > 0 ? total / 7 : 8;
                })(ARG0)
                """, [book]) else { Issue.record("no daily for \(book)"); continue }
            #expect(mineDaily == theirsDaily, Comment(rawValue: "daily for \(book)"))

            let mineOpen = WorkingWeek.openDays(settings: book)
            guard case .array(let open) = try js.value("""
                (function (s) {
                  var wh = globalThis.KhaytWorkingWeek.workingHours(s);
                  return ['sun','mon','tue','wed','thu','fri','sat'].map(function (k) {
                    return (wh[k] || 0) > 0;
                  });
                })(ARG0)
                """, [book]) else { Issue.record("no openDays for \(book)"); continue }
            let theirsOpen = open.map { if case .bool(let b) = $0 { return b } else { return false } }
            #expect(mineOpen == theirsOpen, Comment(rawValue: "openDays for \(book)"))
        }
    }
}
