import SwiftUI
import KhaytCore

/// What the Dashboard reads — the model behind `Triage.swift`.
///
/// ── BUILT ON THE SHARED RULE, NOT BESIDE IT ───────────────────────────────
///
/// Every card here comes from `lib/attention.js` by way of `DashboardFacts` —
/// the same rule the other app shows, already loaded, already counted. A
/// Swift pass over `orders` that decided for itself what "late" means would be
/// a second opinion about the one question the screen exists to answer, and
/// the two would drift the first time either was touched.
///
/// What IS decided here is presentation: which three of them to show, in what
/// order, and what the buttons under each one say.
extension Shop {

    /// One card on the Triage board.
    struct TriageItem: Identifiable {
        let id: String
        let state: ShopState
        /// The caps line: "TWO JOBS ARE LATE".
        let title: String
        let lines: [Line]
        let actions: [TriageAction]

        struct Line {
            /// What it is — a job, a spool, a machine.
            let subject: String
            /// Why it is here, as a sentence a shop can act on. Never a code.
            let because: String
        }
    }

    /// A button under a card. `weight` is §6's four, and `.outward` is the one
    /// that is a rule rather than a style.
    struct TriageAction: Identifiable {
        let id: String
        let titleKey: String
        var weight: Weight = .ordinary
        /// Anything that reaches a customer: drawn differently, ends in an
        /// ellipsis, and confirms before it sends.
        var reachesCustomer = false
        let go: Shelf?

        enum Weight { case primary, brand, ordinary, outward }
    }

    /// At most three, worst first.
    ///
    /// Three because that is what fits at 1100×620 without scrolling, and
    /// because a triage list of nine is a list, not a triage. The rest are one
    /// click away in the Ledger, which is exactly what the mode switch is for.
    var triageCards: [TriageItem] {
        guard let items = attention?.items, !items.isEmpty else { return [] }
        var byKind: [String: [DashboardFacts.Item]] = [:]
        for item in items { byKind[item.kind, default: []].append(item) }

        // Worst first, and "worst" is the shared rule's own severity rather
        // than an order invented here.
        let order = ["order", "stock", "nozzle", "machine"]
        let kinds = byKind.keys.sorted {
            (order.firstIndex(of: $0) ?? order.count) < (order.firstIndex(of: $1) ?? order.count)
        }
        return kinds.prefix(3).compactMap { kind in card(kind: kind, items: byKind[kind] ?? []) }
    }

    private func card(kind: String, items: [DashboardFacts.Item]) -> TriageItem? {
        guard !items.isEmpty else { return nil }
        // The worst of them, not whichever happened to be first: a card
        // headed "9 jobs are late" that takes its colour from a job merely due
        // today is a card that under-reports itself.
        // The worst of them, not whichever happened to be first — and a job
        // with days on the clock is `crit` whatever the rule graded it, since
        // severity says HOW bad and `daysLate` says the work is already over.
        let overdue = kind == "order" && items.contains { ($0.daysLate ?? 0) > 0 }
        let worst = overdue || items.contains { $0.severity == "crit" } ? "crit" : "warn"
        let state = ShopState.of(kind: kind, severity: worst)
        let lines = items.prefix(2).map { item in
            TriageItem.Line(subject: item.name ?? words.callIt("mac.untitled"),
                            because: because(item, kind: kind))
        }
        return TriageItem(
            id: kind,
            state: state,
            // Counted only where a count is the point. "9 jobs are late" is a
            // number a shop acts on; "2 The shelf is thin" is a number glued to
            // a sentence that never asked for one.
            title: kind == "order"
                ? words.counting(items.count, "mac.attn_order")
                : words.callIt("mac.attn_" + kind),
            lines: Array(lines),
            actions: actions(for: kind))
    }

    /// The sentence under a line. Assembled from the rule's own fields, and
    /// always saying the thing a shop would need to decide — how late, how
    /// much is left, what it is holding up.
    private func because(_ item: DashboardFacts.Item, kind: String) -> String {
        switch kind {
        case "order":
            if let days = item.daysLate {
                return words.counting(days, "mac.days_over")
            }
            return words.callIt("mac.past_its_date")
        case "stock":
            if let grams = item.grams {
                return words.callIt("mac.grams_left",
                                    ["n": .number(grams)])
            }
            return words.callIt("mac.out_of_stock")
        case "machine", "nozzle":
            return item.state ?? words.callIt("mac.needs_a_look")
        default:
            return item.state ?? words.callIt("mac.needs_a_look")
        }
    }

    private func actions(for kind: String) -> [TriageAction] {
        switch kind {
        case "order":
            [.init(id: "open", titleKey: "mac.open_both", weight: .primary, go: .jobs(nil)),
             // Reaches a customer: `latebg`, an envelope, an ellipsis, and a
             // confirmation. §6's fourth weight.
             .init(id: "tell", titleKey: "mac.tell_the_customers",
                   weight: .outward, reachesCustomer: true, go: nil)]
        case "stock":
            [.init(id: "buy", titleKey: "mac.log_a_purchase", weight: .primary, go: .expenses),
             .init(id: "shelf", titleKey: "mac.see_shelf", go: .inventory)]
        case "machine", "nozzle":
            [.init(id: "machines", titleKey: "mac.machines", weight: .primary, go: .machines)]
        default:
            [.init(id: "jobs", titleKey: "mac.all_jobs", weight: .primary, go: .jobs(nil))]
        }
    }

    /// The rule's own words are `crit` and `warn` — read from
    /// `lib/attention.js` rather than guessed at. Guessing produced "high",
    /// which matched nothing, so every card drew the warn glyph and nine late
    /// jobs looked like nine things due this afternoon.
    func perform(_ action: TriageAction) {
        if let go = action.go { shelf = go }
    }

    // MARK: - The masthead's four figures

    /// What customers owe. From the shared rule where it has run, because the
    /// dashboard's own figure and a Swift sum of `owed` are two numbers that
    /// must not be allowed to disagree.
    var owedTotal: Double? { facts?.owed ?? (orders.isEmpty ? nil : owed) }

    var openJobCount: Int { orders.count { !$0.isSettled } }

    /// The month, named. "SEPTEMBER · NET" — the month is part of the label
    /// because a figure with no period on it is the commonest way a dashboard
    /// lies by omission.
    var monthNetLabel: String {
        let month = words.say(Date(), .dateTime.month(.wide)).uppercased()
        return month + " · " + words.callIt("mac.net")
    }

    /// Revenue this month, net of tax.
    ///
    /// ── THIS WAS A PERMANENT DASH, AND WHAT CHANGED ───────────────────────
    ///
    /// It read `nil`, always, citing §5 — "Reports is the only place they are
    /// reconciled" — on the grounds that net-of-tax depends on whether the
    /// shop prices tax-inclusive, "a mode this reading is not given", and a
    /// figure divided by a VAT rate that may not apply is the subtly-wrong
    /// number the whole section is about.
    ///
    /// The reasoning was right and the conclusion had an unexamined premise:
    /// the mode was not unavailable, it simply was not asked for. So the
    /// masthead's LARGEST figure, in its most prominent slot, labelled with
    /// the month, printed an em dash on every shop for ever — and a permanent
    /// dash in prime position is not caution, it is a screen giving up on its
    /// own headline.
    ///
    /// It now comes from `lib/pnl-report.js` at month granularity: the SAME
    /// rule, given the SAME settings, that Reports prints. That is what §5 is
    /// protecting — one reconciliation, not two — and two screens reading one
    /// rule is the form of it this codebase uses everywhere else.
    ///
    /// Still nil before the book is read, and for a month with no row of its
    /// own. The dash is then what it always should have meant: nothing to
    /// show yet, rather than nothing we are willing to say.
    var monthNet: Double? { monthNetRevenue }
    var monthGross: Double? { monthTotals }

    /// Only while there is no figure. A note explaining an absence, printed
    /// under a number that is present, reads as a warning about that number.
    var monthNetNote: String? {
        monthNetRevenue == nil ? words.callIt("mac.net_in_reports") : nil
    }

    /// What the month's material cost is KNOWN to be.
    ///
    /// Nil when nothing is known; otherwise the sum of what is, labelled "at
    /// least" by the masthead — never averaged over the jobs that recorded
    /// nothing. `materialCostGapNote` is the one line that says why.
    var monthMaterialCost: Double? {
        let known = thisMonthsOrders.filter { $0.costBasis > 0 }.map(\.costBasis)
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    var materialCostGapNote: String? {
        let missing = thisMonthsOrders.count { $0.costBasis <= 0 && !$0.parts.isEmpty }
        guard missing > 0 else { return nil }
        return words.counting(missing, "mac.n_jobs_unrecorded")
    }

    private var thisMonthsOrders: [Order] {
        let month = Calendar.current.dateComponents([.year, .month], from: Date())
        return orders.filter { order in
            guard let day = Order.day(order.date) else { return false }
            let its = Calendar.current.dateComponents([.year, .month], from: day)
            return its.year == month.year && its.month == month.month
        }
    }

    private var monthTotals: Double? {
        let settled = thisMonthsOrders.filter { $0.isSettled }
        guard !settled.isEmpty else { return nil }
        return settled.reduce(0) { $0 + $1.price }
    }
}
