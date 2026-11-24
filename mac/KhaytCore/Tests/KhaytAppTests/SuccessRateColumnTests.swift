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

    @Test("the frame's five rows, word for word")
    func frame() async {
        let en = Words(); await en.load("en", engine: OperatorLockTests.sharedEngine)
        // Old Ender: 14 prints, 3 failed, 1 cancelled: 10 of 13 decided came out right... the frame's 79% is 11 of 14 decided.
        let ender = Self.row(11, 3, 1, 0)
        #expect(MachineProfitPage.prints(ender, en) == "15 · 3 failed · 1 cancelled")
        #expect(MachineProfitPage.cameOutRight(ender, en) == "79%")
        let u1 = Self.row(39, 2, 0, 0)
        #expect(MachineProfitPage.prints(u1, en) == "41 · 2 failed" && MachineProfitPage.cameOutRight(u1, en) == "95%")
        // Cancelled prints are shown and are not in the percentage.
        let core = Self.row(25, 0, 4, 0)
        #expect(MachineProfitPage.prints(core, en) == "29 · 4 cancelled" && MachineProfitPage.cameOutRight(core, en) == "100%")
        // One failure in two is not a 50% printer.
        let saturn = Self.row(1, 1, 0, 0)
        #expect(MachineProfitPage.prints(saturn, en) == "2 · 1 failed" && MachineProfitPage.cameOutRight(saturn, en) == "Too few prints yet")
        // Three prints, none marked: counted, and no figure at all.
        let bambu = Self.row(0, 0, 0, 3)
        #expect(MachineProfitPage.prints(bambu, en) == "3 · not marked yet" && MachineProfitPage.cameOutRight(bambu, en) == "—")
    }

    @Test("the edges: nothing printed, some unmarked, exactly five, and a printer the rule has no row for")
    func edges() async {
        let en = Words(); await en.load("en", engine: OperatorLockTests.sharedEngine)
        #expect(MachineProfitPage.prints(Self.row(0, 0, 0, 0), en) == "—" && MachineProfitPage.cameOutRight(Self.row(0, 0, 0, 0), en) == "—")
        #expect(MachineProfitPage.prints(nil, en) == "—" && MachineProfitPage.cameOutRight(nil, en) == "—")
        #expect(MachineProfitPage.prints(Self.row(4, 1, 0, 2), en) == "7 · 1 failed · 2 not marked yet")
        #expect(MachineProfitPage.cameOutRight(Self.row(4, 1, 0, 2), en) == "80%")
        #expect(MachineProfitPage.cameOutRight(Self.row(4, 0, 9, 9), en) == "Too few prints yet", "cancelled and unmarked prints do not make up the five")
        // Only cancelled: counted, no figure.
        #expect(MachineProfitPage.prints(Self.row(0, 0, 2, 0), en) == "2 · 2 cancelled" && MachineProfitPage.cameOutRight(Self.row(0, 0, 2, 0), en) == "—")
        // Rounded as a person reads it.
        #expect(MachineProfitPage.cameOutRight(Self.row(2, 4, 0, 0), en) == "33%")
        // Arabic: the same counts, in the shop's language, with nothing left in braces.
        let ar = Words(); await ar.load("ar", engine: OperatorLockTests.sharedEngine)
        let said = MachineProfitPage.prints(Self.row(11, 3, 1, 2), ar)
        #expect(said.contains("فشل") && said.contains("أُلغي") && !said.contains("{"))
        #expect(MachineProfitPage.cameOutRight(Self.row(1, 1, 0, 0), ar) == "الطبعات قليلة بعد")
    }

    @Test("the page is handed the rates for the range it shows, by the shared rule")
    func wiring() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        let reports = try String(contentsOf: app.appending(path: "Reports.swift"), encoding: .utf8)
        #expect(reports.contains("engine.successRates(orders: shop.orderRows, machines: shop.machineRows,"))
        #expect(reports.contains("sites: sites, success: success)"))
        let page = try String(contentsOf: app.appending(path: "MachineProfit.swift"), encoding: .utf8)
        #expect(page.contains("success.first { $0.machineId == row.machineId }") && page.contains(#"words.callIt("mac.mpl_right_note")"#))
    }
}
