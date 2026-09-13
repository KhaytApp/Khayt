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
struct CashFlowChart: View {
    let shop: Shop
    let flow: KhaytEngine.CashFlow?

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
                Bars(rows: flow.rows, currency: shop.currency)
                    .frame(height: 150)
                HStack(alignment: .firstTextBaseline) {
                    Figure(words.callIt("an.collected"),
                           Money.text(flow.totals.collected, shop.currency), tint: nil)
                    Spacer(minLength: 10)
                    Figure(words.callIt("an.expenses_paid"),
                           Money.text(flow.totals.paidOut, shop.currency), tint: nil)
                    Spacer(minLength: 10)
                    // The only figure here that is coloured, and only when it
                    // is negative: more went out than came in, which is the one
                    // thing on this card a shop needs told rather than shown.
                    Figure(words.callIt("an.pnl_net"),
                           Money.text(flow.totals.net, shop.currency),
                           tint: flow.totals.net < 0 ? Khayt.late : nil,
                           alignment: .trailing)
                }
                // ── AND WHAT COULD NOT BE PLACED ──────────────────────────
                //
                // `paidAt` was added after Khayt had been in use, so a shop's
                // older orders carry an amount and no date. A timeline cannot
                // draw them — but leaving them out silently is how a shop that
                // has been paid thirty times reads "collected nothing" and
                // believes it. So the chart says what it could not show.
                if flow.totals.undated > 0 {
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

        var body: some View {
            let peak = max(rows.map { max($0.collected, $0.paidOut) }.max() ?? 0, 1)
            HStack(alignment: .center, spacing: 0) {
                ForEach(rows) { row in
                    VStack(spacing: 0) {
                        Column(value: row.collected, peak: peak, colour: Khayt.done, up: true)
                        Rectangle().fill(Khayt.hairline).frame(height: 1)
                        Column(value: row.paidOut, peak: peak, colour: Khayt.late, up: false)
                        Text(Self.shortMonth(row.month))
                            .font(.caption2).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }

        /// `2026-08` → `08/26`. Not a localised month name: these sit under
        /// narrow columns and a name that fits in one language does not fit in
        /// nine, and digits read the same in all of them.
        static func shortMonth(_ key: String) -> String {
            let parts = key.split(separator: "-")
            guard parts.count == 2 else { return key }
            return "\(parts[1])/\(parts[0].suffix(2))"
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
                    if !up { Spacer(minLength: 0) }
                }
                .frame(height: 62)
                .padding(.horizontal, 5)
            }
        }
    }
}
