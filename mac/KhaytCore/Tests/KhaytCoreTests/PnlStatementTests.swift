import Foundation
import Testing
@testable import KhaytCore

/// The P&L over a period the shop picks, the VAT owed for it, and the files it
/// is exported as — crossing the bridge.
///
/// `test/pnl-range-vat-summary.test.js` holds the arithmetic. These hold the
/// Swift half: that the periods are the book calendar's, that the span reaches
/// the rule and the rows come back cut to it, that the VAT summary decodes in
/// all three tax modes, and that the files keep their promises (a BOM, plain
/// numbers, Western digits).
@Suite struct PnlStatementTests {

    /// A calendar pinned to one zone, so the days do not move with the Mac
    /// running the test. Built the way `Calendar.book` is.
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Riyadh")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    static func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    static let october16 = day(2026, 10, 16)

    static func span(_ kind: PnlRange.Kind, _ now: Date = october16) -> PnlRange.Resolved {
        PnlRange(kind).resolve(now: now, calendar: calendar)
    }

    // MARK: - The periods

    @Test("each named period is the whole period, in the book's days")
    func namedPeriods() {
        #expect(Self.span(.all) == .everything)
        #expect(Self.span(.month) == .span(from: "2026-10-01", to: "2026-10-31"))
        #expect(Self.span(.last_month) == .span(from: "2026-09-01", to: "2026-09-30"))
        #expect(Self.span(.quarter) == .span(from: "2026-10-01", to: "2026-12-31"))
        #expect(Self.span(.last_quarter) == .span(from: "2026-07-01", to: "2026-09-30"))
        #expect(Self.span(.year) == .span(from: "2026-01-01", to: "2026-12-31"))
        #expect(Self.span(.last_year) == .span(from: "2025-01-01", to: "2025-12-31"))
    }

    @Test("January looks back across the year: last month is December, last quarter Q4")
    func acrossTheYear() {
        let jan = Self.day(2027, 1, 15)
        #expect(Self.span(.last_month, jan) == .span(from: "2026-12-01", to: "2026-12-31"))
        #expect(Self.span(.last_quarter, jan) == .span(from: "2026-10-01", to: "2026-12-31"))
        #expect(Self.span(.month, jan) == .span(from: "2027-01-01", to: "2027-01-31"))
    }

    @Test("a leap February ends on the 29th")
    func leapFebruary() {
        let march = Self.day(2028, 3, 10)
        #expect(Self.span(.last_month, march) == .span(from: "2028-02-01", to: "2028-02-29"))
    }

    @Test("the periods are Gregorian even when the Mac's calendar is not")
    func notTheMacsCalendar() {
        // `resolve` defaults to `Calendar.book`; a Hijri calendar handed in
        // by mistake would give a different month, so the default is checked
        // against the Gregorian answer for the same instant.
        let now = Date()
        let book = PnlRange(.month).resolve(now: now)
        let parts = Calendar.book.dateComponents([.year, .month], from: now)
        let prefix = String(format: "%04d-%02d-01", parts.year!, parts.month!)
        #expect(book.bounds?.from == prefix)
    }

    @Test("a custom range: open ends allowed, unreadable or reversed days refused")
    func custom() {
        func resolve(_ a: String, _ b: String) -> PnlRange.Resolved {
            PnlRange(.custom, from: a, to: b).resolve(now: Self.october16, calendar: Self.calendar)
        }
        #expect(resolve("2026-03-01", "2026-03-31") == .span(from: "2026-03-01", to: "2026-03-31"))
        #expect(resolve("2026-03-01", "") == .span(from: "2026-03-01", to: ""))
        #expect(resolve("", "2026-03-31") == .span(from: "", to: "2026-03-31"))
        #expect(resolve(" 2026-03-01 ", "2026-03-31") == .span(from: "2026-03-01", to: "2026-03-31"))
        #expect(resolve("", "") == .invalid, "no days at all is not every period")
        #expect(resolve("2026-02-30", "2026-03-31") == .invalid, "the shape of a day is not a day")
        #expect(resolve("2026-3-1", "2026-03-31") == .invalid)
        #expect(resolve("2026-04-01", "2026-03-31") == .invalid, "the start after the end")
    }

    @Test("a range survives the round trip through scene storage")
    func stored() {
        let range = PnlRange(.custom, from: "2026-01-01", to: "2026-06-30")
        #expect(range.stored == "custom|2026-01-01|2026-06-30")
        #expect(PnlRange(stored: range.stored) == range)
        #expect(PnlRange(stored: "last_quarter||") == PnlRange(.last_quarter))
        #expect(PnlRange(stored: "") == nil)
        #expect(PnlRange(stored: "fortnight|x|y") == nil)
    }

    @Test("the file name carries the period's days")
    func fileStem() {
        #expect(PnlRange(.last_quarter).fileStem(now: Self.october16, calendar: Self.calendar)
                == "2026-07-01_2026-09-30")
        #expect(PnlRange(.all).fileStem(now: Self.october16, calendar: Self.calendar) == "all-time-2026-10-16")
        #expect(PnlRange(.custom, from: "2026-05-01").fileStem(now: Self.october16, calendar: Self.calendar)
                == "from-2026-05-01")
    }

    @Test("a span narrows records the way the rule does")
    func contains() {
        let span = PnlRange.Resolved.span(from: "2026-09-01", to: "2026-09-30")
        #expect(span.contains("2026-09-01"))
        #expect(span.contains("2026-09-30T23:00:00Z"))
        #expect(!span.contains("2026-10-01"))
        #expect(!span.contains("2026"))
        #expect(PnlRange.Resolved.everything.contains("anything"))
        #expect(!PnlRange.Resolved.invalid.contains("2026-09-15"))
    }

    @Test("a period key's whole days")
    func wholeSpan() {
        #expect(PnlPeriod.wholeSpan(of: "2026-Q3")! == ("2026-07-01", "2026-09-30"))
        #expect(PnlPeriod.wholeSpan(of: "2026-Q1")! == ("2026-01-01", "2026-03-31"))
        #expect(PnlPeriod.wholeSpan(of: "2028-02")! == ("2028-02-01", "2028-02-29"))
        #expect(PnlPeriod.wholeSpan(of: "2026-Q5") == nil)
        #expect(PnlPeriod.wholeSpan(of: "nonsense") == nil)
    }

    // MARK: - Through the engine

    static let vat15 = MoneyTaxFixesTests.vat15
    static let salesTax = MoneyTaxFixesTests.salesTax

    static func job(_ id: String, _ date: String, _ price: Double) -> JSONValue {
        .object(["id": .string(id), "status": .string("completed"), "date": .string(date),
                 "price": .number(price), "paidAmount": .number(price)])
    }

    static let orders: [JSONValue] = [
        job("a", "2026-07-10", 115), job("b", "2026-09-05", 230), job("c", "2026-10-02", 115),
    ]
    static let expenses: [JSONValue] = [
        .object(["id": .string("e1"), "date": .string("2026-09-12"), "amount": .number(115),
                 "vatAmount": .number(15), "category": .string("rent")]),
        .object(["id": .string("e2"), "date": .string("2026-09-20"), "amount": .number(50),
                 "category": .string("other")]),
    ]

    static func input(_ settings: [String: JSONValue], from: String? = nil, to: String? = nil,
                      granularity: String = "month") -> PnlInputs {
        PnlInputs(orders: orders, expenses: expenses, settings: settings,
                  now: day(2026, 10, 16), granularity: granularity, from: from, to: to)
    }

    @Test("the span reaches the rule: only its records, and rows that say their days")
    func spanCrossesTheBridge() async throws {
        let engine = try KhaytEngine()
        let all = try await engine.pnlStatement(Self.input(Self.vat15))
        #expect(all.rows.map(\.period) == ["2026-10", "2026-09", "2026-07"])
        #expect(all.rows.allSatisfy { $0.from == nil && $0.to == nil })

        let sep = try await engine.pnlStatement(Self.input(Self.vat15, from: "2026-09-01", to: "2026-09-30",
                                                           granularity: "quarter"))
        let row = try #require(sep.rows.first)
        #expect(sep.rows.count == 1)
        #expect(row.period == "2026-Q3")
        #expect(row.orders == 1, "July is in Q3 but not in September")
        #expect(row.from == "2026-09-01")
        #expect(row.isPartial)
    }

    @Test("VAT, prices INCLUDE it: taken out of the sale, the purchase's tax reclaimed")
    func vatInclusive() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.pnlStatement(Self.input(Self.vat15, from: "2026-09-01", to: "2026-09-30"))
        let vat = out.vat
        #expect(vat.applies)
        #expect(vat.mode == "inclusive")
        #expect(vat.sales == 200)
        #expect(vat.output == 30)
        #expect(vat.input == 15)
        #expect(vat.net == 15)
        #expect(vat.position == "payable")
        #expect(vat.expensesWithVat == 1)
        #expect(vat.expensesWithoutVat == 1)
        let due = out.rows.reduce(0) { $0 + $1.vatDue }
        #expect(abs(due - vat.net) < 0.005, "the summary and the table disagree")
    }

    @Test("VAT, added on TOP: the price is revenue and the tax is extra")
    func vatExclusive() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.pnlStatement(Self.input(Self.salesTax, from: "2026-10-01", to: "2026-10-31"))
        let vat = out.vat
        #expect(vat.mode == "exclusive")
        #expect(vat.sales == 115)
        // 8.25% on top of 115.
        #expect(vat.output == 9.49)
        #expect(vat.input == 0)
        #expect(vat.net == 9.49)
    }

    @Test("no tax set: nothing to summarise, and nothing reclaimed in the P&L either")
    func vatNone() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.pnlStatement(Self.input(["currency": .string("SAR")]))
        #expect(out.vat.applies == false)
        #expect(out.rows.reduce(0) { $0 + $1.vatReclaimable } == 0)
    }

    @Test("the CSV: a BOM, the period, plain numbers; the HTML right to left in Western digits")
    func documents() async throws {
        let engine = try KhaytEngine()
        let docs = try await engine.pnlDocuments(
            Self.input(Self.vat15, from: "2026-09-01", to: "2026-09-30"),
            labels: ["title": "الأرباح والخسائر", "vatNet": "صافي الضريبة المستحقة"],
            periodLabel: "الشهر الماضي", currency: "SAR", rightToLeft: true, language: "ar",
            shopName: "Khayt")
        #expect(docs.csv.hasPrefix("\u{FEFF}\"الأرباح والخسائر\",\"الشهر الماضي\""))
        let lines = docs.csv.components(separatedBy: "\r\n")
        #expect(lines.contains("\"From\",\"2026-09-01\""))
        #expect(lines.contains("\"صافي الضريبة المستحقة\",15"))
        let sep = try #require(lines.first { $0.hasPrefix("\"2026-09\"") })
        #expect(sep == "\"2026-09\",1,200,0,0,0,0,150,0,50,100,30,15,15")
        #expect(docs.html.hasPrefix("<div class=\"pnl-doc\" dir=\"rtl\" lang=\"ar\">"))
        let easternDigits = docs.html.unicodeScalars.contains { (0x0660...0x0669).contains($0.value) }
        #expect(!easternDigits, "the PDF prints Arabic-Indic digits")
    }
}
