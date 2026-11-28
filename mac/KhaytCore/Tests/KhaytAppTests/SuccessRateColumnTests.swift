import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Machine profit's "Prints" and "Came out right" (Mac file, page 25, frame 5).
@MainActor
struct SuccessRateColumnTests {
    static func row(_ finished: Int, _ failed: Int, _ cancelled: Int, _ unknown: Int, enough: Bool? = nil) -> KhaytEngine.SuccessRow {
        let decided = finished + failed
        return .init(machineId: "M", finished: finished, failed: failed, cancelled: cancelled, unknown: unknown,
                     rate: decided > 0 ? (Double(finished) / Double(decided) * 1000).rounded() / 1000 : nil, enough: enough ?? (decided >= 5))
    }

    /// The rule's own per cent, as the page is handed it (the engine is asked in the wiring; here it is its arithmetic).
    static func pct(_ row: KhaytEngine.SuccessRow?) -> Int? {
        guard let rate = row?.rate else { return nil }
        let p = Int((rate * 100).rounded())
        if p >= 100, rate < 1 { return 99 }
        if p <= 0, rate > 0 { return 1 }
        return p
    }

    @Test("the frame's five rows, word for word")
    func frame() async {
        let en = Words(); await en.load("en", engine: OperatorLockTests.sharedEngine)
        // Eleven finished, three failed, one cancelled: 11 of the 14 DECIDED came out right. (The frame's own
        // figures are a sample and do not add up to its 79% as 14 prints; the wording is what is held.)
        let ender = Self.row(11, 3, 1, 0)
        #expect(MachineProfitPage.prints(ender, en) == "15 · 3 failed · 1 cancelled")
        #expect(MachineProfitPage.cameOutRight(ender, percent: Self.pct(ender), en) == "79%")
        let u1 = Self.row(39, 2, 0, 0)
        #expect(MachineProfitPage.prints(u1, en) == "41 · 2 failed" && MachineProfitPage.cameOutRight(u1, percent: Self.pct(u1), en) == "95%")
        // Cancelled prints are shown and are not in the percentage.
        let core = Self.row(25, 0, 4, 0)
        #expect(MachineProfitPage.prints(core, en) == "29 · 4 cancelled" && MachineProfitPage.cameOutRight(core, percent: Self.pct(core), en) == "100%")
        // One failure in two is not a 50% printer.
        let saturn = Self.row(1, 1, 0, 0)
        #expect(MachineProfitPage.prints(saturn, en) == "2 · 1 failed" && MachineProfitPage.cameOutRight(saturn, percent: Self.pct(saturn), en) == "Too few prints yet")
        // Three prints, none marked: counted, and no figure at all.
        let bambu = Self.row(0, 0, 0, 3)
        #expect(MachineProfitPage.prints(bambu, en) == "3 · not marked yet" && MachineProfitPage.cameOutRight(bambu, percent: Self.pct(bambu), en) == "—")
    }

    @Test("the edges: nothing printed, some unmarked, exactly five, and a printer the rule has no row for")
    func edges() async {
        let en = Words(); await en.load("en", engine: OperatorLockTests.sharedEngine)
        #expect(MachineProfitPage.prints(Self.row(0, 0, 0, 0), en) == "—" && MachineProfitPage.cameOutRight(Self.row(0, 0, 0, 0), percent: Self.pct(Self.row(0, 0, 0, 0)), en) == "—")
        #expect(MachineProfitPage.prints(nil, en) == "—" && MachineProfitPage.cameOutRight(nil, percent: Self.pct(nil), en) == "—")
        #expect(MachineProfitPage.prints(Self.row(4, 1, 0, 2), en) == "7 · 1 failed · 2 not marked yet")
        #expect(MachineProfitPage.cameOutRight(Self.row(4, 1, 0, 2), percent: Self.pct(Self.row(4, 1, 0, 2)), en) == "80%")
        #expect(MachineProfitPage.cameOutRight(Self.row(4, 0, 9, 9), percent: Self.pct(Self.row(4, 0, 9, 9)), en) == "Too few prints yet", "cancelled and unmarked prints do not make up the five")
        // Only cancelled: counted, no figure.
        #expect(MachineProfitPage.prints(Self.row(0, 0, 2, 0), en) == "2 · 2 cancelled" && MachineProfitPage.cameOutRight(Self.row(0, 0, 2, 0), percent: Self.pct(Self.row(0, 0, 2, 0)), en) == "—")
        // 199 of 200 is not a perfect printer, and no figure is made up when the rule gave none.
        #expect(MachineProfitPage.cameOutRight(Self.row(199, 1, 0, 0), percent: 99, en) == "99%")
        #expect(MachineProfitPage.cameOutRight(Self.row(9, 1, 0, 0), percent: nil, en) == "—")
        // Rounded as a person reads it.
        #expect(MachineProfitPage.cameOutRight(Self.row(2, 4, 0, 0), percent: Self.pct(Self.row(2, 4, 0, 0)), en) == "33%")
        // Arabic: the same counts, in the shop's language, with nothing left in braces.
        let ar = Words(); await ar.load("ar", engine: OperatorLockTests.sharedEngine)
        let said = MachineProfitPage.prints(Self.row(11, 3, 1, 2), ar)
        #expect(said.contains("فشل") && said.contains("أُلغي") && !said.contains("{"))
        #expect(MachineProfitPage.cameOutRight(Self.row(1, 1, 0, 0), percent: Self.pct(Self.row(1, 1, 0, 0)), ar) == "الطبعات قليلة بعد")
    }

    @Test("a run counts on the shop's own day, not UTC's: a print sent after midnight in Riyadh is today's")
    func ownDay() async throws {
        // 22:30 UTC on Oct 31 is 01:30 on Nov 1 in a shop three hours ahead.
        let late = "2026-10-31T22:30:00.000Z"
        let local = Calendar.localDay(ofInstant: late)
        #expect(Shop.runDay(.string(late)) == local)
        if TimeZone.current.secondsFromGMT(for: try #require(Calendar.instant(late))) >= 2 * 3600 { #expect(local == "2026-11-01") }
        // A bare day is itself; milliseconds are read; rubbish and nothing are no day.
        #expect(Shop.runDay(.string("2026-11-05")) == "2026-11-05")
        #expect(Shop.runDay(.number(1_795_000_000_000)) == Calendar.book.dayString(Date(timeIntervalSince1970: 1_795_000_000)))
        for bad in [JSONValue.string("soon"), .string(""), .number(0), .null, .bool(true)] { #expect(Shop.runDay(bad) == nil) }
        #expect(Shop.runDay(nil) == nil)
        func run(_ at: JSONValue?, _ result: String = "finished") -> JSONValue {
            var r: [String: JSONValue] = ["machineId": .string("M"), "result": .string(result), "resultSource": .string("printer")]
            if let at { r["at"] = at }
            return .object(r)
        }
        let orders: [JSONValue] = [
            .object(["id": .string("1"), "printRuns": .array([run(.string(late)), run(.string("2026-09-01")), run(nil), run(.string("soon"))])]),
            .object(["id": .string("2"), "deleted": .bool(true), "printRuns": .array([run(.string(late))])]),
            .object(["id": .string("3")]),
        ]
        // Only the run on that local day, from the job that is not deleted; the job is reduced to its runs.
        let kept = Shop.runsSent(orders) { $0 == local }
        #expect(kept == [.object(["printRuns": .array([run(.string(late))])])])
        // Everything dated, for "All time": the undated and the unreadable are not runs of any day.
        #expect(Shop.runsSent(orders) { _ in true } == [.object(["printRuns": .array([run(.string(late)), run(.string("2026-09-01"))])])])
        // And the rule counts exactly those, asked with no dates.
        let rows = try await OperatorLockTests.sharedEngine.successRates(orders: kept, machines: [.object(["id": .string("M")])])
        #expect(rows == [.init(machineId: "M", finished: 1, failed: 0, cancelled: 0, unknown: 0, rate: 1, enough: false)])
    }

    @Test("the page is handed the rates for the range it shows, by the shared rule")
    func wiring() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        let reports = try String(contentsOf: app.appending(path: "Reports.swift"), encoding: .utf8)
        // By the shop's own day, picked here; the rule is asked with no dates (its own slice the UTC day).
        #expect(reports.contains("engine.successRates(orders: sent, machines: shop.machineRows)"))
        #expect(reports.contains("Shop.runsSent(shop.orderRows)") && !reports.contains("successRates(orders: shop.orderRows"))
        #expect(reports.contains("sites: sites, success: success, successPercent: successPercent,"))
        #expect(reports.contains("successTone: successTone)"))
        // The per cent and its colour are the shared rule's, asked of the engine:
        // the page rounds nothing and holds no threshold itself.
        #expect(reports.contains("engine.successPercent(row.rate)"))
        #expect(reports.contains("engine.successTone(row.rate, enough: row.enough)"))
        let page = try String(contentsOf: app.appending(path: "MachineProfit.swift"), encoding: .utf8)
        #expect(!page.contains("rate * 100"), "the page rounds a rate itself")
        #expect(page.contains("success.first { $0.machineId == row.machineId }") && page.contains(#"words.callIt("mac.mpl_right_note")"#))
    }
}
