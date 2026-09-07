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
    @State private var adding = false
    @State private var order: [KeyPathComparator<Expense>] = [.init(\.date, order: .reverse)]
    @SceneStorage("expenses.columns") private var columns: TableColumnCustomization<Expense>

    private var rows: [Expense] { shop.shownExpenses.sorted(using: order) }

    var body: some View {
        HSplitView {
            table
            Summary(shop: shop).frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
        }
        .background(Khayt.ground)
        .toolbar { SpendToolbar(shop: shop, add: { adding = true },
                                addLabel: shop.words.callIt("exp.add_title")) }
        .sheet(isPresented: $adding) { ExpenseSheet(shop: shop) }
    }

    private var table: some View {
        Table(rows, sortOrder: $order, columnCustomization: $columns) {
            TableColumn(shop.words.callIt("exp.date"), value: \.date) { e in
                Text(e.day?.formatted(date: .abbreviated, time: .omitted) ?? e.date)
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
            TableColumn(shop.words.callIt("exp.order_ref")) { e in
                Text(e.orderId ?? "—").monospacedDigit()
                    .foregroundStyle(e.orderId == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            }
            .width(min: 90, ideal: 120)
        }
        // The app's ground shows through rather than the system's white — the
        // pane beside this one sits on it, and an opaque table drew a seam
        // down the middle of the window. The alternating row stripes are the
        // system's and still draw.
        .scrollContentBackground(.hidden)
        .overlay {
            if rows.isEmpty {
                EmptyHere(title: shop.words.callIt(shop.expenses.isEmpty ? "exp.empty" : "exp.empty_filter"))
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
            // Recomputed when the period changes as well as the book: the
            // budget rows are about what has been spent, and that is a figure
            // the period picker moves.
            .task(id: shop.expenses.count + shop.period.hashValue) { await recompute() }
        }

        private func recompute() async {
            guard let engine = shop.engine else { budgets = []; return }
            var settings = shop.settingsDict
            let table: [String: JSONValue]
            if case .object(let b)? = settings["expBudgets"] { table = b } else { table = [:] }
            budgets = (try? await engine.budgetProgress(shop.expenseTotals.byCategory, budgets: table)) ?? []
        }
    }
}

/// What the shop threw away.
struct Waste: View {
    @Bindable var shop: Shop
    @State private var logging = false
    @State private var order: [KeyPathComparator<WasteEntry>] = [.init(\.date, order: .reverse)]
    @State private var selection: WasteEntry.ID?
    @SceneStorage("waste.columns") private var columns: TableColumnCustomization<WasteEntry>

    private var rows: [WasteEntry] { shop.shownWaste.sorted(using: order) }

    var body: some View {
        HSplitView {
            table
            Summary(shop: shop).frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
        }
        .background(Khayt.ground)
        .toolbar { SpendToolbar(shop: shop, add: { logging = true },
                                addLabel: shop.words.callIt("waste.add")) }
        .sheet(isPresented: $logging) { WasteSheet(shop: shop) }
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $order, columnCustomization: $columns) {
            TableColumn(shop.words.callIt("waste.date"), value: \.date) { w in
                Text(w.day?.formatted(date: .abbreviated, time: .omitted) ?? w.date)
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
            TableColumn(shop.words.callIt("waste.failure_type"), value: \.failureType) { w in
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
        }
        // As the expenses table above.
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: WasteEntry.ID.self) { ids in
            if let id = ids.first, shop.canMoveJobs {
                Button(shop.words.callIt("common.delete"), role: .destructive) {
                    Task { await shop.deleteWaste(id) }
                }
            }
        }
        .overlay {
            if rows.isEmpty {
                EmptyHere(title: shop.words.callIt("waste.empty"))
            }
        }
    }

    /// Entries, grams, cost — and which failures the shop keeps having.
    private struct Summary: View {
        let shop: Shop

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    let shown = shop.shownWaste
                    let grams = shown.reduce(0) { $0 + $1.weight }
                    let cost = shown.reduce(0) { $0 + $1.cost }
                    DetailSection(shop.words.callIt("exp.summary")) {
                        DetailLine(shop.words.callIt("waste.total_entries"), "\(shown.count)")
                        DetailLine(shop.words.callIt("waste.total_weight"),
                                   "\(Money.grams(grams)) \(shop.words.callIt("mac.grams"))")
                        DetailLine(shop.words.callIt("waste.total_cost"),
                                   Money.text(cost, shop.currency), strong: true)
                    }
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
