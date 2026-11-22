import SwiftUI
import KhaytCore

/// What was paid, how, and when.
///
/// Three fields, because that is what Khayt asks for and what a shop actually
/// knows. The amount is capped at the price — an overpayment is a credit note,
/// not a bigger payment, and the field says so by refusing rather than by
/// explaining afterwards.
struct PaymentSheet: View {
    /// How wide this sheet is. A CONSTANT rather than a number in the body,
    /// because `SnapshotTests` photographs the sheet at a size of its own and
    /// the two silently disagreed: the sheet grew and the picture kept the old
    /// width, so the render came back cropped down the middle with no failure.
    static let width: CGFloat = 380

    let shop: Shop
    let subject: Shop.PendingHold

    @State private var amount: Double = 0
    @State private var method = "cash"
    @State private var paidAt = Date()
    @State private var started = false
    /// What the order is billed and already paid down without cash, by
    /// `KhaytOrderPayment.cashDue`. Nil until asked, or with no engine.
    @State private var due: KhaytEngine.CashDue?
    /// The engine has answered (or failed to); Save waits for it.
    @State private var asked = false
    /// "Clear payment" pressed and not yet answered. It wiped what the
    /// customer paid in one click, from a sheet opened to RECORD a payment.
    @State private var clearing: Order?
    @FocusState private var focused: Bool

    private var job: Order? { shop.orders.first { $0.id == subject.id } }
    /// What the customer is asked for — the price, or price + tax on a shop
    /// that adds it on top.
    // The engine's bill, else the bill the order was loaded with (price +
    // tax on top), and the bare price only when neither is known: a cap at
    // the bare price recorded a payment short by the tax (alpha.82 review).
    private var price: Double { due?.gross ?? job?.figures?.billed ?? job?.price ?? 0 }
    /// What the typed figure is measured against: the bill, less what a gift
    /// card or a credit note has already taken off it.
    private var cashDue: Double { due?.cash ?? price }
    private var currency: String { job?.currency ?? "SAR" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shop.words.callIt("pay.modal_title")).font(.headline)
            Text(subject.project).font(.callout).foregroundStyle(.secondary).lineLimit(1)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(shop.words.callIt("common.total")).foregroundStyle(.secondary)
                    Text(Money.text(price, currency)).monospacedDigit()
                }
                GridRow {
                    Text(shop.words.callIt("pay.amount_paid")).foregroundStyle(.secondary)
                    // The currency beside the box a figure is typed into, not
                    // only beside the totals it is compared against — and the
                    // MARK, the way the two totals on this same sheet write it.
                    // It said "SAR" here and drew the mark two rows above, so
                    // one sheet spelled one currency two ways.
                    HStack(spacing: 4) {
                        TextField("", value: $amount, format: .number.locale(Money.digits).precision(.fractionLength(0...2)))
                            .textFieldStyle(.roundedBorder)
                            .monospacedDigit()
                            .focused($focused)
                            .onSubmit(commit)
                        Text(Money.mark(currency)).foregroundStyle(.secondary)
                        // The commonest payment there is: all of it. The box
                        // is a running total, so without this "they paid" was
                        // reading the bill off the row above and typing it.
                        //
                        // Offered only when it can RAISE what is recorded and
                        // the bill is known (`paidInFull`): see there.
                        let full = Self.paidInFull(due: due, recorded: job?.paidAmount ?? 0)
                        Button(shop.words.callIt("mac.paid_in_full")) {
                            if let full { amount = full }
                        }
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(job == nil || full == nil || abs(amount - (full ?? amount)) < 0.005)
                    }
                }
                GridRow {
                    Text(shop.words.callIt("pay.payment_method")).foregroundStyle(.secondary)
                    Picker("", selection: $method) {
                        ForEach(Shop.paymentMethods, id: \.self) { m in
                            Text(shop.words.callIt("pay.method." + m)).tag(m)
                        }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text(shop.words.callIt("pay.paid_on")).foregroundStyle(.secondary)
                    // No future date: money is recorded when it arrives, and a
                    // payment dated next week is a promise, not a payment.
                    DatePicker("", selection: $paidAt, in: ...Date(), displayedComponents: .date)
                        .labelsHidden()
                }
            }

            // Said before it is saved, by the same rule every report will read
            // it with — a gift card or a credit note on the order can make a
            // part payment settle it, and the shop should see that here.
            //
            // It said `price − amount`, which is exactly what this comment
            // promised it would not: a 500 job with a 100 gift card and 400
            // typed read "Owed 100", and saved as settled.
            if let job {
                Text(shop.words.callIt("flow.owed") + " " + Money.text(max(0, cashDue - amount), currency))
                    .font(.callout)
                    .foregroundStyle(cashDue - amount > 0.005 ? AnyShapeStyle(Khayt.attention) : AnyShapeStyle(.secondary))
                    .monospacedDigit()
                    .help(job.id)
            }

            HStack {
                if (job?.paidAmount ?? 0) > 0 {
                    Button(shop.words.callIt("mac.clear_payment") + "\u{2026}", role: .destructive) {
                        clearing = job
                    }
                }
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.clearQuestion() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("common.save"), action: commit)
                    .keyboardShortcut(.defaultAction)
                    // Not before the bill is known: until then `price` is the
                    // job's bare price, which on a shop adding tax on top is
                    // short by the tax, and the cap in `commit` would record
                    // a payment short by exactly that (Oct 2026 review).
                    .disabled(!asked && shop.engine != nil)
            }
        }
        .padding(18)
        .frame(width: Self.width)
        .task(id: subject.id) { due = await shop.cashDue(subject.id); asked = true }
        .askFirst($clearing,
                  title: { shop.words.callIt("mac.clear_payment_q",
                                             ["amount": .string(Money.text($0.paidAmount, currency)),
                                              "name": .string($0.project)]) },
                  message: { _ in shop.words.callIt("mac.clear_payment_note") + " "
                                  + shop.words.callIt("mac.undo_after") },
                  confirm: shop.words.callIt("mac.clear_payment"),
                  cancel: shop.words.callIt("common.cancel")) { chosen in
            shop.clearQuestion()
            Task { await shop.clearPayment(chosen.id) }
        }
        .onAppear {
            guard !started else { return }
            started = true
            // Opens on what is already recorded, not on zero: the common edit is
            // "they paid the rest", and a field that starts empty makes that a
            // retype rather than a correction.
            amount = job?.paidAmount ?? 0
            if let m = job?.paymentMethod, Shop.paymentMethods.contains(m) { method = m }
            focused = true
        }
    }

    /// What "Paid in full" puts in the box: the figure the Owed line below
    /// measures against — the bill (price + tax on an exclusive shop) less
    /// what a credit note or gift card has already taken off it, by
    /// `KhaytOrderPayment.cashDue`. So pressing it always reads "Owed 0",
    /// and a job a gift card half paid is not recorded as paid twice over.
    ///
    /// The box is the TOTAL paid, not this payment, so this is the whole
    /// figure and not what is left after earlier payments.
    ///
    /// NIL — the button is off — in two cases (alpha.74 review):
    ///   - before the engine has answered. The fallback is the job's `price`,
    ///     which on a tax-exclusive shop is the NET figure, so pressing early
    ///     recorded a payment short by the tax;
    ///   - when what is `recorded` already covers the cash due. A 100 job paid
    ///     100 and then given a 30 credit note has a cash due of 70, and the
    ///     button wrote 70 over the 100 the customer actually handed over.
    static func paidInFull(due: KhaytEngine.CashDue?, recorded: Double) -> Double? {
        guard let figure = due?.cash, figure.isFinite else { return nil }
        let full = (max(0, figure) * 100).rounded() / 100
        guard !(recorded >= full - 0.005) else { return nil }
        return full
    }

    private func commit() {
        let id = subject.id
        let paid = min(max(0, amount), price)
        let when = paidAt
        let how = method
        shop.clearQuestion()
        Task { await shop.recordPayment(id, amount: paid, method: how, paidAt: when) }
    }
}
