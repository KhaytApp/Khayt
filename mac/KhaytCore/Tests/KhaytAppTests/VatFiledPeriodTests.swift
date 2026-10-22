import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A FILED VAT RETURN IS NOT REWRITTEN, on the Mac.
///
/// The owner's rule (2026-10-22, `lib/vat-periods.js`): an invoice dated in a
/// period the shop has marked filed, cancelled after filing, keeps its VAT in
/// the filed period, and the reversal lands in the first open period as an
/// adjustment the VAT card shows on its own line. `test/vat-filed-periods.test.js`
/// holds the arithmetic; these hold the Mac's write of the mark, the bundled
/// rule reading it, and the settings pane's frequency.
@MainActor
struct VatFiledPeriodTests {
    static let vat15: [String: JSONValue] = [
        "currency": .string("SAR"), "enableVat": .bool(true), "vatRate": .number(15),
    ]

    static func day(_ y: Int, _ m: Int, _ d: Int) throws -> Date {
        try #require(Calendar.book.date(from: DateComponents(year: y, month: m, day: d, hour: 12)))
    }

    static func job(status: String = "completed") -> JSONValue {
        .object(["id": .string("INV-1"), "invoiceNumber": .string("INV-1"), "status": .string(status),
                 "date": .string("2026-08-10"), "price": .number(115)])
    }

    static func statement(_ root: [String: JSONValue], engine: KhaytEngine,
                          from: String, to: String) async throws -> PnlStatement {
        guard case .array(let jobs)? = root["printLog"], case .object(let settings)? = root["settings"]
        else { throw CancellationError() }
        return try await engine.pnlStatement(PnlInputs(orders: jobs, expenses: [], settings: settings,
                                                 now: try day(2027, 2, 15), from: from, to: to))
    }

    @Test("marked filed, then cancelled: Q3 keeps its VAT and Q4 shows the adjustment")
    func cancelAfterFiling() async throws {
        let engine = try KhaytEngine()
        var root: [String: JSONValue] = ["settings": .object(Self.vat15), "printLog": .array([Self.job()])]
        try await Shop.applyVatFiled(to: &root, period: "2026-Q3", filed: true,
                                     engine: engine, now: try Self.day(2026, 10, 3))
        guard case .object(let settings)? = root["settings"],
              case .array(let marks)? = settings["vatFiledPeriods"],
              case .object(let mark)? = marks.first else { Issue.record("no mark written"); return }
        #expect(mark["period"] == .string("2026-Q3"))
        #expect(mark["orders"] == .object(["INV-1": .array([.number(15), .number(100)])]),
                "the snapshot: what the return held, job by job")
        #expect(mark["totals"] == .object(["vat": .number(15), "sales": .number(100)]))

        // Cancelled on 5 October, as lib/order-status.js dates it.
        root["printLog"] = .array([.object(["id": .string("INV-1"), "invoiceNumber": .string("INV-1"),
                                            "status": .string("cancelled"), "cancelledAt": .string("2026-10-05"),
                                            "date": .string("2026-08-10"), "price": .number(115)])])
        let q3 = try await Self.statement(root, engine: engine, from: "2026-07-01", to: "2026-09-30")
        #expect(abs(q3.vat.output - 15) < 0.001, "the filed return's figure")
        #expect(!q3.vat.hasAdjustment)

        let q4 = try await Self.statement(root, engine: engine, from: "2026-10-01", to: "2026-12-31")
        #expect(q4.vat.hasAdjustment)
        #expect(abs((q4.vat.adjustment ?? 0) + 15) < 0.001)
        #expect(abs((q4.vat.salesAdjustment ?? 0) + 100) < 0.001)
        #expect(q4.vat.adjustments == 1)
        #expect(abs(q4.vat.outputOnSales) < 0.001, "no invoice of Q4's own")
        #expect(abs((q4.rows.first?.vatAdjustment ?? 0) + 15) < 0.001)

        // Unmarked: an open period again, and the VAT simply drops out of it.
        try await Shop.applyVatFiled(to: &root, period: "2026-Q3", filed: false,
                                     engine: engine, now: try Self.day(2026, 10, 30))
        let open = try await Self.statement(root, engine: engine, from: "2026-07-01", to: "2026-12-31")
        #expect(abs(open.vat.output) < 0.001)
        #expect(!open.vat.hasAdjustment)
    }

    @Test("an invoice edited, or backdated in, after filing is adjusted in the next open period")
    func editAndBackdate() async throws {
        let engine = try KhaytEngine()
        var root: [String: JSONValue] = ["settings": .object(Self.vat15), "printLog": .array([Self.job()])]
        try await Shop.applyVatFiled(to: &root, period: "2026-Q3", filed: true,
                                     engine: engine, now: try Self.day(2026, 10, 3))
        root["printLog"] = .array([
            .object(["id": .string("INV-1"), "invoiceNumber": .string("INV-1"), "status": .string("completed"),
                     "date": .string("2026-08-10"), "price": .number(230),
                     "updatedAt": .string("2026-11-02T09:00:00.000Z")]),
            .object(["id": .string("INV-2"), "invoiceNumber": .string("INV-2"), "status": .string("completed"),
                     "date": .string("2026-09-12"), "price": .number(115)]),
        ])
        let q3 = try await Self.statement(root, engine: engine, from: "2026-07-01", to: "2026-09-30")
        #expect(abs(q3.vat.output - 15) < 0.001, "the filed figure, whatever the book says now")
        let q4 = try await Self.statement(root, engine: engine, from: "2026-10-01", to: "2026-12-31")
        #expect(abs((q4.vat.adjustment ?? 0) - 30) < 0.001, "15 more on the edit, 15 on the backdated invoice")
        #expect(q4.vat.adjustments == 2)
    }

    @Test("the card offers the ended return periods in the span, with the mark")
    func periodsOffered() async throws {
        let engine = try KhaytEngine()
        var settings = Self.vat15
        settings["vatFiledPeriods"] = .array([.string("2026-Q2")])
        let list = try await engine.vatFilingPeriods(settings: settings, from: "2026-01-01", to: "2026-12-31",
                                               today: "2026-10-22")
        #expect(list.map(\.period) == ["2026-Q3", "2026-Q2", "2026-Q1"], "Q4 has not ended")
        #expect(list.map(\.filed) == [false, true, false])
        settings["vatFilingFrequency"] = .string("monthly")
        let months = try await engine.vatFilingPeriods(settings: settings, from: "2026-09-01", to: "2026-10-31",
                                                 today: "2026-10-22")
        #expect(months.map(\.period) == ["2026-09"])
    }

    @Test("the tax pane saves the filing frequency, and a save keeps the marks")
    func frequencySaved() async throws {
        let engine = try KhaytEngine()
        var stored = Self.vat15
        stored["vatFiledPeriods"] = .array([.string("2026-Q3")])
        var root: [String: JSONValue] = ["settings": .object(stored)]
        try await Shop.applySettings(to: &root, form: ["vatFilingFrequency": .string("monthly")],
                                     country: nil, engine: engine)
        guard case .object(let settings)? = root["settings"] else { Issue.record("no settings"); return }
        #expect(settings["vatFilingFrequency"] == .string("monthly"))
        #expect(settings["vatFiledPeriods"] == .array([.string("2026-Q3")]))
        let draft = InvoicePane.Draft.read(settings, shop: Shop())
        #expect(draft.vatFilingFrequency == "monthly")
        #expect(draft.form()["vatFilingFrequency"] == .string("monthly"))
    }

    @Test("cancelling through the bundled status rule dates the cancel as the local day")
    func cancelIsDated() async throws {
        let engine = try KhaytEngine()
        let order: JSONValue = .object(["id": .string("INV-1"), "status": .string("pending"),
                                        "date": .string("2026-10-01")])
        let move = try await engine.moveJob(order: order, to: "cancelled", orders: [order], settings: [:],
                                            inventory: [], consumables: [], machines: [],
                                            now: try Self.day(2026, 10, 5), today: "2026-10-05")
        guard case .object(let o)? = move.order else { Issue.record("not moved"); return }
        let moved = o["cancelledAt"]
        #expect(moved == .string("2026-10-05"))
    }
}
