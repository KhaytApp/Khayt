import Foundation

/// When a customer's invoice falls due — `lib/payment-terms.js`, in Swift.
///
/// Ported so a screen that holds a customer and their jobs (the customer
/// pane, the phone) can say "overdue" without a trip through the JavaScript
/// engine. The JavaScript stays the specification: `PaymentTermsParityTests`
/// loads the real `lib/` file and refuses any disagreement.
///
/// THE RULE: due = invoice date (`order.date`, else its `timestamp`, first ten
/// characters — the date the invoice prints) + the customer's
/// `paymentTermsDays`. Absent, zero, negative or unreadable terms are 0, due on
/// receipt. Overdue is PAST the due date — not on it — and not settled.
///
/// Days are `YYYY-MM-DD` and counted in a fixed UTC Gregorian calendar, so no
/// time zone or daylight-saving change can move a due date by a day. `today`
/// is the shop's local day, as `Calendar.book.dayString` gives it.
public enum PaymentTerms {

    /// What the pickers offer. Anything else is a custom number of days.
    public static let presets = [0, 7, 15, 30, 45, 60, 90]
    /// A year. Beyond it a number is a typo, not an agreement.
    public static let maxDays = 365

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// The terms a stored `paymentTermsDays` holds, in whole days.
    ///
    /// A number, or a string of digits. Not a bool, and not anything a lenient
    /// parser would read as a number (`"0x1e"`): neither is a term anybody
    /// agreed.
    public static func termsDays(_ value: JSONValue?) -> Int {
        let n: Double
        switch value {
        case .number(let d)?:
            n = d
        case .string(let s)?:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isDecimal(t), let d = Double(t) else { return 0 }
            n = d
        default:
            return 0
        }
        guard n.isFinite, n > 0 else { return 0 }
        return Int(min(Double(maxDays), n.rounded(.down)))
    }

    /// The terms of a customer record (`paymentTermsDays`), 0 for none.
    public static func termsDays(customer: [String: JSONValue]?) -> Int {
        termsDays(customer?["paymentTermsDays"])
    }

    /// `^\d+(\.\d+)?$`, the JavaScript's `NUMERIC` after its trim.
    private static func isDecimal(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }
    }

    /// The components of a real `YYYY-MM-DD`, or nil — "2026-02-30" is not one.
    private static func day(_ ymd: String) -> Date? {
        let b = Array(ymd.utf8)
        guard b.count == 10, b[4] == UInt8(ascii: "-"), b[7] == UInt8(ascii: "-") else { return nil }
        let digits = b.enumerated().filter { $0.offset != 4 && $0.offset != 7 }.map(\.element)
        guard digits.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        guard let y = Int(ymd.prefix(4)), let m = Int(ymd.dropFirst(5).prefix(2)),
              let d = Int(ymd.suffix(2)) else { return nil }
        let comps = DateComponents(year: y, month: m, day: d)
        guard let date = utc.date(from: comps) else { return nil }
        let back = utc.dateComponents([.year, .month, .day], from: date)
        guard back.year == y, back.month == m, back.day == d else { return nil }
        return date
    }

    private static func string(_ date: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `ymd` plus `n` days, `YYYY-MM-DD`; "" for a day that is not one.
    public static func addDays(_ ymd: String, _ n: Int) -> String {
        guard let d = day(ymd), let out = utc.date(byAdding: .day, value: n, to: d) else { return "" }
        return string(out)
    }

    /// Whole days from `from` to `to`, positive when `to` is later.
    public static func daysBetween(_ from: String, _ to: String) -> Int? {
        guard let a = day(from), let b = day(to) else { return nil }
        return utc.dateComponents([.day], from: a, to: b).day
    }

    /// The date the invoice is dated: `date`, else `timestamp`, first ten
    /// characters. "" when neither is a day.
    public static func invoiceDate(_ order: [String: JSONValue]) -> String {
        // JavaScript's `date || timestamp`: the first TRUTHY one. A truthy value
        // that is not a string (a number, an object) is never a day once
        // `String()` has had it, so it reads as "" rather than falling through.
        func pick(_ k: String) -> String?? {
            switch order[k] {
            case nil, .null?: return nil
            case .string(let s)?: return s.isEmpty ? nil : .some(s)
            case .bool(let b)?: return b ? .some(nil) : nil
            case .number(let n)?: return (n == 0 || n.isNaN) ? nil : .some(nil)
            default: return .some(nil)
            }
        }
        guard let picked = pick("date") ?? pick("timestamp"), let text = picked else { return "" }
        let s = String(text.prefix(10))
        return day(s) == nil ? "" : s
    }

    /// The day this invoice falls due on `terms` days, or "".
    public static func dueDate(invoiceDate: String, terms: Int) -> String {
        guard day(invoiceDate) != nil else { return "" }
        return addDays(invoiceDate, max(0, terms))
    }

    /// The day this order's invoice falls due for this customer, or "".
    public static func dueDate(order: [String: JSONValue], customer: [String: JSONValue]?) -> String {
        dueDate(invoiceDate: invoiceDate(order), terms: termsDays(customer: customer))
    }

    /// Days past the due date: positive once overdue, 0 on the day, negative
    /// before. Nil when there is no date to work from.
    public static func daysPastDue(order: [String: JSONValue], customer: [String: JSONValue]?,
                                   today: String) -> Int? {
        let due = dueDate(order: order, customer: customer)
        guard !due.isEmpty else { return nil }
        return daysBetween(due, String(today.prefix(10)))
    }

    /// Work that cannot owe: a quote, a cancelled job, a voided or credited invoice.
    public static func owesAtAll(_ order: [String: JSONValue]) -> Bool {
        func present(_ k: String) -> Bool {
            switch order[k] {
            case nil, .null?: return false
            case .string(let s)?: return !s.isEmpty
            case .bool(let b)?: return b
            case .number(let n)?: return n != 0 && !n.isNaN
            default: return true
            }
        }
        if case .string(let st)? = order["status"], st == "quote" || st == "cancelled" { return false }
        return !present("voidedAt") && !present("creditedAt")
    }

    /// Past due and not settled. `settled` is the caller's: it holds the money
    /// rule and the currencies.
    public static func overdue(order: [String: JSONValue], customer: [String: JSONValue]?,
                               today: String, settled: Bool) -> Bool {
        guard owesAtAll(order), !settled else { return false }
        guard let d = daysPastDue(order: order, customer: customer, today: today) else { return false }
        return d > 0
    }

    /// Past due, from an invoice date and terms already in hand.
    public static func isPastDue(invoiceDate: String, terms: Int, today: String) -> Bool {
        let due = dueDate(invoiceDate: String(invoiceDate.prefix(10)), terms: terms)
        guard !due.isEmpty, let d = daysBetween(due, String(today.prefix(10))) else { return false }
        return d > 0
    }
}
