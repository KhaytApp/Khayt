import Foundation
import SwiftUI
import Testing
import KhaytCore
@testable import KhaytApp

/// Logged labour on the Mac's P&L — the same rule the desktop runs
/// (`lib/pnl-report.js` LABOUR), crossing the bridge and drawn.
///
/// `test/pnl-labour.test.js` holds the arithmetic and the ratchet over every
/// caller. These hold the crossing: that the line decodes, that the sample
/// book reaches it, that the masthead and Reports read the same net, and that
/// the screens that print a net print the labour beside it.
@Suite @MainActor struct LabourPnlTests {

    private func sample() async -> Shop {
        let shop = Shop()
        await shop.load(.sample, asOf: SampleBook.anchor)
        return shop
    }

    private func periods(_ shop: Shop, timeEntries: [JSONValue],
                         granularity: String = "month") async throws -> [PnlPeriod] {
        let engine = try #require(shop.engine)
        return try await engine.pnlByPeriod(
            orders: shop.orderRows, expenses: shop.expenseRows,
            settings: shop.settingsDict, clients: shop.clientRows,
            currencies: Invoice.currencyTable(shop), now: SampleBook.anchor ?? Date(),
            granularity: granularity, wasteLog: shop.wasteRows,
            inventory: shop.inventoryRows, machines: shop.machineRows,
            recentMonthlyHours: shop.recentMonthlyHours, timeEntries: timeEntries)
    }

    @Test("the sample book reaches the labour line, and net falls by exactly it")
    func sampleReachesIt() async throws {
        let shop = await sample()
        #expect(!shop.timeEntryRows.isEmpty, "the sample book logs time")
        let without = try await periods(shop, timeEntries: [])
        let with = try await periods(shop, timeEntries: shop.timeEntryRows)
        let labour = with.reduce(0) { $0 + $1.labourValue }
        #expect(labour > 100, "labour reached the P&L (\(labour))")
        #expect(without.allSatisfy { $0.labourValue == 0 })
        for row in without {
            let moved = try #require(with.first { $0.period == row.period })
            #expect(moved.revenue == row.revenue && moved.cogs == row.cogs && moved.expenses == row.expenses,
                    "\(row.period): only labour and net move")
            #expect(Int(((row.net - moved.net) * 100).rounded()) == Int((moved.labourValue * 100).rounded()),
                    "\(row.period): net falls by the labour")
        }
    }

    @Test("the masthead's month and Reports' month are one row, labour included")
    func mastheadAgrees() async throws {
        let shop = await sample()
        let now = SampleBook.anchor ?? Date()
        let month = await Shop.thisMonthsRow(
            engine: shop.engine, orders: shop.orderRows, expenses: shop.expenseRows,
            settings: shop.settingsDict, clients: shop.clientRows,
            currencies: Invoice.currencyTable(shop), wasteLog: shop.wasteRows,
            inventory: shop.inventoryRows, machines: shop.machineRows,
            recentMonthlyHours: shop.recentMonthlyHours,
            timeEntries: shop.timeEntryRows, now: now)
        let reports = try await periods(shop, timeEntries: shop.timeEntryRows)
            .first { $0.period == DateRange.localMonth(now) }
        #expect(month?.net == reports?.net)
        #expect(month?.labour == reports?.labour)
    }

    @Test("the masthead is handed the time log when the book loads")
    func mastheadIsHandedIt() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Shop.swift"), encoding: .utf8)
        #expect(src.contains("timeEntries: Self.rows(root, \"timeEntries\"), now: now)"))
    }

    @Test("an older bundle without the field decodes, as no labour")
    func olderBundle() throws {
        let json = #"[{"period":"2026-Q3","orders":1,"revenue":10,"shipping":0,"expenses":0,"fixed":0,"vatCollected":0,"vatReclaimable":0,"vatDue":0,"net":10}]"#
        let rows = try JSONDecoder().decode([PnlPeriod].self, from: Data(json.utf8))
        #expect(rows[0].labourValue == 0)
        #expect(rows[0].labourOverlap == nil)
    }

    @Test("a machine and a branch carry the labour of their jobs")
    func machineAndBranch() async throws {
        let shop = await sample()
        let engine = try #require(shop.engine)
        let report = try await engine.machineProfit(
            machines: shop.machineRows, completed: shop.orderRows.filter { row in
                guard case .object(let o) = row, case .string(let s)? = o["status"] else { return false }
                return s == "completed" || s == "delivered"
            },
            expenses: [], maintenance: [], settings: shop.settingsDict, clients: shop.clientRows,
            unassigned: "—", timeEntries: shop.timeEntryRows)
        #expect((report.totals.labour ?? 0) > 0, "the sample's logged hours reach its machines")
        let sites = try await engine.locationPl(
            orders: shop.orderRows, expenses: shop.expenseRows, wasteLog: shop.wasteRows,
            machines: shop.machineRows, locations: shop.locationRows, settings: shop.settingsDict,
            clients: shop.clientRows, currencies: Invoice.currencyTable(shop),
            inventory: shop.inventoryRows, now: SampleBook.anchor ?? Date(),
            timeEntries: shop.timeEntryRows, jobs: shop.orderRows)
        #expect(sites.rows.reduce(0) { $0 + ($1.labour ?? 0) } > 0)
    }

    /// LOOK at these. The table needs the live page; the statement and the
    /// waterfall beside it are what a shop reads the labour off.
    @Test("the P&L statement and the waterfall, photographed with labour")
    func picture() async throws {
        let shop = await sample()
        let rows = try await periods(shop, timeEntries: shop.timeEntryRows, granularity: "quarter")
        let row = try #require(rows.first { $0.labourValue > 0 })
        let snap = SnapshotTests()
        try snap.render(Reports.Totals(shop: shop, rows: rows, floor: nil).statement
                            .frame(width: 300).background(Khayt.ground),
                        "labour-pnl-totals", size: CGSize(width: 300, height: 640))
        try snap.renderDark(Reports.Totals(shop: shop, rows: rows, floor: nil).statement
                                .frame(width: 300),
                            "labour-pnl-totals-dark", size: CGSize(width: 300, height: 640))
        try snap.render(Reports.QuarterDrawn(shop: shop, row: row)
                            .frame(width: 640).padding(Metric.screen).background(Khayt.ground),
                        "labour-pnl-waterfall", size: CGSize(width: 680, height: 320))
    }
}
