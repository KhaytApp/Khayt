import Foundation

extension QueueOrder {
    var isOverdue: Bool {
        DueDateParser.isOverdue(dueDate)
    }

    var formattedDueDate: String? { DueDateParser.display(dueDate) }
}

extension OrderLogEntry {
    var isOverdue: Bool {
        DueDateParser.isOverdue(dueDate)
    }

    /// Whether a quote's last day has gone by, on the shop's calendar day —
    /// the same comparison `lib/lan-quote-page.js` makes before it lets a
    /// customer approve one. A quote with no last day never expires.
    func isQuoteExpired(today: String = BookReader.today()) -> Bool {
        guard let last = quoteExpiresAt?.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty else {
            return false
        }
        return String(last.prefix(10)) < today
    }
}

/// The Quotes list: which records are on it, and in what order.
///
/// Quotes are not in the queue — `/api/queue` and the book's own queue rule
/// both leave them out, because a quote is not work yet — and History takes
/// only finished jobs. So a quote made on this phone used to vanish from it
/// the moment it was saved. This is the list that keeps it.
enum QuoteList {
    /// Open quotes only, newest first, as the book's `date` says; the id breaks
    /// a tie so two quotes made the same day keep one order between reloads.
    static func select(_ entries: [OrderLogEntry]) -> [OrderLogEntry] {
        entries.filter { $0.status == OrderStatus.quote.rawValue }
            .sorted { a, b in
                let da = a.date ?? "", db = b.date ?? ""
                return da != db ? da > db : a.id > b.id
            }
    }
}

enum DueDateParser {
    private static let formats = ["yyyy-MM-dd", "yyyy/MM/dd", "dd/MM/yyyy", "MM/dd/yyyy"]

    /// A day from the book, for a person: "8 Oct" / "8 أكتوبر" in the app's
    /// language (Western digits), the year only when it is not this one —
    /// rather than the book's "2026-10-08", which read as a stray Western
    /// number on an Arabic screen. Unparseable: as written.
    ///
    /// Gregorian, always: the book's days are Gregorian, and a Saudi phone's
    /// own calendar is Umm al-Qura (see `pulse`).
    static func display(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let date = parse(raw) else { return raw }
        let gregorian = Calendar(identifier: .gregorian)
        let thisYear = gregorian.isDate(date, equalTo: Date(), toGranularity: .year)
        let style = Date.FormatStyle(date: .omitted, time: .omitted, locale: L10n.locale, calendar: gregorian)
            .day().month(.abbreviated)
        return thisYear ? date.formatted(style) : date.formatted(style.year())
    }

    static func isOverdue(_ raw: String?) -> Bool {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let due = parse(raw) else { return false }
        return due < Calendar.current.startOfDay(for: Date())
    }

    static func parse(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 10 {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: trimmed) { return d }
            iso.formatOptions = [.withInternetDateTime]
            if let d = iso.date(from: trimmed) { return d }
            let prefix = String(trimmed.prefix(10))
            for f in formats {
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.dateFormat = f
                if let d = df.date(from: prefix) { return d }
            }
        }
        for f in formats {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = f
            if let d = df.date(from: trimmed) { return d }
        }
        return nil
    }
}

extension OrderStatus {
    var localizedLabel: String {
        switch self {
        case .quote: return L10n.tr("status.quote")
        case .pending: return L10n.tr("status.pending")
        case .printing: return L10n.tr("status.printing")
        case .post: return L10n.tr("status.post")
        case .qc: return L10n.tr("status.qc")
        case .completed: return L10n.tr("status.completed")
        case .delivered: return L10n.tr("status.delivered")
        // `shipped` reached the enum and `label` but not this switch, and a
        // non-exhaustive switch is a COMPILE error — so `ios/` did not build at
        // all on main. Nothing said so: `ci.yml`'s required checks never run
        // `xcodebuild`, and the iOS contract check compiles `KhaytModels.swift`
        // on its own, which is the one file that WAS finished.
        case .shipped: return L10n.tr("status.shipped")
        case .on_hold: return L10n.tr("status.on_hold")
        }
    }
}

/// A job is the same job while its id is — so a page pushed for it survives
/// the queue being reloaded underneath it.
extension QueueOrder: Hashable {
    static func == (a: QueueOrder, b: QueueOrder) -> Bool {
        a.id == b.id && a.status == b.status && a.machineId == b.machineId && a.dueDate == b.dueDate
    }
    func hash(into h: inout Hasher) { h.combine(id) }
}

extension QueueOrder {
    /// A finished job from history, as the order page reads one. The queue
    /// shape is what the page draws; history simply has no printer to show.
    init(entry: OrderLogEntry) {
        self.init(id: entry.id, project: entry.project, client: entry.client, status: entry.status,
                  machine: nil, machineId: nil, dueDate: entry.dueDate, priority: nil)
    }
}

/// A spool is the same spool while its id is, so its page survives the list
/// being reloaded underneath it.
extension InventorySpool: Hashable {
    static func == (a: InventorySpool, b: InventorySpool) -> Bool {
        a.id == b.id && a.remaining == b.remaining && a.weight == b.weight
    }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// The customer's answer to a quote, as the order page writes it.
///
/// Both go through `BookWriter.setOrderStatus` (by way of
/// `KhaytAPIClient.updateOrderStatus`), never a write of their own: that is
/// where a move out of `quote` is stamped `quoteAcceptedAt` and a move into
/// `cancelled` is stamped `cancelledAt`, and where the shop's order-status rule
/// will run when the phone takes it on.
///
/// Decline CANCELS, it does not delete. The desktop's Reject removes the quote
/// (or cancels it, when it already took money); a phone that deleted records
/// would be one more way to lose them, and a cancelled quote is still the
/// record of what was offered and turned down.
enum QuoteAnswer {
    case approve
    case decline

    var status: String {
        switch self {
        case .approve: return OrderStatus.pending.rawValue
        case .decline: return "cancelled"
        }
    }
}
