import SwiftUI
import KhaytCore

/// Change a job's due date, priority or price — the Mac's Edit sheet's
/// fields, through the same rule (`lib/order-edit.js`): only what was
/// changed is sent, the edit is written in the job's history, and a typed
/// price carries the money with it.
struct EditOrderSheet: View {
    let orderId: String
    let start: KhaytAPIClient.OrderEditState
    var currency: String?
    var onSaved: () async -> Void = {}

    @EnvironmentObject private var api: KhaytAPIClient
    @Environment(\.dismiss) private var dismiss
    @State private var hasDue = false
    @State private var due = Date()
    @State private var level = "normal"
    @State private var price = ""
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
                } footer: {
                    Text(problem ?? L10n.tr("edit.price.note"))
                        .foregroundStyle(problem == nil ? KhaytDesign.note : KhaytDesign.late)
                }
            }
            .navigationTitle(L10n.tr("edit.title"))
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
            }
        }
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

    private func save() async {
        let typed = SpoolDraft.price(price)
        let fields = Self.fields(start: start, due: hasDue ? Self.dayFormat.string(from: due) : nil,
                                 level: level, price: typed)
        guard !fields.isEmpty else { dismiss(); return }
        saving = true
        defer { saving = false }
        do {
            try await api.editOrder(orderId: orderId, fields: fields)
            CompanionHaptics.success()
            await onSaved()
            dismiss()
        } catch {
            problem = error.localizedDescription
            CompanionHaptics.warning()
        }
    }
}
