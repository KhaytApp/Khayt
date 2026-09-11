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
    @State private var machinePL: KhaytEngine.MachineProfitReport?
    /// What the shop must bill this month to cover what it pays anyway.
    /// Beside the quarters rather than on a page of its own: a shop reading
    /// what it made is the shop that wants to know whether it was enough.
    @State private var floor: KhaytEngine.BreakEven?
    /// What reached the bank rather than what was earned. Beside the quarters
    /// because a shop can be profitable and unable to pay the rent, and the
    /// P&L alone cannot say which it is.
    @State private var flow: KhaytEngine.CashFlow?
    /// What each customer has been worth over its whole life with the shop —
    /// beside the top lists, which answer "who is biggest this period".
    @State private var worth: KhaytEngine.ClientValue?
    /// How many quotes turn into work, beside how accurate they are.
    @State private var funnel: KhaytEngine.QuoteFunnel?
    /// Which products actually earn — beside the list of what sells most,
    /// which is a different question and often a different order.
    @State private var earns: KhaytEngine.ProductProfit?
    /// Whether the shop is growing or serving the same people.
    @State private var mix: KhaytEngine.CustomerMix?
    /// When work actually finishes — which day, which hour, and how much of it
    /// on days the shop is shut.
    @State private var when: KhaytEngine.Throughput?
    /// How far each machine runs from its quote, and the shop's own figure.
    /// Not filtered to the chosen period: a machine's calibration is not a
    /// property of this quarter, and the measured-only filter already thins the
    /// readings enough without also throwing away last month's.
    @State private var accuracy: [KhaytEngine.MachineAccuracy] = []
    @State private var shopAccuracy: KhaytEngine.MachineAccuracy?
    @State private var variance: [KhaytEngine.ModelVariance] = []
    /// The sentence each row earned, keyed by model. Worked out here rather
    /// than in the row's body: it is an engine call, and a body runs whenever
    /// anything near it changes.
    @State private var advice: [String: KhaytEngine.VarianceAdvice] = [:]
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
                Best(shop: shop, best: best, worth: worth, earns: earns, mix: mix, when: when)
            } else if shop.reportPage == .quoting {
                Quoting(shop: shop, rows: variance, said: advice, funnel: funnel)
            } else if shop.reportPage == .machines {
                MachineProfitPage(shop: shop, report: machinePL,
                                  accuracy: accuracy, shopAccuracy: shopAccuracy)
            } else if shop.reportPage == .custom {
                CustomReportPage(shop: shop)
            } else if rows.isEmpty {
                EmptyHere(title: shop.words.callIt("an.pnl_empty"), mark: .reports)
                    .frame(maxHeight: .infinity)
            } else {
                HSplitView {
                    // ── THE ARITHMETIC, THEN THE TABLE ────────────────────
                    //
                    // This page was the one screen in the app with no drawing
                    // on it at all: a table and a panel of totals. It printed
                    // a quarter's net in a cell, and a number in a cell is a
                    // number a shop either trusts or does not.
                    //
                    // The chart is the same arithmetic `lib/pnl-report.js`
                    // already did, laid out so it can be checked by eye. The
                    // table stays underneath — a chart is not a replacement
                    // for the figures, and the lightest bar on it is only
                    // legible BECAUSE the figures are there.
                    VStack(spacing: 0) {
                        if let latest = rows.first { QuarterDrawn(shop: shop, row: latest) }
                        table
                        // Under the table rather than beside it: the quarters
                        // are what the shop earned, and this is the follow-up
                        // question — did any of it arrive.
                        CashFlowChart(shop: shop, flow: flow)
                            .padding(Metric.screen)
                    }
                    Totals(shop: shop, rows: rows, floor: floor)
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
        // Every finished job in the book, not the chosen period: four prints of
        // one model across a year is the evidence, and a quarter that happened
        // to contain one of them is not.
        .task(id: shop.orderRows.count) { await recomputeVariance() }
        // With the PERIOD, unlike the variance: "which machine earned" is a
        // question about a stretch of time, and the same machine can be the
        // best one quarter and the worst the next. That is the point of asking.
        .task(id: shop.period) { await recomputeMachinePL() }
        // And NOT with the period, beside it on the same screen. "Which machine
        // earned" is a question about a stretch of time; "is this machine
        // slower than its slicer thinks" is a question about the machine, and
        // answering it from one quarter's prints would throw away most of the
        // little evidence the measured-only filter leaves.
        .task(id: shop.orderRows.count) { await recomputeAccuracy() }
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
            // WHAT IS ACTUALLY OWED, in its own column beside what was charged.
            // The tax a shop paid on its purchases comes off the tax it
            // charged, and the difference is the figure a return is filed on.
            //
            // Shown only to a shop that reclaims anything: a column of zeros
            // teaches people to stop reading the ones next to it. A conditional
            // TableColumn needs macOS 14.4, which is why this was a second line
            // squeezed into the column before — the app's floor is 26 now.
            if shop.reclaimsTax {
                TableColumn(shop.words.callIt("exp.vat_due"), value: \.vatDue) { r in
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(Money.text(r.vatDue, shop.currency))
                            .monospacedDigit()
                        if r.vatReclaimable > 0 {
                            Text("−\(Money.text(r.vatReclaimable, shop.currency))")
                                .font(.caption).foregroundStyle(.tertiary)
                                .help(shop.words.callIt("exp.vat_reclaimed"))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 100, ideal: 140, max: 220)
            }
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
        await recomputeBreakEven()
        await recomputeCashFlow()
        await recomputeClientValue()
        await recomputeFunnel()
        await recomputeProductProfit()
        await recomputeCustomerMix()
        await recomputeThroughput()
        owed = try? await engine.receivables(
            orders: shop.orderRows, settings: shop.settingsDict, clients: shop.clientRows,
            currencies: Invoice.currencyTable(shop), language: shop.words.language, now: Date())
        await recomputeBest()
    }

    private func recomputeBreakEven() async {
        guard let engine = shop.engine else { return }
        // NINETY DAYS, and the same window the other app uses. Long enough that
        // one unusual job does not move the margin, short enough that last
        // year's prices do not set this month's target.
        let since = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let month = DateFormatter()
        month.locale = Locale(identifier: "en_US_POSIX")
        month.dateFormat = "yyyy-MM"

        // Finished, unvoided, and business — the same set the quarters count,
        // because a target derived from one set of jobs and drawn beside a
        // figure derived from another is two answers pretending to be one.
        let completed = shop.orderRows.filter { row in
            guard case .object(let o) = row else { return false }
            guard case .string(let status)? = o["status"], status == "completed" else { return false }
            if case .string(let voided)? = o["voidedAt"], !voided.isEmpty { return false }
            return true
        }
        var costs: [JSONValue] = []
        if case .array(let stored)? = shop.settingsDict["fixedCosts"] { costs = stored }

        floor = try? await engine.breakEven(
            fixedCosts: costs, completed: completed,
            since: day.string(from: since), month: month.string(from: Date()),
            settings: shop.settingsDict, clients: shop.clientRows)
    }

    private func recomputeCashFlow() async {
        guard let engine = shop.engine else { return }
        let month = DateFormatter()
        month.locale = Locale(identifier: "en_US_POSIX")
        month.dateFormat = "yyyy-MM"
        // SIX MONTHS, the same window the other app draws. Long enough to show
        // a season and short enough that each column is still readable at the
        // width this panel gets.
        //
        // The orders are handed over WHOLE: which of them are cash — unvoided,
        // in the shop's trade, and scaled by what was actually paid — is the
        // module's rule and not a filter applied out here, because getting it
        // wrong out here is precisely what the module was written to stop.
        flow = try? await engine.cashFlow(
            orders: shop.orderRows, expenses: shop.expenseRows,
            endMonth: month.string(from: Date()), months: 6,
            settings: shop.settingsDict, clients: shop.clientRows)
    }

    private func recomputeClientValue() async {
        guard let engine = shop.engine else { return }
        // NOT filtered to the chosen period. Lifetime value is a lifetime — a
        // customer's whole history with the shop is the point of it, and
        // narrowing it to a quarter would make it the top-clients list above
        // with a different heading.
        worth = try? await engine.clientValue(
            clients: shop.clientRows, orders: shop.orderRows, now: Date(),
            quietDays: 90, limit: 10,
            settings: shop.settingsDict, language: shop.words.language)
    }

    private func recomputeFunnel() async {
        guard let engine = shop.engine else { return }
        // NOT filtered to the chosen period. A win rate over one quarter of a
        // small shop is a handful of decisions, and the figure moves twenty
        // points on one job — which makes it noise rather than a rate.
        funnel = try? await engine.quoteFunnel(
            orders: shop.orderRows, now: Date(),
            settings: shop.settingsDict, clients: shop.clientRows)
    }

    private func recomputeProductProfit() async {
        guard let engine = shop.engine else { return }
        earns = try? await engine.productProfit(
            orders: shop.orderRows, products: shop.productRows,
            expenses: shop.expenseRows, untagged: shop.words.callIt("an.untagged"),
            settings: shop.settingsDict, clients: shop.clientRows,
            language: shop.words.language)
    }

    private func recomputeCustomerMix() async {
        guard let engine = shop.engine else { return }
        // The whole book, and no window. Who is NEW cannot be decided from a
        // slice of history, and over a quarter a small shop's split is a
        // handful of decisions rather than a proportion.
        mix = try? await engine.customerMix(
            orders: shop.orderRows, from: "", to: "",
            settings: shop.settingsDict, clients: shop.clientRows)
    }

    private func recomputeThroughput() async {
        guard let engine = shop.engine else { return }
        let open = (try? await engine.openDays(settings: shop.settingsDict))
            ?? Array(repeating: true, count: 7)
        when = try? await engine.throughput(
            orders: shop.orderRows, openDays: open, minimum: 10)
    }

    private func recomputeMachinePL() async {
        guard let engine = shop.engine else { return }
        // ── ALL FOUR FILTERED THE SAME WAY ────────────────────────────────
        //
        // The module does not know what a range is, and the bug this code
        // already carries a note about is exactly this asymmetry: maintenance
        // was once filtered by calendar year while revenue was filtered by the
        // chosen range, so "This month" charged January's belt overhaul against
        // July's revenue and a profitable printer read as loss-making.
        let done = await shop.completedInPeriod()
        machinePL = try? await engine.machineProfit(
            machines: shop.machineRows,
            completed: done.orders,
            expenses: done.expenses,
            maintenance: done.maintenance,
            settings: shop.settingsDict, clients: shop.clientRows,
            unassigned: shop.words.callIt("dash.unassigned"))
    }

    private func recomputeAccuracy() async {
        guard let engine = shop.engine else { return }
        // `minSamples: 1`, like the model panel: one measured print IS evidence,
        // and the row carries its own count and confidence so it can say how
        // much. Hiding it until there are two means a shop that has just started
        // measuring sees nothing and concludes the screen is broken.
        accuracy = (try? await engine.machineAccuracy(orders: shop.orderRows, minSamples: 1)) ?? []
        shopAccuracy = try? await engine.shopAccuracy(orders: shop.orderRows, minSamples: 1)
    }

    private func recomputeVariance() async {
        guard let engine = shop.engine else { return }
        // `minSamples: 1` — a single print IS evidence, and the row says so by
        // carrying its own count and confidence. Hiding it until there are two
        // would mean a shop that has just started measuring sees nothing and
        // concludes the screen is broken.
        let rows = (try? await engine.estimateVariance(orders: shop.orderRows, minSamples: 1)) ?? []
        var said: [String: KhaytEngine.VarianceAdvice] = [:]
        for row in rows {
            if let one = try? await engine.varianceAdvice(row) { said[row.printFileId] = one }
        }
        variance = rows
        advice = said
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
        let worth: KhaytEngine.ClientValue?
        let earns: KhaytEngine.ProductProfit?
        let mix: KhaytEngine.CustomerMix?
        let when: KhaytEngine.Throughput?

        var body: some View {
            // Two cards rather than two halves of one pane divided by a rule.
            // The rule was doing the work a gap and two edges do better, and it
            // left both lists sitting directly on the window with nothing to
            // say where either began.
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        Ranking(title: shop.words.callIt("an.top_clients"),
                                rows: best?.clients ?? [], empty: "an.no_top_clients",
                                shop: shop, showing: .revenue)
                        Ranking(title: shop.words.callIt("an.top_products"),
                                rows: best?.products ?? [], empty: "an.no_top_products",
                                shop: shop, showing: .count)
                    }
                    // ── AND WHO IS WORTH KEEPING ──────────────────────────
                    //
                    // The lists above answer "who was biggest THIS period",
                    // which is the question a shop asks monthly. This answers
                    // "who has been worth the most, ever, and who has stopped
                    // coming back" — the question it should ask before it
                    // decides who to chase.
                    // Above the lifetime table, because it is the question
                    // that frames it: a shop reading who its best customers are
                    // should know first whether it is finding new ones.
                    CustomerMixCard(shop: shop, report: mix)
                        .card(rail: Khayt.cyan, padding: 14)
                    ClientValueTable(shop: shop, report: worth)
                        .card(rail: Khayt.cyan, padding: 14)
                    // ── AND WHICH OF THEM EARNS ───────────────────────────
                    //
                    // The list above is what sells MOST. This is what makes
                    // money, and the two are routinely in a different order —
                    // which is the finding, and why they sit on one screen.
                    ProductProfitTable(shop: shop, report: earns)
                        .card(rail: Khayt.cyan, padding: 14)
                    ThroughputCard(shop: shop, report: when)
                        .card(rail: Khayt.cyan, padding: 14)
                }
                .padding(Metric.screen)
            }
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
                EmptyHere(title: shop.words.callIt("an.aged_none"), mark: .reports)
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

    /// The most recent quarter, drawn.
    ///
    /// Only ONE quarter. A waterfall reads left to right as one running total,
    /// so two quarters side by side on one axis would draw a sum nobody is
    /// asking for — the table below is where quarters are compared.
    private struct QuarterDrawn: View {
        let shop: Shop
        let row: PnlPeriod

        /// Revenue, everything that took a piece out of it, and what was left.
        ///
        /// `revenue` is already net of tax and `fixed` is not inside
        /// `expenses` — the panel beside this adds them, and so does
        /// `lib/pnl-report.js` when it works out `net`. So these four bars are
        /// the whole of the arithmetic and nothing here re-derives it.
        private var steps: [WaterfallStep] {
            var out: [WaterfallStep] = [
                WaterfallStep(label: shop.words.callIt("an.revenue"),
                              amount: row.revenue, anchored: true),
                WaterfallStep(label: shop.words.callIt("an.pnl_expenses"), amount: -row.expenses),
            ]
            // Only when there is any. A bar of zero height under a label is a
            // row of the table that wandered onto the chart.
            if row.fixed != 0 {
                out.append(WaterfallStep(label: shop.words.callIt("mac.of_which_fixed"),
                                         amount: -row.fixed))
            }
            out.append(WaterfallStep(label: shop.words.callIt("an.pnl_net"),
                                     amount: row.net, anchored: true))
            return out
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Drawn(mark: .reports, size: 13).foregroundStyle(.tertiary)
                    Text(shop.words.callIt("mac.quarter_drawn", ["q": .string(row.period)]))
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase).tracking(0.5)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(shop.words.callIt("an.pnl_orders") + " \(row.orders)")
                        .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                }
                Waterfall(steps: steps, currency: shop.currency, height: 220)
            }
            .card(padding: 14)
            .padding(Metric.screen)
            .padding(.bottom, 0)
        }
    }

    /// Every quarter added up, and the last one on its own.
    private struct Totals: View {
        let shop: Shop
        let rows: [PnlPeriod]
        let floor: KhaytEngine.BreakEven?

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
                        // ── AND THE SUM THAT MADE IT ─────────────────────
                        //
                        // The panel below lists Revenue, Expenses AND VAT, so a
                        // reader subtracts all three and gets a figure four
                        // thousand short of the one above. Net income is
                        // revenue LESS EXPENSES: revenue is already net of the
                        // tax, because tax collected on a sale is money held
                        // for ZATCA and never income. The VAT line is what the
                        // shop owes, sitting beside the arithmetic rather than
                        // inside it — and a figure printed next to numbers it
                        // does not come from is a figure that looks wrong.
                        HStack(spacing: 5) {
                            Rectangle().fill(Khayt.hairline).frame(width: 1, height: 9)
                            Text("\(Money.figure(rows.reduce(0) { $0 + $1.revenue })) − "
                                 + "\(Money.figure(rows.reduce(0) { $0 + $1.expenses + $1.fixed }))")
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Text(shop.words.callIt("an.pnl_title"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .card(rail: net < 0 ? Khayt.late : Khayt.cyan, padding: 14)

                    // ── AND WHETHER IT WAS ENOUGH ─────────────────────────
                    //
                    // Directly under the net, because the two answer halves of
                    // one question. "I made 12,000" is only good news against
                    // what the shop had to bill to cover the rent, and that
                    // figure lived nowhere in this app at all.
                    BreakEvenCard(shop: shop, report: floor)
                        .card(rail: (floor?.surplus ?? 0) < 0 ? Khayt.late : Khayt.cyan,
                              padding: 14)

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
                            // Ruled off from the two above it, because it is
                            // NOT a third subtraction — it is what the shop
                            // owes ZATCA, and it has already been taken out of
                            // the revenue line by the time that figure is
                            // printed. Listed flush with the others it read as
                            // a cost, and the obvious arithmetic came out four
                            // thousand short of the net income beside it.
                            LayerRule()
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
