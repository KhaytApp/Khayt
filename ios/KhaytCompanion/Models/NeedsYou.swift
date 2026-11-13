import Foundation

/// Home's "Needs you" list — what needs the owner, worked out from what Home
/// already loads. Pure, so the rules the shared design sets (Figma
/// Qqxg4imtKVgC3TfNGcRGOk 91:1156, "Rules every app keeps") are tested here
/// rather than looked for on a screen:
///
/// - one row per KIND of problem, never one per item ("3 jobs are late");
/// - at most five kinds, the rest folded into "and N more";
/// - a kind with nothing in it is not a row, and no rows is the calm state;
/// - late first, then what stops the next job, then what waits on the shop,
///   then what waits on someone else;
/// - late means `QueueOrder.isOverdue` — past its day AND still open — the
///   same rule as `lib/attention.js` `isOpenOrder`, so the number matches the
///   Mac's.
enum NeedsYou {
    enum Kind: String, CaseIterable, Sendable {
        /// Open jobs past their due day.
        case late
        /// Spools at or under the low-stock line (`InventorySpool.isLowStock`).
        case lowStock
        /// Job requests in intake, waiting for the shop to answer.
        case waiting
        /// Open quotes, waiting for the customer.
        case quotes
    }

    /// The colour role a row takes: red for late, amber for what needs doing
    /// today, steel for what waits on someone else.
    enum Tone: Sendable { case late, today, waitingOnOthers }

    struct Row: Identifiable, Equatable, Sendable {
        let kind: Kind
        /// How many things of this kind — what the row's title counts.
        let count: Int
        /// The line under the title: which ones, or the worst of them.
        let detail: String
        var id: Kind { kind }

        var tone: Tone {
            switch kind {
            case .late: return .late
            case .lowStock, .waiting: return .today
            case .quotes: return .waitingOnOthers
            }
        }
    }

    /// The rows Home draws, and how many kinds were folded away.
    struct Summary: Equatable, Sendable {
        let shown: [Row]
        /// Kinds past the fifth, said as "and N more".
        let more: Int
        /// Every kind that needs the owner — the greeting's count.
        var total: Int { shown.count + more }
        var isCalm: Bool { total == 0 }
    }

    static let limit = 5

    /// One row per kind with something in it, most urgent first.
    ///
    /// `quotes` is nil when this phone cannot see them (the native Mac serves
    /// no `/api/orders`): an unknown is not a zero, so it adds no row either way.
    static func rows(queue: [QueueOrder], spools: [InventorySpool],
                     waiting: [WaitingListItem], quotes: [OrderLogEntry]? = nil) -> [Row] {
        var rows: [Row] = []

        let late = queue.filter(\.isOverdue)
        if !late.isEmpty {
            let detail: String
            if late.count == 1, let one = late.first {
                detail = one.formattedDueDate.map { L10n.format("needs.late.one", one.displayTitle, $0) }
                    ?? one.displayTitle
            } else {
                detail = late.map(\.displayTitle).joined(separator: " · ")
            }
            rows.append(Row(kind: .late, count: late.count, detail: detail))
        }

        // Emptiest first, as `lib/attention.js` sorts the shelf: the spool
        // closest to stopping a job is the one the line names.
        let low = spools.filter(\.isLowStock)
            .sorted { ($0.remainingGrams ?? 0, $0.id) < ($1.remainingGrams ?? 0, $1.id) }
        if let first = low.first {
            let grams = L10n.grams(Int((first.remainingGrams ?? 0).rounded()))
            let detail = L10n.count("needs.low.count", low.count) + " · "
                + L10n.format("needs.low.left", first.displayLabel, grams)
            rows.append(Row(kind: .lowStock, count: low.count, detail: detail))
        }

        if !waiting.isEmpty {
            rows.append(Row(kind: .waiting, count: waiting.count,
                            detail: waiting.map(\.displayClient).joined(separator: " · ")))
        }

        if let quotes {
            let open = QuoteList.select(quotes)
            if !open.isEmpty {
                rows.append(Row(kind: .quotes, count: open.count,
                                detail: open.map(\.displayTitle).joined(separator: " · ")))
            }
        }
        return rows
    }

    /// The first five, and how many more there were.
    static func fold(_ rows: [Row], limit: Int = NeedsYou.limit) -> Summary {
        Summary(shown: Array(rows.prefix(limit)), more: max(0, rows.count - limit))
    }

    static func summary(queue: [QueueOrder], spools: [InventorySpool],
                        waiting: [WaitingListItem], quotes: [OrderLogEntry]? = nil) -> Summary {
        fold(rows(queue: queue, spools: spools, waiting: waiting, quotes: quotes))
    }

    /// "Good morning." — by the hour on the phone's clock.
    static func greetingKey(hour: Int) -> String {
        switch hour {
        case 4..<12: return "home.greeting.morning"
        case 12..<17: return "home.greeting.afternoon"
        default: return "home.greeting.evening"
        }
    }

    /// Open jobs due from today through the next six days, soonest first. A
    /// late job is not here: it is already the first row of Needs you.
    static func dueThisWeek(_ queue: [QueueOrder], now: Date = Date()) -> [QueueOrder] {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 7, to: today) else { return [] }
        let dated: [(QueueOrder, Date)] = queue.compactMap { order in
            guard OrderOpenness.isOpen(status: order.status, voided: order.voided),
                  let raw = order.dueDate, !raw.isEmpty,
                  let due = DueDateParser.parse(raw) else { return nil }
            let day = calendar.startOfDay(for: due)
            return (day >= today && day < end) ? (order, day) : nil
        }
        return dated.sorted { ($0.1, $0.0.id) < ($1.1, $1.0.id) }.map(\.0)
    }

    /// "2 of 3": machines with a printing job on them, of the machines that
    /// can take work. Nil when the phone has no machines to count — a figure
    /// it cannot work out is hidden, never a dash.
    static func onTheMachines(_ machines: [MachineInfo], queue: [QueueOrder]) -> (busy: Int, of: Int)? {
        let working = machines.filter(\.isAssignable)
        guard !working.isEmpty else { return nil }
        let printingOn = Set(queue.filter { $0.status == OrderStatus.printing.rawValue }.compactMap(\.machineId))
        return (working.filter { printingOn.contains($0.id) }.count, working.count)
    }
}
