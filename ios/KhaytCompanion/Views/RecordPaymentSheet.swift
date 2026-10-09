import SwiftUI

/// Record what a customer paid, at the counter — the Mac's "Record payment"
/// sheet, on the phone.
///
/// The figure is the TOTAL paid on the job (the shop's rule sets `paidAmount`
/// to it), so the field opens on what was already paid plus what is owed:
/// "paid in full" is one tap, and a part payment is a smaller number.
struct RecordPaymentSheet: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @Environment(\.dismiss) private var dismiss

    let orderId: String
    let state: BookWriter.PaymentState
    let currency: String?
    let onSaved: () async -> Void

    @State private var amount = ""
    @State private var method = "cash"
    @State private var isSaving = false
    @State private var error: String?

    private var typed: Double? { SpoolDraft.price(amount) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    V2FieldCard {
                        V2Field(label: L10n.tr("pay.billed")) {
                            Text(Money.text(state.cashDue, currency))
                                .font(.khayt(17, .semibold, relativeTo: .headline).monospacedDigit())
                                .foregroundStyle(KhaytDesign.ink)
                        }
                        V2Field(label: L10n.tr("pay.amount_paid")) {
                            TextField("", text: $amount, prompt: Text(verbatim: "0.00"))
                                .keyboardType(.decimalPad)
                                .font(.khayt(26, .semibold, relativeTo: .title).monospacedDigit())
                        }
                        V2Field(label: L10n.tr("pay.method"), last: true) {
                            V2Chips(options: BookWriter.paymentMethods, selection: $method) { L10n.tr("pay.method.\($0)") }
                                .padding(.vertical, 4)
                        }
                    }
                    V2Note(text: L10n.tr("pay.total_hint"))
                    if let error { V2Note(text: error, tone: KhaytDesign.late) }
                    V2PrimaryButton(title: L10n.tr("pay.save"), busy: isSaving, disabled: typed == nil) {
                        Task { await save() }
                    }
                    .padding(.top, 4)
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(KhaytDesign.ground.ignoresSafeArea())
            .navigationTitle(L10n.tr("pay.modal_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.close")) { dismiss() }
                }
            }
            .onAppear {
                // Paid in full, as the opening figure — the commonest case at a counter.
                amount = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), state.cashDue)
            }
        }
    }

    private func save() async {
        guard let total = typed else { return }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            try await api.recordPayment(orderId: orderId, totalPaid: total, method: method)
            CompanionHaptics.success()
            await onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
            CompanionHaptics.warning()
        }
    }
}

/// The order page's money: where the job stands, and the way to record more.
struct PaymentCard: View {
    let state: BookWriter.PaymentState
    let currency: String?
    let onRecord: () -> Void

    private var tone: Color {
        switch state.status {
        case "paid": return KhaytDesign.done
        case "partial": return KhaytDesign.attention
        default: return KhaytDesign.late
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L10n.tr("pay.section").uppercased())
                .font(.khayt(10.5, .bold, relativeTo: .caption2))
                .tracking(1.05)
                .foregroundStyle(KhaytDesign.note)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L10n.tr("pay.status.\(state.status)"))
                    .font(.khayt(12, .semibold, relativeTo: .caption))
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .foregroundStyle(tone)
                    .background(tone.opacity(0.14), in: Capsule())
                if state.owed > 0 {
                    Text(L10n.format("pay.owed", Money.text(state.owed, currency)))
                        .font(.khayt(14.5, .medium, relativeTo: .subheadline).monospacedDigit())
                        .foregroundStyle(KhaytDesign.ink)
                }
                Spacer(minLength: 0)
                if state.status != "paid" {
                    Button(L10n.tr("pay.modal_title"), action: onRecord)
                        .font(.khayt(14.5, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(KhaytDesign.brand)
                }
            }
            .padding(14)
            .card()
        }
    }
}
