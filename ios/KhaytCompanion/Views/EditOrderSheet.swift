import SwiftUI
import KhaytCore

/// Change a job's due date, priority or price — the Mac's Edit sheet's
/// fields, through the same rule (`lib/order-edit.js`): only what was
/// changed is sent, the edit is written in the job's history, and a typed
/// price carries the money with it.
///
/// ── REVISE IS THIS SHEET ──────────────────────────────────────────────────
///
/// Handed `revising`, the sheet is a quote's Revise (Turki, Nov 2026: Revise
/// covers every field, not just the price and notes). It is the desktop's
/// Revise — keep the quote as it is, then open the order editor — in one
/// sheet: the due date, priority and price above, and below them the quote's
/// own terms the order editor also writes (`applyDetails`): its notes, the
/// notes printed on it, the discount and the shipping. Saving goes through
/// `BookWriter.reviseQuote`, which keeps the version as it was
/// (`lib/quote-revision.js`) and makes the change in ONE write; the quote stays
/// a quote, so the customer is asked again.
///
/// The customer, the parts, quantities, material and machine are not here:
/// no app's order editor changes them on a saved job (the desktop's editor
/// and the Mac's Edit sheet do not either), and `applyDetails` — the shared
/// rule — has no field for them.
struct EditOrderSheet: View {
    let orderId: String
    let start: KhaytAPIClient.OrderEditState
    var currency: String?
    /// A quote being revised, or nil for an ordinary edit.
    var revising: KhaytAPIClient.QuoteState?
    var onSaved: () async -> Void = {}

    @EnvironmentObject private var api: KhaytAPIClient
    @Environment(\.dismiss) private var dismiss
    @State private var hasDue = false
    @State private var due = Date()
    @State private var level = "normal"
    @State private var price = ""
    @State private var notes = ""
    @State private var invoiceNotes = ""
    @State private var discount = ""
    @State private var shipping = ""
    @State private var saving = false
    @State private var problem: String?

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(L10n.tr("edit.due"), isOn: $hasDue)
                    if hasDue {
                        DatePicker(L10n.tr("edit.due"), selection: $due, displayedComponents: .date)
                            .labelsHidden()
                    }
                }
                Section {
                    Picker(L10n.tr("edit.priority"), selection: $level) {
                        Text(L10n.tr("edit.priority.normal")).tag("normal")
                        Text(L10n.tr("edit.priority.high")).tag("high")
                        Text(L10n.tr("edit.priority.urgent")).tag("urgent")
                    }
                }
                Section {
                    TextField(currency.map { L10n.format("order.new.price_in", Money.mark($0)) } ?? L10n.tr("order.new.price"),
                              text: $price)
                        .keyboardType(.decimalPad)
                        .font(.khayt(16, relativeTo: .body).monospacedDigit())
                } header: {
                    if revising != nil { Text(L10n.tr("quote.revise.price")) }
                } footer: {
                    if revising == nil {
                        Text(problem ?? L10n.tr("edit.price.note"))
                            .foregroundStyle(problem == nil ? KhaytDesign.note : KhaytDesign.late)
                    }
                }
                if let quote = revising { reviseSections(quote) }
            }
            .navigationTitle(L10n.tr(revising == nil ? "edit.title" : "quote.revise"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("common.cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("common.save")) { Task { await save() } }.disabled(saving)
                }
            }
            .onAppear {
                hasDue = start.dueDate != nil
                if let d = start.dueDate, let date = Self.dayFormat.date(from: d) { due = date }
                level = start.priorityLevel
                price = Money.figure(start.price)
                if let quote = revising {
                    notes = quote.notes
                    invoiceNotes = quote.invoiceNotes
                    discount = Self.plain(quote.discountPct)
                    shipping = Self.plain(quote.shippingCost)
                }
            }
        }
    }

    /// The quote's own terms, below the fields every edit has.
    @ViewBuilder
    private func reviseSections(_ quote: KhaytAPIClient.QuoteState) -> some View {
        Section {
            LabeledContent(L10n.tr("quote.revise.discount")) {
                TextField("0", text: $discount)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    .font(.khayt(16, relativeTo: .body).monospacedDigit())
            }
            LabeledContent(currency.map { L10n.format("quote.revise.shipping_in", Money.mark($0)) }
                           ?? L10n.tr("quote.revise.shipping")) {
                TextField("0", text: $shipping)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    .font(.khayt(16, relativeTo: .body).monospacedDigit())
            }
        } footer: {
            Text(L10n.tr("quote.revise.terms.note")).foregroundStyle(KhaytDesign.note)
        }
        Section {
            TextField(L10n.tr("quote.revise.printed_notes"), text: $invoiceNotes, axis: .vertical)
                .lineLimit(2...6)
        } header: {
            Text(L10n.tr("quote.revise.printed_notes"))
        } footer: {
            Text(L10n.tr("quote.revise.printed_notes.sub")).foregroundStyle(KhaytDesign.note)
        }
        Section {
            TextField(L10n.tr("quote.revise.notes"), text: $notes, axis: .vertical)
                .lineLimit(3...8)
        } header: {
            Text(L10n.tr("quote.revise.notes"))
        } footer: {
            Text(problem ?? L10n.format("quote.revise.note", quote.version, quote.version + 1))
                .foregroundStyle(problem == nil ? KhaytDesign.note : KhaytDesign.late)
        }
    }

    /// A figure as a box shows it to be edited: no grouping, no trailing zeros.
    static func plain(_ n: Double) -> String {
        guard n != 0 else { return "" }
        if n == n.rounded() { return String(Int(n)) }
        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), n)
    }

    /// Only the fields that moved: a key left out is left alone by the rule.
    static func fields(start: KhaytAPIClient.OrderEditState, due: String?, level: String,
                       price: Double?) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        if due != start.dueDate { out["dueDate"] = due.map(JSONValue.string) ?? .null }
        if level != start.priorityLevel { out["priorityLevel"] = .string(level) }
        if let price, abs(price - start.price) > 0.004 { out["price"] = .number(price) }
        return out
    }

    /// A revision's fields: an edit's, and the quote's own terms that moved.
    /// A discount or shipping box left empty is 0; one that cannot be read
    /// leaves the term alone.
    static func reviseFields(start: KhaytAPIClient.OrderEditState, quote: KhaytAPIClient.QuoteState,
                             due: String?, level: String, price: Double?,
                             discount: String, shipping: String,
                             notes: String, invoiceNotes: String) -> [String: JSONValue] {
        var out = fields(start: start, due: due, level: level, price: price)
        func figure(_ typed: String) -> Double? {
            let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? 0 : PhoneCalculator.parse(t)
        }
        if let d = figure(discount), abs(d - quote.discountPct) > 0.004 { out["discountPct"] = .number(d) }
        if let s = figure(shipping), abs(s - quote.shippingCost) > 0.004 { out["shippingCost"] = .number(s) }
        if notes != quote.notes { out["notes"] = .string(notes) }
        if invoiceNotes != quote.invoiceNotes { out["invoiceNotes"] = .string(invoiceNotes) }
        return out
    }

    private func save() async {
        let typed = SpoolDraft.price(price)
        let day = hasDue ? Self.dayFormat.string(from: due) : nil
        let fields: [String: JSONValue]
        if let quote = revising {
            fields = Self.reviseFields(start: start, quote: quote, due: day, level: level, price: typed,
                                       discount: discount, shipping: shipping,
                                       notes: notes, invoiceNotes: invoiceNotes)
        } else {
            fields = Self.fields(start: start, due: day, level: level, price: typed)
        }
        guard !fields.isEmpty else { dismiss(); return }
        saving = true
        defer { saving = false }
        do {
            if revising != nil {
                try await api.reviseQuote(orderId: orderId, fields: fields)
            } else {
                try await api.editOrder(orderId: orderId, fields: fields)
            }
            CompanionHaptics.success()
            await onSaved()
            dismiss()
        } catch {
            problem = error.localizedDescription
            CompanionHaptics.warning()
        }
    }
}
