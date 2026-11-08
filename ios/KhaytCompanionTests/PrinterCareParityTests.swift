import XCTest
import JavaScriptCore
import KhaytCore
@testable import KhaytCompanion

/**
 * The phone's printer-care rules against the shop's own.
 *
 * `CareRules` is a Swift port of `lib/maintenance.js` and the parts list of
 * `lib/care-plans.js`. Nothing here is a copied expectation: every answer is
 * asked of the REAL JavaScript, loaded out of `lib/` into JavaScriptCore, and
 * the Swift must give the same one. Change the rule and this fails.
 *
 * The fixtures span every case the card can draw: each status tier on the
 * hours clock and the date clock, each clock alone and both together, a task
 * that was never done, a deferral that is active, one that a later
 * completion superseded, values stored as strings and nulls, and a parts
 * list whose rows order on several different days.
 */
final class PrinterCareParityTests: XCTestCase {

    // 2026-11-07T09:00:00Z, a fixed now.
    let nowMs = 1_794_042_000_000.0
    let day = 86_400_000.0

    private var js: JSContext!

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let ctx = try XCTUnwrap(JSContext())
        var thrown: String?
        ctx.exceptionHandler = { _, e in thrown = e?.toString() }
        for file in ["lib/maintenance.js", "lib/care-plans.js"] {
            let source = try String(contentsOf: root.appending(path: file), encoding: .utf8)
            ctx.evaluateScript(source)
            XCTAssertNil(thrown, "\(file) did not load: \(thrown ?? "")")
        }
        js = ctx
    }

    // MARK: - Asking the JavaScript

    private func text(_ v: JSONValue) -> String {
        String(data: try! JSONEncoder().encode(v), encoding: .utf8)!
    }

    private func ask(_ expression: String) throws -> JSONValue {
        let out = try XCTUnwrap(js.evaluateScript("JSON.stringify(\(expression))")?.toString(), expression)
        return try JSONDecoder().decode(JSONValue.self, from: Data(out.utf8))
    }

    private func iso(_ offsetDays: Double) -> JSONValue { .string(CareRules.iso(ms: nowMs + offsetDays * day)) }

    private func close(_ a: Double?, _ b: JSONValue?, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        switch (a, b) {
        case (nil, nil), (nil, .null?): return
        case (let x?, .number(let y)?): XCTAssertEqual(x, y, accuracy: 1e-6, what, file: file, line: line)
        default: XCTFail("\(what): swift \(String(describing: a)) js \(String(describing: b))", file: file, line: line)
        }
    }

    // MARK: - Fixtures

    private var tasks: [[String: JSONValue]] {
        [
            // Hours only, across every tier at the meters below.
            ["id": .string("h"), "machineId": .string("A"), "intervalHours": .number(100), "lastDoneHours": .number(0)],
            // Hours as a string and a null days, as an older writer leaves them.
            ["id": .string("hs"), "machineId": .string("A"), "intervalHours": .string("80"), "intervalDays": .null,
             "lastDoneHours": .string("10")],
            // Days only: ok, warning, due, overdue.
            ["id": .string("d-ok"), "machineId": .string("A"), "intervalDays": .number(30), "lastDoneAt": iso(-10)],
            ["id": .string("d-warn"), "machineId": .string("A"), "intervalDays": .number(30), "lastDoneAt": iso(-28)],
            ["id": .string("d-due"), "machineId": .string("A"), "intervalDays": .number(30), "lastDoneAt": iso(-31)],
            ["id": .string("d-over"), "machineId": .string("A"), "intervalDays": .number(30), "lastDoneAt": iso(-50)],
            // Days, never done: the full interval left, ok.
            ["id": .string("d-never"), "machineId": .string("A"), "intervalDays": .number(14)],
            // A bare date, which JavaScript reads as UTC midnight.
            ["id": .string("d-bare"), "machineId": .string("A"), "intervalDays": .number(7),
             "lastDoneAt": .string("2026-10-30")],
            // Both clocks: the worse one wins either way round.
            ["id": .string("both-h"), "machineId": .string("A"), "intervalHours": .number(50), "intervalDays": .number(90),
             "lastDoneHours": .number(0), "lastDoneAt": iso(-5)],
            ["id": .string("both-d"), "machineId": .string("A"), "intervalHours": .number(1000), "intervalDays": .number(10),
             "lastDoneHours": .number(20), "lastDoneAt": iso(-16)],
            // Neither clock.
            ["id": .string("none"), "machineId": .string("A"), "intervalHours": .number(0), "intervalDays": .null],
            // A deferral, active: inspected after the last completion.
            ["id": .string("def-h"), "machineId": .string("A"), "intervalHours": .number(100), "lastDoneHours": .number(0),
             "lastDoneAt": iso(-40), "inspectedAt": iso(-2), "inspectedHours": .number(95),
             "deferUntilHours": .number(145), "deferUntilAt": .null],
            ["id": .string("def-d"), "machineId": .string("A"), "intervalDays": .number(30), "lastDoneAt": iso(-45),
             "inspectedAt": iso(-1), "inspectedHours": .number(0), "deferUntilHours": .null, "deferUntilAt": iso(14)],
            ["id": .string("def-both"), "machineId": .string("A"), "intervalHours": .number(60), "intervalDays": .number(20),
             "lastDoneHours": .number(10), "lastDoneAt": iso(-30), "inspectedAt": iso(-3), "inspectedHours": .number(70),
             "deferUntilHours": .string("100"), "deferUntilAt": iso(4)],
            // A deferral superseded: done again after the inspection.
            ["id": .string("def-gone"), "machineId": .string("A"), "intervalDays": .number(30), "lastDoneAt": iso(-1),
             "inspectedAt": iso(-6), "deferUntilAt": iso(40), "deferUntilHours": .null],
            // An inspection that pushed nothing out is no deferral.
            ["id": .string("def-empty"), "machineId": .string("A"), "intervalDays": .number(30), "lastDoneAt": iso(-40),
             "inspectedAt": iso(-1), "deferUntilHours": .string(""), "deferUntilAt": .null],
        ]
    }

    private var jobs: [JSONValue] {
        func job(_ id: String, _ machine: JSONValue?, _ status: String, _ hours: JSONValue?,
                 completed: Double? = nil, date: String? = nil) -> JSONValue {
            var o: [String: JSONValue] = ["id": .string(id), "status": .string(status)]
            if let machine { o["machineId"] = machine }
            if let hours { o["printTime"] = hours }
            if let completed { o["completedAt"] = iso(completed) }
            if let date { o["date"] = .string(date) }
            return .object(o)
        }
        return [
            job("j1", .string("A"), "completed", .number(12.5), completed: -3),
            job("j2", .string("A"), "delivered", .string("7"), completed: -12),
            job("j3", .string("A"), "printing", .number(40)),
            job("j4", .string("A"), "cancelled", .number(9), completed: -1),
            job("j5", .string("A"), "completed", .number(30), date: "2026-08-01"),
            job("j6", .string("A"), "completed", .null, completed: -2),
            job("j7", .string("B"), "completed", .number(4), completed: -5),
            job("j8", .string("B"), "completed", .number(-2), completed: -4),
            job("j9", .number(5), "completed", .number(100), completed: -1),
            job("j10", .string("C"), "completed", .number(20), completed: 2),
            job("j11", .string("A"), "completed", .number(3), date: "2026-11-01"),
        ]
    }

    // MARK: - lib/maintenance.js

    func testTaskStatusMatchesTheRuleAtEveryMeter() throws {
        var tiers = Set<String>()
        for task in tasks {
            for meter in [0.0, 50, 89.9, 90, 100, 120, 149.9, 150, 400] {
                let swift = CareRules.taskStatus(task, machineHours: meter, nowMs: nowMs)
                let rule = try ask("KhaytMaintenance.taskStatus(\(text(.object(task))), \(meter), \(nowMs))")
                guard case .object(let o) = rule else { return XCTFail("no answer") }
                let what = "\(task["id"]!) at \(meter)"
                XCTAssertEqual(o["status"], .string(swift.status), what)
                XCTAssertEqual(o["deferred"], .bool(swift.deferred), what)
                close(swift.hoursRemaining, o["hoursRemaining"], what + " hours")
                close(swift.daysRemaining, o["daysRemaining"], what + " days")
                tiers.insert(swift.status)
            }
        }
        XCTAssertEqual(tiers, ["ok", "warning", "due", "overdue"], "the fixtures stopped reaching a tier")
    }

    func testActiveDeferralMatches() throws {
        for task in tasks {
            let swift = CareRules.activeDeferral(task)
            let rule = try ask("KhaytMaintenance.activeDeferral(\(text(.object(task))))")
            if case .object(let o) = rule {
                let d = try XCTUnwrap(swift, "\(task["id"]!): the rule has a deferral")
                close(d.untilHours, o["untilHours"], "\(task["id"]!) untilHours")
                close(d.untilMs, o["untilMs"], "\(task["id"]!) untilMs")
            } else {
                XCTAssertNil(swift, "\(task["id"]!): the rule has none")
            }
        }
        XCTAssertNotNil(CareRules.activeDeferral(tasks.first { $0["id"] == .string("def-d") }!))
        XCTAssertNil(CareRules.activeDeferral(tasks.first { $0["id"] == .string("def-gone") }!))
    }

    func testDeferTaskWritesTheSamePatch() throws {
        let nowIso = CareRules.iso(ms: nowMs)
        for task in tasks {
            for meter in [0.0, 95, 160] {
                let swift = CareRules.deferTask(task, machineHours: meter, nowIso: nowIso)
                let rule = try ask("KhaytMaintenance.deferTask(\(text(.object(task))), \(meter), '\(nowIso)')")
                guard case .object(let o) = rule else { return XCTFail("no answer") }
                let what = "\(task["id"]!) at \(meter)"
                XCTAssertEqual(Set(o.keys), Set(swift.keys), what)
                XCTAssertEqual(o["inspectedAt"], swift["inspectedAt"], what)
                XCTAssertEqual(o["deferUntilAt"], swift["deferUntilAt"], what)
                if case .number(let h)? = swift["deferUntilHours"] { close(h, o["deferUntilHours"], what) }
                else { XCTAssertEqual(o["deferUntilHours"], .null, what) }
                if case .number(let h)? = swift["inspectedHours"] { close(h, o["inspectedHours"], what) }
            }
        }
    }

    /// Done after "not needed": markDone's two fields alone, and the rule
    /// then reads the deferral as superseded, in both languages.
    func testMarkDoneSupersedesADeferral() throws {
        let nowIso = CareRules.iso(ms: nowMs)
        var task = tasks.first { $0["id"] == .string("def-both") }!
        let swift = CareRules.markDone(machineHours: 123.5, nowIso: nowIso)
        let rule = try ask("KhaytMaintenance.markDone(\(text(.object(task))), 123.5, '\(nowIso)')")
        XCTAssertEqual(rule, .object(swift))
        for (k, v) in swift { task[k] = v }
        XCTAssertNil(CareRules.activeDeferral(task))
        XCTAssertEqual(try ask("KhaytMaintenance.activeDeferral(\(text(.object(task))))"), .null)
        let st = CareRules.taskStatus(task, machineHours: 123.5, nowMs: nowMs)
        XCTAssertFalse(st.deferred)
        XCTAssertEqual(st.status, "ok")
    }

    func testHoursMeterAndRateMatch() throws {
        for machine in ["A", "B", "C", "5", "Z"] {
            let meter = CareRules.hoursMeter(jobs, machineId: machine)
            close(meter, try ask("KhaytMaintenance.hoursMeter(\(text(.array(jobs))), '\(machine)')"), "meter \(machine)")
            for window in [30.0, 7, 120] {
                let rate = CareRules.hoursPerDay(jobs, machineId: machine, nowMs: nowMs, windowDays: window)
                close(rate, try ask("KhaytMaintenance.hoursPerDay(\(text(.array(jobs))), '\(machine)', \(nowMs), \(window))"),
                      "rate \(machine) over \(window)")
            }
        }
        // The Mac's whole-book meters are the same sum.
        let byMachine = BookScope.hoursByMachine(jobs)
        for machine in ["A", "B", "C"] {
            close(byMachine[machine] ?? 0, try ask("KhaytMaintenance.hoursMeter(\(text(.array(jobs))), '\(machine)')"),
                  "BookScope meter \(machine)")
        }
        XCTAssertNil(byMachine["5"], "a numeric machine id is no machine to the rule")
    }

    func testProjectDueMatches() throws {
        for task in tasks {
            for (meter, rate) in [(0.0, 0.0), (60, 2.5), (150, 1), (95, 0.4)] {
                let swift = CareRules.projectDue(task, meter: meter, rate: rate, nowMs: nowMs)
                let rule = try ask("KhaytMaintenance.projectDue(\(text(.object(task))), \(meter), \(rate), \(nowMs))")
                guard case .object(let o) = rule else { return XCTFail("no answer") }
                let what = "\(task["id"]!) \(meter)/\(rate)"
                close(swift.dueMs, o["dueMs"], what)
                XCTAssertEqual(o["dueAt"], swift.dueAt.map { .string($0) } ?? .null, what)
                XCTAssertEqual(o["clock"], swift.clock.map { .string($0) } ?? .null, what)
                XCTAssertEqual(o["status"], .string(swift.status), what)
                XCTAssertEqual(o["deferred"], .bool(swift.deferred), what)
            }
        }
    }

    // MARK: - lib/care-plans.js

    func testThePartsCatalogueIsTheRules() throws {
        let rule = try ask("KhaytCarePlans.parts()")
        let expected: JSONValue = .array(CareRules.parts.map {
            .object(["id": .string($0.id), "unit": .string($0.unit), "leadDays": .number($0.leadDays)])
        })
        XCTAssertEqual(rule, expected)
    }

    func testPartsBuyListMatchesWithSeveralOrderByDates() throws {
        func task(_ id: String, _ machine: String, _ extra: [String: JSONValue], parts: [(String, JSONValue)]) -> JSONValue {
            var o: [String: JSONValue] = ["id": .string(id), "machineId": .string(machine), "name": .string("Task " + id),
                                          "careTaskId": .string(id.lowercased())]
            o["parts"] = .array(parts.map { .object(["id": .string($0.0), "qty": $0.1]) })
            for (k, v) in extra { o[k] = v }
            return .object(o)
        }
        let machines: [JSONValue] = [
            .object(["id": .string("A"), "name": .string("Bravo X1")]),
            .object(["id": .string("B"), "name": .string("Alpha MK4")]),
            .object(["id": .string("R"), "name": .string("Retired one"), "status": .string("retired")]),
            .object(["id": .string("Q"), "name": .string("Gone too"), "retiredAt": .string("2026-01-01")]),
        ]
        let list: [JSONValue] = [
            // Overdue now: order now (late), two parts.
            task("T1", "A", ["intervalDays": .number(30), "lastDoneAt": iso(-50)],
                 parts: [("nozzle", .number(2)), ("ptfe_tube", .null)]),
            // Due in 20 days, a 14-day part: order in 6.
            task("T2", "B", ["intervalDays": .number(60), "lastDoneAt": iso(-40)], parts: [("carbon_filter", .number(1))]),
            // Hours, projected by the machine's rate.
            task("T3", "A", ["intervalHours": .number(100), "lastDoneHours": .number(0)], parts: [("grease", .string("1"))]),
            // Beyond the 90-day horizon: not listed.
            task("T4", "B", ["intervalDays": .number(365), "lastDoneAt": iso(-10)], parts: [("oil", .number(1))]),
            // Unknown parts dropped; a zero quantity reads as one.
            task("T5", "B", ["intervalDays": .number(10), "lastDoneAt": iso(-3)],
                 parts: [("unobtainium", .number(1)), ("ipa", .number(0))]),
            // On a retired machine, and on no machine.
            task("T6", "R", ["intervalDays": .number(5), "lastDoneAt": iso(-9)], parts: [("nozzle", .number(1))]),
            task("T7", "Q", ["intervalDays": .number(5), "lastDoneAt": iso(-9)], parts: [("nozzle", .number(1))]),
            task("T8", "Nope", ["intervalDays": .number(5), "lastDoneAt": iso(-9)], parts: [("nozzle", .number(1))]),
            // Deferred out by a week.
            task("T9", "A", ["intervalDays": .number(30), "lastDoneAt": iso(-40), "inspectedAt": iso(-1),
                             "deferUntilAt": iso(7), "deferUntilHours": .null], parts: [("fep_film", .number(1))]),
            // Hours on a machine with no recent jobs: nothing to project.
            task("T10", "B", ["intervalHours": .number(100), "lastDoneHours": .number(0)], parts: [("rail_lube", .number(1))]),
        ]
        let swift = CareRules.partsBuyList(machines: machines, tasks: list, jobs: jobs, nowMs: nowMs)
        let rule = try ask("KhaytCarePlans.partsBuyList({ machines: \(text(.array(machines))), tasks: \(text(.array(list))), "
                           + "jobs: \(text(.array(jobs))), now: \(nowMs) })")
        guard case .array(let rows) = rule else { return XCTFail("no list") }
        XCTAssertEqual(rows.count, swift.count)
        for (r, s) in zip(rows, swift) {
            guard case .object(let o) = r else { continue }
            let what = "\(s.taskId)/\(s.partId)"
            XCTAssertEqual(o["partId"], .string(s.partId), what)
            XCTAssertEqual(o["unit"], .string(s.unit), what)
            close(s.qty, o["qty"], what + " qty")
            XCTAssertEqual(o["machineId"], .string(s.machineId), what)
            XCTAssertEqual(o["machineName"], .string(s.machineName), what)
            XCTAssertEqual(o["taskId"], .string(s.taskId), what)
            XCTAssertEqual(o["careTaskId"], s.careTaskId.map { .string($0) } ?? .null, what)
            XCTAssertEqual(o["taskName"], .string(s.taskName), what)
            XCTAssertEqual(o["dueAt"], .string(s.dueAt), what)
            XCTAssertEqual(o["orderBy"], .string(s.orderBy), what)
            close(s.leadDays, o["leadDays"], what + " lead")
            XCTAssertEqual(o["late"], .bool(s.late), what)
            XCTAssertEqual(o["status"], .string(s.status), what)
            XCTAssertEqual(o["clock"], s.clock.map { .string($0) } ?? .null, what)
        }
        XCTAssertGreaterThanOrEqual(Set(swift.map { String($0.orderBy.prefix(10)) }).count, 4,
                                    "the fixture stopped spreading order-by dates")
        XCTAssertTrue(swift.contains(where: \.late) && swift.contains(where: { !$0.late }))

        // A shop's own lead times, too.
        let lead = ["nozzle": 2.0, "carbon_filter": 30]
        let mine = CareRules.partsBuyList(machines: machines, tasks: list, jobs: jobs, nowMs: nowMs, leadDays: lead)
        let theirs = try ask("KhaytCarePlans.partsBuyList({ machines: \(text(.array(machines))), tasks: \(text(.array(list))), "
                             + "jobs: \(text(.array(jobs))), now: \(nowMs), leadDays: { nozzle: 2, carbon_filter: 30 } })")
        guard case .array(let rows2) = theirs else { return XCTFail("no list") }
        XCTAssertEqual(rows2.map { r -> String in
            if case .object(let o) = r, case .string(let t)? = o["taskId"], case .string(let p)? = o["partId"],
               case .string(let b)? = o["orderBy"] { return t + p + b }
            return ""
        }, mine.map { $0.taskId + $0.partId + $0.orderBy })
    }
}

/// The writes and the book around the rules.
@MainActor
final class PrinterCareBookTests: XCTestCase {

    private var dir: URL!
    private var book: CompanionBook!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "care-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = CompanionBook(directory: dir)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func shop(jobs: [JSONValue], tasks: [JSONValue]) -> [String: JSONValue] {
        [
            "machines": .array([.object(["id": .string("M1"), "name": .string("Printer one")])]),
            "printLog": .array(jobs),
            "machMaintTasks": .array(tasks),
        ]
    }

    private func job(_ id: String, _ hours: Double) -> JSONValue {
        .object(["id": .string(id), "machineId": .string("M1"), "status": .string("completed"),
                 "printTime": .number(hours), "rev": .number(1)])
    }

    private let nozzle: JSONValue = .object([
        "id": .string("T1"), "machineId": .string("M1"), "name": .string("Replace nozzle"),
        "intervalHours": .number(100), "lastDoneHours": .number(0), "rev": .number(3),
        "inspectedAt": .string("2026-11-01T00:00:00.000Z"), "inspectedHours": .number(90),
        "deferUntilHours": .number(140), "deferUntilAt": .null,
    ])

    private func whole(_ store: [String: JSONValue]) -> BookScope.Taken {
        var held: [String: BookScope.Taken.Held] = [:]
        for (k, v) in store { if case .array(let r) = v { held[k] = .init(whole: true, sent: r.count, available: nil) } }
        return BookScope.Taken(collections: held, omitted: [], takenAt: "2026-11-07T00:00:00.000Z")
    }

    private func record(_ collection: String, _ id: String) throws -> [String: JSONValue] {
        guard case .array(let rows)? = try book.read()[collection] else { throw XCTSkip("no \(collection)") }
        for case .object(let o) in rows where o["id"] == .string(id) { return o }
        throw XCTSkip("no \(id)")
    }

    func testDoneWritesMarkDonesFieldsAndAServiceLine() throws {
        let store = shop(jobs: [job("J1", 60), job("J2", 50.5)], tasks: [nozzle])
        try book.replace(with: store, scope: whole(store))
        try book.replaceBaseline(with: store)
        let now = Date(timeIntervalSince1970: 1_794_042_000)
        try BookWriter(book: book).markCareTaskDone(taskId: "T1", now: now)

        let task = try record("machMaintTasks", "T1")
        XCTAssertEqual(task["lastDoneHours"], .number(110.5))
        XCTAssertEqual(task["lastDoneAt"], .string("2026-11-07T09:00:00.000Z"))
        XCTAssertEqual(task["rev"], .number(4), "stamped, or the Mac's older copy wins the merge")
        XCTAssertEqual(task["deferUntilHours"], .number(140), "markDone leaves the deferral; lastDoneAt supersedes it")
        XCTAssertNil(CareRules.activeDeferral(task))

        guard case .array(let log)? = try book.read()["machMaintLog"], case .object(let line)? = log.first else {
            return XCTFail("no service logged")
        }
        XCTAssertEqual(Set(line.keys), ["id", "machineId", "date", "note", "cost", "rev", "updatedAt"])
        XCTAssertEqual(line["machineId"], .string("M1"))
        XCTAssertEqual(line["note"], .string("Replace nozzle"))
        XCTAssertEqual(line["cost"], .number(0))
        XCTAssertEqual(line["date"], .string(BookWriter.localDay(now)))
        XCTAssertEqual(line["rev"], .number(1))
        if case .string(let id)? = line["id"] { XCTAssertTrue(id.hasPrefix("MAINT-")) }
    }

    func testNotNeededWritesTheDeferralAndNoServiceLine() throws {
        let store = shop(jobs: [job("J1", 120)], tasks: [nozzle])
        try book.replace(with: store, scope: whole(store))
        try book.replaceBaseline(with: store)
        let now = Date(timeIntervalSince1970: 1_794_042_000)
        try BookWriter(book: book).deferCareTask(taskId: "T1", now: now)

        let task = try record("machMaintTasks", "T1")
        XCTAssertEqual(task["inspectedAt"], .string("2026-11-07T09:00:00.000Z"))
        XCTAssertEqual(task["inspectedHours"], .number(120))
        XCTAssertEqual(task["deferUntilHours"], .number(170))
        XCTAssertEqual(task["deferUntilAt"], .null)
        XCTAssertEqual(task["lastDoneHours"], .number(0), "not needed is not done")
        XCTAssertNil(task["lastDoneAt"])
        XCTAssertNil(try book.read()["machMaintLog"], "nothing was serviced")
        XCTAssertTrue(CareRules.taskStatus(task, machineHours: 120, nowMs: CareRules.ms(now)).deferred)
    }

    func testACutBookCountsTheMacsMetersPlusWhatHappenedHere() throws {
        // The Mac counted 900 hours; the phone was sent one job of them and
        // has finished another since.
        let arrived = shop(jobs: [job("J1", 10)], tasks: [nozzle])
        var scope = whole(arrived)
        var held = scope.collections
        held["printLog"] = .init(whole: false, sent: 1, available: 400)
        scope = BookScope.Taken(collections: held, omitted: [], takenAt: scope.takenAt, meters: ["M1": 900])
        try book.replace(with: arrived, scope: scope)
        try book.replaceBaseline(with: arrived)
        try book.update { root in root["printLog"] = .array([job("J1", 10), job("J9", 4)]) }

        let care = try XCTUnwrap(Optional(CareBook(store: try book.read(), baseline: book.baseline(),
                                                    scope: book.scope(), now: Date())))
        XCTAssertEqual(care.meters["M1"] ?? nil, 904)
        try BookWriter(book: book).markCareTaskDone(taskId: "T1")
        XCTAssertEqual(try record("machMaintTasks", "T1")["lastDoneHours"], .number(904))
    }

    /// A cut book as a current Mac (or the phone's own cloud pull) sends it:
    /// 900 hours over the whole book, 10 of them on the one job sent.
    private func cutWithSnapshot() throws {
        let arrived = shop(jobs: [job("J1", 10)], tasks: [nozzle])
        var held = whole(arrived).collections
        held["printLog"] = .init(whole: false, sent: 1, available: 400)
        try book.replace(with: arrived, scope: BookScope.Taken(collections: held, omitted: [], takenAt: "2026-11-07T00:00:00.000Z",
                                                               meters: ["M1": 900], metersHeld: ["M1": 10]))
        try book.replaceBaseline(with: arrived)
    }

    /// A cloud change folds into the book AND the baseline (`CloudSync.pull`),
    /// so a meter measured against the baseline never moved for it — on a
    /// phone signed in to the cloud the meter froze at the last Mac pull.
    func testAFinishedJobArrivingByCloudChangeRaisesTheMeter() throws {
        try cutWithSnapshot()
        let after: [JSONValue] = [job("J1", 10), job("J5", 6)]
        try book.update { root in root["printLog"] = .array(after) }
        var baseline = try XCTUnwrap(book.baseline())
        baseline["printLog"] = .array(after)
        try book.replaceBaseline(with: baseline)

        let care = CareBook(store: try book.read(), baseline: book.baseline(), scope: book.scope(), now: Date())
        XCTAssertEqual(care.meters["M1"] ?? nil, 906, "the cloud's finished job did not move the meter")
    }

    func testAJobFinishedOnThePhoneRaisesTheMeter() throws {
        try cutWithSnapshot()
        try book.update { root in root["printLog"] = .array([job("J1", 10), job("J9", 4)]) }
        let care = CareBook(store: try book.read(), baseline: book.baseline(), scope: book.scope(), now: Date())
        XCTAssertEqual(care.meters["M1"] ?? nil, 904)
        try BookWriter(book: book).markCareTaskDone(taskId: "T1")
        XCTAssertEqual(try record("machMaintTasks", "T1")["lastDoneHours"], .number(904))
    }

    func testACutBookWithNoMetersRefusesRatherThanGuess() throws {
        let store = shop(jobs: [job("J1", 10)], tasks: [nozzle])
        var held = whole(store).collections
        held["printLog"] = .init(whole: false, sent: 1, available: 400)
        try book.replace(with: store, scope: BookScope.Taken(collections: held, omitted: [], takenAt: "x"))
        try book.replaceBaseline(with: store)
        let care = CareBook(store: try book.read(), baseline: book.baseline(), scope: book.scope(), now: Date())
        XCTAssertTrue(care.tasks(for: "M1").allSatisfy(\.hoursUnknown))
        XCTAssertThrowsError(try BookWriter(book: book).markCareTaskDone(taskId: "T1")) {
            XCTAssertEqual($0 as? BookWriter.Refusal, .careHoursUnknown)
        }
        XCTAssertThrowsError(try BookWriter(book: book).deferCareTask(taskId: "nope"))
    }

    func testTheMacSendsMetersOnlyWhenItCutsTheJobs() {
        var many: [JSONValue] = []
        for i in 0..<230 { many.append(job("J\(i)", 1)) }
        let cut = BookScope.take(from: shop(jobs: many, tasks: [nozzle]))
        XCTAssertEqual(cut.taken.meters?["M1"], 230)
        if case .array(let t)? = cut.store["machMaintTasks"] { XCTAssertEqual(t.count, 1) } else { XCTFail("tasks not sent") }
        XCTAssertNil(BookScope.take(from: shop(jobs: [job("J1", 1)], tasks: [])).taken.meters)
    }

    func testTheSampleShopHasSomethingDueAndOverdue() {
        let now = Date()
        let store = SampleShop.book(now: now)
        let care = CareBook(store: store, baseline: store, scope: SampleShop.scope(now: now), now: now)
        let x1c = care.tasks(for: "M-X1C").map(\.status.status)
        XCTAssertEqual(Array(x1c.prefix(2)), ["overdue", "due"], "worst first")
        XCTAssertTrue(care.tasks(for: "M-SAT").contains { $0.status.deferred })
        XCTAssertGreaterThanOrEqual(Set(care.buyList.map { String($0.orderBy.prefix(10)) }).count, 3)
        XCTAssertEqual(care.buyList.map(\.orderByMs), care.buyList.map(\.orderByMs).sorted())
    }

    /// Every word the care screens say, in all nine languages.
    func testEveryCareWordIsInEveryLanguage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let en = try XCTUnwrap(NSDictionary(contentsOf: root.appending(path: "KhaytCompanion/Resources/en.lproj/Localizable.strings")) as? [String: String])
        let keys = en.keys.filter { $0.hasPrefix("care.") }
        XCTAssertGreaterThan(keys.count, 30)
        for part in CareRules.parts { XCTAssertNotNil(en["care.part." + part.id], part.id) }
        for lang in ["ar", "de", "es", "fr", "ja", "pt-BR", "tr", "zh-Hans"] {
            let table = try XCTUnwrap(NSDictionary(contentsOf: root.appending(path: "KhaytCompanion/Resources/\(lang).lproj/Localizable.strings")) as? [String: String])
            for k in keys { XCTAssertNotNil(table[k], "\(lang): \(k)") }
        }
        let ar = try XCTUnwrap(NSDictionary(contentsOf: root.appending(path: "KhaytCompanion/Resources/ar.lproj/Localizable.strings")) as? [String: String])
        for k in keys { XCTAssertFalse(ar[k]!.contains("خيط"), "the app is Khayt in Latin letters: \(k)") }
    }
}
