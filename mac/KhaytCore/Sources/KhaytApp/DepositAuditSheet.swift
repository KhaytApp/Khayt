import SwiftUI
import KhaytCore

/// Deposits an old defect took off the book, and the one-click way back.
///
/// ── WHY IT FLAGS AND DOES NOT FIX ─────────────────────────────────────────
///
/// Saving an order that had a payment plan used to write the collected
/// instalment total straight over `paidAmount`, erasing the deposit the shop
/// had already taken. The code is fixed; the books written before it are not,
/// and those orders show less paid than they should — so the shop has been
/// chasing customers for money they handed over.
///
/// `paidAmount` drives receivables, payment status and the payment webhooks.
/// Rewriting it without the owner looking would be a worse thing to do than
/// the bug: what is shown here is both figures, per order, and nothing moves
/// until somebody asks. Each repair is a single write with the app's ordinary
/// undo behind it.
///
/// The figures are not this app's arithmetic. `lib/deposit-audit.js` recovers
/// them from the order's own record — the deposit it took, plus the instalment
/// rows it marked paid — and refuses to repair an order that no longer looks
/// affected.
struct DepositAuditSheet: View {
    @Bindable var shop: Shop

    /// The order waiting for a yes, and what the repair would say.
    @State private var confirming: KhaytEngine.ErasedDeposit?

    private var currency: String { shop.currency }

    var body: some View {
        // `SheetFrame`: one row per affected order, and a book can have many.
        SheetFrame(width: 520) {
            VStack(alignment: .leading, spacing: 6) {
                Text(shop.words.callIt("dep.head")).font(.headline)
                Text(shop.words.callIt("dep.body"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(shop.words.callIt("dep.total",
                                       ["n": .string(Money.text(shop.depositsUnaccounted, currency))]))
                    .font(.callout).foregroundStyle(Khayt.attention)
                    .monospacedDigit()
            }

            if shop.erasedDeposits.isEmpty {
                // Everything has been put back. Not a fault, and not an empty
                // screen either.
                Label(shop.words.callIt("dep.restored"), systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(Khayt.done)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shop.erasedDeposits) { entry in
                        row(entry)
                        Divider()
                    }
                }
            }

            if let problem = shop.moveProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } footer: {
            HStack {
                Spacer()
                Button(shop.words.callIt("common.close")) { shop.reviewingDeposits = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        // BOTH FIGURES IN THE QUESTION, not just the new one. The shop is
        // being asked to agree that money it cannot see on the screen was
        // received, and the deposit is the reason to believe it.
        .confirmationDialog(
            shop.words.callIt("dep.confirm",
                              ["n": .string(Money.text(confirming?.recovered ?? 0, currency)),
                               "d": .string(Money.text(confirming?.deposit ?? 0, currency))]),
            isPresented: Binding(get: { confirming != nil },
                                 set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible
        ) {
            Button(shop.words.callIt("dep.restore_btn")) {
                guard let entry = confirming else { return }
                confirming = nil
                Task { await shop.restoreDeposit(entry.id) }
            }
            Button(shop.words.callIt("common.cancel"), role: .cancel) { confirming = nil }
        }
    }

    /// One order: what it says it holds, and what its own record says it does.
    private func row(_ entry: KhaytEngine.ErasedDeposit) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.project).lineLimit(1)
                Text(shop.words.callIt("pay.deposit_on_file", ["amt": .string(Money.text(entry.deposit, currency))]))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            // The pair, in the order a correction reads: what is on the record
            // now, then what it should be.
            Text(Money.text(entry.currentPaid, currency))
                .font(.callout).monospacedDigit().foregroundStyle(.tertiary)
            Image(systemName: "arrow.forward").font(.caption2).foregroundStyle(.tertiary)
            Text(Money.text(entry.recovered, currency))
                .font(.callout).monospacedDigit().fontWeight(.medium)
            Button(shop.words.callIt("dep.restore_btn")) { confirming = entry }
                .disabled(!shop.canMoveJobs)
        }
        .padding(.vertical, 7)
    }
}
