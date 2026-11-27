import XCTest
import KhaytCore
@testable import KhaytCompanion

/// The success rate on the phone's machine page (signed frame 6): the shared
/// rule through the phone's own engine, the book's window, and the words.
/// Sample data only.
@MainActor
final class SuccessRateTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "success-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func book(_ store: [String: JSONValue]) throws -> CompanionBook {
        let b = CompanionBook(directory: dir)
        try b.replace(with: store, scope: nil)
        return b
    }

    /// `test/fixtures/printer-success-vectors.json` through the engine the
    /// phone ships (`KhaytEngine.successRates`, Mac #2696).
    func testTheSharedVectorsThroughThePhonesEngine() async throws {
        struct Want: Decodable { let machineId: String; let finished: Int; let failed: Int; let cancelled: Int; let unknown: Int
                                 let rate: Double?; let enough: Bool }
        // As the Mac's SuccessRatesTests reads them: a case may leave both
        // lists out, and may name the caller's calendar (#2702).
        struct Input: Decodable { let machines: [JSONValue]?; let orders: [JSONValue]?; let from: String?; let to: String? }
        struct CalendarOf: Decodable { let utcOffsetMinutes: Int?; let timeZone: String? }
        struct Case: Decodable { let why: String; let input: Input; let calendar: CalendarOf?; let want: [Want] }
        struct Vectors: Decodable { let cases: [Case] }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "test/fixtures/printer-success-vectors.json")
        let v = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(v.cases.count, 2)
        let engine = try await BookReader(book: try book(SampleShop.book())).sharedEngine()
        for c in v.cases {
            var zone: Calendar?
            if let named = c.calendar?.timeZone {
                zone = Calendar(identifier: .gregorian)
                zone?.timeZone = try XCTUnwrap(TimeZone(identifier: named), named)
            } else if let minutes = c.calendar?.utcOffsetMinutes {
                zone = Calendar(identifier: .gregorian)
                zone?.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: minutes * 60))
            }
            let rows = try await engine.successRates(orders: c.input.orders ?? [], machines: c.input.machines ?? [],
                                                     from: c.input.from, to: c.input.to, calendar: zone)
            XCTAssertEqual(rows.map(\.machineId), c.want.map(\.machineId), "\(c.why): worst first")
            for (got, want) in zip(rows, c.want) {
                XCTAssertEqual([got.finished, got.failed, got.cancelled, got.unknown],
                               [want.finished, want.failed, want.cancelled, want.unknown], "\(c.why): \(want.machineId)")
                XCTAssertEqual(got.rate, want.rate, "\(c.why): \(want.machineId)")
                XCTAssertEqual(got.enough, want.enough, "\(c.why): \(want.machineId)")
            }
        }
        let needed = try await engine.successRunsNeeded()
        XCTAssertEqual(needed, 5)
    }

    private func run(_ machine: String, _ day: String, _ result: String?) -> JSONValue {
        var o: [String: JSONValue] = ["machineId": .string(machine), "at": .string(day)]
        if let result { o["result"] = .string(result); o["resultSource"] = .string("printer") }
        return .object(o)
    }

    /// The book's last 30 days, one machine: 23 finished, 2 failed, 3
    /// cancelled, and an older failure that is outside the window.
    func testAMachinesRateIsCountedOverTheLastThirtyDays() async throws {
        let now = ISO8601DateFormatter().date(from: "2026-11-24T09:00:00Z")!
        var runs: [JSONValue] = []
        for i in 0..<23 { runs.append(run("M-SAMPLE", String(format: "2026-11-%02d", 1 + i % 20), "finished")) }
        runs += [run("M-SAMPLE", "2026-11-10", "failed"), run("M-SAMPLE", "2026-11-12", "failed")]
        runs += (0..<3).map { _ in run("M-SAMPLE", "2026-11-15", "cancelled") }
        runs.append(run("M-SAMPLE", "2026-09-01", "failed"))      // before the window
        runs.append(run("M-OTHER", "2026-11-15", "failed"))       // another printer
        var store = SampleShop.book()
        store["machines"] = .array([.object(["id": .string("M-SAMPLE"), "name": .string("Sample MK4")]),
                                    .object(["id": .string("M-OTHER"), "name": .string("Sample U1")])])
        store["printLog"] = .array([.object(["id": .string("J-1"), "project": .string("Sample job"), "status": .string("completed"),
                                             "printRuns": .array(runs)])])
        let reader = BookReader(book: try book(store))
        let got = try await reader.machineSuccess(machineId: "M-SAMPLE", now: now)
        let s = try XCTUnwrap(got)
        XCTAssertEqual([s.finished, s.failed, s.cancelled], [23, 2, 3])
        XCTAssertTrue(s.enough)
        XCTAssertEqual(s.needed, 5)
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(.system) }
        XCTAssertEqual(s.percent, "92%")
        XCTAssertEqual(s.detail, "23 finished, 2 failed · 3 cancelled not counted")
        // A printer in the book with no runs at all shows no card.
        var idle = store
        if case .array(var ms)? = idle["machines"] { ms.append(.object(["id": .string("M-IDLE")])); idle["machines"] = .array(ms) }
        let idleDir = dir.appending(path: "idle", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: idleDir, withIntermediateDirectories: true)
        let idleBook = CompanionBook(directory: idleDir)
        try idleBook.replace(with: idle, scope: nil)
        let never = try await BookReader(book: idleBook).machineSuccess(machineId: "M-IDLE", now: now)
        XCTAssertNil(never, "no runs: no card, not \"0 of 5 needed\"")
        let other = try await reader.machineSuccess(machineId: "M-OTHER", now: now)
        XCTAssertNil(other?.percent, "one failed print is not a 0% printer")
        XCTAssertEqual(other?.detail, "Not enough prints yet: 1 of 5 needed")
        let none = try await reader.machineSuccess(machineId: "M-NOPE", now: now)
        XCTAssertNil(none, "a machine the book does not have shows no card")
    }

    func testTheWindowIsThirtyBookDays() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-11-24T09:00:00Z")!
        let w = MachineSuccess.window(now: now, zone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(w.to, "2026-11-24")
        XCTAssertEqual(w.from, "2026-10-26", "today and the 29 days before it: thirty days")
    }

    /// The apps write a run's `at` as a full UTC timestamp. The window is the
    /// SHOP's days, so an evening print west of UTC and an early one east of
    /// it are counted on the day the shop saw them (review of #2698).
    func testARunIsCountedOnTheShopsOwnDay() throws {
        let west = try XCTUnwrap(TimeZone(identifier: "America/New_York")), east = try XCTUnwrap(TimeZone(identifier: "Asia/Riyadh"))
        XCTAssertEqual(MachineSuccess.localDay(ofRun: "2026-11-25T01:00:00.000Z", zone: west), "2026-11-24", "20:00 on the 24th in New York")
        XCTAssertEqual(MachineSuccess.localDay(ofRun: "2026-10-25T23:30:00.000Z", zone: east), "2026-10-26", "02:30 on the 26th in Riyadh")
        XCTAssertEqual(MachineSuccess.localDay(ofRun: "2026-11-24T09:00:00Z", zone: east), "2026-11-24", "no fraction")
        XCTAssertEqual(MachineSuccess.localDay(ofRun: "2026-11-24", zone: west), "2026-11-24", "a bare day is a day")
        XCTAssertNil(MachineSuccess.localDay(ofRun: "yesterday", zone: west))

        func job(_ id: String, _ runs: [JSONValue], deleted: Bool = false) -> JSONValue {
            .object(["id": .string(id), "client": .string("Sample customer"), "price": .number(120), "deleted": .bool(deleted),
                     "printRuns": .array(runs)])
        }
        let log = [job("J-1", [run("M-1", "2026-11-25T01:00:00.000Z", "finished"),      // tonight, west of UTC: counted
                               run("M-1", "2026-11-25T06:00:00.000Z", "failed"),        // tomorrow there too: not yet
                               run("M-2", "2026-11-24T12:00:00.000Z", "failed")]),      // another printer
                   job("J-2", [run("M-2", "2026-11-24T12:00:00.000Z", "finished")]),    // none on this printer: left out whole
                   .object(["id": .string("J-3")])]                                     // never printed
        let counted = MachineSuccess.orders(log, machineId: "M-1", from: "2026-10-26", to: "2026-11-24", zone: west)
        XCTAssertEqual(counted.count, 1)
        guard case .object(let o) = counted[0], case .array(let runs)? = o["printRuns"] else { return XCTFail("shape") }
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(Set(o.keys), ["id", "deleted", "printRuns"], "only what the rule counts crosses into JavaScript")
    }

    /// The figure is the shared rule's, through the phone's engine: the
    /// phone rounds nothing itself.
    func testThePercentIsTheSharedRules() async throws {
        let engine = try await BookReader(book: try book(SampleShop.book())).sharedEngine()
        func whole(_ rate: Double?) async throws -> Int? { try await engine.successPercent(rate) }
        let cases: [(Double?, Int?)] = [(0.995, 99), (1, 100), (0.005, 1), (0.003, 1), (0, 0), (0.833, 83), (0.5, 50), (nil, nil), (1.2, nil), (-0.1, nil)]
        for (rate, want) in cases {
            let got = try await whole(rate)
            XCTAssertEqual(got, want, "\(String(describing: rate))")
        }
    }

    func testTheCardsWords() {
        L10n.setLanguage(.en)
        defer { L10n.setLanguage(.system) }
        let few = MachineSuccess(finished: 2, failed: 1, cancelled: 0, rate: 0.667, enough: false, needed: 5, whole: 67)
        XCTAssertNil(few.percent, "the frame's dash: too few prints to say, whatever the figure")
        XCTAssertEqual(few.detail, "Not enough prints yet: 3 of 5 needed")
        let clean = MachineSuccess(finished: 9, failed: 0, cancelled: 0, rate: 1, enough: true, needed: 5, whole: 100)
        XCTAssertEqual(clean.percent, "100%")
        XCTAssertEqual(clean.detail, "9 finished, 0 failed", "no cancelled part when none were")
        XCTAssertNil(MachineSuccess(finished: 0, failed: 0, cancelled: 4, rate: nil, enough: false, needed: 5, whole: nil).percent)
        XCTAssertNil(MachineSuccess(finished: 6, failed: 0, cancelled: 0, rate: 1, enough: true, needed: 5, whole: nil).percent, "no figure: the dash")
        XCTAssertEqual(L10n.format("success.window", "Prusa MK4"), "Prusa MK4 · last 30 days")
    }

    func testTheWordsAreInAllNineLanguages() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for lang in ["en", "ar", "de", "es", "fr", "ja", "pt-BR", "tr", "zh-Hans"] {
            let url = root.appending(path: "KhaytCompanion/Resources/\(lang).lproj/Localizable.strings")
            let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], lang)
            for key in ["success.title", "success.window", "success.counts", "success.cancelled", "success.not_enough"] {
                XCTAssertFalse((table[key] ?? "").isEmpty, "\(lang): \(key)")
            }
            for key in ["success.counts", "success.not_enough"] {
                XCTAssertTrue(table[key]!.contains("%1$d") && table[key]!.contains("%2$d"), "\(lang): \(key) names both numbers")
            }
        }
    }
}
