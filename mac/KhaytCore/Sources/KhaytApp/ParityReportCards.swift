import SwiftUI
import AppKit
import KhaytCore
import KhaytWidgetData

// The desktop's analytics cards the Mac's Reports lacked, each from the
// shared rule the desktop now draws it from too:
//
//   - Monthly revenue vs expenses, and profit margin by month —
//     `lib/pnl-trend.js` over the P&L by month (`renderMonthlyTrendChart`,
//     `renderProfitMarginChart`);
//   - Profit by filament, and material usage by month —
//     `lib/filament-report.js` (`renderFilamentAnalytics`,
//     `renderMaterialUsageChart`);
//   - The 12-week production heatmap — `lib/completion-heatmap.js`.
//
// Each card asks the engine for its own figures — off the main thread, an
// actor call — and draws the six-month windows in book months.

/// What a card's figures are recomputed on: the books it reads.
private struct BooksKey: Equatable {
    let orders: Int
    let expenses: Int
    let shelf: Int
    let waste: Int
    let entries: Int
    let settings: JSONValue

    @MainActor init(_ shop: Shop) {
        orders = shop.orderRows.count
        expenses = shop.expenseRows.count
        shelf = shop.inventoryRows.count
        waste = shop.wasteRows.count
        entries = shop.timeEntryRows.count
        settings = shop.settingsValue
    }
}

/// A card's small uppercase heading, as the other Reports cards draw theirs.
private struct CardHeading: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .textCase(.uppercase).tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

private struct KeySwatch: View {
    let colour: Color
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(colour).frame(width: 9, height: 9)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// The colour a spool's hex names, or a neutral one.
private func swatch(_ hex: String) -> Color {
    Color(nsColor: NSColor(hex: hex) ?? .tertiaryLabelColor)
}

// MARK: - Revenue against spending, and the margin, by month

struct RevenueTrendCards: View {
    let shop: Shop
    @State private var months: [PnlTrendMonth] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MonthlyTrendChart(shop: shop, months: months)
            MarginTrendChart(shop: shop, months: months)
        }
        .task(id: BooksKey(shop)) { await recompute() }
    }

    private func recompute() async {
        guard let engine = shop.engine else { return }
        let now = Date()
        let input = PnlInputs(
            orders: shop.orderRows, expenses: shop.expenseRows, settings: shop.settingsDict,
            clients: shop.clientRows, currencies: Invoice.currencyTable(shop), now: now,
            granularity: "month", wasteLog: shop.wasteRows, inventory: shop.inventoryRows,
            machines: shop.machineRows, recentMonthlyHours: shop.recentMonthlyHours,
            timeEntries: shop.timeEntryRows)
        // SIX MONTHS, the other app's window, in book months.
        let keys = Calendar.book.monthKeys(endingAt: now, count: 6)
        months = (try? await engine.pnlTrend(input, months: keys)) ?? []
    }
}

/// Revenue beside what the shop spent, a pair of columns a month, with the
/// month's profit above them — the desktop's "Monthly Revenue vs Expenses".
private struct MonthlyTrendChart: View {
    let shop: Shop
    let months: [PnlTrendMonth]

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                CardHeading(text: words.callIt("an.monthly_trend_title"))
                Spacer()
                KeySwatch(colour: Khayt.done, label: words.callIt("an.monthly_rev"))
                KeySwatch(colour: Khayt.late, label: words.callIt("an.monthly_exp"))
            }
            if months.contains(where: { $0.revenue > 0 || $0.expenses > 0 }) {
                let peak = max(months.map { max($0.revenue, $0.expenses) }.max() ?? 0, 1)
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(months) { m in
                        VStack(spacing: 4) {
                            Text(m.revenue > 0 || m.expenses > 0 ? Money.figure(m.profit) : " ")
                                .font(.caption2.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(m.profit >= 0 ? Khayt.done : Khayt.late)
                                .lineLimit(1).minimumScaleFactor(0.6)
                            HStack(alignment: .bottom, spacing: 3) {
                                TrendBar(value: m.revenue, peak: peak, colour: Khayt.done)
                                TrendBar(value: m.expenses, peak: peak, colour: Khayt.late)
                            }
                            .frame(height: TrendBar.tall, alignment: .bottom)
                            Text(MonthLabel.short(m.month))
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .help(Self.readout(m, words: words, currency: shop.currency))
                    }
                }
                Text(words.callIt("an.monthly_profit_above"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(words.callIt("an.no_data")).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    static func readout(_ m: PnlTrendMonth, words: Words, currency: String) -> String {
        let month: String = MonthLabel.long(m.month, language: words.language)
        let revenue: String = Money.text(m.revenue, currency)
        let spent: String = Money.text(m.expenses, currency)
        return month + " \u{00B7} " + revenue + " / " + spent
    }
}

/// One column, as tall as its share of the window's largest figure.
private struct TrendBar: View {
    static let tall: CGFloat = 90
    let value: Double
    let peak: Double
    let colour: Color

    var body: some View {
        // A sliver for a figure too small to draw, as the desktop's 2px floor.
        let fraction = value > 0 ? max(0.02, min(1, value / peak)) : 0
        RoundedRectangle(cornerRadius: 2)
            .fill(colour)
            .frame(width: 14, height: fraction * Self.tall)
            .growsToItsReading(fraction)
    }
}

/// The P&L's blended margin per month, coloured by the desktop's bands
/// (40% and up, 20% and up, below) — "Avg Profit Margin by Month".
private struct MarginTrendChart: View {
    let shop: Shop
    let months: [PnlTrendMonth]

    static func colour(_ pct: Double) -> Color {
        switch PnlTrendMonth.band(pct) {
        case "good": Khayt.done
        case "fair": Khayt.attention
        default: Khayt.late
        }
    }

    var body: some View {
        let words = shop.words
        let shown = months.compactMap { $0.marginPct }
        VStack(alignment: .leading, spacing: 10) {
            CardHeading(text: words.callIt("an.profit_margin_title"))
            if shown.isEmpty {
                Text(words.callIt("an.no_data")).font(.callout).foregroundStyle(.secondary)
            } else {
                let peak = max(shown.max() ?? 0, 1)
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(months) { m in
                        VStack(spacing: 4) {
                            if let pct = m.marginPct {
                                Text(Self.percent(pct))
                                    .font(.caption2).monospacedDigit()
                                    .foregroundStyle(Self.colour(pct))
                                MarginBar(pct: pct, peak: peak, colour: Self.colour(pct))
                            } else {
                                Spacer(minLength: 0)
                            }
                            Text(MonthLabel.short(m.month))
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: MarginBar.tall + 34, alignment: .bottom)
                    }
                }
            }
        }
    }

    static func percent(_ pct: Double) -> String {
        let n: String = Money.quantity(pct, decimals: 0)
        return n + "%"
    }
}

private struct MarginBar: View {
    static let tall: CGFloat = 70
    let pct: Double
    let peak: Double
    let colour: Color

    var body: some View {
        // A margin below zero draws the floor, as the desktop's 4px minimum.
        let fraction = max(0.05, min(1, pct / peak))
        RoundedRectangle(cornerRadius: 3)
            .fill(colour)
            .frame(width: 30, height: fraction * Self.tall)
            .growsToItsReading(fraction)
    }
}

// MARK: - Profit by filament, and material usage

struct FilamentReportCards: View {
    let shop: Shop
    @State private var report: FilamentReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            FilamentProfitTable(shop: shop, rows: report?.rows ?? [])
            MaterialUsageChart(shop: shop, usage: report?.usage, months: report?.months ?? [])
        }
        .task(id: BooksKey(shop)) { await recompute() }
    }

    private func recompute() async {
        guard let engine = shop.engine else { return }
        let keys = Calendar.book.monthKeys(endingAt: Date(), count: 6)
        report = try? await engine.filamentReport(
            orders: shop.orderRows, inventory: shop.inventoryRows,
            settings: shop.settingsDict, clients: shop.clientRows, months: keys)
    }
}

/// Revenue, margin and print speed per filament, best earner first — the
/// desktop's "Filament Performance". Revenue is net of tax, as on the P&L.
private struct FilamentProfitTable: View {
    let shop: Shop
    let rows: [FilamentReport.Row]

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 8) {
            CardHeading(text: words.callIt("an.filament_perf"))
            if rows.isEmpty {
                Text(words.callIt("an.filament_no_data")).font(.callout).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text(words.callIt("inv.material"))
                        Text(words.callIt("an.filament_orders")).gridColumnAlignment(.trailing)
                        Text(words.callIt("an.revenue")).gridColumnAlignment(.trailing)
                        Text(words.callIt("an.filament_margin")).gridColumnAlignment(.trailing)
                        Text(words.callIt("an.filament_time_pg")).gridColumnAlignment(.trailing)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(rows) { r in
                        GridRow {
                            HStack(spacing: 6) {
                                Circle().fill(swatch(r.color)).frame(width: 10, height: 10)
                                Text(r.label).fontWeight(.semibold).lineLimit(1)
                            }
                            Text(Money.quantity(Double(r.orders), decimals: 0)).monospacedDigit()
                            Text(Money.text(r.revenue, shop.currency)).monospacedDigit()
                                .foregroundStyle(Khayt.done)
                            Text(Self.margin(r.marginPct)).monospacedDigit().fontWeight(.semibold)
                                .foregroundStyle(Self.marginColour(r.marginPct))
                            Text(Self.timePer100g(r.avgTimePerGram, words: words)).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text(words.callIt("mac.filament_net_note"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func margin(_ pct: Double) -> String {
        let n: String = Money.quantity(pct, decimals: 0)
        return n + "%"
    }

    /// 60% and up, 30% and up, below — the desktop's three colours.
    static func marginColour(_ pct: Double) -> Color {
        pct >= 60 ? Khayt.done : pct >= 30 ? Khayt.brand : Khayt.attention
    }

    /// Hours per 100 g, as the desktop's column reads it, or a dash.
    static func timePer100g(_ perGram: Double?, words: Words) -> String {
        guard let perGram else { return "\u{2014}" }
        let n: String = Money.quantity(perGram * 100, decimals: 2)
        return n + " " + words.callIt("common.hours")
    }
}

/// Grams used per material per month, stacked — the desktop's "Material
/// Usage" chart, from each spool's usage history.
private struct MaterialUsageChart: View {
    let shop: Shop
    let usage: FilamentReport.Usage?
    let months: [String]

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            CardHeading(text: words.callIt("an.mat_usage_title"))
            if let usage, !usage.materials.isEmpty {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(months, id: \.self) { month in
                        VStack(spacing: 4) {
                            VStack(spacing: 1) {
                                Spacer(minLength: 0)
                                // Top of the stack first: the first material
                                // sits on the floor, as the desktop stacks it.
                                ForEach(Array(usage.materials.reversed()), id: \.self) { mat in
                                    UsageSegment(grams: usage.grams(mat, month), peak: usage.maxGrams,
                                                 colour: swatch(usage.colors[mat] ?? ""))
                                }
                            }
                            .frame(width: 26, height: UsageSegment.tall)
                            Text(MonthLabel.short(month))
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .help(Self.readout(month, usage: usage, words: words))
                    }
                }
                HStack(spacing: 12) {
                    ForEach(usage.materials, id: \.self) { mat in
                        KeySwatch(colour: swatch(usage.colors[mat] ?? ""), label: mat)
                    }
                }
            } else {
                Text(words.callIt("an.mat_usage_empty"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "October 2026 · PLA 40 g, PETG 12 g".
    static func readout(_ month: String, usage: FilamentReport.Usage, words: Words) -> String {
        let grams = words.callIt("common.grams")
        let parts: [String] = usage.materials.compactMap { mat in
            let g = usage.grams(mat, month)
            guard g > 0 else { return nil }
            let n: String = Money.quantity(g, decimals: 0)
            return mat + " " + n + " " + grams
        }
        let name: String = MonthLabel.long(month, language: words.language)
        return parts.isEmpty ? name : name + " \u{00B7} " + parts.joined(separator: ", ")
    }
}

private struct UsageSegment: View {
    static let tall: CGFloat = 110
    let grams: Double
    let peak: Double
    let colour: Color

    var body: some View {
        // A material used at all gets at least a sliver, as the desktop's 2px.
        let fraction = grams > 0 ? max(0.02, min(1, grams / max(peak, 1))) : 0
        if fraction > 0 {
            RoundedRectangle(cornerRadius: 2)
                .fill(colour)
                .frame(height: fraction * Self.tall)
                .growsToItsReading(fraction)
        }
    }
}

// MARK: - The 12-week production heatmap

/// Finished work by weekday over the last twelve weeks, in the period the
/// Best page is showing — the desktop's "Production heatmap".
struct CompletionHeatmapCard: View {
    let shop: Shop
    @State private var heat: CompletionHeatmap?

    private struct Key: Equatable {
        let orders: Int
        let period: Period
    }

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                CardHeading(text: words.callIt("an.production_heatmap"))
                Spacer()
                Text(words.callIt("an.last_12_weeks")).font(.caption).foregroundStyle(.secondary)
            }
            if let heat, heat.hasData {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(0..<7, id: \.self) { day in
                        HStack(spacing: 3) {
                            Text(Self.dayName(day, words.language))
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 30, alignment: .leading)
                            ForEach(0..<12, id: \.self) { week in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Khayt.brand.opacity(Self.tint(heat, day, week)))
                                    .frame(height: 14)
                                    .help(Self.count(heat, day, week))
                            }
                        }
                    }
                }
            } else {
                Text(words.callIt("an.heatmap_no_data"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: Key(orders: shop.orderRows.count, period: shop.period)) { await recompute() }
    }

    private func recompute() async {
        guard let engine = shop.engine else { return }
        // The period the page shows, by the job's date — as the desktop's
        // grid is filtered to its analytics range.
        let inRange = shop.orderRows.filter { row in
            guard case .object(let o) = row else { return false }
            return shop.inPeriod(Shop.plainString(o["date"]) ?? "")
        }
        heat = try? await engine.completionHeatmap(orders: inRange, now: Date())
    }

    static func tint(_ heat: CompletionHeatmap, _ day: Int, _ week: Int) -> Double {
        guard day < heat.intensity.count, week < heat.intensity[day].count else { return 0.12 }
        return heat.intensity[day][week]
    }

    static func count(_ heat: CompletionHeatmap, _ day: Int, _ week: Int) -> String {
        guard day < heat.matrix.count, week < heat.matrix[day].count else { return "" }
        return Money.quantity(Double(heat.matrix[day][week]), decimals: 0)
    }

    /// Sunday first, matching `getDay()`, in the shop's language.
    static func dayName(_ day: Int, _ language: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Digits.locale(language: language)
        let symbols = calendar.shortWeekdaySymbols
        return day >= 0 && day < symbols.count ? symbols[day] : ""
    }
}
