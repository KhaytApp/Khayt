import SwiftUI
import KhaytCore

/// What reached the bank, and what left it.
///
/// NOT the P&L next to it. A quarter's net says what the shop EARNED; this says
/// what it actually has. A shop can be profitable and unable to pay the rent —
/// a month of finished work nobody has paid for is a good quarter and an empty
/// account — and that gap is the whole reason both are on this screen.
///
/// ── ONE BASELINE, TWO DIRECTIONS ──────────────────────────────────────────
///
/// The other app draws two bars side by side per month, both growing upward
/// from the same floor, and leaves the reader to compare heights. Money in and
/// money out are opposite things, so they are drawn as opposites: in above the
/// line, out below it. Whether a month was net positive is then a shape rather
/// than a subtraction the reader has to perform.
///
/// ── AND A BAR HAS TO BE ABLE TO SAY WHAT IT IS WORTH ──────────────────────
///
/// `Bars` has taken a `currency` since it was written and never used it. That
/// is the whole bug in one line: the chart was built meaning to say what a
/// column was worth and never did, so six months of a shop's bank movements
/// could be COMPARED and not READ. There is no axis either — the columns are
/// scaled against the largest movement in the window and nothing on the card
/// says what that is.
///
/// So the figures under the chart are a readout now. With the pointer away
/// they are the window's totals, which is what they always were; over a column
/// they are that month's, and the caption says which month. Nothing appears or
/// disappears, so the card does not change height when a pointer crosses it.
struct CashFlowChart: View {
    let shop: Shop
    let flow: KhaytEngine.CashFlow?

    /// `YYYY-MM`, or nil for the whole window. Lives here rather than in
    /// `Bars` because the figures that read it are this view's.
    @State private var pointingAt: String?

    private var month: KhaytEngine.CashFlow.Month? {
        guard let pointingAt else { return nil }
        return flow?.rows.first { $0.month == pointingAt }
    }

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(words.callIt("an.cash_flow"))
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase).tracking(0.6)
                    .foregroundStyle(Khayt.brand)
                Spacer()
                Key(colour: Khayt.done, label: words.callIt("an.collected"))
                Key(colour: Khayt.late, label: words.callIt("an.expenses_paid"))
            }

            if let flow, flow.totals.anyMovement {
                Bars(rows: flow.rows, currency: shop.currency,
                     language: words.language, pointingAt: $pointingAt)
                    .frame(height: 150)

                // WHICH MONTHS THIS IS, which the card never said. The window
                // is chosen elsewhere on the screen and the axis under the
                // columns is `08/26` — so a reader who wanted the span had to
                // read the first and last labels and work it out.
                Text(MonthLabel.span(flow.rows.map(\.month), pointingAt: pointingAt,
                                     language: words.language))
                    .font(.caption).foregroundStyle(pointingAt == nil ? .secondary : .primary)
                    .lineLimit(1).minimumScaleFactor(0.75)
                    // The one word that changes when the pointer moves, so it
                    // has to be legible mid-change rather than cross-faded.
                    .contentTransition(.identity)
                    .animation(nil, value: pointingAt)

                HStack(alignment: .firstTextBaseline) {
                    Figure(words.callIt("an.collected"),
                           Money.text(month?.collected ?? flow.totals.collected, shop.currency),
                           tint: nil)
                    Spacer(minLength: 10)
                    Figure(words.callIt("an.expenses_paid"),
                           Money.text(month?.paidOut ?? flow.totals.paidOut, shop.currency),
                           tint: nil)
                    Spacer(minLength: 10)
                    // The only figure here that is coloured, and only when it
                    // is negative: more went out than came in, which is the one
                    // thing on this card a shop needs told rather than shown.
                    Figure(words.callIt("an.pnl_net"),
                           Money.text(month?.net ?? flow.totals.net, shop.currency),
                           tint: (month?.net ?? flow.totals.net) < 0 ? Khayt.late : nil,
                           alignment: .trailing)
                }
                // ── AND WHAT COULD NOT BE PLACED ──────────────────────────
                //
                // `paidAt` was added after Khayt had been in use, so a shop's
                // older orders carry an amount and no date. A timeline cannot
                // draw them — but leaving them out silently is how a shop that
                // has been paid thirty times reads "collected nothing" and
                // believes it. So the chart says what it could not show.
                //
                // Only against the window's own totals. Undated money belongs
                // to no month, so repeating the sentence while a reader is
                // pointing at August would be claiming it is August's.
                if flow.totals.undated > 0 && pointingAt == nil {
                    Text(words.callIt("mac.cf_undated",
                                      ["amount": .string(Money.text(flow.totals.undated,
                                                                    shop.currency))]))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                // Nothing moved, which is not the same as nothing being known.
                Text(words.callIt("an.no_data"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func Key(colour: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(colour).frame(width: 9, height: 9)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func Figure(_ label: String, _ value: String, tint: Color?,
                        alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
                // The figure is answering a different question the moment the
                // pointer moves, and a money figure that simply IS a different
                // number is the thing `Motion` was written about.
                .contentTransition(.numericText())
                .foregroundStyle(tint ?? .primary)
        }
    }

    /// In above the line, out below it.
    ///
    /// Scaled against the single largest movement in EITHER direction, so the
    /// two halves share a scale — half-height above and half-height below have
    /// to mean the same number of riyals or the shape lies.
    private struct Bars: View {
        let rows: [KhaytEngine.CashFlow.Month]
        let currency: String
        let language: String
        @Binding var pointingAt: String?
        @Environment(\.accessibilityReduceMotion) private var reduced

        var body: some View {
            let peak = max(rows.map { max($0.collected, $0.paidOut) }.max() ?? 0, 1)
            HStack(alignment: .center, spacing: 0) {
                ForEach(rows) { row in
                    let here = pointingAt == row.month
                    VStack(spacing: 0) {
                        Column(value: row.collected, peak: peak, colour: Khayt.done, up: true)
                        Rectangle().fill(Khayt.hairline).frame(height: 1)
                        Column(value: row.paidOut, peak: peak, colour: Khayt.late, up: false)
                        Text(MonthLabel.short(row.month))
                            .font(.caption2).monospacedDigit()
                            // The month under the pointer is named in full
                            // above; this is the same month, so it stops being
                            // one of twelve grey labels.
                            .foregroundStyle(here ? AnyShapeStyle(.primary)
                                                  : AnyShapeStyle(.secondary))
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    // The column the pointer is on, so the readout under the
                    // chart is visibly about THIS one.
                    .background(here ? Khayt.recessed : .clear,
                                in: RoundedRectangle(cornerRadius: 4))
                    .animation(Motion.of(Motion.hover, unless: reduced), value: here)
                    // The whole column, not the bar: a month that collected
                    // nothing draws a bar three pixels tall, and a readout you
                    // can only reach by hitting three pixels is not one.
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { pointingAt = row.month }
                        else if pointingAt == row.month { pointingAt = nil }
                    }
                    // Said as well as shown. The readout under the chart needs
                    // a pointer; this reaches a reader using VoiceOver, and
                    // survives a screenshot.
                    .help(readout(row))
                }
            }
            // A pointer leaving the chart sideways can miss every column's own
            // exit, which used to leave the figures frozen on whichever month
            // it left by.
            .onHover { inside in if !inside { pointingAt = nil } }
        }

        private func readout(_ row: KhaytEngine.CashFlow.Month) -> String {
            MonthLabel.long(row.month, language: language)
                + " · " + Money.text(row.collected, currency)
                + " / " + Money.text(row.paidOut, currency)
        }

        private struct Column: View {
            let value: Double
            let peak: Double
            let colour: Color
            let up: Bool

            var body: some View {
                // A movement too small to draw still gets a sliver: a month
                // with 40 riyals in it and a month with none must not look the
                // same, and rounding to zero pixels is exactly how they would.
                let fraction = max(value > 0 ? 0.03 : 0, min(1, value / peak))
                VStack(spacing: 0) {
                    if up { Spacer(minLength: 0) }
                    RoundedRectangle(cornerRadius: 2)
                        .fill(colour)
                        .frame(height: fraction * 62)
                        // Out of the baseline it is drawn against, which is the
                        // hairline in the middle of the card for both halves —
                        // so money in grows up off the line and money out hangs
                        // down from it.
                        .growsToItsReading(fraction, from: up ? .bottom : .top)
                    if !up { Spacer(minLength: 0) }
                }
                .frame(height: 62)
                .padding(.horizontal, 5)
            }
        }
    }
}
