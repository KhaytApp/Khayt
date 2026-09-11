import Foundation
import KhaytCore

/// What the shop spent, as the book records it.
///
/// Decoded leniently for the same reason `Order` is: an expense written by an
/// older build, or by the phone, is missing fields this app would otherwise
/// refuse — and a row that will not decode is counted and never shown.
struct Expense: Identifiable, Decodable, Hashable, Sendable {
    let id: String
    let date: String
    let category: String
    let amount: Double
    let note: String
    let orderId: String?
    let receiptPath: String?
    /// "monthly", "quarterly", "annually" — or nil for a one-off.
    let recurring: String?
    let nextDue: String?

    private enum CodingKeys: String, CodingKey {
        case id, date, category, amount, note, orderId, receiptPath, recurring, nextDue
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "other"
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        orderId = try c.decodeIfPresent(String.self, forKey: .orderId)
        receiptPath = try c.decodeIfPresent(String.self, forKey: .receiptPath)
        recurring = try c.decodeIfPresent(String.self, forKey: .recurring)
        nextDue = try c.decodeIfPresent(String.self, forKey: .nextDue)
    }

    var day: Date? { Order.day(date) }
}

/// A failed print, and what it cost.
struct WasteEntry: Identifiable, Decodable, Hashable, Sendable {
    let id: String
    let date: String
    let material: String
    /// One of the nine the log knows; anything else was filed as `other`.
    let failureType: String
    let weight: Double
    let cost: Double
    let reason: String
    let notes: String
    let orderId: String?
    let machineId: String?
    /// The spool the grams came off, when they were deducted from one. Written
    /// since #971; entries older than that have none, and deleting one of those
    /// cannot put the filament back.
    let spoolId: String?

    private enum CodingKeys: String, CodingKey {
        case id, date, material, failureType, weight, cost, reason, notes, orderId, machineId, spoolId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        material = try c.decodeIfPresent(String.self, forKey: .material) ?? ""
        failureType = try c.decodeIfPresent(String.self, forKey: .failureType) ?? "other"
        weight = try c.decodeIfPresent(Double.self, forKey: .weight) ?? 0
        cost = try c.decodeIfPresent(Double.self, forKey: .cost) ?? 0
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        orderId = try c.decodeIfPresent(String.self, forKey: .orderId)
        machineId = try c.decodeIfPresent(String.self, forKey: .machineId)
        spoolId = try c.decodeIfPresent(String.self, forKey: .spoolId)
    }

    var day: Date? { Order.day(date) }
}

/// The period a list is showing, in Khayt's own order.
///
/// The values are `lib/date-range.js`'s, so "this month" means the same thing
/// on both screens and in both apps. `custom` is not offered yet — the two
/// screens that have it in Khayt carry a pair of date fields with it, and a
/// range picker that silently shows everything is worse than one fewer option.
enum Period: String, CaseIterable, Identifiable {
    case month, last_month, quarter, year, all
    var id: String { rawValue }
    /// Khayt's own label for it.
    var key: String { "an.range." + rawValue }
}


/// What a shop reads at the end of a month: what it made, what it is still
/// owed, and who it made it from. On the Shop rather than the view, so a
/// snapshot run can turn the page — the same reason the period and the
/// settings pane are.
enum ReportPage: String, CaseIterable, Identifiable {
    case profit, owing, best, quoting, machines, custom
    var id: String { rawValue }
    var key: String {
        switch self {
        case .profit:   return "an.pnl_title"
        case .owing:    return "an.aged_receivables"
        case .best:     return "mac.best"
        case .quoting:  return "mac.quoting"
        case .machines: return "mac.mpl_title"
        case .custom:   return "rb.title"
        }
    }
}
