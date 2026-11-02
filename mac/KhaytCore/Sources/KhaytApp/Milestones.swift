import Foundation
import KhaytCore

/// One milestone of a job: a part of the price asked for on its own.
///
/// ── THE SHAPE IS THE DESKTOP'S ────────────────────────────────────────────
///
/// `order.milestoneInvoices` is an array of
/// `{ id, label, percentage, amount, issuedAt }` (`openMilestoneInvoices` in
/// renderer/app-exports.js). `id` is `uid('MS')` — `"MS-"` + base36 time +
/// three random capitals — `amount` is in the JOB'S OWN currency, the same
/// units as `order.price`, and `issuedAt` is a book-calendar `YYYY-MM-DD`
/// stamped when the document is produced. A milestone added in either app
/// shows in both, so this app reads and writes exactly that.
///
/// Anything else a milestone carries (`paidAt`, whatever a newer build adds)
/// is NOT this app's to drop. Every write below edits the stored array in place
/// — append, remove by id, set one key on one entry — and never rebuilds an
/// entry from the fields this struct knows. `Milestone` is only what the sheet
/// READS.
struct Milestone: Identifiable, Equatable, Sendable {
    let id: String
    var label: String
    var percentage: Double
    var amount: Double
    /// The day a proforma for it was last produced, or nil if never.
    var issuedAt: String?

    init(id: String, label: String, percentage: Double, amount: Double, issuedAt: String? = nil) {
        self.id = id; self.label = label; self.percentage = percentage
        self.amount = amount; self.issuedAt = issuedAt
    }

    /// An entry as stored. Nil for one with no id — it cannot be addressed, so
    /// it is neither listed nor touched (and stays in the book as it is).
    init?(_ value: JSONValue) {
        guard case .object(let o) = value, let id = Shop.plainString(o["id"]), !id.isEmpty else { return nil }
        self.id = id
        label = Shop.plainString(o["label"]) ?? ""
        percentage = Milestones.number(o["percentage"])
        amount = Milestones.number(o["amount"])
        let day = Shop.plainString(o["issuedAt"]) ?? ""
        issuedAt = day.isEmpty ? nil : day
    }

    /// What the document is handed: `milestone` in `lib/invoice-document.js`.
    func document(of total: Double) -> JSONValue {
        .object(["label": .string(label), "percentage": .number(percentage),
                 "amount": .number(amount), "total": .number(total)])
    }
}

enum Milestones {
    static let key = "milestoneInvoices"

    /// The milestones on a job's raw record, in the order they are stored.
    static func read(_ order: JSONValue?) -> [Milestone] {
        guard case .object(let o)? = order, case .array(let list)? = o[key] else { return [] }
        return list.compactMap(Milestone.init)
    }

    /// What `percent` of `price` comes to, to the cent — the figure a new
    /// milestone starts with (the shop may then type another).
    static func amount(percent: Double, of price: Double) -> Double {
        guard percent.isFinite, price.isFinite else { return 0 }
        return ((percent * price / 100) * 100).rounded() / 100
    }

    /// `uid('MS')` as the desktop writes it (renderer/util.js).
    static func newId(now: Date = Date()) -> String {
        let time = String(Int(now.timeIntervalSince1970 * 1000), radix: 36)
        let letters = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        let salt = String((0..<3).map { _ in letters.randomElement()! }).uppercased()
        return "MS-" + time + salt
    }

    /// The job with a milestone appended. Every other key — and every other
    /// milestone, known keys or not — is as it was.
    static func adding(_ milestone: Milestone, to order: JSONValue) -> JSONValue {
        guard case .object(var o) = order else { return order }
        var list: [JSONValue] = []
        if case .array(let existing)? = o[key] { list = existing }
        var entry: [String: JSONValue] = [
            "id": .string(milestone.id), "label": .string(milestone.label),
            "percentage": .number(milestone.percentage), "amount": .number(milestone.amount),
        ]
        if let day = milestone.issuedAt { entry["issuedAt"] = .string(day) }
        list.append(.object(entry))
        o[key] = .array(list)
        return .object(o)
    }

    /// The job without milestone `id`. Nothing else moves.
    static func removing(_ id: String, from order: JSONValue) -> JSONValue {
        guard case .object(var o) = order, case .array(let list)? = o[key] else { return order }
        o[key] = .array(list.filter { Milestone($0)?.id != id })
        return .object(o)
    }

    /// The job with milestone `id` stamped as issued on `day`: one key on one
    /// entry, so a `paidAt` or anything else beside it survives.
    static func stamping(_ id: String, on day: String, in order: JSONValue) -> JSONValue {
        guard case .object(var o) = order, case .array(var list)? = o[key] else { return order }
        for i in list.indices {
            guard case .object(var entry) = list[i], Milestone(list[i])?.id == id else { continue }
            entry["issuedAt"] = .string(day)
            list[i] = .object(entry)
        }
        o[key] = .array(list)
        return .object(o)
    }

    /// A number the way the book may spell it: a number, or a numeral string.
    static func number(_ value: JSONValue?) -> Double {
        switch value {
        case .number(let n): return n
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces)) ?? 0
        default: return 0
        }
    }
}
