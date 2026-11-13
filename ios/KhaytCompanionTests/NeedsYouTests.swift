import XCTest
@testable import KhaytCompanion

/// Home's "Needs you" (Figma Qqxg4imtKVgC3TfNGcRGOk 91:1156, "Rules every app
/// keeps"): one row per kind, at most five, late first, nothing → calm, and
/// late counted by the open-only `isOverdue`.
final class NeedsYouTests: XCTestCase {

    override func setUp() { L10n.setLanguage(.en) }
    override func tearDown() { L10n.setLanguage(.system) }

    private func day(_ offset: Int) -> String {
        let cal = Calendar(identifier: .gregorian)
        let d = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date()))!
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = cal
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    private func job(_ id: String, _ status: String = "pending", due: Int? = nil,
                     machine: String? = nil, voided: Bool = false) -> QueueOrder {
        var o = QueueOrder(id: id, project: "Job \(id)", client: "Client", status: status,
                           machine: nil, machineId: machine, dueDate: due.map(day), priority: nil)
        o.voided = voided
        return o
    }

    private func decode<T: Decodable>(_ json: String) -> T {
        try! JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    private func spool(_ id: String, grams: Double) -> InventorySpool {
        decode(#"{"id":"\#(id)","brand":"Bambu","material":"PLA","weight":\#(grams)}"#)
    }

    private func request(_ id: String, _ name: String) -> WaitingListItem {
        decode(#"{"id":"\#(id)","clientName":"\#(name)"}"#)
    }

    private func quote(_ id: String) -> OrderLogEntry {
        decode(#"{"id":"\#(id)","project":"Quote \#(id)","status":"quote"}"#)
    }

    private func machine(_ id: String, offline: Bool = false, retired: Bool = false) -> MachineInfo {
        decode(#"{"id":"\#(id)","name":"\#(id)","isOffline":\#(offline)\#(retired ? #","status":"retired""# : "")}"#)
    }

    func testOneRowPerKindNeverOnePerItem() {
        let rows = NeedsYou.rows(
            queue: [job("A", due: -3), job("B", due: -1), job("C", due: -2)],
            spools: [spool("S1", grams: 120), spool("S2", grams: 80), spool("S3", grams: 900)],
            waiting: [request("W1", "Jordan Lee"), request("W2", "Sam Rivera")])
        XCTAssertEqual(rows.map(\.kind), [.late, .lowStock, .waiting])
        XCTAssertEqual(rows.map(\.count), [3, 2, 2])
        XCTAssertEqual(rows[2].detail, "Jordan Lee · Sam Rivera")
        // The emptiest spool is the one named.
        XCTAssertEqual(rows[1].detail, "2 spools low · Bambu · PLA 80 g left")
    }

    func testLateCountsOnlyOpenJobsPastTheirDay() {
        let rows = NeedsYou.rows(
            queue: [job("open", due: -2),
                    job("done", "completed", due: -5),
                    job("cancelled", "cancelled", due: -5),
                    job("voided", due: -5, voided: true),
                    job("today", due: 0),
                    job("undated")],
            spools: [], waiting: [])
        XCTAssertEqual(rows.map(\.kind), [.late])
        XCTAssertEqual(rows.first?.count, 1)
        XCTAssertTrue(rows.first?.detail.hasPrefix("Job open was due") ?? false, rows.first?.detail ?? "")
        // The same rule as the Orders list's Late chip.
        let queue = [job("open", due: -2), job("done", "completed", due: -5)]
        XCTAssertEqual(rows.first?.count, queue.filter(\.isOverdue).count)
    }

    func testLateLeadsWhateverArrivesFirst() {
        let rows = NeedsYou.rows(
            queue: [job("A", due: -1)],
            spools: [spool("S1", grams: 50)],
            waiting: [request("W1", "Jordan")],
            quotes: [quote("Q1")])
        XCTAssertEqual(rows.map(\.kind), [.late, .lowStock, .waiting, .quotes])
        XCTAssertEqual(rows.map(\.tone), [.late, .today, .today, .waitingOnOthers])
    }

    func testAtMostFiveKindsAndTheRestFold() {
        let row = { (k: NeedsYou.Kind) in NeedsYou.Row(kind: k, count: 1, detail: "") }
        let seven = [row(.late), row(.lowStock), row(.waiting), row(.quotes), row(.late), row(.lowStock), row(.waiting)]
        let folded = NeedsYou.fold(seven)
        XCTAssertEqual(folded.shown.count, 5)
        XCTAssertEqual(folded.more, 2)
        XCTAssertEqual(folded.total, 7, "the greeting counts every kind, folded or not")
        XCTAssertEqual(L10n.count("needs.more", folded.more), "and 2 more")

        let four = NeedsYou.fold(Array(seven.prefix(4)))
        XCTAssertEqual(four.shown.count, 4)
        XCTAssertEqual(four.more, 0)
    }

    func testNothingToDoIsTheCalmState() {
        let summary = NeedsYou.summary(
            queue: [job("A", due: 3), job("B", "completed", due: -4)],
            spools: [spool("S1", grams: 900)], waiting: [], quotes: [])
        XCTAssertTrue(summary.isCalm)
        XCTAssertEqual(summary.shown, [])
        XCTAssertEqual(summary.total, 0)
    }

    func testQuotesTheyCannotSeeAreNotAZero() {
        XCTAssertEqual(NeedsYou.rows(queue: [], spools: [], waiting: [], quotes: nil), [])
        XCTAssertEqual(NeedsYou.rows(queue: [], spools: [], waiting: [], quotes: [quote("Q1"), quote("Q2")]).first?.count, 2)
    }

    func testTheGreetingSaysTheCount() {
        XCTAssertEqual(L10n.count("needs.count", 3), "3 things need you.")
        XCTAssertEqual(L10n.count("needs.count", 1), "1 thing needs you.")
        XCTAssertEqual(L10n.count("needs.late", 1), "1 job is late")
        XCTAssertEqual(NeedsYou.greetingKey(hour: 9), "home.greeting.morning")
        XCTAssertEqual(NeedsYou.greetingKey(hour: 14), "home.greeting.afternoon")
        XCTAssertEqual(NeedsYou.greetingKey(hour: 21), "home.greeting.evening")
        XCTAssertEqual(NeedsYou.greetingKey(hour: 2), "home.greeting.evening")
    }

    func testArabicCountsTakeTheirOwnForms() {
        L10n.setLanguage(.ar)
        XCTAssertEqual(L10n.count("needs.late", 1), "طلب واحد متأخر")
        XCTAssertEqual(L10n.count("needs.count", 2), "أمران يحتاجانك.")
    }

    func testDueThisWeekIsOpenJobsInTheNextSevenDaysSoonestFirst() {
        let due = NeedsYou.dueThisWeek([
            job("late", due: -1), job("in6", due: 6), job("today", due: 0),
            job("in7", due: 7), job("done", "completed", due: 1), job("undated"), job("tomorrow", "printing", due: 1),
        ])
        XCTAssertEqual(due.map(\.id), ["today", "tomorrow", "in6"])
    }

    func testOnTheMachinesCountsWorkingMachinesWithAPrintingJob() {
        let machines = [machine("M1"), machine("M2"), machine("M3"), machine("down", offline: true), machine("old", retired: true)]
        let figure = NeedsYou.onTheMachines(machines, queue: [
            job("A", "printing", machine: "M1"), job("B", "printing", machine: "M2"),
            job("C", "pending", machine: "M3"), job("D", "printing", machine: "old"),
        ])
        XCTAssertEqual(figure?.busy, 2)
        XCTAssertEqual(figure?.of, 3)
        XCTAssertNil(NeedsYou.onTheMachines([], queue: []), "no machines is a hidden tile, never 0 of 0")
    }
}
