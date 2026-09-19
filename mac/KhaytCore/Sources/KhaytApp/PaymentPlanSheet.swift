import SwiftUI
import KhaytCore

/// A customer paying a job off over months.
///
/// ── WHY THIS EXISTS ───────────────────────────────────────────────────────
///
/// Khayt has always been able to agree a plan: three payments, a month apart,
/// on what a job still owes. This app could READ one — the Spending screen ages
/// each instalment from its own due date, not the order's — and could neither
/// write one nor collect one. A shop working on a Mac had to open the other app
/// to set up a plan it had already agreed on the phone.
///
/// Nothing here is arithmetic this app does for itself. The schedule is
/// `lib/payment-plan.js`'s `monthlyPlan`, what is owed is `lib/order-money.js`'s
/// `orderOwedRaw`, and what collecting a row does to the job's cash figures is
/// `collectionTotals` — three rules with a history of destroying money when
/// they were written twice.
struct PaymentPlanSheet: View {
    @Bindable var shop: Shop
    let job: Order

    /// The job as it stands NOW, not as it was when the sheet opened: every
    /// action here writes the book and reloads, and a sheet reading its own
    /// stale copy would show a row it had just collected as still outstanding.
    private var current: Order { shop.orders.first { $0.id == job.id } ?? job }
    private var rows: [Order.PlanRow] { current.instalments }
    private var currency: String { current.currency.isEmpty ? shop.currency : current.currency }

    /// What the job still owes, by the shared rule. Held in state because the
    /// rule runs in the engine, which is an actor: a view cannot ask it a
    /// question in the middle of drawing.
    @State private var owed: Double?

    /// Whether the "replace this plan" question is up.
    @State private var replacing = false

    /// What the plan has brought in, and what it still asks for.
    private var collected: Double { rows.filter(\.paid).reduce(0) { $0 + $1.amount } }
    private var scheduled: Double { rows.reduce(0) { $0 + $1.amount } }

    var body: some View {
        // `SheetFrame`: a plan is a list of the shop's own records and grows
        // with how many payments were agreed, and a sheet cannot be moved.
        SheetFrame(width: 480) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shop.words.callIt("inst.title")).font(.headline)
                Text(current.client.isEmpty ? current.project
                                            : "\(current.project) · \(current.client)")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }

            if rows.isEmpty {
                empty
            } else {
                plan
            }

            if let problem = shop.moveProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let notice = shop.moveNotices.first {
                Label(notice, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } footer: {
            HStack {
                if !rows.isEmpty {
                    Button(shop.words.callIt("common.remove"), role: .destructive) {
                        Task { await shop.dropPlan(job.id) }
                    }
                }
                Spacer()
                Button(shop.words.callIt("common.close")) { shop.planFor = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        // The engine is an actor, so what the job owes cannot be asked for in
        // the middle of drawing — it arrives just after the sheet does.
        .task { owed = await shop.owedOn(job.id) }
    }

    /// No plan yet: what one would be, and the button that writes it.
    ///
    /// §6 — never a blank panel. It says what a plan IS before offering one,
    /// because "Generate plan" on an empty sheet is a button whose result the
    /// shop only learns by pressing it.
    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(shop.words.callIt("mac.plan_explains"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabelledFigure(label: shop.words.callIt("flow.owed"),
                           value: owed,
                           style: .money(code: currency),
                           words: shop.words)
            // ── A BUTTON THAT EXISTS ONLY TO REFUSE IS NOT A BUTTON ────────
            //
            // Photographed against a settled job, this offered "Generate plan"
            // over an OWED of 0.00 — and pressing it answered "this order is
            // already paid in full". The shared rule's two refusals are the
            // two sentences to say instead, and they are said BEFORE the
            // gesture rather than after it.
            if let owed, owed > 0 {
                Button(shop.words.callIt("inst.generate")) {
                    Task {
                        await shop.makePlan(job.id)
                        self.owed = await shop.owedOn(job.id)
                    }
                }
                .keyboardShortcut(.defaultAction)
            } else if owed != nil {
                Text(shop.words.callIt(current.price > 0 ? "inst.nothing_owed" : "inst.need_price"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The agreed payments, in the order they fall due.
    private var plan: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(shop.words.callIt("inst.progress",
                                       ["paid": .string(Money.text(collected, currency)),
                                        "total": .string(Money.text(scheduled, currency))]))
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }

            ForEach(rows) { row in
                PlanRowView(shop: shop, job: job, row: row, currency: currency)
                Divider()
            }

            // ── A BUTTON IS NOT A QUESTION ────────────────────────────────
            //
            // This said "Replace the current installments?" on its face —
            // `inst.replace_q` is the CONFIRMATION Khayt asks after the
            // gesture, and using it as a label put the question where the
            // action belongs. Photographing the sheet is what showed it.
            //
            // Replacing a plan IS a renegotiation, so the question is still
            // asked; it is asked in the dialog, where a question goes.
            Button(shop.words.callIt("inst.generate")) { replacing = true }
                .font(.callout)
                .confirmationDialog(shop.words.callIt("inst.replace_q"),
                                    isPresented: $replacing, titleVisibility: .visible) {
                    Button(shop.words.callIt("inst.generate"), role: .destructive) {
                        Task { await shop.makePlan(job.id) }
                    }
                    Button(shop.words.callIt("common.cancel"), role: .cancel) {}
                }
        }
    }
}

/// One agreed payment: when, how much, and whether it has arrived.
private struct PlanRowView: View {
    @Bindable var shop: Shop
    let job: Order
    let row: Order.PlanRow
    let currency: String

    var body: some View {
        HStack(spacing: 10) {
            // A collected row is MARKED, not merely a different shade of the
            // same row: `Khayt.marked` is the filled glyph held to the
            // graphical contrast threshold, and colour alone would say nothing
            // to a shop that cannot see the difference.
            Button {
                Task { await shop.collect(job.id, rowId: row.id, collected: !row.paid) }
            } label: {
                Image(systemName: row.paid ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(row.paid ? Khayt.marked : Khayt.note)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(shop.words.callIt(row.paid ? "inst.paid" : "inst.mark_paid"))
            // Nothing to collect on a row a shop has not dated or priced.
            .disabled(row.amount <= 0)

            VStack(alignment: .leading, spacing: 2) {
                Text(Money.text(row.amount, currency)).monospacedDigit()
                Text(due).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(shop.words.callIt(row.paid ? "inst.paid" : "inst.unpaid"))
                .font(.caption)
                .foregroundStyle(row.paid ? AnyShapeStyle(.secondary) : AnyShapeStyle(Khayt.attention))
        }
    }

    /// The day it falls due — or the day it was collected, which is the more
    /// useful answer once it has been.
    private var due: String {
        if row.paid, let on = row.paidAt, !on.isEmpty {
            return shop.words.callIt("inst.paid") + " · " + on
        }
        return row.dueDate.isEmpty ? shop.words.callIt("oe.due_date") : row.dueDate
    }
}
