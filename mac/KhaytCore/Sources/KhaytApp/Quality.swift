import SwiftUI
import KhaytCore

/// How much of the shop's work passes inspection, and how much first time.
///
/// ── TWO FIGURES, AND THE GAP BETWEEN THEM IS THE FINDING ──────────────────
///
/// Pass rate is the easy number and the less useful one: a shop that reprints
/// until it passes has a pass rate near 100% and a quality problem. First-pass
/// yield collapses a reprint chain to one job, so it says how much was right
/// the first time — and the difference between them is exactly the work the
/// shop did twice and was not paid for twice.
struct QualityCard: View {
    let shop: Shop
    let report: KhaytEngine.QcMetrics?

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 10) {
            Text(words.callIt("mac.qc_title"))
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase).tracking(0.6)
                .foregroundStyle(Khayt.cyan)

            if let report, let pass = report.passRate {
                HStack(alignment: .top, spacing: 22) {
                    // First-pass yield FIRST and emphasised: it is the one that
                    // says something a shop did not already know.
                    Rate(words.callIt("mac.qc_first"), report.firstPassYield, big: true)
                    Rate(words.callIt("mac.qc_passed"), pass, big: false)
                    Spacer(minLength: 0)
                }

                // The gap, in jobs rather than percentage points — "four jobs
                // you did twice" is a thing to picture, and "3 points" is not.
                let reprinted = max(0, report.roots - report.firstPass)
                if reprinted > 0 {
                    Text(words.callIt("mac.qc_gap", ["n": .number(Double(reprinted))]))
                        .font(.callout).foregroundStyle(Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let worst = report.worstDefect {
                    Text(words.callIt("mac.qc_worst", [
                        "fault": .string(MachineReliabilityCard.fault(worst.type, words)),
                    ]))
                    .font(.caption).foregroundStyle(.secondary)
                }
                if report.rmaCount > 0 {
                    Text(words.callIt("mac.qc_rma", [
                        "n": .number(Double(report.rmaCount)),
                        "amount": .string(Money.text(report.rmaCost, shop.currency)),
                    ]))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                // Not "0%". A shop that has never inspected anything has not
                // failed everything, which is what a nought here would claim.
                Text(words.callIt("mac.qc_none"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func Rate(_ label: String, _ value: Double?, big: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            BigFigure(value: value.map { Money.quantity($0 * 100, decimals: 0) } ?? "—",
                      unit: value == nil ? "" : "%",
                      // Red below three-quarters right first time. One
                      // threshold, not a gradient: a shop acts on this at a
                      // point, and a continuous colour has none.
                      tint: (value ?? 1) < 0.75 ? Khayt.late : nil,
                      size: big ? 26 : 18)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
