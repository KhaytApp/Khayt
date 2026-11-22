import SwiftUI
import KhaytCore

/// The job intake waiting list — enquiries that are not jobs yet.
///
/// The LAN intake form has written customers' requests into `waitingList`
/// since it was built, and no screen on this Mac read them: a request from the
/// shop's Wi-Fi was visible only in the other app. This is the desktop's list
/// (renderer/waiting-list.js) on the same records, through the same rules
/// (`lib/intake-queue.js`): the funnel, the list most urgent first, add and
/// edit, remind on WhatsApp, decline, delete, and promote — which opens the
/// job sheet on it as a quote.
struct IntakeSheet: View {
    let shop: Shop

    @State private var shown: [JSONValue] = []
    @State private var funnel: IntakeFunnel?
    @State private var editing: Editing?
    @State private var reminding: Reminding?
    @State private var problem: String?
    @State private var deleting: String?

    /// An enquiry open in the editor; `id` nil for a new one.
    struct Editing: Identifiable {
        let id = UUID()
        var itemId: String?
        var fields: Fields
    }

    struct Fields: Equatable {
        var project = ""
        var clientId = ""
        var priority = "normal"
        var notes = ""
        var estimatedValue = 0.0
        var reminderDate = ""
        var status = "active"
    }

    struct Reminding: Identifiable {
        let id = UUID()
        let itemId: String
        var phone: String
        var text: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(shop.words.callIt("waiting.title")).font(.headline)
                Spacer()
                Button(shop.words.callIt("waiting.add")) {
                    editing = Editing(itemId: nil, fields: Fields())
                }
                .disabled(!shop.canMoveJobs)
            }
            if let funnel, funnel.total > 0 { funnelRow(funnel) }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if shown.isEmpty {
                Text(shop.words.callIt("waiting.empty")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                // Capped: the list grows with the shop, and a sheet cannot be
                // moved, so past the screen its own buttons would be lost.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shown.indices, id: \.self) { i in
                            row(shown[i])
                            Divider()
                        }
                    }
                }
                .frame(height: 340)
            }
            HStack {
                Spacer()
                Button(shop.words.callIt("common.close")) { shop.showingIntake = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 620)
        .task(id: shop.intakeRows + shop.intakeHistoryRows) { await reload() }
        .shopSheet(item: $editing) { e in
            IntakeEditor(shop: shop, editing: e) { message in
                problem = message
            }
        }
        .shopSheet(item: $reminding) { r in
            IntakeReminder(shop: shop, reminding: r) { message in problem = message }
        }
        .confirmationDialog(shop.words.callIt("common.delete"),
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(shop.words.callIt("common.delete"), role: .destructive) {
                if let id = deleting { Task { await shop.deleteIntake(id) } }
                deleting = nil
            }
            Button(shop.words.callIt("common.cancel"), role: .cancel) { deleting = nil }
        }
    }

    private func reload() async {
        shown = await shop.intakeShown()
        funnel = await shop.intakeFunnel()
    }

    private func funnelRow(_ f: IntakeFunnel) -> some View {
        HStack(spacing: 18) {
            figure(String(f.total), "waiting.funnel_total")
            figure(String(f.active), "waiting.funnel_active")
            figure(String(f.converted) + " · " + Self.pct(f.convertedPct, shop.words.locale), "waiting.funnel_converted")
            figure(String(f.declined), "waiting.funnel_declined")
            figure(Money.text(f.pipeline, shop.currency), "waiting.funnel_pipeline")
        }
    }

    private func figure(_ value: String, _ key: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(shop.words.callIt(key)).font(.caption).foregroundStyle(.secondary)
        }
    }

    static func pct(_ v: Double, _ locale: Locale) -> String {
        (v / 100).formatted(.percent.precision(.fractionLength(0...1)).locale(locale))
    }

    @ViewBuilder private func row(_ raw: JSONValue) -> some View {
        let o = Shop.asObject(raw) ?? [:]
        let id = Shop.plainString(o["id"]) ?? ""
        let project = Shop.plainString(o["project"]).flatMap { $0.isEmpty ? nil : $0 }
            ?? shop.words.callIt("waiting.untitled")
        let status = Shop.plainString(o["status"]) ?? "active"
        let priority = Shop.plainString(o["priority"]) ?? "normal"
        let reminder = Shop.plainString(o["reminderDate"]) ?? ""
        let due = !reminder.isEmpty && reminder <= Shop.localDay() && status != "declined"
        let who = Self.customerName(o, clients: shop.clients)
        let value = Shop.plainNumber(o["estValue"]).flatMap { $0 > 0 ? $0 : nil }
            ?? Shop.plainNumber(o["estimatedValue"]) ?? 0
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle.fill")
                .font(.caption2)
                .foregroundStyle(Self.tint(priority))
                .help(shop.words.callIt("waiting.priority_" + priority))
                .accessibilityLabel(shop.words.callIt("waiting.priority_" + priority))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(project).fontWeight(.medium).lineLimit(1)
                    if status == "reminded" {
                        Text(shop.words.callIt("waiting.status_reminded"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !who.isEmpty {
                    Label(who, systemImage: "person").font(.callout).foregroundStyle(.secondary)
                }
                if let notes = Shop.plainString(o["notes"]), !notes.isEmpty, notes != project {
                    Text(notes).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                if value > 0 {
                    Text(shop.words.callIt("waiting.est_prefix") + " " + Money.text(value, shop.currency))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if due {
                    Text(shop.words.callIt("mac.intake_reminder_due", ["date": .string(reminder)]))
                        .font(.caption).foregroundStyle(Khayt.attention)
                }
            }
            Spacer()
            Button(shop.words.callIt("waiting.promote")) {
                Task { await shop.promoteIntake(id) }
            }
            .disabled(!shop.canMoveJobs)
            Menu {
                Button(shop.words.callIt("waiting.remind") + "\u{2026}") {
                    reminding = Reminding(itemId: id, phone: Self.phone(o, clients: shop.clients),
                                          text: Self.reminderText(project: project, name: who, words: shop.words))
                }
                Button(shop.words.callIt("common.edit") + "\u{2026}") {
                    editing = Editing(itemId: id, fields: Self.fields(o))
                }
                Button(shop.words.callIt("waiting.decline")) { Task { await shop.declineIntake(id) } }
                Divider()
                Button(shop.words.callIt("common.delete") + "\u{2026}", role: .destructive) { deleting = id }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!shop.canMoveJobs)
            .accessibilityLabel(shop.words.callIt("common.more"))
        }
        .padding(.vertical, 3)
    }

    static func tint(_ priority: String) -> Color {
        switch priority {
        case "urgent": .red
        case "high": .orange
        case "low": .secondary.opacity(0.5)
        default: .secondary
        }
    }

    /// Who it is for: the customer it names, else the name the form took.
    static func customerName(_ o: [String: JSONValue], clients: [Client]) -> String {
        if let cid = Shop.plainString(o["clientId"]), !cid.isEmpty,
           let c = clients.first(where: { $0.id == cid }) {
            return c.anyName
        }
        return Shop.plainString(o["clientName"]) ?? ""
    }

    static func phone(_ o: [String: JSONValue], clients: [Client]) -> String {
        if let cid = Shop.plainString(o["clientId"]), !cid.isEmpty,
           let c = clients.first(where: { $0.id == cid }), !c.phone.isEmpty {
            return c.phone
        }
        return Shop.plainString(o["phone"]) ?? ""
    }

    static func reminderText(project: String, name: String, words: Words) -> String {
        name.isEmpty
            ? words.callIt("mac.intake_remind_text_noname", ["project": .string(project)])
            : words.callIt("mac.intake_remind_text", ["name": .string(name), "project": .string(project)])
    }

    static func fields(_ o: [String: JSONValue]) -> Fields {
        Fields(project: Shop.plainString(o["project"]) ?? "",
               clientId: Shop.plainString(o["clientId"]) ?? "",
               priority: Shop.plainString(o["priority"]) ?? "normal",
               notes: Shop.plainString(o["notes"]) ?? "",
               estimatedValue: Shop.plainNumber(o["estimatedValue"]) ?? Shop.plainNumber(o["estValue"]) ?? 0,
               reminderDate: Shop.plainString(o["reminderDate"]) ?? "",
               status: Shop.plainString(o["status"]) ?? "active")
    }
}

/// Add or edit one enquiry — the desktop's waiting-list editor, field for field.
struct IntakeEditor: View {
    let shop: Shop
    let editing: IntakeSheet.Editing
    let said: (String?) -> Void

    @State private var f = IntakeSheet.Fields()
    @State private var hasReminder = false
    @State private var reminder = Date()
    @State private var problem: String?
    @State private var started = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(shop.words.callIt(editing.itemId == nil ? "waiting.add" : "waiting.edit")).font(.headline)
            Form {
                TextField(shop.words.callIt("waiting.project"), text: $f.project,
                          prompt: Text(shop.words.callIt("waiting.project_ph")))
                Picker(shop.words.callIt("waiting.client"), selection: $f.clientId) {
                    Text(shop.words.callIt("waiting.no_client")).tag("")
                    ForEach(shop.clients, id: \.id) { c in Text(c.anyName).tag(c.id) }
                    if !f.clientId.isEmpty, !shop.clients.contains(where: { $0.id == f.clientId }) {
                        Text(f.clientId).tag(f.clientId)
                    }
                }
                Picker(shop.words.callIt("waiting.priority_label"), selection: $f.priority) {
                    ForEach(["urgent", "high", "normal", "low"], id: \.self) { p in
                        Text(shop.words.callIt("waiting.priority_" + p)).tag(p)
                    }
                }
                TextField(shop.words.callIt("waiting.notes"), text: $f.notes,
                          prompt: Text(shop.words.callIt("waiting.notes_ph")), axis: .vertical)
                    .lineLimit(2...5)
                TextField(shop.words.callIt("waiting.est_value"), value: $f.estimatedValue,
                          format: .number.locale(Money.digits).precision(.fractionLength(0...2)))
                Toggle(shop.words.callIt("waiting.reminder_date"), isOn: $hasReminder)
                if hasReminder {
                    DatePicker("", selection: $reminder, displayedComponents: .date).labelsHidden()
                }
                Picker(shop.words.callIt("waiting.status"), selection: $f.status) {
                    Text(shop.words.callIt("waiting.funnel_active")).tag("active")
                    Text(shop.words.callIt("waiting.status_reminded")).tag("reminded")
                    Text(shop.words.callIt("waiting.funnel_declined")).tag("declined")
                }
            }
            .formStyle(.grouped)
            if let problem {
                Text(problem).font(.callout).foregroundStyle(Khayt.attention)
            }
            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("common.save"), action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
        .onAppear {
            guard !started else { return }
            started = true
            f = editing.fields
            if let day = Order.day(f.reminderDate) { hasReminder = true; reminder = day }
        }
    }

    private func save() {
        var out = f
        out.reminderDate = hasReminder ? Shop.localDay(reminder) : ""
        let fields: [String: JSONValue] = [
            "project": .string(out.project), "clientId": .string(out.clientId),
            "priority": .string(out.priority), "notes": .string(out.notes),
            "estimatedValue": .number(out.estimatedValue), "reminderDate": .string(out.reminderDate),
            "status": .string(out.status),
        ]
        let id = editing.itemId
        Task {
            if let refused = await shop.saveIntake(id, fields: fields) { problem = refused; return }
            said(nil)
            dismiss()
        }
    }
}

/// Remind the customer on WhatsApp, with the desktop's message typed in.
struct IntakeReminder: View {
    let shop: Shop
    let reminding: IntakeSheet.Reminding
    let said: (String?) -> Void

    @State private var phone = ""
    @State private var text = ""
    @State private var problem: String?
    @State private var started = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(shop.words.callIt("waiting.remind_title")).font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text(shop.words.callIt("waiting.remind_msg")).foregroundStyle(.secondary)
                TextEditor(text: $text).frame(minHeight: 80)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(shop.words.callIt("waiting.remind_phone")).foregroundStyle(.secondary)
                TextField("+966501234567", text: $phone).textFieldStyle(.roundedBorder)
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(Khayt.attention)
            }
            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("mac.send_on_whatsapp")) {
                    let id = reminding.itemId, to = phone, message = text
                    Task {
                        if let refused = await shop.remindIntake(id, phone: to, text: message) {
                            problem = refused; return
                        }
                        said(nil)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear {
            guard !started else { return }
            started = true
            phone = reminding.phone
            text = reminding.text
        }
    }
}
