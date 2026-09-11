import SwiftUI
import KhaytCore

/// What the shop has to bill this month before any of it is profit.
///
/// Rent, the licence, the connection, the accountant — money that goes out
/// whether or not a single print is sold. The target is that total divided by
/// the share of each riyal billed that survives the work itself.
///
/// ── DRAWN AS A DISTANCE, NOT AS A NUMBER ──────────────────────────────────
///
/// The figure a shop needs is not "4,364" — it is *how far off am I, and is it
/// the 3rd or the 27th*. So the bar is the screen and the figures annotate it:
/// what has been billed, where the line is, and which side of it today falls.
///
/// The other app draws the same thing as three grey boxes and a progress bar
/// with the target written above it in English regardless of language. Every
/// word here is a key, and the nine locales have them.
struct BreakEvenCard: View {
    let shop: Shop
    let report: KhaytEngine.BreakEven?

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            Text(words.callIt("an.be_title"))
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase).tracking(0.6)
                .foregroundStyle(Khayt.cyan)

            if let report, !report.costs.isEmpty {
                body(for: report, words)
            } else {
                // NOT "no data". A shop reaches this by never having told Khayt
                // what it pays every month, which is a thing it can go and do —
                // so the screen says what and where.
                Text(words.callIt("an.be_none"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func body(for report: KhaytEngine.BreakEven, _ words: Words) -> some View {
        let currency = shop.currency

        if let target = report.breakEvenRevenue {
            // The one number worth reading from across a desk, and it is the
            // DISTANCE rather than the target: a shop that is 2,363 short knows
            // what to do about it in a way that "your target is 4,364" does not
            // convey on its own.
            let surplus = report.surplus ?? 0
            let over = surplus >= 0
            VStack(alignment: .leading, spacing: 4) {
                Text(words.callIt(over ? "an.be_above" : "an.be_below"))
                    .font(.caption).foregroundStyle(.secondary)
                BigFigure(value: Money.figure(abs(surplus)), unit: Money.mark(currency),
                          // Red when the month is still short, and otherwise
                          // uncoloured — never green for being ahead. Being
                          // ahead is the ordinary case; being behind is the
                          // shop being told something.
                          tint: over ? nil : Khayt.late, size: 24)
            }

            Bar(fraction: (report.progressPct ?? 0) / 100, over: over)
                .frame(height: 8)

            HStack(alignment: .firstTextBaseline) {
                Line(words.callIt("an.be_billed"),
                     Money.text(report.billedThisMonth, currency))
                Spacer(minLength: 12)
                Line(words.callIt("an.be_target"), Money.text(target, currency),
                     alignment: .trailing)
            }
        } else {
            // The costs are known and the margin is not. Saying so beats
            // drawing a bar against a target that does not exist.
            Text(words.callIt("an.be_no_history"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Divider().opacity(0.6)

        Line(words.callIt("an.be_fixed"), Money.text(report.totalFixed, currency))
        if let margin = report.marginPct {
            Line(words.callIt("an.be_margin"),
                 Money.quantity(margin * 100, decimals: 0) + "%")
        }

        // What the total is made of. A figure a shop cannot take apart is a
        // figure it has to trust rather than check.
        VStack(alignment: .leading, spacing: 3) {
            ForEach(report.costs) { cost in
                HStack {
                    Text(cost.name).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Money.text(cost.amount, currency))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    private func Line(_ label: String, _ value: String,
                      alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
        }
    }

    /// How far through the month's target the shop is.
    ///
    /// A plain `Capsule` over a `Capsule` rather than `ProgressView`: the
    /// system bar is a determinate *task* indicator, and this is not a task —
    /// it is a distance, and it needs to be able to read as full without
    /// implying anything has finished.
    private struct Bar: View {
        let fraction: Double
        let over: Bool

        var body: some View {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Khayt.recessed)
                    Capsule()
                        .fill(over ? Khayt.cyan : Khayt.late)
                        .frame(width: max(0, min(1, fraction)) * geometry.size.width)
                }
            }
        }
    }
}
