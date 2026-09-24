import Foundation

extension QueueOrder {
    var isOverdue: Bool {
        DueDateParser.isOverdue(dueDate)
    }

    var formattedDueDate: String? {
        guard let dueDate, !dueDate.isEmpty else { return nil }
        return dueDate
    }
}

extension OrderLogEntry {
    var isOverdue: Bool {
        DueDateParser.isOverdue(dueDate)
    }
}

enum DueDateParser {
    private static let formats = ["yyyy-MM-dd", "yyyy/MM/dd", "dd/MM/yyyy", "MM/dd/yyyy"]

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
