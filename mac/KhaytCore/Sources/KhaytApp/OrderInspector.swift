import SwiftUI
import KhaytCore

/// The selected job, in detail.
///
/// The money here is not arithmetic written in Swift. `lib/tax.js` decides how a
/// price divides into what the shop keeps and what it is only holding for the
/// tax authority, and it does it differently by country — inclusive in the Gulf
/// and most of Europe, added on top in the US and Canada. A second
/// implementation would be a second chance to get that backwards.
struct OrderInspector: View {
    let shop: Shop
    @State private var split: TaxSplit?

    var body: some View {
        Group {
            if let job = shop.selected {
                Detail(job: job, shop: shop, split: split)
                    .task(id: job.id) { split = await shop.taxSplit(job.price) }
            } else {
                EmptyHere(title: shop.words.callIt("mac.no_job"), message: shop.words.callIt("mac.no_job_hint"), mark: .jobs)
            }
        }
    }
}

private struct Detail: View {
    let job: Order
    let shop: Shop
    let split: TaxSplit?
    @State private var zatca: KhaytEngine.ZatcaReporting.Invoice?
    @State private var editing: Order.Part?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                money
                if !job.parts.isEmpty {
                    Divider()
                    parts
                }
                // What the whole object came to, for a shop looking at one
                // leg of it. Only where there is a kit to show or a book that
                // has kits in it — a picker offering to file a job into
                // nothing, on every job, is a control that says nothing.
                if shop.kit(of: job.id) != nil || !shop.kits.isEmpty || shop.canWrite {
                    Divider()
                    KitSection(shop: shop, job: job)
                }
                // Only for an invoice that is actually owed a report. A job
                // still on the bench is not late, and a shop that has not
                // opted into Phase 2 is not subject to any of this — saying
                // "not submitted" there would raise an alarm about a rule that
                // does not apply to it.
                if let zatca, zatca.eligible, zatca.status != "notConfigured" {
                    Divider()
                    ZatcaLine(state: zatca, shop: shop)
                }
                if !job.notes.isEmpty {
                    Divider()
                    DetailSection(shop.words.callIt("doc.notes")) { Text(job.notes).textSelection(.enabled) }
                }
            }
            .padding(16)
        }
        .task(id: job.id) {
            zatca = await shop.zatcaReporting()?.invoices.first { $0.id == job.id }
        }
        .sheet(item: $editing) { part in
            EditPartSheet(shop: shop, orderId: job.id, part: part)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.project)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Text(job.id).monospacedDigit()
                if let s = Stage.of(job) {
                    Text("·")
                    Label(shop.words.callIt(s.key), systemImage: s.symbol).labelStyle(.titleAndIcon)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !job.client.isEmpty {
                Label(job.client, systemImage: "person")
                    .font(.callout)
                    .padding(.top, 2)
            }
        }
    }

    private var money: some View {
        DetailSection(shop.words.callIt("mac.money")) {
            DetailLine(shop.words.callIt("common.total"), Money.text(job.price, job.currency))
            if let split {
                // Only shown for a registered shop: an unregistered one has no
                // split, and inventing a zero-rate line would imply otherwise.
                DetailLine(shop.words.callIt("mac.shop_keeps"), Money.text(split.subtotal, job.currency), dim: true)
                DetailLine(shop.taxSummary.map { String($0.prefix(while: { !$0.isNumber })).trimmingCharacters(in: .whitespaces) } ?? "Tax",
                     Money.text(split.taxTotal, job.currency), dim: true)
            }
            DetailLine(shop.words.callIt("mac.paid"), Money.text(job.paidAmount, job.currency))
            DetailLine(shop.words.callIt("flow.owed"), Money.text(job.owed, job.currency), strong: !job.isSettled)
            if shop.canMoveJobs {
                // Where somebody is already reading what is owed. ⇧⌘P does the
                // same thing from anywhere; this is the one place the question
                // "has this been paid" is actually being asked.
                Button(shop.words.callIt("pay.modal_title")) {
                    shop.pendingPayment = Shop.PendingHold(id: job.id, project: job.project)
                }
                .buttonStyle(.link)
                .font(.callout)
                .padding(.top, 2)
            }
            // Beside the figures it states. Not behind `canMoveJobs`: showing
            // the document writes nothing, and the sample shop is the one book
            // most people will look at an invoice in first.
            Button(shop.words.callIt("doc.invoice")) { shop.showInvoice(job.id) }
                .buttonStyle(.link)
                .font(.callout)
            if let due = Order.day(job.dueDate) {
                DetailLine(shop.words.callIt("doc.due"), due.formatted(date: .abbreviated, time: .omitted),
                     warn: job.isOverdue())
            }
        }
    }

    private var parts: some View {
        DetailSection(shop.words.callIt("mac.parts")) {
            // By position: a part with no id of its own is given a fresh one on
            // every read, and keying on that would rebuild the rows each reload.
            ForEach(Array(job.parts.enumerated()), id: \.offset) { _, part in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(part.name).lineLimit(1)
                        Text(part.colour.isEmpty ? part.material : "\(part.material) · \(part.colour)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("×\(part.qty)").monospacedDigit()
                        // `grams`, not `figure`. The money formatter always
                        // shows two decimals, which is what turned a 180g
                        // failure into "180.00 grams" once already — and here
                        // printed a 129.18g part where a shop reads 129.2.
                        // The SYMBOL, not the word — this sits beside "×1" in
                        // a narrow column. `common.grams` is where Khayt keeps
                        // it, and it is not "g" everywhere: Arabic writes جم.
                        // Hard-coding the letter was a claim that the symbol is
                        // universal, and the catalogue says otherwise.
                        Text("\(Money.grams(part.printWeight)) \(shop.words.callIt("common.grams"))")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                // Double-click opens it, the way a job, a spool and a model all
                // open. A context menu as well, because a double-click you have
                // to know about is a feature for the person who wrote it.
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if shop.canMoveJobs { editing = part } }
                .contextMenu {
                    Button(shop.words.callIt("mac.edit_part") + "\u{2026}") { editing = part }
                        .disabled(!shop.canMoveJobs)
                }
            }
            DetailLine(shop.words.callIt("mac.machine_time"), String(format: "%.1f h", job.printTime), dim: true)
        }
    }
}


/// Whether this invoice has been reported to the tax authority.
///
/// Khayt already puts the Phase 1 QR on the document. What this says is the
/// thing a Saudi shop can be penalised for and could not see on this app: that
/// the invoice in the customer's hand has not been reported.
///
/// It does NOT offer to submit. Signing needs Node crypto and lives in the
/// Electron app, and a button here that could not finish the job would be
/// worse than the plain statement.
struct ZatcaLine: View {
    let state: KhaytEngine.ZatcaReporting.Invoice
    let shop: Shop

    var body: some View {
        // NO HEADING. There is no plain "ZATCA" label in the locales, and the
        // status strings are whole sentences already — "Submitted to ZATCA",
        // "Not submitted". A heading above them would either repeat the word or
        // mean inventing a key that needs nine translations to say it again.
        VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).foregroundStyle(colour)
                    Text(shop.words.callIt(key)).foregroundStyle(colour)
                    if let icv = state.icv {
                        Text("·").foregroundStyle(.tertiary)
                        // The counter the authority requires to be unbroken, so
                        // a gap in it is something a shop can be asked about.
                        Text("ICV \(icv.formatted(.number.precision(.fractionLength(0))))")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                // Why it was refused. Without it "rejected" is a dead end.
                if !state.message.isEmpty, state.status != "accepted" {
                    Text(state.message).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            if let at = state.at {
                Text(Date(timeIntervalSince1970: at / 1000)
                    .formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var key: String {
        switch state.status {
        case "accepted": "zatca2.status_accepted"
        case "rejected": "zatca2.status_rejected"
        case "error":    "zatca2.status_error"
        default:         "zatca2.status_pending"
        }
    }

    private var colour: Color {
        switch state.status {
        case "accepted": Khayt.done
        case "rejected", "error": Khayt.late
        default: Khayt.attention
        }
    }

    private var symbol: String {
        switch state.status {
        case "accepted": "checkmark.seal.fill"
        case "rejected", "error": "exclamationmark.triangle.fill"
        default: "clock.badge.exclamationmark"
        }
    }
}
