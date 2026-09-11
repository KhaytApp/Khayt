import SwiftUI
import KhaytCore

/// What the shop's models really cost, against what it quotes for them.
///
/// ── WHY THE MODEL AND NOT THE ORDER ───────────────────────────────────────
///
/// Analytics can already say "your estimates ran 12% short last quarter". That
/// is true and a shop can do nothing with it: an order happened once, to one
/// customer, at a price already charged. The unit that can be acted on is the
/// MODEL — "this hood is quoted at 197 g and across two prints it took 226,
/// 15% more filament than you charge for" is a sentence that changes a price.
///
/// ── AND WHY IT CAN BE EMPTY IN A BUSY SHOP ────────────────────────────────
///
/// Two filters, from `lib/estimate-variance.js`, and neither implies the other.
/// A reading counts only if a PRINTER reported it — a typed actual is usually
/// the estimate confirmed, so counting those would compare an estimate to
/// itself — and only if the job had ONE part, because a multi-part job's
/// figures were divided to get here and are not evidence about any one model.
/// A shop with plenty of finished work can therefore see nothing here, so the
/// empty state says which of the two is missing rather than "no data".
struct Quoting: View {
    let shop: Shop
    let rows: [KhaytEngine.ModelVariance]
    /// The sentence each row earned, if any. Worked out with the rows rather
    /// than per-row in the body: it is an engine call, and a `View` body runs
    /// whenever anything near it changes.
    let said: [String: KhaytEngine.VarianceAdvice]
    /// How many quotes turn into work. Beside how ACCURATE the quotes are,
    /// because those are the two halves of one question: a shop whose quotes
    /// are precise and rarely accepted is priced wrong, and one whose quotes
    /// are always accepted and always over is priced low.
    var funnel: KhaytEngine.QuoteFunnel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // The funnel FIRST, and shown even when there is no variance to
                // report: how many quotes are won is knowable from the day a
                // shop opens, and how far a quote misses needs measured prints.
                // Hiding the first behind the second is why this screen was
                // blank for a shop that had never measured anything.
                QuoteFunnelCard(shop: shop, report: funnel)
                    .card(rail: Khayt.cyan, padding: 14)

                if rows.isEmpty {
                    EmptyHere(title: shop.words.callIt("mac.quoting_empty"),
                              message: shop.words.callIt("mac.quoting_empty_why"),
                              mark: .reports)
                } else {
                    list
                }
            }
            .padding(Metric.screen)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The rows, outside the `ScrollView` that holds them.
    ///
    /// Split out so the harness can photograph them: `ImageRenderer` draws
    /// NOTHING inside a `ScrollView` and does not say so — the view comes back
    /// fully transparent, which reads as a white page in anything that opens
    /// the PNG. This screen was drawn blank twice before that was believed.
    @ViewBuilder var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows) { row in
                Row(shop: shop, row: row, said: said[row.printFileId])
            }
        }
    }

    private struct Row: View {
        let shop: Shop
        let row: KhaytEngine.ModelVariance
        let said: KhaytEngine.VarianceAdvice?

        var body: some View {
            let words = shop.words
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.name.isEmpty ? row.printFileId : row.name)
                        .font(.headline)
                    Spacer()
                    // How much evidence is behind the row, always — a figure
                    // from one print and a figure from nine are different
                    // claims and must not look alike.
                    Text(words.counting(row.sampled, "mac.prints_word"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 22) {
                    Axis(shop: shop, label: words.callIt("mac.filament"),
                         est: row.estGrams, act: row.actGrams,
                         pct: row.gramsDeltaPct, unit: "g")
                    Axis(shop: shop, label: words.callIt("mac.time"),
                         est: row.estHours, act: row.actHours,
                         pct: row.hoursDeltaPct, unit: "h")
                }
                if let said {
                    // Only where the module says it is worth saying. Over-
                    // quoting is not a problem being solved here, and a panel
                    // that reports every 3% wobble is a panel nobody reads.
                    Text(words.callIt(said.axis == "time" ? "mac.quoting_advice_time"
                                                          : "mac.quoting_advice_filament",
                                      ["pct": .number(Double(said.pct))]))
                        .font(.callout)
                        .foregroundStyle(Khayt.attention)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 14)
        }
    }

    /// One axis of the comparison — filament or time.
    private struct Axis: View {
        let shop: Shop
        let label: String
        let est: Double?
        let act: Double?
        let pct: Double?
        let unit: String
        /// THE ARROW STAYS `→` IN ARABIC, and flipping it to `←` was tried and
        /// is wrong — the picture said so and nothing else would have.
        ///
        /// `559 g → 587 g` contains no strong right-to-left character, so bidi
        /// resolves the whole line as left-to-right whatever the window's
        /// direction is: the quote stays on the left and what it really took on
        /// the right, in both languages. A `←` there does not mirror the line,
        /// it only reverses the arrow inside a line that did not move — which
        /// reads as "587 became 559", the opposite of the truth.

        /// NOT `Money.figure`, which is a money formatter and always writes
        /// two decimals. Hours keep one, because a tenth of an hour is six
        /// minutes and a shop schedules in those; grams keep none.
        private func figure(_ value: Double) -> String {
            Money.quantity(value, decimals: unit == "h" ? 1 : 0)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                // NULL IS NOT ZERO. The shared rule returns null for a side it
                // does not know, and printing that as 0 g would read as a print
                // that used no filament rather than one nobody measured.
                if let est, let act {
                    Text("\(figure(est)) \(unit) → \(figure(act)) \(unit)")
                        .font(.callout.monospacedDigit())
                } else {
                    Text(shop.words.callIt("mac.not_measured"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let pct {
                    // Over is what costs the shop money; under is a quote it
                    // got away with. Coloured accordingly, and never red for
                    // being under.
                    Text(shop.words.callIt(pct >= 0 ? "mac.pct_over" : "mac.pct_under",
                                           ["pct": .number(abs(pct.rounded()))]))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(pct >= 10 ? Khayt.attention : .secondary)
                }
            }
        }
    }
}
