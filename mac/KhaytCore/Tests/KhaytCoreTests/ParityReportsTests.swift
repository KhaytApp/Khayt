import Foundation
import Testing
@testable import KhaytCore

/// The desktop's reports, through the engine: profit by filament, material
/// usage, the P&L trend, the completion heatmap, the box-form VAT return, the
/// shopping list and the test-print log.
///
/// `test/mac-parity-reports.test.js` pins each module's figures against the
/// desktop's old inline code. What matters here is that the Mac asks the same
/// module with the same money underneath it — revenue net of VAT — and that
/// what crosses back decodes.
@Suite struct ParityReportsTests {

    static let vat15: [String: JSONValue] = ["currency": .string("SAR"), "enableVat": .bool(true),
                                             "vatRate": .number(15)]

    static func job(_ id: String, date: String, price: Double, status: String = "completed",
                    spool: String = "S1", grams: Double = 50) -> JSONValue {
        .object([
            "id": .string(id), "status": .string(status), "date": .string(date),
            "price": .number(price), "paidAmount": .number(price),
            "parts": .array([.object([
                "filamentId": .string(spool), "material": .string("PLA"),
                "printWeight": .number(grams), "spoolCost": .number(80), "spoolWeight": .number(1000),
            ])]),
        ])
    }

    static let shelf: [JSONValue] = [
        .object(["id": .string("S1"), "material": .string("PLA"), "color": .string("#ff0000"),
                 "weight": .number(120), "reorderPoint": .number(200), "reorderQty": .number(1000),
                 "usageHistory": .array([.object(["date": .string("2026-10-03"), "weightUsed": .number(40)])])]),
        .object(["id": .string("S2"), "material": .string("PETG"), "weight": .number(900),
                 "usageHistory": .array([])]),
    ]

    @Test("profit by filament is on revenue net of VAT, and usage fills every month")
    func filament() async throws {
        let engine = try KhaytEngine()
        let report = try await engine.filamentReport(
            orders: [Self.job("a", date: "2026-10-01", price: 115)], inventory: Self.shelf,
            settings: Self.vat15, clients: [], months: ["2026-09", "2026-10"])
        let row = try #require(report.rows.first)
        #expect(row.key == "S1")
        #expect(row.orders == 1)
        #expect(abs(row.revenue - 100) < 0.001)   // 115 with the 15% taken out
        #expect(abs(row.matCost - 4) < 0.001)     // 50 g of an 80-per-kilo spool
        #expect(abs(row.marginPct - 96) < 0.001)
        #expect(row.avgTimePerGram == nil)
        #expect(report.usage.materials == ["PLA"])
        #expect(report.usage.grams("PLA", "2026-10") == 40)
        #expect(report.usage.grams("PLA", "2026-09") == 0)
        #expect(report.usage.maxGrams == 40)
    }

    @Test("the trend is the P&L by month, a row per month asked")
    func trend() async throws {
        let engine = try KhaytEngine()
        var parts = DateComponents()
        parts.year = 2026; parts.month = 10; parts.day = 16; parts.hour = 12
        let now = try #require(Calendar.book.date(from: parts))
        let input = PnlInputs(orders: [Self.job("a", date: "2026-10-01", price: 115)],
                              expenses: [.object(["id": .string("e"), "date": .string("2026-10-02"),
                                                  "amount": .number(30), "category": .string("other")])],
                              settings: Self.vat15, now: now)
        let months = Calendar.book.monthKeys(endingAt: now, count: 6)
        #expect(months == ["2026-05", "2026-06", "2026-07", "2026-08", "2026-09", "2026-10"])
        let trend = try await engine.pnlTrend(input, months: months)
        #expect(trend.map(\.month) == months)
        let october = try #require(trend.last)
        #expect(abs(october.revenue - 100) < 0.001)
        #expect(october.expenses > 0)
        #expect(abs(october.profit - (october.revenue - october.expenses)) < 0.001)
        #expect(october.marginPct != nil)
        #expect(trend.first?.marginPct == nil)
        #expect(PnlTrendMonth.band(40) == "good")
        #expect(PnlTrendMonth.band(25) == "fair")
        #expect(PnlTrendMonth.band(5) == "poor")
    }

    @Test("the month keys cross a year end")
    func monthKeys() throws {
        var parts = DateComponents()
        parts.year = 2027; parts.month = 2; parts.day = 3
        let date = try #require(Calendar.book.date(from: parts))
        #expect(Calendar.book.monthKeys(endingAt: date, count: 3) == ["2026-12", "2027-01", "2027-02"])
    }

    @Test("the heatmap counts finished work by weekday and week")
    func heatmap() async throws {
        let engine = try KhaytEngine()
        let now = Date()
        let iso = ISO8601DateFormatter()
        let done: [JSONValue] = (0..<6).map { i in
            .object(["id": .string("h\(i)"), "status": .string("completed"),
                     "completedAt": .string(iso.string(from: now.addingTimeInterval(Double(-i) * 86_400)))])
        }
        let heat = try await engine.completionHeatmap(orders: done, now: now)
        #expect(heat.jobs == 6)
        #expect(heat.hasData)
        #expect(heat.matrix.count == 7)
        #expect(heat.matrix.allSatisfy { $0.count == 12 })
        #expect(heat.matrix.flatMap { $0 }.reduce(0, +) == 6)
        #expect(heat.intensity.flatMap { $0 }.allSatisfy { $0 >= 0.12 && $0 <= 0.97 + 1e-9 })
    }

    @Test("the box-form VAT return takes the tax out of what was invoiced")
    func vatReturn() async throws {
        let engine = try KhaytEngine()
        let doc = try await engine.vatReturn(
            orders: [Self.job("a", date: "2026-08-01", price: 230, status: "printing"),
                     Self.job("b", date: "2026-08-02", price: 999, status: "quote")],
            expenses: [.object(["id": .string("e"), "date": .string("2026-08-05"),
                                "amount": .number(115), "vatAmount": .number(15)])],
            settings: Self.vat15, clients: [], currencies: [:],
            from: "2026-07-01", to: "2026-09-30", shopName: "Atelier", periodTitle: "Q3 2026")
        #expect(abs(doc.box1 - 200) < 0.001)
        #expect(abs(doc.box3 - 30) < 0.001)
        #expect(doc.box6 == 115)
        #expect(doc.box7Known)
        #expect(abs(doc.netVat - 15) < 0.001)
        #expect(doc.isSaudiForm)
        #expect(doc.invoices == 1)
        #expect(doc.html.contains("Box 3"))
        #expect(doc.html.contains("Atelier"))
        #expect(doc.html.contains("30.00"))
    }

    @Test("the shopping list is the low spools, by supplier, with its text")
    func shopping() async throws {
        let engine = try KhaytEngine()
        let list = try await engine.shoppingList(spools: Self.shelf, suppliers: [], settings: [:],
                                                 noSupplier: "No supplier set", title: "Shopping list")
        #expect(list.groups.map(\.supplier) == ["No supplier set"])
        let item = try #require(list.groups.first?.items.first)
        #expect(item.id == "S1")
        #expect(item.have == 120)
        #expect(item.buy == 1000)
        #expect(list.text.contains("PLA   120 g → 1000 g"))
    }

    @Test("a test print is written in the desktop's fields and takes its grams off the spool")
    func testPrint() async throws {
        let engine = try KhaytEngine()
        let made = try await engine.addTestPrint(
            [], spool: Self.shelf[0],
            raw: ["date": .string(""), "machineId": .string(""), "testType": .string("retraction"),
                  "result": .string("good"), "printTemp": .number(210), "bedTemp": .null,
                  "speed": .null, "notes": .string(" ok "), "weightUsed": .number(5)],
            id: "TP1", today: "2026-11-06")
        guard case .object(let entry)? = made.testPrints.first else { Issue.record("no entry"); return }
        #expect(entry["id"] == .string("TP1"))
        #expect(entry["spoolId"] == .string("S1"))
        #expect(entry["date"] == .string("2026-11-06"))
        #expect(entry["machineId"] == .null)
        #expect(entry["printTemp"] == .number(210))
        #expect(entry["bedTemp"] == .null)
        #expect(entry["notes"] == .string("ok"))
        #expect(entry["weightUsed"] == .number(5))
        guard case .object(let spool)? = made.item else { Issue.record("no spool"); return }
        #expect(spool["weight"] == .number(115))
        guard case .array(let history)? = spool["usageHistory"], case .object(let line)? = history.first else {
            Issue.record("no usage line"); return
        }
        #expect(line["orderId"] == .string("TP1"))
        #expect(line["project"] == .string("Test print (retraction)"))

        let back = try await engine.removeTestPrint(made.testPrints, spool: made.item, id: "TP1")
        #expect(back.testPrints.isEmpty)
        guard case .object(let restored)? = back.item else { Issue.record("no spool"); return }
        #expect(restored["weight"] == .number(120))
    }

    @Test("the test-print kinds the Mac offers are the module's")
    func kinds() async throws {
        let runtime = try JSRuntime(modules: ["test-prints"])
        let types = try runtime.value("KhaytTestPrints", "TEST_TYPES", as: [String].self)
        let results = try runtime.value("KhaytTestPrints", "TEST_RESULTS", as: [String].self)
        #expect(types == ["temp_tower", "retraction", "first_layer", "stringing", "overhang", "dimensional", "other"])
        #expect(results == ["excellent", "good", "fair", "poor"])
    }
}
