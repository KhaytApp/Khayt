import SwiftUI
import KhaytCore

/// What the shop spent.
///
/// A table of expenses for a period, the totals beside it, and budget against
/// actual for every category the shop has set one on. The record an entry
/// writes is `lib/expense-book.js`'s, so an expense added here is the same
/// record Khayt would have written.
struct Expenses: View {
    @Bindable var shop: Shop
    @State private var order: [KeyPathComparator<Expense>] = [.init(\.date, order: .reverse)]
    @SceneStorage("expenses.columns") private var columns: TableColumnCustomization<Expense>

    private var rows: [Expense] { shop.shownExpenses.sorted(using: order) }

    var body: some View {
        VStack(spacing: 0) {
            DueRecurring(shop: shop)
            screen
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Khayt.ground)
        .screenToolbar { SpendToolbar(shop: shop, add: { shop.addingExpense = true },
                                      addLabel: shop.words.callIt("exp.add_title")) }
        .shopSheet(isPresented: $shop.addingExpense, onDismiss: { shop.receiptPrefill = nil }) { ExpenseSheet(shop: shop) }
        .shopSheet(isPresented: $shop.readingReceipt) { ReceiptReaderSheet(shop: shop) }
    }

    private var screen: some View {
        Group {
            // AN EMPTY BOOK IS ONE STATE, NOT THREE PANES. With nothing ever
            // recorded, the split drew an empty table, a summary of zeros and
            // a wide gap between them — three panes saying "nothing" in three
            // ways. The whole screen says it once, with the way in. A filter
            // that matches nothing still keeps the split: there IS a summary.
            if shop.expenses.isEmpty {
                EmptyHere(title: shop.words.callIt("mac.expenses_empty"), mark: .expenses) {
                    HStack(spacing: 10) {
                        Button(shop.words.callIt("exp.add_title")) { shop.addingExpense = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(!shop.canMoveJobs)
                        Button(shop.words.callIt("mac.receipt_add") + "\u{2026}") { shop.startReadingReceipt() }
                            .disabled(!shop.canMoveJobs)
                    }
                    // Why the buttons are grey, as Customers says it.
                    WhyLockedNote(shop: shop)
                }
            } else {
                HSplitView {
                    table
                    Summary(shop: shop).frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The standing costs that have come round, each with the desktop's two
    /// answers: Add files this cycle's copy (`lib/expense-book.js`
    /// `comeRound`), Skip moves the schedule on and files nothing.
    ///
    /// A strip above the table rather than a toast: the desktop's toast is
    /// gone in eight seconds and asks again at the next launch, and a list
    /// that stays until it is answered says the same thing without a timer.
    /// Nothing at all when nothing is due.
    struct DueRecurring: View {
        @Bindable var shop: Shop
        @State private var due: [Expense] = []
        @State private var busy = false

        var body: some View {
            VStack(spacing: 0) {
                ForEach(due.prefix(5)) { e in
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Khayt.attention)
                        Text(label(e))
                            .lineLimit(1).truncationMode(.tail)
                        Text(e.nextDue ?? "").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Spacer()
                        Button(shop.words.callIt("mac.recurring_skip")) { answer(e, add: false) }
                            .disabled(busy || !shop.canMoveJobs)
                        Button(shop.words.callIt("common.add")) { answer(e, add: true) }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy || !shop.canMoveJobs)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    Divider()
                }
                if due.count > 5 {
                    Text(shop.words.counting(due.count - 5, "mac.recurring_more"))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 5)
                    Divider()
                }
            }
            .background(due.isEmpty ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.quaternary.opacity(0.4)))
            .task(id: shop.expenses) { due = await shop.dueRecurringExpenses() }
        }

        /// One line per due expense. Built in steps: as a single `+` chain
        /// inside `Text(...)` the release compiler gave up type-checking it.
        private func label(_ e: Expense) -> String {
            let due: String = shop.words.callIt("exp.recurring_due")
            let category: String = shop.words.callIt("exp.cat." + e.category)
            let amount: String = Money.text(e.amount, shop.currency)
            var line = due + ": " + category + " " + amount
            if !e.note.isEmpty { line += " \u{00B7} " + e.note }
            return line
        }

        private func answer(_ e: Expense, add: Bool) {
            busy = true
            Task {
                await shop.answerRecurring(e.id, add: add)
                due = await shop.dueRecurringExpenses()
                busy = false
            }
        }
    }

    private var table: some View {
        Table(rows, sortOrder: $order, columnCustomization: $columns) {
            TableColumn(shop.words.callIt("exp.date"), value: \.date) { e in
                Text(e.day.map { shop.words.say($0, Date.FormatStyle(date: .abbreviated, time: .omitted)) } ?? e.date)
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 110)
            TableColumn(shop.words.callIt("exp.category"), value: \.category) { e in
                Label(shop.words.callIt("exp.cat." + e.category), systemImage: Self.symbol(e.category))
                    .labelStyle(.titleAndIcon)
            }
            .width(min: 110, ideal: 150)
            TableColumn(shop.words.callIt("exp.amount"), value: \.amount) { e in
                Text(Money.text(e.amount, shop.currency)).monospacedDigit()
            }
            .width(min: 90, ideal: 110)
            TableColumn(shop.words.callIt("exp.note"), value: \.note) { e in
                HStack(spacing: 6) {
                    Text(e.note.isEmpty ? "—" : e.note)
                        .foregroundStyle(e.note.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                    if let recurring = e.recurring {
                        // What it repeats as, and when it is next due: the two
                        // things that tell a standing cost from a one-off.
                        Label(shop.words.callIt("exp.recurring_" + recurring)
                                + (e.nextDue.map { " · " + $0 } ?? ""),
                              systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 140, ideal: 260)
            // A COLUMN HEAD, not the form's label. The shared "Link to order
            // (optional)" is the expense sheet's field and was clipped here to
            // "Link to order (" — a column says what is in it, in a word.
            TableColumn(shop.words.callIt("mac.expense_order_col")) { e in
                Text(e.orderId ?? "—").monospacedDigit()
                    .foregroundStyle(e.orderId == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            }
            .width(min: 90, ideal: 120)
        }
        // The app's ground shows through rather than the system's white — the
        // pane beside this one sits on it, and an opaque table drew a seam
        // down the middle of the window.
        //
        // AND NO STRIPES. These two tables were the only ones in the app with
        // no `tableStyle` at all, so they took the system default: alternating
        // fills, and — worse — the fill continues past the last row. A shop
        // with six waste entries got six rows and then twenty empty grey bands
        // down the rest of the window, which reads as a list that failed to
        // load rather than as a short list.
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .overlay {
            if rows.isEmpty {
                EmptyHere(title: shop.words.callIt(shop.expenses.isEmpty ? "mac.expenses_empty" : "exp.empty_filter"), mark: .expenses)
            }
        }
    }

    /// A category's own mark, so the table reads at a glance.
    static func symbol(_ category: String) -> String {
        switch category {
        case "filament": "line.3.horizontal.decrease"
        case "electricity": "bolt"
        case "maintenance": "wrench.and.screwdriver"
        case "tools": "hammer"
        case "equipment": "printer"
        case "shipping": "shippingbox"
        default: "square.grid.2x2"
        }
    }

    /// Revenue, expenses, profit — and every category's budget against actual.
    private struct Summary: View {
        let shop: Shop
        @State private var budgets: [BudgetRow] = []

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    let totals = shop.expenseTotals
                    DetailSection(shop.words.callIt("exp.summary")) {
                        DetailLine(shop.words.callIt("exp.sum.expenses"),
                                   Money.text(totals.total, shop.currency), strong: true)
                        ForEach(Shop.expenseCategories, id: \.self) { category in
                            let spent = totals.byCategory[category] ?? 0
                            if spent > 0 {
                                DetailLine(shop.words.callIt("exp.cat." + category),
                                           Money.text(spent, shop.currency), dim: true)
                            }
                        }
                    }
                    if !budgets.isEmpty {
                        DetailSection(shop.words.callIt("exp.budget_title")) {
                            ForEach(budgets) { row in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(shop.words.callIt("exp.cat." + row.category))
                                        Spacer()
                                        Text(Money.text(row.spent, shop.currency) + " / "
                                             + Money.text(row.budget, shop.currency))
                                            .monospacedDigit()
                                            .foregroundStyle(row.over ? AnyShapeStyle(Khayt.attention) : AnyShapeStyle(.secondary))
                                    }
                                    ProgressView(value: row.pct, total: 100)
                                        .tint(row.over ? Khayt.attention : .accentColor)
                                    if row.over {
                                        Text(shop.words.callIt("exp.over_budget"))
                                            .font(.caption).foregroundStyle(Khayt.attention)
                                    }
                                }
                                .font(.callout)
                            }
                        }
                    } else {
                        Text(shop.words.callIt("exp.no_budgets"))
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(Metric.pane)
            }
            // The BOOK moves these rows; the period picker does not. A budget
            // is a monthly thing — see `expenseTotalsThisMonth` — and this
            // panel says so in its own heading.
            .task(id: shop.expenses.count) { await recompute() }
        }

        private func recompute() async {
            guard let engine = shop.engine else { budgets = []; return }
            let settings = shop.settingsDict
            let table: [String: JSONValue]
            if case .object(let b)? = settings["expBudgets"] { table = b } else { table = [:] }
            budgets = (try? await engine.budgetProgress(shop.expenseTotalsThisMonth,
                                                        budgets: table)) ?? []
        }
    }
}

/// What the shop threw away.
struct Waste: View {
    @Bindable var shop: Shop
    @State private var order: [KeyPathComparator<WasteEntry>] = [.init(\.date, order: .reverse)]
    @State private var selection: WasteEntry.ID?
    /// The row the shop chose Delete on, held until it answers. No undo
    /// exists for a waste entry, so the one click asks first.
    @State private var deleting: WasteEntry?
    @SceneStorage("waste.columns") private var columns: TableColumnCustomization<WasteEntry>

    private var rows: [WasteEntry] { shop.shownWaste.sorted(using: order) }

    var body: some View {
        Group {
            // As the expenses screen: a log with nothing in it is one empty
            // state across the window, not a table, a trend and a gap.
            if shop.wasteRows.isEmpty {
                EmptyHere(title: shop.words.callIt("mac.waste_empty"), mark: .waste) {
                    Button(shop.words.callIt("waste.add")) { shop.loggingWaste = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(!shop.canMoveJobs)
                    WhyLockedNote(shop: shop)
                }
            } else {
                HSplitView {
                    table
                    Summary(shop: shop).frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Khayt.ground)
        .screenToolbar { SpendToolbar(shop: shop, add: { shop.loggingWaste = true },
                                      addLabel: shop.words.callIt("waste.add")) }
        .shopSheet(isPresented: $shop.loggingWaste, onDismiss: { shop.wastePrefill = nil }) { WasteSheet(shop: shop) }
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $order, columnCustomization: $columns) {
            TableColumn(shop.words.callIt("waste.date"), value: \.date) { w in
                Text(w.day.map { shop.words.say($0, Date.FormatStyle(date: .abbreviated, time: .omitted)) } ?? w.date)
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 110)
            TableColumn(shop.words.callIt("waste.material"), value: \.material) { w in
                Text(w.material.isEmpty ? "—" : w.material)
            }
            .width(min: 80, ideal: 110)
            // The FIGURE only. `waste.weight` is "Wasted weight (g)", and it
            // carries the unit in all nine languages — Arabic included, which
            // is where this was checked. Repeating it in the cell gave every
            // row "180 grams" under a heading that had already said (g); the
            // rule is `Money.figure`'s, one column heading rather than forty
            // repetitions.
            TableColumn(shop.words.callIt("waste.weight"), value: \.weight) { w in
                Text(Money.grams(w.weight)).monospacedDigit()
            }
            .width(min: 110, ideal: 130)
            TableColumn(shop.words.callIt("mac.failure_category"), value: \.failureType) { w in
                Text(shop.words.callIt("waste.ft." + w.failureType))
            }
            .width(min: 110, ideal: 150)
            TableColumn(shop.words.callIt("waste.reason"), value: \.reason) { w in
                Text(w.reason.isEmpty ? "—" : w.reason)
                    .foregroundStyle(w.reason.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 220)
            TableColumn(shop.words.callIt("waste.est_cost"), value: \.cost) { w in
                Text(Money.text(w.cost, shop.currency)).monospacedDigit()
            }
            .width(min: 90, ideal: 110)
            // THE REST OF WHAT THE FAILURE COST: the machine's time and the
            // power, beside the filament above (`lib/failed-print-cost.js`).
            // A dash, not a zero, on a row that has no breakdown — a failure
            // logged without a job, or before this existed, was never costed,
            // which is not the same as costing nothing.
            TableColumn(shop.words.callIt("mac.waste_machine")) { (w: WasteEntry) in
                Text(w.costMachine.map { Money.text($0, shop.currency) } ?? "—")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100)
            TableColumn(shop.words.callIt("mac.waste_power")) { (w: WasteEntry) in
                Text(w.costPower.map { Money.text($0, shop.currency) } ?? "—")
                    .monospacedDigit().foregroundStyle(.secondary)
                    .help(w.energyWh.map { Money.quantity($0 / 1000, decimals: 2) + " kWh" } ?? "")
            }
            .width(min: 80, ideal: 100)
            TableColumn(shop.words.callIt("mac.waste_full"), value: \.full) { w in
                Text(Money.text(w.full, shop.currency)).monospacedDigit()
                    .fontWeight(w.costFull == nil ? .regular : .semibold)
            }
            .width(min: 90, ideal: 110)
        }
        // As the expenses table above — including the stripes, which drew
        // twenty empty bands under this shop's six waste entries.
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: WasteEntry.ID.self) { ids in
            if let id = ids.first, shop.canMoveJobs {
                Button(shop.words.callIt("common.delete") + "\u{2026}", role: .destructive) {
                    deleting = rows.first { $0.id == id }
                }
            }
        }
        .askFirst($deleting,
                  title: { shop.words.callIt("mac.delete_product_q",
                                             ["name": .string(AskName.waste($0, words: shop.words))]) },
                  message: { _ in shop.words.callIt("mac.no_undo") },
                  confirm: shop.words.callIt("common.delete"),
                  cancel: shop.words.callIt("common.cancel")) { entry in
            Task { await shop.deleteWaste(entry.id) }
        }
        .overlay {
            if rows.isEmpty {
                EmptyHere(title: shop.words.callIt("mac.waste_empty"), mark: .waste)
            }
        }
    }

    /// What the failures really cost: filament, machine time, electricity.
    ///
    /// Information, not a P&L figure — the note says so, in those words, so a
    /// shop comparing this with the profit and loss is not left wondering why
    /// the two disagree. Only drawn once some row carries the breakdown.
    struct TrueCost: View {
        let shop: Shop
        let shown: [WasteEntry]
        /// `KhaytFailedPrintCost.totals` over the shown rows — the one
        /// definition of the three costs, the same one `WhereFailuresCost`
        /// groups by, so this total and those groups cannot disagree.
        @State private var totals: KhaytEngine.FailedCostTotals?

        var body: some View {
            Group {
                if let t = totals, t.costed > 0 {
                    DetailSection(shop.words.callIt("mac.waste_true_title")) {
                        DetailLine(shop.words.callIt("mac.waste_filament"), Money.text(t.material, shop.currency))
                        DetailLine(shop.words.callIt("mac.waste_machine"), Money.text(t.machine, shop.currency))
                        DetailLine(shop.words.callIt("mac.waste_power"), Money.text(t.power, shop.currency))
                        if t.energyWh > 0 {
                            DetailLine(shop.words.callIt("mac.waste_energy"),
                                       Money.quantity(t.energyWh / 1000, decimals: 2) + " kWh")
                        }
                        DetailLine(shop.words.callIt("mac.waste_full"),
                                   Money.text(t.full, shop.currency), strong: true)
                        Text(shop.words.callIt("mac.waste_true_note"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if t.costed < shown.count {
                            Text(shop.words.callIt("mac.waste_true_older"))
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .task(id: shown) { await sum() }
        }

        private func sum() async {
            guard let engine = shop.engine else { totals = nil; return }
            let ids = Set(shown.map(\.id))
            let log = shop.wasteRows.filter { Shop.recordId($0).map(ids.contains) ?? false }
            totals = try? await engine.failedCostTotals(wasteLog: log)
        }
    }

    /// WHERE the failures cost: the shown entries grouped by printer, by
    /// material or by customer, biggest true cost first
    /// (`KhaytFailedPrintCost.byGroup`). The same "true cost" as the section
    /// above, so the groups add up to its total — an entry whose printer, job
    /// or customer is not known is counted under "Unknown", not dropped.
    struct WhereFailuresCost: View {
        let shop: Shop
        let shown: [WasteEntry]
        @State private var by = "machine"
        @State private var rows: [KhaytEngine.FailedCostGroup] = []

        /// The top of the list; the table has the rest.
        static let shownRows = 5

        /// By customer only for somebody who may see the customers.
        private var groupings: [(String, String)] {
            var out = [("machine", "mac.waste_by_printer"), ("material", "mac.waste_by_material")]
            if shop.canShow(.customers) { out.append(("customer", "mac.waste_by_customer")) }
            return out
        }

        private struct Asked: Hashable {
            let by: String
            let shown: [WasteEntry]
        }

        var body: some View {
            if !shown.isEmpty {
                DetailSection(shop.words.callIt("mac.waste_where_title")) {
                    Picker("", selection: $by) {
                        ForEach(groupings, id: \.0) { key, word in
                            Text(shop.words.callIt(word)).tag(key)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    ForEach(rows.prefix(Self.shownRows)) { row in
                        DetailLine((row.unknown ? shop.words.callIt("mac.waste_unknown") : row.label)
                                   + " · " + shop.words.counting(row.count, "mac.waste_n_failures"),
                                   Money.text(row.full, shop.currency), dim: row.unknown)
                    }
                }
                .task(id: Asked(by: by, shown: shown)) { await group() }
            }
        }

        private func group() async {
            // A grouping the person may no longer see (signed out of a role
            // that could) falls back to the printer.
            if !groupings.contains(where: { $0.0 == by }) { by = "machine"; return }
            guard let engine = shop.engine else { rows = []; return }
            let ids = Set(shown.map(\.id))
            let log = shop.wasteRows.filter { Shop.recordId($0).map(ids.contains) ?? false }
            rows = (try? await engine.failedCostByGroup(
                wasteLog: log, by: by, orders: shop.orderRows, machines: shop.machineRows,
                spools: shop.inventoryRows, clients: shop.clientRows)) ?? []
        }
    }

    /// Entries, grams, cost — and which failures the shop keeps having.
    private struct Summary: View {
        let shop: Shop
        /// Six months of grams by failure type. Every entry, not the chosen
        /// period: a trend is the point, and a period is one column of it.
        @State private var trend: KhaytEngine.WasteTrend?

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    WasteTrendCard(shop: shop, trend: trend)
                    LayerRule()
                    let shown = shop.shownWaste
                    let grams = shown.reduce(0) { $0 + $1.weight }
                    let cost = shown.reduce(0) { $0 + $1.cost }
                    DetailSection(shop.words.callIt("exp.summary")) {
                        DetailLine(shop.words.callIt("waste.total_entries"), "\(shown.count)")
                        DetailLine(shop.words.callIt("waste.total_weight"),
                                   "\(Money.grams(grams)) \(shop.words.callIt("common.grams"))")
                        DetailLine(shop.words.callIt("waste.total_cost"),
                                   Money.text(cost, shop.currency), strong: true)
                        // AGAINST WHAT THE PERIOD EARNED — the desktop's
                        // figure and colours (`lib/waste-entry.js`
                        // `shareOfRevenue`), over the period's trade revenue
                        // (`tradeRevenue`, the goal bar's rule). Absent with
                        // no revenue to divide by.
                        if let share {
                            DetailLine(shop.words.callIt("waste.pct_revenue"),
                                       Money.quantity(share.pct, decimals: 1) + "%")
                                .foregroundStyle(share.tone == "bad" ? AnyShapeStyle(Khayt.late)
                                                 : share.tone == "warn" ? AnyShapeStyle(Khayt.attention)
                                                 : AnyShapeStyle(Khayt.done))
                        }
                    }
                    TopOrders(shop: shop, shown: shown)
                    TrueCost(shop: shop, shown: shown)
                    WhereFailuresCost(shop: shop, shown: shown)
                    let counts = Dictionary(grouping: shown, by: \.failureType).mapValues(\.count)
                    if !counts.isEmpty {
                        DetailSection(shop.words.callIt("waste.failure_breakdown")) {
                            ForEach(counts.sorted { $0.value > $1.value }, id: \.key) { kind, n in
                                DetailLine(shop.words.callIt("waste.ft." + kind), "\(n)")
                            }
                        }
                    }
                }
                .padding(Metric.pane)
            }
            .task(id: shop.wasteRows.count) {
                guard let engine = shop.engine else { return }
                trend = try? await engine.wasteTrend(wasteLog: shop.wasteRows, now: Date(), months: 6, named: 3)
            }
            .task(id: Asked(period: shop.period, shown: shop.shownWaste)) { await divide() }
        }

        @State private var share: KhaytEngine.WasteShare?
        private struct Asked: Hashable { let period: Period; let shown: [WasteEntry] }

        private func divide() async {
            guard let engine = shop.engine else { share = nil; return }
            let span = shop.wasteRevenueSpan()
            let cost = shop.shownWaste.reduce(0) { $0 + $1.cost }
            guard let revenue = await shop.tradeRevenue(from: span.from, to: span.to) else { share = nil; return }
            share = try? await engine.wasteShare(cost: cost, revenue: revenue)
        }
    }

    /// The jobs whose failures cost the most — the desktop's "Top orders by
    /// waste" (`lib/waste-entry.js` `topOrders`), over the shown entries.
    /// Only for somebody who may see the jobs; a row opens its job.
    struct TopOrders: View {
        let shop: Shop
        let shown: [WasteEntry]
        @State private var rows: [KhaytEngine.WasteOrder] = []

        var body: some View {
            Group {
                if shop.lockAllows("orders", "view"), !rows.isEmpty {
                    DetailSection(shop.words.callIt("waste.top_orders")) {
                        ForEach(rows) { row in
                            let job = shop.orders.first { $0.id == row.orderId }
                            Button {
                                guard job != nil else { return }
                                shop.shelf = .jobs(nil)
                                shop.search = ""
                                shop.selection = row.orderId
                            } label: {
                                DetailLine((job.map { $0.project.isEmpty ? $0.reference : $0.project } ?? row.orderId)
                                           + " \u{00B7} " + shop.words.counting(row.count, "mac.waste_n_failures"),
                                           Money.text(row.cost, shop.currency))
                            }
                            .buttonStyle(.plain)
                            .disabled(job == nil)
                        }
                    }
                }
            }
            .task(id: shown) {
                guard let engine = shop.engine else { rows = []; return }
                let ids = Set(shown.map(\.id))
                let log = shop.wasteRows.filter { Shop.recordId($0).map(ids.contains) ?? false }
                rows = (try? await engine.wasteTopOrders(log, limit: 5)) ?? []
            }
        }
    }
}

/// Which stretch of the book a screen is showing.
///
/// A Menu, not a Picker. A Picker in a toolbar draws as a popup whose label is
/// its selected value, and it came out EMPTY — a chevron with nothing beside
/// it, in every photograph, whichever style and sizing it was given. A Menu
/// says what it is showing.
struct PeriodMenu: View {
    let shop: Shop

    var body: some View {
        Menu {
            ForEach(Period.allCases) { period in
                Button {
                    shop.period = period
                } label: {
                    if shop.period == period { Label(shop.words.callIt(period.key), systemImage: "checkmark") }
                    else { Text(shop.words.callIt(period.key)) }
                }
            }
        } label: {
            // A bare `Text`. A toolbar Menu draws a `Label` as its icon alone —
            // `.labelStyle(.titleAndIcon)` does not change that — and which
            // period a list is showing is the one thing a period control has to
            // say. It was a calendar glyph and a chevron.
            Text(shop.words.callIt(shop.period.key))
        }
        .menuStyle(.borderlessButton)
    }
}

/// The period picker and the add button, shared by both spending screens.
struct SpendToolbar: ToolbarContent {
    let shop: Shop
    let add: () -> Void
    let addLabel: String

    var body: some ToolbarContent {
        ToolbarItem { PeriodMenu(shop: shop) }
        ToolbarItem {
            Button(addLabel, systemImage: "plus", action: add)
                // The sample shop is for looking at, and a button that opens a
                // form nothing can save is worse than one that is not there.
                .disabled(!shop.canMoveJobs)
        }
    }
}

/// What the last expense or waste write said.
///
/// Above whichever screen you are on, not inside one: adding an expense from
/// the Expenses screen reloads the book, and a message drawn inside a list
/// that has just been rebuilt is a message nobody sees.
struct SpendBanner: View {
    @Bindable var shop: Shop

    var body: some View {
        if let problem = shop.spendProblem {
            Banner(text: problem, symbol: "exclamationmark.triangle", tint: Khayt.attention) {
                shop.spendProblem = nil
            }
        } else if let note = shop.spendNote {
            Banner(text: note, symbol: "checkmark.circle", tint: .secondary) {
                shop.spendNote = nil
            }
        }
    }

    private struct Banner: View {
        let text: String
        let symbol: String
        let tint: Color
        let dismiss: () -> Void

        var body: some View {
            HStack(spacing: 8) {
                Label(text, systemImage: symbol).foregroundStyle(tint).font(.callout)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.5))
        }
    }
}
