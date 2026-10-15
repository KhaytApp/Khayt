import Foundation

/// Which stretch of the book the profit and loss covers.
///
/// The shop picks it on the Reports screen — this month, last month, this or
/// last quarter, this or last year, two days of its own, or every period the
/// book holds — and every figure on the page follows it: the table's rows, the
/// totals, the waterfall, the VAT summary and the exported file.
///
/// ── THE BOOK CALENDAR, AND WHOLE PERIODS ─────────────────────────────────
///
/// The days are worked out in `Calendar.book` — Gregorian, this Mac's time
/// zone — and NEVER `Calendar.current`, which on a Mac set to Umm al-Qura
/// would make "this month" a Hijri month (see `BookCalendar.swift`). A named
/// period is the WHOLE period, last day included, even while it is still
/// running: `lib/pnl-report.js` already charges the period in progress its
/// overhead only up to today, and a shop that dated a job tomorrow still sees
/// it under "this month".
///
/// Portable on purpose — KhaytCore ships in the phone too.
public struct PnlRange: Equatable, Hashable, Sendable {
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case all, month, last_month, quarter, last_quarter, year, last_year, custom
        public var id: String { rawValue }

        /// The catalogue key for its name. Khayt's own words where Khayt has
        /// them — the analytics range names and the tax export's — so this
        /// screen does not invent a second word for "last quarter".
        public var key: String {
            switch self {
            case .all:          return "an.range.all"
            case .month:        return "an.range.month"
            case .last_month:   return "an.range.last_month"
            case .quarter:      return "an.range.quarter"
            case .last_quarter: return "tax.last_quarter"
            case .year:         return "an.range.year"
            case .last_year:    return "pnl.range_last_year"
            case .custom:       return "tax.custom_range"
            }
        }
    }

    /// What a range comes to: every period, a span of book days, or a custom
    /// range that cannot be read — which is NOT every period. A picker that
    /// quietly shows the whole book when the dates are wrong is worse than one
    /// that says they are wrong.
    public enum Resolved: Equatable, Sendable {
        case everything
        /// Book days, `YYYY-MM-DD`; an empty end is open.
        case span(from: String, to: String)
        case invalid
    }

    public var kind: Kind
    /// The custom range's ends, as the shop typed them. Kept when another
    /// period is picked, so switching back finds them still there.
    public var from: String
    public var to: String

    public init(_ kind: Kind = .all, from: String = "", to: String = "") {
        self.kind = kind
        self.from = from
        self.to = to
    }

    /// The days the range covers, as of `now`.
    public func resolve(now: Date = Date(), calendar: Calendar = .book) -> Resolved {
        let parts = calendar.dateComponents([.year, .month], from: now)
        let year = parts.year ?? 1970, month = parts.month ?? 1
        func day(_ y: Int, _ m: Int, _ d: Int) -> String { String(format: "%04d-%02d-%02d", y, m, d) }
        func last(_ y: Int, _ m: Int) -> Int {
            guard let first = calendar.date(from: DateComponents(year: y, month: m, day: 1)) else { return 28 }
            return calendar.range(of: .day, in: .month, for: first)?.count ?? 28
        }
        /// `count` months from the first of (y, m), which may run back a year.
        func months(_ y: Int, _ m: Int, _ count: Int) -> Resolved {
            var (y0, m0) = (y, m)
            while m0 < 1 { m0 += 12; y0 -= 1 }
            var (y1, m1) = (y0, m0 + count - 1)
            while m1 > 12 { m1 -= 12; y1 += 1 }
            return .span(from: day(y0, m0, 1), to: day(y1, m1, last(y1, m1)))
        }
        let quarterStart = ((month - 1) / 3) * 3 + 1
        switch kind {
        case .all:          return .everything
        case .month:        return months(year, month, 1)
        case .last_month:   return months(year, month - 1, 1)
        case .quarter:      return months(year, quarterStart, 3)
        case .last_quarter: return months(year, quarterStart - 3, 3)
        case .year:         return months(year, 1, 12)
        case .last_year:    return months(year - 1, 1, 12)
        case .custom:
            let a = from.trimmingCharacters(in: .whitespaces)
            let b = to.trimmingCharacters(in: .whitespaces)
            // An end typed but not a real day is wrong, not open.
            if !a.isEmpty, !Self.isDay(a, calendar) { return .invalid }
            if !b.isEmpty, !Self.isDay(b, calendar) { return .invalid }
            if a.isEmpty && b.isEmpty { return .invalid }
            if !a.isEmpty, !b.isEmpty, a > b { return .invalid }
            return .span(from: a, to: b)
        }
    }

    /// A real Gregorian day written the way the book writes one. "2026-02-30"
    /// has the shape and is not a day.
    public static func isDay(_ text: String, _ calendar: Calendar = .book) -> Bool {
        guard text.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil,
              let y = Int(text.prefix(4)), let m = Int(text.dropFirst(5).prefix(2)),
              let d = Int(text.suffix(2)),
              let date = calendar.date(from: DateComponents(year: y, month: m, day: d))
        else { return false }
        return calendar.dayString(date) == text
    }

    /// For `@SceneStorage`, which holds strings: `kind|from|to`.
    public var stored: String { "\(kind.rawValue)|\(from)|\(to)" }

    public init?(stored: String) {
        let parts = stored.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, let kind = Kind(rawValue: first) else { return nil }
        self.init(kind, from: parts.count > 1 ? parts[1] : "", to: parts.count > 2 ? parts[2] : "")
    }

    /// The span in a file name: `2026-07-01_2026-09-30`, `all-time`, or
    /// `from-2026-01-01`. Book days rather than a name, because a name is in
    /// the shop's language and "this month" means a different month next
    /// month — the file has to say which one it holds.
    public func fileStem(now: Date = Date(), calendar: Calendar = .book) -> String {
        switch resolve(now: now, calendar: calendar) {
        case .everything, .invalid:
            return "all-time-" + calendar.dayString(now)
        case .span(let a, let b):
            if a.isEmpty { return "to-" + b }
            if b.isEmpty { return "from-" + a }
            return a + "_" + b
        }
    }
}

public extension PnlRange.Resolved {
    /// Is a record dated `date` inside? Compared as book-day strings, the way
    /// `lib/pnl-report.js` and `lib/vat-summary.js` compare them, so a list
    /// narrowed here holds what the P&L beside it counted.
    func contains(_ date: String) -> Bool {
        switch self {
        case .everything: return true
        case .invalid: return false
        case .span(let from, let to):
            let day = String(date.prefix(10))
            guard day.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil else { return false }
            if !from.isEmpty && day < from { return false }
            if !to.isEmpty && day > to { return false }
            return true
        }
    }

    /// The span's ends, or nil for every period.
    var bounds: (from: String, to: String)? {
        if case .span(let a, let b) = self { return (a, b) }
        return nil
    }
}

public extension PnlPeriod {
    /// The days a period key names, whole: "2026-Q3" is 1 July to 30
    /// September, "2026-09" is September. Nil for a key of neither shape.
    static func wholeSpan(of key: String, calendar: Calendar = .book) -> (from: String, to: String)? {
        guard key.count >= 7, let year = Int(key.prefix(4)) else { return nil }
        let first: Int, count: Int
        if key.dropFirst(4).hasPrefix("-Q"), let q = Int(key.dropFirst(6)), (1...4).contains(q) {
            first = (q - 1) * 3 + 1; count = 3
        } else if let m = Int(key.dropFirst(5).prefix(2)), (1...12).contains(m), key.count == 7 {
            first = m; count = 1
        } else { return nil }
        let lastMonth = first + count - 1
        guard let start = calendar.date(from: DateComponents(year: year, month: lastMonth, day: 1)),
              let days = calendar.range(of: .day, in: .month, for: start)?.count else { return nil }
        return (String(format: "%04d-%02d-01", year, first),
                String(format: "%04d-%02d-%02d", year, lastMonth, days))
    }

    /// True when the chosen span holds only some of this period's days — this
    /// month under the quarter view — so a label naming the period alone
    /// would claim days the figures do not cover.
    var isPartial: Bool {
        guard let from, let to, let whole = Self.wholeSpan(of: period) else { return false }
        return from != whole.from || to != whole.to
    }
}

/// Everything `pnlByPeriod` is asked with, gathered once so the screen and the
/// export ask the SAME question — a file that disagreed with the screen it was
/// exported from would be worse than no file.
public struct PnlInputs: Sendable {
    public var orders: [JSONValue]
    public var expenses: [JSONValue]
    public var settings: [String: JSONValue]
    public var clients: [JSONValue]
    public var currencies: [String: JSONValue]
    public var now: Date
    public var granularity: String
    public var wasteLog: [JSONValue]
    public var inventory: [JSONValue]
    public var machines: [JSONValue]
    public var recentMonthlyHours: [String: Double]
    public var timeEntries: [JSONValue]
    /// Book days; nil is every period in the book.
    public var from: String?
    public var to: String?

    public init(orders: [JSONValue], expenses: [JSONValue], settings: [String: JSONValue],
                clients: [JSONValue] = [], currencies: [String: JSONValue] = [:], now: Date,
                granularity: String = "quarter", wasteLog: [JSONValue] = [],
                inventory: [JSONValue] = [], machines: [JSONValue] = [],
                recentMonthlyHours: [String: Double] = [:], timeEntries: [JSONValue] = [],
                from: String? = nil, to: String? = nil) {
        self.orders = orders; self.expenses = expenses; self.settings = settings
        self.clients = clients; self.currencies = currencies; self.now = now
        self.granularity = granularity; self.wasteLog = wasteLog; self.inventory = inventory
        self.machines = machines; self.recentMonthlyHours = recentMonthlyHours
        self.timeEntries = timeEntries; self.from = from; self.to = to
    }

    /// The span as the rule takes it, or null for every period.
    var rangeJSON: JSONValue {
        let a = from ?? "", b = to ?? ""
        if a.isEmpty && b.isEmpty { return .null }
        return .object(["from": .string(a), "to": .string(b)])
    }

    /// The arguments in the order the expressions below number them.
    var arguments: [JSONValue] {
        [.array(orders), .array(expenses), .object(settings), .array(clients),
         .object(currencies), .number(now.timeIntervalSince1970 * 1000), .string(granularity),
         .array(wasteLog), .array(inventory), .array(machines),
         .object(recentMonthlyHours.mapValues { .number($0) }), .array(timeEntries), rangeJSON]
    }

    /// `pnlByPeriod`'s context, for an expression that has bound `arguments`.
    static let context = "{settings: ARG2, clients: ARG3, currencies: ARG4, now: new Date(ARG5), granularity: ARG6, wasteLog: ARG7, inventory: ARG8, machines: ARG9, recentMonthlyHours: ARG10, timeEntries: ARG11, range: ARG12}"
}

/// The VAT owed for the span: `lib/vat-summary.js`'s `summarize`.
public struct VatSummary: Decodable, Sendable, Equatable {
    /// False for a shop with no tax set, and then nothing is drawn.
    public let applies: Bool
    /// What the shop's tax is called — "VAT", "GST".
    public let name: String
    /// "inclusive" (prices hold the tax, taken out of revenue) or "exclusive"
    /// (added on top; revenue is the price typed).
    public let mode: String
    public let rates: [Rate]
    /// Revenue the tax was charged on, net of it.
    public let sales: Double
    /// Output VAT: charged on the span's sales.
    public let output: Double
    /// Input VAT: what the span's expenses RECORDED paying. An expense entered
    /// without its tax reclaims nothing — see `expensesWithoutVat`.
    public let input: Double
    /// output − input. Negative is a refund due, not an error.
    public let net: Double
    /// "payable", "refund" or "nil".
    public let position: String
    public let expensesWithVat: Int
    public let expensesWithoutVat: Int

    public struct Rate: Decodable, Sendable, Equatable {
        public let label: String
        public let percent: Double
    }
}

/// The P&L over a span and the VAT for it, asked in one go.
public struct PnlStatement: Decodable, Sendable, Equatable {
    public let rows: [PnlPeriod]
    public let vat: VatSummary
}

/// The same statement written out: a CSV (BOM, plain numbers) and the HTML a
/// PDF is printed from.
public struct PnlDocuments: Decodable, Sendable, Equatable {
    public let csv: String
    public let html: String
}
