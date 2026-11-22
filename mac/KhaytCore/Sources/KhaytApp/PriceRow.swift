import SwiftUI

/// One material's price, as both price cards draw it.
///
/// ── ONE ROW, TWO CARDS ────────────────────────────────────────────────────
///
/// The shelf's card (`MaterialCostCard`) and the purchase log's
/// (`SupplierPricesCard`) sit one above the other on the same report and
/// each laid its row out its own way: the unit beside the name in one and
/// under it in the other, the figure before the change in one and after it
/// in the other, two type sizes, two paddings. Read together they looked like
/// two different kinds of fact. The row is shared now; what each card puts IN
/// it is still its own.
struct PriceRow: View {
    let title: String
    /// The unit and how many buys are behind the figure, on the second line.
    let detail: String
    let figure: String
    /// "▲ 6%", or empty for no change worth saying.
    var change: String = ""
    var changeTint: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(figure)
                .font(.callout.weight(.medium)).monospacedDigit()
            Text(change)
                .font(.caption).monospacedDigit()
                .foregroundStyle(changeTint)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }

    /// "▲ 6%" — an arrow rather than a sign, because a "+" on a cost reads
    /// as good news everywhere else on the screen.
    static func change(_ pct: Double?, atLeast threshold: Double) -> String {
        guard let pct, abs(pct) >= threshold else { return "" }
        return (pct > 0 ? "▲ " : "▼ ") + Money.quantity(abs(pct), decimals: 0) + "%"
    }
}
