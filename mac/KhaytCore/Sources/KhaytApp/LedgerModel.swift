import SwiftUI
import KhaytCore

/// What the Ledger reads.
///
/// The one rule this file exists to hold: a figure the book was never told is
/// `nil`, all the way through. `charged` is a Double because a job always has
/// a price; `margin` is an Optional because a margin needs a cost, and a cost
/// the shop never recorded is not zero. Every dash on that screen comes from
/// an Optional that was never filled rather than from a view deciding to draw
/// one, which is the only version of §5 that survives contact with a table.
extension Shop {

    enum LedgerFilter: CaseIterable, Hashable {
        case needsMe, running, unpaid, all

        var titleKey: String {
            switch self {
            case .needsMe: "mac.filter_needs_me"
            case .running: "mac.filter_running"
            case .unpaid:  "mac.filter_unpaid"
            case .all:     "mac.filter_all"
            }
        }
    }

    /// One row.
    struct LedgerLine: Identifiable, Hashable {
        let id: String
        let state: ShopState
        let title: String
        let who: String
        /// Already formatted — "−1d", "17:00", "Wed 16" — because "due" is a
        /// relative reading whose words differ per language, and a Date in the
        /// row would put that decision in the view.
        let due: String
        let charged: Double
        /// Nil when the cost is unknown. NOT zero.
        let margin: Double?
        let net: Double?
        let vat: Double?
        let marginMoney: Double?
        let reference: String
        /// One sentence saying why the cost is not known, or nil when it is.
        let costUnknownWhy: String?
    }

    var ledgerRows: [LedgerLine] {
        shownForLedger.map(line(for:))
    }

    private var shownForLedger: [Order] {
        let rows: [Order]
        switch ledgerFilter {
        case .needsMe: rows = orders.filter { isLate($0) || !$0.isSettled }
        case .running: rows = orders.filter { $0.status.lowercased() == "printing" }
        case .unpaid:  rows = orders.filter { !$0.isSettled }
        case .all:     rows = orders
        }
        // Urgency, not date: late first, then due, then the rest. The spec's
        // own words for the default sort.
        return rows.sorted { a, b in
            let (x, y) = (urgency(a), urgency(b))
            if x != y { return x < y }
            return (a.dueDate ?? a.date) < (b.dueDate ?? b.date)
        }
    }

    func ledgerCount(_ filter: LedgerFilter) -> Int {
        switch filter {
        case .needsMe: orders.count { isLate($0) || !$0.isSettled }
        case .running: orders.count { $0.status.lowercased() == "printing" }
        case .unpaid:  orders.count { !$0.isSettled }
        case .all:     orders.count
        }
    }

    /// What the rows on screen come to. Only the ones that HAVE a figure —
    /// and `ledgerUnpricedNote` says how many did not, so the total is never
    /// read as covering more than it does.
    var ledgerShownTotal: Double? {
        let open = shownForLedger.filter { !$0.isSettled }
        return open.isEmpty ? nil : open.reduce(0) { $0 + $1.owed }
    }

    var ledgerUnpricedNote: String? {
        let blind = shownForLedger.count { $0.costBasis <= 0 && !$0.parts.isEmpty }
        guard blind > 0 else { return nil }
        return words.counting(blind, "mac.n_without_cost")
    }

    private func line(for order: Order) -> LedgerLine {
        let costKnown = order.costBasis > 0
        return LedgerLine(
            id: order.id,
            state: state(of: order),
            title: order.project,
            who: order.client.isEmpty ? words.callIt("mac.no_customer") : order.client,
            due: dueWords(order),
            charged: order.price,
            margin: costKnown && order.price > 0
                ? (order.price - order.costBasis) / order.price : nil,
            net: nil,
            vat: nil,
            marginMoney: costKnown ? order.price - order.costBasis : nil,
            reference: "#" + order.id,
            costUnknownWhy: costKnown ? nil : words.callIt("mac.cost_never_recorded"))
    }

    private func state(of order: Order) -> ShopState {
        if order.isSettled { return .done }
        if isLate(order) { return .late }
        switch order.status.lowercased() {
        case "printing":        return .running
        case "quote", "quoted": return .quoted
        case "post", "qc":      return .finishing
        default:                return .queued
        }
    }

    private func isLate(_ order: Order) -> Bool {
        if let resolved = order.isLateResolved { return resolved }
        guard let due = Order.day(order.dueDate ?? ""), !order.isSettled else { return false }
        return due < Calendar.current.startOfDay(for: Date())
    }

    private func urgency(_ order: Order) -> Int {
        if isLate(order) { return 0 }
        if let due = Order.day(order.dueDate ?? ""),
           Calendar.current.isDateInToday(due) { return 1 }
        if order.isSettled { return 4 }
        return 2
    }

    /// "−2d", "17:00", "Wed 16" — the shortest true reading.
    private func dueWords(_ order: Order) -> String {
        guard let due = Order.day(order.dueDate ?? "") else { return "—" }
        let start = Calendar.current.startOfDay(for: Date())
        let days = Calendar.current.dateComponents([.day], from: start, to: due).day ?? 0
        if days < 0 { return "−" + String(-days) + "d" }
        if days == 0 { return due.formatted(date: .omitted, time: .shortened) }
        return due.formatted(.dateTime.weekday(.abbreviated).day())
    }

    /// A spool, as a shop says it: "PLA Basic · Black".
    func spoolName(_ spool: Spool) -> String {
        let colour = spool.colourVariant ?? spool.color
        guard let colour, !colour.isEmpty else { return spool.material }
        return spool.material + " · " + colour
    }

    /// What a machine tile says. The three readings §4 distinguishes: running
    /// with a figure, idle, and a machine Khayt has no protocol for.
    func tileReading(for machine: Machine) -> (percent: Double?, state: ShopState, line: String) {
        let reading = printers.readings[machine.id]?.status
        if let reading, PrinterWatch.isPrinting(reading.state) {
            return (Double(reading.progress) / 100, .running,
                    reading.filename.isEmpty ? words.callIt("mac.printing") : reading.filename)
        }
        if reading == nil {
            return (nil, .offline, words.callIt("mac.no_protocol"))
        }
        return (nil, .queued, words.callIt("mac.idle"))
    }
}
