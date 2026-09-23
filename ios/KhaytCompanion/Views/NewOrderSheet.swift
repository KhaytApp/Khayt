import SwiftUI

/// Create a quick order or quote and send it to the desktop queue.
struct NewOrderSheet: View {
    let machines: [MachineInfo]
    var onCreated: () -> Void = {}

    @EnvironmentObject private var api: KhaytAPIClient
    @Environment(\.dismiss) private var dismiss

    @State private var draft = NewOrderDraft()
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var currency: String?

    private var canSave: Bool {
        !draft.project.trimmingCharacters(in: .whitespaces).isEmpty && !isSaving
    }

    private var selectedMachineName: String {
        machines.first { $0.id == draft.machineId }?.name ?? L10n.tr("order.new.unassigned")
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker(L10n.tr("order.new.type"), selection: $draft.isQuote) {
                    Text(L10n.tr("order.new.order")).tag(false)
                    Text(L10n.tr("order.new.quote")).tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))

                Section(L10n.tr("order.new.details")) {
                    TextField(L10n.tr("order.new.project"), text: $draft.project)
                    TextField(L10n.tr("order.new.client"), text: $draft.client)
                    TextField(L10n.tr("order.new.material"), text: $draft.material)
                    // The shop's own currency when the book says it — this
                    // said "SAR" to every shop, wherever it was.
                    TextField(currency.map { String(format: L10n.tr("order.new.price_in"), Money.mark($0)) }
                              ?? L10n.tr("order.new.price"),
                              text: $draft.price)
                        .keyboardType(.decimalPad)
                }

                Section(L10n.tr("order.new.schedule")) {
                    Toggle(L10n.tr("order.new.set_due"), isOn: $hasDueDate)
                    if hasDueDate {
                        DatePicker(L10n.tr("order.new.due"), selection: $dueDate, displayedComponents: .date)
                    }
                    if !machines.isEmpty {
                        Menu {
                            Button { draft.machineId = nil } label: {
                                Label(L10n.tr("order.new.unassigned"), systemImage: draft.machineId == nil ? "checkmark" : "circle")
                            }
                            ForEach(machines) { m in
                                Button { draft.machineId = m.id } label: {
                                    Label(m.name ?? m.id, systemImage: draft.machineId == m.id ? "checkmark" : "printer")
                                }
                            }
                        } label: {
                            HStack {
                                Text(L10n.tr("order.new.machine")).foregroundStyle(KhaytDesign.text)
                                Spacer()
                                Text(selectedMachineName).foregroundStyle(KhaytDesign.textDim)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption).foregroundStyle(KhaytDesign.textMuted)
                            }
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).font(.caption).foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text(L10n.tr(draft.isQuote ? "order.new.create_quote" : "order.new.add"))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(!canSave)
                }
            }
            .navigationTitle(L10n.tr(draft.isQuote ? "order.new.title_quote" : "order.new.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.cancel")) { dismiss() }
                }
            }
            .task { currency = await api.shopCurrency() }
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        if hasDueDate {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            fmt.locale = Locale(identifier: "en_US_POSIX")
            draft.dueDate = fmt.string(from: dueDate)
        } else {
            draft.dueDate = ""
        }
        do {
            try await api.createOrder(draft)
            CompanionHaptics.success()
            onCreated()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            CompanionHaptics.warning()
        }
    }
}
