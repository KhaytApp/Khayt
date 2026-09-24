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
        /// Whether there is anything left to do about the money.
        ///
        /// Here rather than derived from `state`, because they stopped being
        /// the same question: a job can be DONE and unpaid, and that row is
        /// one a shop still has to act on.
        let settled: Bool
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
        let where_ = state(of: order)
        return LedgerLine(
            id: order.id,
            state: where_,
            title: order.project,
            who: order.client.isEmpty ? words.callIt("mac.no_customer") : order.client,
            due: dueWords(order, at: where_),
            charged: order.price,
            margin: costKnown && order.price > 0
                ? (order.price - order.costBasis) / order.price : nil,
            net: nil,
            vat: nil,
            marginMoney: costKnown ? order.price - order.costBasis : nil,
            reference: "#" + order.id,
            costUnknownWhy: costKnown ? nil : words.callIt("mac.cost_never_recorded"),
            settled: order.isSettled)
    }

    /// Where the work stands — which is what this screen says it answers.
    ///
    /// ── A QUARTER OF THE ROWS SAID THE WRONG THING ────────────────────────
    ///
    /// The switch handled four statuses and sent everything else to `.queued`,
    /// whose word is "Queued" in English and "في الانتظار" — *waiting* — in
    /// Arabic. On the sample shop that was six of the twenty-four unsettled
    /// rows: four jobs the shop had FINISHED and two it had CANCELLED, all
    /// drawn as work waiting to be made, on the screen whose stated job is
    /// "where does the work stand".
    ///
    /// Every status the book can hold is named here now, and the `default` is
    /// gone — a fall-through is what made a cancelled job read as queued, and
    /// leaving one in means the next status added does it again.
    private func state(of order: Order) -> ShopState {
        let status = order.status.lowercased()
        // CANCELLED FIRST, before the money. A cancelled job can carry an
        // unpaid balance for ever — nothing will ever settle it — so testing
        // settlement first would leave it reading as live work indefinitely.
        if status == "cancelled" { return .cancelled }
        if order.isSettled { return .done }
        if isLate(order) { return .orderLate }
        switch status {
        case "printing":                          return .running
        case "quote", "quoted":                   return .quoted
        case "post", "qc":                        return .finishing
        // THE WORK IS DONE; the money is what is not. That is the `charged`
        // column's business and the `unpaid` filter's, and it is why the row
        // stops dimming on this state — see `LedgerRow`.
        case "completed", "shipped", "delivered": return .done
        case "pending", "on_hold":                return .queued
        default:                                  return .queued
        }
    }

    private func isLate(_ order: Order) -> Bool {
        if let resolved = order.isLateResolved { return resolved }
        guard let due = Order.day(order.dueDate ?? ""), !order.isSettled else { return false }
        return due < Calendar.book.startOfDay(for: Date())
    }

    private func urgency(_ order: Order) -> Int {
        if isLate(order) { return 0 }
        if let due = Order.day(order.dueDate ?? ""),
           Calendar.book.isDateInToday(due) { return 1 }
        if order.isSettled { return 4 }
        return 2
    }

    /// "−2d", "17:00", "Wed 16" — the shortest true reading.
    ///
    /// ── A COUNTDOWN IS ONLY TRUE OF WORK STILL IN FLIGHT ──────────────────
    ///
    /// It counted for every row, so a job the shop FINISHED in April read
    /// "−144d" — a hundred and forty-four days late, about something that is
    /// done. The same for a job the shop cancelled, which is not late and
    /// never will be. On a book whose unsettled rows are a quarter finished
    /// work, that is a column of warnings about the past.
    ///
    /// A promise date is only a deadline until the thing is made. Afterwards
    /// it is a fact, and the fact a shop wants is WHEN — so a finished or
    /// cancelled row shows the date it was due and stops counting.
    private func dueWords(_ order: Order, at state: ShopState) -> String {
        guard let due = Order.day(order.dueDate ?? "") else { return "—" }
        if state == .done || state == .cancelled {
            return words.say(due, .dateTime.day().month(.abbreviated))
        }
        let start = Calendar.book.startOfDay(for: Date())
        let days = Calendar.book.dateComponents([.day], from: start, to: due).day ?? 0
        if days < 0 { return "−" + String(-days) + "d" }
        if days == 0 { return words.say(due, Date.FormatStyle(date: .omitted, time: .shortened)) }
        return words.say(due, .dateTime.weekday(.abbreviated).day())
    }

    /// A spool, as a shop says it: "PLA Basic · Black".
    func spoolName(_ spool: Spool) -> String {
        let colour = spool.colourVariant ?? spool.color
        guard let colour, !colour.isEmpty else { return spool.material }
        return spool.material + " · " + colour
    }

    /// WHY a machine is not printing — and they are four different facts.
    ///
    /// ── THE DEFECT THIS EXISTS FOR ────────────────────────────────────────
    ///
    /// `tileReading` had one test — "is there a reading" — and said **"no
    /// link"** for everything that failed it. So the front door told a shop
    /// the same sentence about a laser cutter Khayt has no protocol for, a
    /// Snapmaker somebody has not typed an address into yet, and a perfectly
    /// well configured printer that simply had not answered its first poll of
    /// the morning. One of those is permanent, one takes thirty seconds to
    /// fix, and one is not a problem at all.
    ///
    /// `Dashboard.Tile` had already been through this — its own comment says
    /// all five tiles once read "Khayt cannot ask this machine" including
    /// three printers Khayt speaks four protocols for, and that "those are
    /// different facts and only one of them is fixable". That reasoning was
    /// never applied to the strip that actually ships on Triage, which is the
    /// default front door. Two views answering one question, and the one
    /// people look at had the wrong answer.
    ///
    /// So it is one rule now, here, and both tiles ask it.
    enum Quiet {
        /// A KIND with no protocol in this repo — a laser, a UV flatbed.
        /// Nothing to do about it, and saying "not connected" would send
        /// somebody looking for a setting that cannot exist.
        case noProtocol
        /// A printer Khayt speaks to, with no address typed in yet. The one
        /// that is worth a shop's thirty seconds.
        case notSetUp
        /// Set up, asked, and silent. Different from never having been asked.
        case notAnswering
        /// Answering, and not printing. Not a problem; the ordinary state of
        /// a machine between jobs.
        case idle

        var wordKey: String {
            switch self {
            case .noProtocol:   "mac.no_protocol"
            case .notSetUp:     "mac.not_connected"
            case .notAnswering: "mac.attn_state_offline"
            case .idle:         "mac.idle"
            }
        }

        /// THE GLYPH NAMES THE KIND, THE WORD CARRIES THE SEVERITY —
        /// `StateMark`'s own rule, and it settles this cleanly.
        ///
        /// Three of these four are the same KIND: a quiet machine with
        /// nothing wrong. Not set up, nothing to set up, and simply between
        /// jobs all draw `queued`, and the sentence underneath is what tells
        /// them apart. Only one is a different kind — set up, asked, and
        /// silent is a machine to go and look at — and only that one gets a
        /// different mark.
        ///
        /// The first version gave `noProtocol` the `quoted` diamond, which is
        /// the mark for a job that is only a quote. That file says in as many
        /// words that no glyph appears in two tables, and borrowing one is how
        /// a set stops meaning anything.
        var state: ShopState {
            switch self {
            case .notAnswering:              .machineCheck
            case .noProtocol, .notSetUp, .idle: .queued
            }
        }
    }

    func quiet(_ machine: Machine) -> Quiet {
        // AN ANSWER BEATS EVERY GUESS. If the machine has told this app what
        // it is doing, nothing read off the settings can contradict it — and
        // this test was third at first, so a machine that had answered was
        // still reported as not set up because its record was thin.
        if printers.readings[machine.id]?.status != nil { return .idle }
        // Is this KIND askable at all? `lib/machine-kinds.js` answers it, and
        // it is a fact about the kind rather than about the setup.
        guard kind(of: machine)?.polled ?? true else { return .noProtocol }
        guard PrinterWatch.notWatched(machine) == nil else { return .notSetUp }
        return .notAnswering
    }

    /// What a machine tile says: a print in progress, or why there is not one.
    func tileReading(for machine: Machine) -> TileReading {
        if let status = printers.readings[machine.id]?.status,
           PrinterWatch.isPrinting(status.state) {
            return TileReading(percent: Double(status.progress) / 100, state: .running,
                               line: status.timeRemaining.map(PrinterWatch.spell)
                                     ?? words.callIt("mac.printing"),
                               filename: status.filename)
        }
        let why = quiet(machine)
        return TileReading(percent: nil, state: why.state, line: words.callIt(why.wordKey),
                           filename: "")
    }
}

/// What one machine tile draws.
///
/// A struct rather than a tuple because the running case carries three things
/// now — how far, how long, and what — and a four-field tuple read at two call
/// sites is how the wrong element gets picked.
struct TileReading {
    /// 0…1 while a print is running, and nil otherwise. NOT a change: it was
    /// drawn with `Figure.signedPercent` and every running machine on the
    /// front door said "+48%", as though a print nearly half done were a rise
    /// of 48 percent in something. Nobody saw it because no picture of a
    /// running tile had ever been taken — neither book this app is
    /// photographed against can reach a printer.
    let percent: Double?
    let state: ShopState
    /// The sentence under the name: the time left while printing, and why it
    /// is not printing otherwise.
    let line: String
    /// Only while running, and only for the tooltip — the name of a sliced
    /// file is a long ugly string and the tile is two hundred points wide.
    let filename: String
}
