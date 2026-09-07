import SwiftUI
import KhaytCore

/// The shop's quarters: what it earned, what it spent, what it kept.
///
/// The figures are `lib/pnl-report.js`'s `pnlByPeriod` — which orders count,
/// which are voided, how the tax is worked out, and how a quarter in progress
/// is charged its share of the overhead. All of it was inline in the Electron
/// analytics screen, so this app had no P&L and no way to have one without a
/// second opinion about the shop's money.
///
/// A table and not a chart, deliberately: this is the screen a shop reads at
/// the end of a quarter to decide something, and a bar it cannot read a figure
/// off is decoration.
struct Reports: View {
    @Bindable var shop: Shop
    @State private var rows: [PnlPeriod] = []
    @State private var owed: Receivables?
    @State private var best: KhaytEngine.TopLists?
    @State private var order: [KeyPathComparator<PnlPeriod>] = [.init(\.period, order: .reverse)]
    @SceneStorage("reports.columns") private var columns: TableColumnCustomization<PnlPeriod>

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $shop.reportPage) {
                ForEach(ReportPage.allCases) { p in Text(shop.words.callIt(p.key)).tag(p) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.vertical, 8)

            if shop.reportPage == .owing {
                Owing(shop: shop, owed: owed)
            } else if shop.reportPage == .best {
                Best(shop: shop, best: best)
            } else if rows.isEmpty {
                ContentUnavailableView(shop.words.callIt("an.pnl_empty"), systemImage: "chart.bar.doc.horizontal")
                    .frame(maxHeight: .infinity)
            } else {
                HSplitView {
                    table
                    Totals(shop: shop, rows: rows)
                        .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                }
            }
        }
        .background(Khayt.ground)
        // Only the Best page reads the period, so only it offers the control.
        // A picker on a screen it does not move is a control that teaches a
        // shop it does nothing.
        .toolbar {
            if shop.reportPage == .best {
                ToolbarItem { PeriodMenu(shop: shop) }
            }
        }
        .task(id: shop.orderRows.count + shop.expenseRows.count) { await recompute() }
        // The period is the Best page's alone — the P&L reports every quarter
        // at once and the receivables age themselves — so recomputing all three
        // when it changes would be three answers to a question one asked.
        .task(id: shop.period) { await recomputeBest() }
    }

    private var table: some View {
        Table(rows.sorted(using: order), sortOrder: $order, columnCustomization: $columns) {
            TableColumn(shop.words.callIt("an.pnl_period"), value: \.period) { r in
                Text(r.period).font(.body.weight(.semibold)).monospacedDigit()
            }
            .width(min: 80, ideal: 100, max: 160)
            TableColumn(shop.words.callIt("an.pnl_orders"), value: \.orders) { r in
                Text("\(r.orders)").monospacedDigit()
            }
            .width(min: 60, ideal: 80, max: 120)
            TableColumn(shop.words.callIt("an.revenue"), value: \.revenue) { r in
                Text(Money.text(r.revenue, shop.currency)).monospacedDigit()
            }
            .width(min: 110, ideal: 140, max: 220)
            TableColumn(shop.words.callIt("an.pnl_expenses"), value: \.expenses) { r in
                // What was spent AND the overhead charged to the period, which
                // is the figure the net is worked out from. Two numbers in one
                // column, because the shop is owed the one it can check.
                VStack(alignment: .trailing, spacing: 1) {
                    let spent = r.expenses + r.fixed
                    // A quarter that spent nothing shows nothing, rather than
                    // "−0.00", which reads as a figure somebody worked out.
                    // Negated rather than prefixed with a minus glyph: the
                    // formatter's own sign is the one the net column uses, and
                    // two different minus signs in one table is a typo.
                    Text(spent > 0 ? Money.text(-spent, shop.currency) : "—")
                        .monospacedDigit()
                        .foregroundStyle(spent > 0 ? AnyShapeStyle(Khayt.attention) : AnyShapeStyle(.tertiary))
                    if r.fixed > 0 {
                        Text(shop.words.callIt("mac.of_which_fixed") + " " + Money.text(r.fixed, shop.currency))
                            .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 120, ideal: 160, max: 240)
            TableColumn(shop.words.callIt("an.pnl_vat"), value: \.vatCollected) { r in
                Text(Money.text(r.vatCollected, shop.currency))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 130, max: 200)
            TableColumn(shop.words.callIt("an.pnl_net"), value: \.net) { r in
                Text(Money.text(r.net, shop.currency))
                    .font(.body.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(r.net >= 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(Khayt.late))
            }
            .width(min: 110, ideal: 140, max: 220)
        }
        // NO ZEBRA. This table has one row per quarter — two of them on the
        // shop's own book — and the stripes are drawn down the whole window
        // whether there are rows in them or not, so a shop with a young book
        // read two figures above a dozen empty grey bands and reasonably
        // wondered what had failed to load. The same thing made the filament
        // shelf look broken.
        //
        // Striping earns its keep across forty rows of similar numbers. It
        // cannot here, because there will never be forty quarters, and the
        // separators already carry the eye across a row this short.
        // EVERY COLUMN HAS A CEILING, and this is the one table that needs
        // one.
        //
        // A `Table` spreads its spare width across its columns, which on a
        // 2560-point display put a quarter's name and its net income fifteen
        // hundred points apart — the two ends of a row somebody has to read as
        // one line. The other three tables in this app can afford that: they
        // stripe their rows, and zebra is what carries an eye across a wide
        // row. This is the only one with striping switched OFF — deliberately,
        // because it holds one row per quarter and stripes down an empty
        // window looked like a screen that had failed to load — so it has
        // nothing to carry the eye and must not spread in the first place.
        //
        // The slack goes nowhere and the table simply ends. That is the right
        // answer for six columns of money: a figure is as readable at 140
        // points as at 400, and the space is better spent as nothing.
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        // The app's ground shows through rather than the system's white.
        //
        // A `Table` paints an opaque background of its own, and beside a pane
        // on `Khayt.ground` that drew a hard seam down the middle of the
        // window — two halves of one screen looking like two documents.
        .scrollContentBackground(.hidden)
    }

    private func recompute() async {
        guard let engine = shop.engine else { rows = []; owed = nil; return }
        rows = (try? await engine.pnlByPeriod(
            orders: shop.orderRows, expenses: shop.expenseRows,
            settings: shop.settingsDict, clients: shop.clientRows,
            currencies: Invoice.currencyTable(shop), now: Date())) ?? []
        owed = try? await engine.receivables(
            orders: shop.orderRows, settings: shop.settingsDict, clients: shop.clientRows,
            currencies: Invoice.currencyTable(shop), language: shop.words.language, now: Date())
        await recomputeBest()
    }

    private func recomputeBest() async {
        guard let engine = shop.engine else { best = nil; return }
        best = try? await engine.topLists(
            orders: shop.orderRows, products: shop.productRows, clients: shop.clientRows,
            settings: shop.settingsDict, currencies: Invoice.currencyTable(shop),
            language: shop.words.language, period: shop.period.rawValue, now: Date())
    }

    /// Who the shop's money came from, and what it is asked for.
    ///
    /// Two lists rather than one, because they answer different questions and
    /// are counted differently: customers are ranked over what completed and
    /// was billed, products over every order in the period whatever became of
    /// it. A part quoted twenty times and made twice belongs at the top of the
    /// second list and nowhere on the first.
    private struct Best: View {
        let shop: Shop
        let best: KhaytEngine.TopLists?

        var body: some View {
            // Two cards rather than two halves of one pane divided by a rule.
            // The rule was doing the work a gap and two edges do better, and it
            // left both lists sitting directly on the window with nothing to
            // say where either began.
            HStack(alignment: .top, spacing: 14) {
                Ranking(title: shop.words.callIt("an.top_clients"),
                        rows: best?.clients ?? [], empty: "an.no_top_clients",
                        shop: shop, showing: .revenue)
                Ranking(title: shop.words.callIt("an.top_products"),
                        rows: best?.products ?? [], empty: "an.no_top_products",
                        shop: shop, showing: .count)
            }
            .padding(Metric.screen)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }

        /// Which number the list is ranked by — the one that gets the emphasis,
        /// because a column of bold figures in an order nobody can see is a
        /// table that has to be read twice.
        enum Ranked { case revenue, count }

        struct Ranking: View {
            let title: String
            let rows: [KhaytEngine.TopRow]
            let empty: String
            let shop: Shop
            let showing: Ranked

            var body: some View {
                DetailSection(title) {
                    if rows.isEmpty {
                        Text(shop.words.callIt(empty))
                            .foregroundStyle(.secondary)
                            .card()
                    } else {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(Array(rows.enumerated()), id: \.element.id) { place, row in
                                    Row(place: place + 1, row: row, shop: shop, showing: showing)
                                    if place < rows.count - 1 { Divider().padding(.leading, 40) }
                                }
                            }
                            .card(padding: 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        struct Row: View {
            let place: Int
            let row: KhaytEngine.TopRow
            let shop: Shop
            let showing: Ranked

            /// The ranked column is the emphasised one; a figure that is not
            /// there is fainter than one that is merely secondary.
            private var revenueTint: AnyShapeStyle {
                if row.revenue <= 0 { return AnyShapeStyle(.tertiary) }
                return showing == .revenue ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
            }

            var body: some View {
                HStack(spacing: 10) {
                    Text("\(place)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, alignment: .trailing)
                    // A record with no name filled in reads as blank in Khayt's
                    // own lists. Here it says so, because a blank line in a
                    // ranked list looks like the app lost the row.
                    Text(row.name.isEmpty ? shop.words.callIt("mac.unnamed") : row.name)
                        .foregroundStyle(row.name.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    // "0.00 SAR" beside "3×" is a lie the arithmetic did not
                    // tell. `topProducts` counts EVERY order and takes revenue
                    // only from the ones that completed, so a part quoted three
                    // times and never made has three and nothing — and nothing
                    // is not zero. The P&L column beside this one already
                    // refuses to print "−0.00" for the same reason.
                    Text(row.revenue > 0 ? Money.text(row.revenue, shop.currency) : "—")
                        .monospacedDigit()
                        .font(showing == .revenue ? .body.weight(.semibold) : .body)
                        .foregroundStyle(revenueTint)
                    Text("\(row.count)×")
                        .monospacedDigit()
                        .font(showing == .count ? .body.weight(.semibold) : .callout)
                        .foregroundStyle(showing == .count ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .frame(width: 46, alignment: .trailing)
                }
                .padding(.horizontal, 14).padding(.vertical, 7)
            }
        }
    }

    /// What the shop is still owed, and since when.
    ///
    /// Oldest first, because what a shop chases is the top of this list — and
    /// the four ages across the top, because "how much of this is really old"
    /// is the question the totals cannot answer.
    private struct Owing: View {
        let shop: Shop
        let owed: Receivables?
        @State private var order: [KeyPathComparator<Receivables.Row>] = [.init(\.days, order: .reverse)]

        var body: some View {
            if let owed, !owed.rows.isEmpty {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        ForEach(owed.buckets) { bucket in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(shop.words.callIt("an.aged_bucket_days", ["label": .string(bucket.label)]))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(Money.text(bucket.total, shop.currency))
                                    .font(.title3.weight(.semibold)).monospacedDigit()
                                    .foregroundStyle(Self.tint(bucket.label))
                                Text(shop.words.callIt("an.aged_orders_n", ["n": .number(Double(bucket.count))]))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            .card(rail: bucket.count == 0 ? nil : Self.rail(bucket.label), padding: 10)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)

                    Table(owed.rows.sorted(using: order), sortOrder: $order) {
                        TableColumn(shop.words.callIt("an.aged_col_order"), value: \.id) { row in
                            Text(row.id).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .width(min: 90, ideal: 120)
                        TableColumn(shop.words.callIt("an.aged_col_project"), value: \.project) { row in
                            HStack(spacing: 5) {
                                Text(row.project.isEmpty ? "—" : row.project).lineLimit(1)
                                // An instalment is one payment of a plan, not
                                // the whole order — the row is aged by its own
                                // due date and shows only its own amount.
                                if row.instalment {
                                    Image(systemName: "calendar.badge.clock")
                                        .font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .width(min: 120, ideal: 200)
                        TableColumn(shop.words.callIt("an.aged_col_client"), value: \.client) { row in
                            Text(row.client.isEmpty ? "—" : row.client)
                                .foregroundStyle(row.client.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                                .lineLimit(1)
                        }
                        .width(min: 110, ideal: 170)
                        TableColumn(shop.words.callIt("an.aged_col_owed"), value: \.owed) { row in
                            Text(Money.text(row.owed, shop.currency))
                                .monospacedDigit().foregroundStyle(Khayt.attention)
                        }
                        .width(min: 100, ideal: 130)
                        TableColumn(shop.words.callIt("an.aged_col_days"), value: \.days) { row in
                            Text("\(row.days)").monospacedDigit()
                                .foregroundStyle(Self.tint(row.bucket))
                        }
                        .width(min: 60, ideal: 80)
                    }
                    // As the P&L table above: the bucket cards over it sit on
                    // the app's ground, and an opaque white table under them
                    // cut the screen in half.
                    .scrollContentBackground(.hidden)
                }
            } else {
                ContentUnavailableView(shop.words.callIt("an.aged_none"),
                                       systemImage: "checkmark.circle")
                    .frame(maxHeight: .infinity)
            }
        }

        /// Older is louder. The oldest bucket is the one a shop acts on.
        /// How old a debt is, in the palette's own colours.
        ///
        /// `.yellow` was here for the 31-60 bucket — picked at the call site,
        /// which is the exact habit `Palette.swift` was written to stop, and it
        /// was measurably wrong rather than merely off-brand: SwiftUI's yellow
        /// is `#FFCC00`, which is **1.51:1 on white**. Text needs 4.5. That
        /// figure has been all but invisible in light appearance; the palette's
        /// amber is 5.29:1.
        ///
        /// Two buckets share the amber and that is deliberate. Both are "wants
        /// a person, and will keep working if it does not get one", which is
        /// what the colour means; a fourth hue invented to keep them apart
        /// would be a colour standing for nothing. The buckets are already told
        /// apart by their labels, and the table sorts by age.
        /// The rail on a bucket's card. Nil for the youngest, which is the
        /// bucket a healthy book keeps most of its money in — a rail on every
        /// tile would say all four are equally worth acting on. The caller also
        /// passes nil for an EMPTY bucket: nothing owed for 31-60 days is not a
        /// thing to chase, and the board applies the same rule to a column with
        /// no cards in it.
        static func rail(_ bucket: String) -> Color? {
            switch bucket {
            case "90+": Khayt.late
            case "61-90", "31-60": Khayt.attention
            default: nil
            }
        }

        static func tint(_ bucket: String) -> AnyShapeStyle {
            switch bucket {
            case "90+": AnyShapeStyle(Khayt.late)
            case "61-90", "31-60": AnyShapeStyle(Khayt.attention)
            default: AnyShapeStyle(.secondary)
            }
        }
    }

    /// Every quarter added up, and the last one on its own.
    private struct Totals: View {
        let shop: Shop
        let rows: [PnlPeriod]

        var body: some View {
            let net = rows.reduce(0) { $0 + $1.net }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // ── THE ANSWER, FIRST AND LARGEST ─────────────────────
                    //
                    // What a shop opens this screen to find out is whether it
                    // made money, and that figure was the fourth line of a
                    // four-line list, set at the same size as the VAT it is
                    // not. It is the one number on the page worth reading from
                    // across a desk.
                    //
                    // Red when it is negative and otherwise uncoloured —
                    // NOT green for a profit. A shop that made money knows
                    // that is the ordinary case; a shop that lost money is
                    // being told something, and if both states were coloured
                    // neither would be news. The table beside this already
                    // colours a negative quarter the same red.
                    VStack(alignment: .leading, spacing: 4) {
                        Text(shop.words.callIt("an.pnl_net"))
                            .font(.system(size: 10, weight: .semibold))
                            .textCase(.uppercase).tracking(0.6)
                            .foregroundStyle(Khayt.cyan)
                        BigFigure(value: Money.figure(net), unit: Money.mark(shop.currency),
                                  tint: net < 0 ? Khayt.late : nil, size: 28)
                        Text(shop.words.callIt("an.pnl_title"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .card(rail: net < 0 ? Khayt.late : Khayt.cyan, padding: 14)

                    // The components it is made of. Net is deliberately NOT
                    // repeated here — it is the card above, and one figure
                    // under one word twice on one pane is how two answers to
                    // the same question get to disagree.
                    DetailSection(shop.words.callIt("an.pnl_title")) {
                        VStack(spacing: 6) {
                            DetailLine(shop.words.callIt("an.revenue"),
                                       Money.text(rows.reduce(0) { $0 + $1.revenue }, shop.currency))
                            DetailLine(shop.words.callIt("an.pnl_expenses"),
                                       Money.text(rows.reduce(0) { $0 + $1.expenses + $1.fixed }, shop.currency), dim: true)
                            DetailLine(shop.words.callIt("an.pnl_vat"),
                                       Money.text(rows.reduce(0) { $0 + $1.vatCollected }, shop.currency), dim: true)
                        }
                        .card()
                    }

                    if let latest = rows.first {
                        DetailSection(latest.period) {
                            VStack(spacing: 6) {
                                DetailLine(shop.words.callIt("an.pnl_orders"), "\(latest.orders)")
                                DetailLine(shop.words.callIt("an.revenue"),
                                           Money.text(latest.revenue, shop.currency))
                                DetailLine(shop.words.callIt("an.pnl_net"),
                                           Money.text(latest.net, shop.currency), strong: true,
                                           tint: latest.net < 0 ? Khayt.late : nil)
                                // The quarter in progress is charged only the part
                                // of its overhead that has elapsed, so its net is
                                // comparable with the finished ones beside it.
                                if latest.fixed > 0 {
                                    Text(shop.words.callIt("mac.quarter_in_progress"))
                                        .font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .card()
                        }
                    }
                }
                .padding(Metric.pane)
            }
        }
    }
}
