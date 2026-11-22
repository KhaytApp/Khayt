import SwiftUI

/// Create a quick order or quote and send it to the desktop queue.
struct NewOrderSheet: View {
    let machines: [MachineInfo]
    var onCreated: () -> Void = {}
    /// Where the form starts — a quote priced from a model file, say.
    var initial: NewOrderDraft? = nil

    @EnvironmentObject private var api: KhaytAPIClient
    @Environment(\.dismiss) private var dismiss

    @State private var draft = NewOrderDraft()
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var currency: String?
    /// The shop's saved customers, to pick from as the name is typed.
    @State private var clients: [Client] = []

    /// Saved customers whose name starts a word with what was typed — shown
    /// until one is picked. A few at most: this is a hint, not a directory.
    private var clientMatches: [Client] {
        let typed = draft.client.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard draft.clientId == nil, !typed.isEmpty else { return [] }
        return Array(clients.filter { c in
            [c.displayName, c.nameEn ?? "", c.nameAr ?? ""].contains { name in
                let n = name.lowercased()
                return n.hasPrefix(typed) || n.contains(" " + typed)
            }
        }.prefix(4))
    }

    private var canSave: Bool {
        !draft.project.trimmingCharacters(in: .whitespaces).isEmpty && !isSaving
    }

    private var selectedMachineName: String {
        machines.first { $0.id == draft.machineId }?.name ?? L10n.tr("order.new.unassigned")
    }

    @EnvironmentObject private var health: ConnectionHealth

    /// Where this write goes, said before it is made. The design refuses a
    /// write with the Mac away; the phone no longer has to — with its book it
    /// saves here and sends the change on. Only a bookless phone with the Mac
    /// out of reach genuinely cannot.
    private var blocked: Bool { !api.holdsBook && !health.macInReach }
    private var writeNote: String {
        if api.holdsBook { return L10n.tr(health.macInReach ? "order.new.note.sent" : "order.new.note.later") }
        return L10n.tr(health.macInReach ? "order.new.note.live" : "order.new.note.blocked")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    typePicker
                    VStack(spacing: 0) {
                        field(L10n.tr("order.new.client")) {
                            HStack(spacing: 8) {
                                TextField("", text: $draft.client, prompt: prompt("Acme Robotics"))
                                    .onChange(of: draft.client) { _, typed in
                                        // Typing over a picked customer unpicks it.
                                        if let id = draft.clientId,
                                           clients.first(where: { $0.id == id })?.displayName != typed {
                                            draft.clientId = nil
                                        }
                                    }
                                if draft.clientId != nil {
                                    Image(systemName: "person.crop.circle.badge.checkmark")
                                        .foregroundStyle(KhaytDesign.done)
                                        .accessibilityLabel(L10n.tr("order.new.client.saved"))
                                }
                            }
                        }
                        ForEach(clientMatches) { c in
                            Button {
                                draft.client = c.displayName
                                draft.clientId = c.id
                            } label: {
                                HStack {
                                    Image(systemName: "person.crop.circle").foregroundStyle(KhaytDesign.note)
                                    Text(c.displayName).foregroundStyle(KhaytDesign.ink)
                                    if let other = c.secondaryName {
                                        Text(other).foregroundStyle(KhaytDesign.note)
                                    }
                                    Spacer()
                                }
                                .font(.khayt(15, relativeTo: .body))
                                .padding(.horizontal, 16).padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(L10n.tr("order.new.client.pick"))
                            .overlay(alignment: .bottom) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
                        }
                        field(L10n.tr("order.new.project")) {
                            TextField("", text: $draft.project, prompt: prompt("Falcon hood"))
                        }
                        field(L10n.tr("order.new.material")) {
                            TextField("", text: $draft.material, prompt: prompt("PLA · Ink"))
                        }
                        // The shop's own currency when the book says it.
                        field(currency.map { L10n.format("order.new.price_in", Money.mark($0)) }
                              ?? L10n.tr("order.new.price")) {
                            TextField("", text: $draft.price, prompt: prompt("0"))
                                .keyboardType(.decimalPad)
                        }
                        dueRow
                        if !machines.isEmpty { machineRow }
                    }
                    .card()

                    Text(errorMessage ?? writeNote)
                        .font(.khayt(12.5, relativeTo: .footnote))
                        .foregroundStyle(errorMessage != nil ? KhaytDesign.late
                                         : (blocked ? KhaytDesign.attention : KhaytDesign.note))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2)
                        .padding(.top, 12)

                    Button { Task { await save() } } label: {
                        Group {
                            if isSaving {
                                ProgressView().tint(KhaytDesign.onBrand)
                            } else {
                                Text(L10n.tr(draft.isQuote ? "order.new.create_quote" : "order.new.add"))
                            }
                        }
                        .font(.khayt(17, .semibold, relativeTo: .headline))
                        .foregroundStyle(KhaytDesign.onBrand)
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .background(KhaytDesign.brand.opacity(canSave && !blocked ? 1 : 0.45),
                                    in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSave || blocked)
                    .padding(.top, 16)
                }
                .padding(16)
            }
            .editsShop()
            .scrollDismissesKeyboard(.interactively)
            .background(KhaytDesign.ground.ignoresSafeArea())
            .onAppear { if let initial, draft.project.isEmpty { draft = initial } }
            .navigationTitle(L10n.tr(draft.isQuote ? "order.new.title_quote" : "order.new.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.cancel")) { dismiss() }
                }
            }
            .task {
                currency = await api.shopCurrency()
                clients = (try? await api.fetchClients()) ?? []
                // A quote that came in with a name: link it when it names one
                // saved customer exactly.
                if draft.clientId == nil {
                    let typed = draft.client.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let exact = clients.filter { $0.displayName.lowercased() == typed }
                    if !typed.isEmpty, exact.count == 1 { draft.clientId = exact[0].id }
                }
            }
        }
    }

    private var typePicker: some View {
        HStack(spacing: 3) {
            ForEach([false, true], id: \.self) { quote in
                let on = draft.isQuote == quote
                Button { draft.isQuote = quote } label: {
                    Text(L10n.tr(quote ? "order.new.quote" : "order.new.order"))
                        .font(.khayt(13.5, .semibold, relativeTo: .subheadline))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(on ? KhaytDesign.ink : KhaytDesign.note)
                        .background(on ? KhaytDesign.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(KhaytDesign.sunk, in: RoundedRectangle(cornerRadius: 10))
        .padding(.bottom, 14)
    }

    /// The design's field: a small label above a large value, one per row.
    private func field<V: View>(_ label: String, @ViewBuilder input: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label.uppercased())
                .font(.khayt(10, .bold, relativeTo: .caption2))
                .khaytTracking(1)
                .foregroundStyle(KhaytDesign.note)
            input()
                .font(.khayt(16, .medium, relativeTo: .body))
                .foregroundStyle(KhaytDesign.ink)
                .frame(minHeight: 32)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
    }

    /// A placeholder, in the design's dimmer ink. An example, not an
    /// instruction — the label above already says what goes here.
    private func prompt(_ example: String) -> Text {
        Text(verbatim: example).foregroundStyle(KhaytDesign.note.opacity(0.6))
    }

    private var dueRow: some View {
        field(L10n.tr("order.new.due")) {
            HStack {
                if hasDueDate {
                    DatePicker("", selection: $dueDate, displayedComponents: .date)
                        .labelsHidden()
                    Spacer()
                    Button { hasDueDate = false } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(KhaytDesign.note)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr("common.clear"))
                } else {
                    Button { hasDueDate = true } label: {
                        Text(L10n.tr("order.new.set_due")).foregroundStyle(KhaytDesign.brand)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
        }
    }

    private var machineRow: some View {
        field(L10n.tr("order.new.machine")) {
            Menu {
                Button { draft.machineId = nil } label: {
                    Label(L10n.tr("order.new.unassigned"), systemImage: draft.machineId == nil ? "checkmark" : "circle")
                }
                ForEach(machines.filter(\.isAssignable)) { m in
                    Button { draft.machineId = m.id } label: {
                        Label(m.name ?? m.id, systemImage: draft.machineId == m.id ? "checkmark" : "printer")
                    }
                }
            } label: {
                HStack {
                    Text(selectedMachineName).foregroundStyle(KhaytDesign.ink)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption).foregroundStyle(KhaytDesign.note)
                }
            }
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
