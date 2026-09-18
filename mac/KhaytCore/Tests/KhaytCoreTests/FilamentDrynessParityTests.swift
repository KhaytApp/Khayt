import Foundation
import Testing
@testable import KhaytCore

/// When a spool needs drying again, against the JavaScript it came from.
///
/// The interesting half is not the table — it is `materialKey`, which turns a
/// shop's own free text into one of nine polymers. A spool is labelled
/// "PLA Matte", "PA6-CF", "Sunlu PETG" or whatever the supplier printed on it,
/// and getting that wrong gives the shelf a drying interval meant for a
/// different plastic: twenty days for a nylon that needs one.
@MainActor
struct FilamentDrynessParityTests {

    private func js() throws -> JSModule { try JSModule(["filament-dryness"]) }

    private func theirKey(_ js: JSModule, _ material: JSONValue) throws -> String? {
        let answer = try js.value("globalThis.KhaytFilamentDryness.materialKey(ARG0)", [material])
        if case .string(let s) = answer { return s }
        return nil
    }

    private func theirStatus(_ js: JSModule, _ record: JSONValue,
                             now: Double) throws -> FilamentDryness.Status {
        guard case .object(let o) = try js.value(
            "globalThis.KhaytFilamentDryness.dryStatus(ARG0, ARG1)", [record, .number(now)])
        else { Issue.record("not an object")
               return FilamentDryness.Status(state: "«?»", daysSince: nil, intervalDays: -1, pct: -1) }
        var state = "«?»"; if case .string(let s)? = o["state"] { state = s }
        var days: Double?; if case .number(let d)? = o["daysSince"] { days = d }
        var interval = -1.0; if case .number(let i)? = o["intervalDays"] { interval = i }
        var pct = -1.0; if case .number(let p)? = o["pct"] { pct = p }
        return FilamentDryness.Status(state: state, daysSince: days,
                                      intervalDays: interval, pct: pct)
    }

    private func checkStatus(_ record: JSONValue, now: Double,
                             _ what: String, _ js: JSModule) throws {
        let mine = FilamentDryness.status(of: record, now: now)
        let theirs = try theirStatus(js, record, now: now)
        #expect(mine == theirs, Comment(rawValue: "\(what)\n  swift \(mine)\n  js    \(theirs)"))
    }

    /// Every spelling a spool label has ever carried, plus the near-misses.
    static let labels = [
        "PLA", "pla", "PLA Matte", "PLA+", "Bambu PLA Basic", "Silk PLA",
        "PETG", "petg", "Sunlu PETG", "PETG-CF", "CF-PETG",
        "TPU", "TPU 95A", "tpu",
        "ABS", "ABS+", "ASA", "asa",
        "PC", "PC-ABS", "Polycarbonate", "PCTG",
        "PVA", "pva",
        // Nylon, which is the regex's whole reason for existing.
        "NYLON", "Nylon", "nylon 6", "PA", "PA6", "PA12", "PA6-CF", "PA-CF",
        "PAHT-CF", "PA12-CF", "pa6", "PA_6",
        // And the words that must NOT be nylon.
        "SPAGHETTI", "PAINT", "PAPER", "SPA", "APA", "PANTONE", "COMPACT",
        // Nothing at all.
        "", "   ", "unknown stuff", "Wood fill", "Metal",
    ]

    @Test("every spool label resolves to the same material")
    func materialKeysMatch() throws {
        let js = try js()
        for label in Self.labels {
            let mine = FilamentDryness.materialKey(.string(label))
            let theirs = try theirKey(js, .string(label))
            #expect(mine == theirs, Comment(rawValue:
                "\(label.debugDescription): swift \(mine ?? "nil") vs js \(theirs ?? "nil")"))
        }
    }

    @Test("a material that is not a string")
    func oddMaterials() throws {
        let js = try js()
        for value in [JSONValue.null, .number(7), .bool(true), .bool(false),
                      .array([]), .array([.string("PLA")]), .object([:]), .string("")] {
            let mine = FilamentDryness.materialKey(value)
            let theirs = try theirKey(js, value)
            #expect(mine == theirs, Comment(rawValue:
                "\(value): swift \(mine ?? "nil") vs js \(theirs ?? "nil")"))
        }
    }

    @Test("the order of the substring list decides PC-ABS")
    func listOrderMatters() throws {
        // `['PETG','PLA','TPU','ABS','ASA','PVA','PC']` — ABS comes before PC,
        // so "PC-ABS" is ABS. Reordering that list silently re-labels a shelf.
        let js = try js()
        for label in ["PC-ABS", "ABS-PC", "PLA-PETG", "PETG-PLA", "ASA-ABS", "PVA-PC"] {
            #expect(FilamentDryness.materialKey(.string(label)) == (try theirKey(js, .string(label))),
                    Comment(rawValue: label))
        }
        #expect(FilamentDryness.materialKey(.string("PC-ABS")) == "ABS",
                "the list order changed and a shelf just changed material")
    }

    @Test("the table is the same table, row for row")
    func tableMatches() throws {
        let js = try js()
        guard case .object(let theirs) = try js.value("globalThis.KhaytFilamentDryness.MATERIALS")
        else { Issue.record("no table"); return }
        #expect(Set(theirs.keys) == Set(FilamentDryness.materials.keys),
                Comment(rawValue: "keys differ: \(Set(theirs.keys).symmetricDifference(FilamentDryness.materials.keys))"))
        for (key, value) in theirs {
            guard case .object(let row) = value,
                  let mine = FilamentDryness.materials[key] else {
                Issue.record(Comment(rawValue: "\(key) missing")); continue
            }
            func n(_ k: String) -> Double { if case .number(let d)? = row[k] { return d }; return .nan }
            #expect(mine.openDays == n("openDays"), Comment(rawValue: "\(key) openDays"))
            #expect(mine.sealedDays == n("sealedDays"), Comment(rawValue: "\(key) sealedDays"))
            #expect(mine.dryTempC == n("dryTempC"), Comment(rawValue: "\(key) dryTempC"))
            #expect(mine.dryHours == n("dryHours"), Comment(rawValue: "\(key) dryHours"))
        }
        // And the fallback, which is what an unrecognised label gets.
        guard case .object(let fb) = try js.value("globalThis.KhaytFilamentDryness.DEFAULT")
        else { Issue.record("no default"); return }
        func d(_ k: String) -> Double { if case .number(let x)? = fb[k] { return x }; return .nan }
        #expect(FilamentDryness.fallback.openDays == d("openDays"))
        #expect(FilamentDryness.fallback.sealedDays == d("sealedDays"))
    }

    @Test("a real shelf, at every stage of drying out")
    func realShelf() throws {
        let js = try js()
        let now = 1_790_000_000_000.0
        for material in ["PLA", "PA6-CF", "PETG", "unknown"] {
            for storage in ["open", "drybox", "sealed", "shelf", ""] {
                for daysAgo in [0.0, 1, 5, 9, 10, 10.5, 13, 14, 15, 60, 90, 200] {
                    try checkStatus(.object([
                        "material": .string(material), "storage": .string(storage),
                        "driedAt": .number(now - daysAgo * 86_400_000),
                    ]), now: now, "\(material)/\(storage) \(daysAgo)d ago", js)
                }
            }
        }
    }

    @Test("never dried is unknown, not overdue")
    func neverDriedIsUnknown() throws {
        // A spool nobody has recorded a drying for is one nobody knows about.
        // Calling that overdue fills the screen with alarms about shelves the
        // shop has not started tracking.
        let js = try js()
        let now = 1_790_000_000_000.0
        for value in [JSONValue.null, .string(""), .number(0), .bool(false),
                      .string("not a date"), .string("2026-13-99"), .array([]), .object([:])] {
            try checkStatus(.object(["material": .string("PLA"), "driedAt": value]),
                            now: now, "driedAt \(value)", js)
        }
        try checkStatus(.object(["material": .string("PLA")]), now: now, "no driedAt", js)
        #expect(FilamentDryness.status(of: .object(["material": .string("PLA")]),
                                       now: now).state == "unknown")
    }

    @Test("a drying recorded in the future does not read as freshly dried for ever")
    func futureDryingIsFloored() throws {
        let js = try js()
        let now = 1_790_000_000_000.0
        for ahead in [1.0, 30, 400] {
            try checkStatus(.object(["material": .string("PLA"),
                                     "driedAt": .number(now + ahead * 86_400_000)]),
                            now: now, "dried \(ahead) days ahead", js)
        }
    }

    @Test("driedAt as a stored date string, not a number")
    func stringDatesMatch() throws {
        let js = try js()
        let now = 1_790_000_000_000.0
        for value in ["2026-09-01", "2026-09-01T00:00:00Z", "2026-09-01T00:00:00",
                      "2026-01-01", "2020-01-01", "2030-01-01"] {
            try checkStatus(.object(["material": .string("PLA"), "driedAt": .string(value)]),
                            now: now, "driedAt \(value)", js)
        }
    }

    @Test("only a drybox and a sealed bag count as sealed")
    func sealedStorageMatches() throws {
        let js = try js()
        let now = 1_790_000_000_000.0
        for value in [JSONValue.string("drybox"), .string("sealed"), .string("DRYBOX"),
                      .string("dry box"), .string("open"), .string(""), .null,
                      .bool(true), .number(1), .array([])] {
            try checkStatus(.object(["material": .string("PLA"), "storage": value,
                                     "driedAt": .number(now - 20 * 86_400_000)]),
                            now: now, "storage \(value)", js)
        }
    }

    @Test("the boundaries between good, due and overdue")
    func thresholdsMatch() throws {
        // 0.75 and 1.0 exactly, from both sides.
        let js = try js()
        let now = 1_790_000_000_000.0
        let interval = 14.0   // PLA, open air
        for fraction in [0.0, 0.7499, 0.75, 0.7501, 0.9999, 1.0, 1.0001, 2.0] {
            try checkStatus(.object(["material": .string("PLA"),
                                     "driedAt": .number(now - fraction * interval * 86_400_000)]),
                            now: now, "at \(fraction) of the interval", js)
        }
    }

    @Test("a record that is not a record")
    func degenerateRecords() throws {
        let js = try js()
        let now = 1_790_000_000_000.0
        for value in [JSONValue.null, .string("x"), .number(3), .array([]), .object([:]),
                      .bool(true)] {
            try checkStatus(value, now: now, "record \(value)", js)
        }
    }
}
