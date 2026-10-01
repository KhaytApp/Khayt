import SwiftUI
import KhaytCore

/// A machine's book value, what it has lost and what life it has left — the
/// machine card's "Value" section. Every figure is `lib/depreciation.js`'s;
/// this only lays them out, and says what is missing where one cannot be
/// worked out yet rather than printing a dash.
struct MachineValueLines: View {
    let shop: Shop
    let value: KhaytEngine.MachineValue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let book = value.bookValue {
                DetailLine(shop.words.callIt("mac.dep_book_value"), Money.text(book, shop.currency))
            }
            if let lost = value.toDate {
                DetailLine(shop.words.callIt("mac.dep_to_date"), Money.text(lost, shop.currency), dim: true)
            }
            if let hours = value.remainingHours {
                DetailLine(shop.words.callIt("mac.dep_left"),
                           shop.words.callIt("mac.dep_hours_left",
                                             ["n": .string(Money.quantity(hours, decimals: 0))]),
                           dim: true)
            } else if let months = value.remainingMonths {
                DetailLine(shop.words.callIt("mac.dep_left"),
                           shop.words.counting(Int(saturating: months.rounded()), "mac.dep_months_left"),
                           dim: true)
            }
            if let rate = value.hourlyRate {
                DetailLine(shop.words.callIt("mac.dep_rate"),
                           shop.words.callIt("mac.dep_per_hour_amount",
                                             ["rate": .string(Money.text(rate, shop.currency))]),
                           dim: true)
            }
            if value.fullyDepreciated {
                Text(shop.words.callIt("mac.dep_fully"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let needs = value.needs {
                Text(shop.words.callIt("mac.dep_needs_" + needs))
                    .font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// What the shop's own history says the failure allowance should be, beside
/// the field where it is set — with a button to use it.
///
/// ── NEVER SILENTLY ────────────────────────────────────────────────────────
///
/// `lib/failure-rate.js` works the figure out from QC fails, waste tied to
/// jobs and finished jobs over the last ninety days. This view only OFFERS it:
/// the field changes when the shop presses "Use this", and not otherwise. A
/// price that moved because the app decided the shop fails more often than it
/// thought is a price nobody can explain to a customer.
///
/// Nothing is drawn with no history at all. With some, but under the minimum,
/// it says how many prints there are so far, so the shop knows why there is no
/// suggestion yet.
struct FailureHint: View {
    let shop: Shop
    let machineId: String?
    let material: String?
    /// The figure currently in the field, so "Use this" is not offered when it
    /// already is the figure.
    let current: Double?
    let use: (Double) -> Void

    @State private var suggestion: KhaytEngine.FailureSuggestion?

    var body: some View {
        Group {
            if let s = suggestion, s.attempts > 0 {
                if s.enough, let pct = s.pct {
                    HStack(spacing: 6) {
                        Text(shop.words.callIt("mac.fail_suggest", [
                            "pct": .string(Money.quantity(pct, decimals: pct == pct.rounded() ? 0 : 1)),
                            "n": .number(Double(s.attempts)),
                        ]))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        if current.map({ abs($0 - pct) > 0.05 }) ?? true {
                            Button(shop.words.callIt("mac.fail_use")) { use(pct) }
                                .controlSize(.small)
                        }
                    }
                    Text(shop.words.callIt("mac.fail_scope_" + s.scope))
                        .font(.caption2).foregroundStyle(.tertiary)
                } else {
                    Text(shop.words.callIt("mac.fail_too_few", [
                        "n": .number(Double(s.attempts)), "min": .number(Double(s.minSample)),
                    ]))
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(id: "\(machineId ?? "")|\(material ?? "")|\(shop.orderRows.count)|\(shop.wasteRows.count)") {
            suggestion = await shop.failureSuggestion(machineId: machineId, material: material)
        }
    }
}
