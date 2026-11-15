import SwiftUI
import KhaytCore

/// Change a job's due date, priority or price — the Mac's Edit sheet's
/// fields, through the same rule (`lib/order-edit.js applyJobEdit`): only
/// what was changed is sent, the edit is written in the job's history, and
/// a typed price below what was paid is refused with the rule's reason
/// (nothing is written, the sheet stays open), never settled by capping
/// what was paid.
///
/// ── REVISE IS THIS SHEET ──────────────────────────────────────────────────
///
/// Handed `revising`, the sheet is a quote's Revise (Turki, Nov 2026: Revise
/// covers every field, not just the price and notes). It is the desktop's
/// Revise — keep the quote as it is, then open the order editor — in one
/// sheet: the due date, priority and price above, and below them the quote's
/// own terms the order editor also writes (`applyJobEdit`): its notes, the
/// notes printed on it, the discount and the shipping. Saving goes through
/// `BookWriter.reviseQuote`, which keeps the version as it was
/// (`lib/quote-revision.js`) and makes the change in ONE write; the quote stays
/// a quote, so the customer is asked again.
///
/// ── THE MARKUP (Mac #2494, Figma 233:2 / 233:32) ──────────────────────────
///
/// Where the price was made from cost, the markup is a field: a new one is
/// sent as `marginPct` and the same rule (`applyMarkup` inside
/// `applyJobEdit`) works the price again from cost, with the discount, rush,
/// shipping, extras and rounding as they were. The new total shows under it
/// before saving (a dry run of the same rule). Once the customer has seen the
/// price, Save asks first ("Change the price") and then saves with
/// `priceSeenOk`. The field is not shown where the rule would refuse it: a
/// typed price, another currency, parts that may no longer change.
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
    /// The markup as the rule reads it; nil = no field.
    @State private var markupState: KhaytAPIClient.MarkupState?
    @State private var markup = ""
    @State private var markupProblem: String?
    @State private var newTotal: Double?
    @State private var askingMarkup = false

    static let dayFormat: DateFormatter = {
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
                            .environment(\.calendar, Calendar(identifier: .gregorian))
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
                    // The rule's refusal sits under the price it is about
                    // (Figma 231:333), on an edit and a revision alike.
                    if let problem {
                        Text(problem).foregroundStyle(KhaytDesign.late)
                    } else if revising == nil {
                        Text(L10n.tr("edit.price.note")).foregroundStyle(KhaytDesign.note)
                    }
                }
                if markupState != nil { markupSection }
                if let quote = revising { reviseSections(quote) }
            }
            .editsShop()
            .navigationTitle(L10n.tr(revising == nil ? "edit.title" : "quote.revise"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("common.cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("common.save")) { Task { await save() } }.disabled(saving || !api.canWrite)
                }
            }
            // The customer has seen this price: a new markup moves it, so ask.
            .confirmationDialog(L10n.tr("mac.js_markup_q"), isPresented: $askingMarkup, titleVisibility: .visible) {
                Button(L10n.tr("mac.js_markup_change")) { Task { await save(priceSeenOk: true) } }
                Button(L10n.tr("common.cancel"), role: .cancel) {}
            }
            .task {
                guard api.canWrite, let state = await api.markupState(orderId: orderId) else { return }
                markupState = state
                markup = state.typed
            }
            // What the new markup comes to, a breath after typing stops.
            .task(id: markup) { await previewMarkup() }
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

    /// The markup, with the new total it makes (or why it can't) under it.
    private var markupSection: some View {
        Section {
            LabeledContent(L10n.tr("mac.markup")) {
                HStack(spacing: 4) {
                    TextField("0", text: $markup)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        .font(.khayt(16, relativeTo: .body).monospacedDigit())
                        .accessibilityLabel(L10n.tr("mac.markup"))
                    Text(verbatim: "%").foregroundStyle(KhaytDesign.note)
                }
            }
        } footer: {
            if let markupProblem {
                Text(markupProblem).foregroundStyle(KhaytDesign.late)
            } else if let newTotal {
                Text(verbatim: L10n.tr("mac.js_new_total") + "  " + Money.text(newTotal, currency))
                    .foregroundStyle(KhaytDesign.note)
                    .monospacedDigit()
            }
        }
    }

    /// The markup to send: only when it was changed. One that cannot be read
    /// is sent as typed, so the rule refuses it ('bad_markup') and says why.
    static func markupField(_ typed: String, opened: KhaytAPIClient.MarkupState?) -> JSONValue? {
        guard let opened else { return nil }
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != opened.typed else { return nil }
        if let n = PhoneCalculator.parse(t) {
            return abs(n - opened.percent) < 0.005 ? nil : .number(n)
        }
        return .string(t)
    }

    private func previewMarkup() async {
        guard let field = Self.markupField(markup, opened: markupState) else {
            newTotal = nil; markupProblem = nil; return
        }
        try? await Task.sleep(for: .milliseconds(250))
        if Task.isCancelled { return }
        do {
            let total = try await api.previewJobEdit(orderId: orderId, fields: ["marginPct": field])
            guard !Task.isCancelled else { return }
            newTotal = total; markupProblem = nil
        } catch {
            guard !Task.isCancelled else { return }
            newTotal = nil; markupProblem = error.localizedDescription
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
            Text(L10n.format("quote.revise.note", quote.version, quote.version + 1))
                .foregroundStyle(KhaytDesign.note)
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

    private func save(priceSeenOk: Bool = false) async {
        let typed = SpoolDraft.price(price)
        let day = hasDue ? Self.dayFormat.string(from: due) : nil
        var fields: [String: JSONValue]
        if let quote = revising {
            fields = Self.reviseFields(start: start, quote: quote, due: day, level: level, price: typed,
                                       discount: discount, shipping: shipping,
                                       notes: notes, invoiceNotes: invoiceNotes)
        } else {
            fields = Self.fields(start: start, due: day, level: level, price: typed)
        }
        let newMarkup = Self.markupField(markup, opened: markupState)
        if let newMarkup { fields["marginPct"] = newMarkup }
        guard !fields.isEmpty else { dismiss(); return }
        // A seen price is asked about before a markup moves it.
        if newMarkup != nil, markupState?.askPrice == true, !priceSeenOk {
            askingMarkup = true
            return
        }
        saving = true
        defer { saving = false }
        problem = nil
        markupProblem = nil
        do {
            if revising != nil {
                try await api.reviseQuote(orderId: orderId, fields: fields, priceSeenOk: priceSeenOk)
            } else {
                try await api.editOrder(orderId: orderId, fields: fields, priceSeenOk: priceSeenOk)
            }
            CompanionHaptics.success()
            await onSaved()
            dismiss()
        } catch let refused as BookWriter.JobEditRefused where refused.needsAsking && !priceSeenOk {
            // Seen since the sheet opened (shared from the Mac): ask now.
            askingMarkup = true
        } catch let refused as BookWriter.JobEditRefused where refused.isMarkup {
            markupProblem = refused.localizedDescription
            CompanionHaptics.warning()
        } catch {
            problem = error.localizedDescription
            CompanionHaptics.warning()
        }
    }
}
