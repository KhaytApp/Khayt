import SwiftUI
import KhaytCore

/// The whole order editor — the desktop's "Edit order" — beside the quick
/// Edit Job sheet's three fields.
///
/// What it writes is `lib/order-edit.js applyDetails`, the rule the desktop's
/// editor runs: notes, the internal and invoice notes, tags, courier and
/// tracking number, the delivery address, who is on it, and the three terms
/// that re-price the job — discount, shipping and extra charges. Only what the
/// shop CHANGED is handed over (`fields`), so opening and saving a job here
/// never writes back a stale copy of a field somebody else changed meanwhile.
///
/// The due date, priority and a typed total stay on Edit Job, which is where
/// the shop floor reaches for them; photos, files and the payment plan have
/// screens of their own.
struct OrderDetailsSheet: View {
    static let width: CGFloat = 560

    let shop: Shop
    let subject: Shop.PendingHold

    /// The editor's fields, as it opened them and as they stand.
    struct Form: Equatable {
        var notes = ""
        var internalNotes = ""
        var invoiceNotes = ""
        var tags = ""
        var courierName = ""
        var trackingNumber = ""
        var deliveryAddress = ""
        var operatorId = ""
        /// Who the job is for — "" is nobody. Saved by its own rule
        /// (`lib/order-edit.js changeCustomer`), not by `applyDetails`.
        var clientId = ""
        var discountPct = 0.0
        var shippingCost = 0.0
        var lines: [Line] = []
        /// The shop's own order fields (`settings.customFields`), by field id —
        /// `order.customData`.
        var custom: [String: String] = [:]
    }

    /// One extra charge. `raw` keeps every field the line carries — its id, a
    /// marketplace's tag — so saving it changes only the label and amount.
    struct Line: Identifiable, Equatable {
        let id = UUID()
        var raw: [String: JSONValue] = [:]
        var label = ""
        var amount = 0.0
    }

    @State private var form = Form()
    @State private var opened = Form()
    @State private var started = false
    @State private var saving = false
    /// Why the customer cannot be changed (`zatca` | `voided` | `credited` |
    /// `paid`), or nil. Read once when the sheet opens.
    @State private var customerLock: String?

    private var job: Order? { shop.orders.first { $0.id == subject.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(shop.words.callIt("oe.title")).font(.headline)
            Text(subject.project).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    people
                    Divider()
                    money
                    Divider()
                    delivery
                    Divider()
                    notes
                    if !customFields.isEmpty {
                        Divider()
                        custom
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 560)
            HStack {
                Spacer()
                SaveProblem(text: shop.moveProblem)
                Button(shop.words.callIt("common.cancel")) { shop.clearQuestion() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("common.save"), action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
        }
        .padding(18)
        .frame(width: Self.width)
        .onAppear {
            guard !started else { return }
            started = true
            let was = Self.opening(shop.orderFields(subject.id))
            opened = was
            form = was
            let id = subject.id
            Task { customerLock = await shop.customerLock(id) }
        }
    }

    // MARK: - Sections

    @ViewBuilder private var people: some View {
        customer
        let ops = Self.operatorChoices(shop.operatorRows, current: form.operatorId)
        if !ops.isEmpty {
            LabeledContent(shop.words.callIt("op.assigned")) {
                Picker("", selection: $form.operatorId) {
                    Text(shop.words.callIt("op.unassigned")).tag("")
                    ForEach(ops, id: \.id) { op in Text(op.name).tag(op.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
            }
        }
        LabeledContent(shop.words.callIt("tag.label")) {
            VStack(alignment: .leading, spacing: 2) {
                TextField(shop.words.callIt("tag.ph"), text: $form.tags).textFieldStyle(.roundedBorder)
                Text(shop.words.callIt("tag.hint")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The job's customer. A job with no customer can always be given one;
    /// otherwise the picker is shut once the invoice has left the shop
    /// (Turki's rule, Nov 10), and says which way it left.
    @ViewBuilder private var customer: some View {
        let locked = Self.customerShut(lock: customerLock, openedWith: opened.clientId)
        LabeledContent(shop.words.callIt("mac.customer")) {
            VStack(alignment: .leading, spacing: 2) {
                Picker("", selection: $form.clientId) {
                    Text(shop.words.callIt("mac.job_customer_none")).tag("")
                    ForEach(Self.customerChoices(shop.clients, current: form.clientId), id: \.id) { c in
                        Text(c.name).tag(c.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                .disabled(locked)
                if locked, let lock = customerLock {
                    Text(Shop.customerLockWords(shop.words)[lock] ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if form.clientId != opened.clientId,
                          Self.currencyDiffers(job: job?.currency ?? "",
                                               was: shop.clients.first { $0.id == opened.clientId }?.currency,
                                               shop: shop.currency,
                                               client: shop.clients.first { $0.id == form.clientId }?.currency) {
                    Text(shop.words.callIt("mac.job_customer_currency"))
                        .font(.caption).foregroundStyle(Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var money: some View {
        let code = (job?.currency.isEmpty ?? true) ? shop.currency : (job?.currency ?? shop.currency)
        HStack(spacing: 16) {
            LabeledContent(shop.words.callIt("oe.discount_pct") + " (%)") {
                TextField("", value: $form.discountPct, format: .number.locale(Money.digits).precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder).frame(width: 70).monospacedDigit()
            }
            LabeledContent(shop.words.callIt("oe.shipping") + " (\(code))") {
                TextField("", value: $form.shippingCost, format: .number.locale(Money.digits).precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder).frame(width: 90).monospacedDigit()
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(shop.words.callIt("calc.extra_lines")).foregroundStyle(.secondary)
                Spacer()
                // The shop's post-process presets, each added as a line in
                // one click — the desktop's preset picker.
                let presets = shop.settingsList(.postProcessPresets)
                if !presets.isEmpty {
                    Menu(shop.words.callIt("set.post_process_presets")) {
                        ForEach(Array(presets.enumerated()), id: \.offset) { _, p in
                            let name = Shop.plainString(p["name"]) ?? ""
                            let amount = Shop.plainNumber(p["amount"]) ?? 0
                            let priced: String = Money.text(amount, shop.currency)
                            let title: String = "\(name) (+\(priced))"
                            Button(title) {
                                form.lines.append(Line(label: name, amount: amount))
                            }
                        }
                    }
                    .fixedSize()
                }
                Button(shop.words.callIt("calc.add_extra_line")) { form.lines.append(Line()) }
                    .buttonStyle(.link)
            }
            ForEach($form.lines.byID) { $line in
                HStack(spacing: 8) {
                    TextField(shop.words.callIt("calc.extra_label_ph"), text: $line.label)
                        .textFieldStyle(.roundedBorder)
                    TextField("", value: $line.amount, format: .number.locale(Money.digits).precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder).frame(width: 90).monospacedDigit()
                    Button {
                        form.lines.removeAll { $0.id == line.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(shop.words.callIt("common.delete"))
                    .accessibilityLabel(shop.words.callIt("common.delete"))
                }
            }
        }
    }

    @ViewBuilder private var delivery: some View {
        HStack(spacing: 12) {
            LabeledContent(shop.words.callIt("oe.courier")) {
                TextField("", text: $form.courierName).textFieldStyle(.roundedBorder)
            }
            LabeledContent(shop.words.callIt("oe.tracking_number")) {
                TextField("", text: $form.trackingNumber).textFieldStyle(.roundedBorder)
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            Text(shop.words.callIt("oe.delivery_address")).foregroundStyle(.secondary)
            let saved = Self.savedAddresses(clientRow(form.clientId.isEmpty ? nil : form.clientId))
            if !saved.isEmpty {
                Menu(shop.words.callIt("oe.select_address")) {
                    ForEach(saved, id: \.address) { a in
                        Button(a.label) { form.deliveryAddress = a.address }
                    }
                }
                .fixedSize()
            }
            TextEditor(text: $form.deliveryAddress)
                .font(.body).frame(minHeight: 44, maxHeight: 70)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
        }
    }

    @ViewBuilder private var notes: some View {
        note("oe.notes", $form.notes, hint: nil)
        note("oe.internal_notes", $form.internalNotes, hint: "oe.internal_notes_ph")
        note("oe.invoice_notes", $form.invoiceNotes, hint: "oe.invoice_notes_hint")
    }

    /// `settings.customFields`, as `{ id, label }`.
    private var customFields: [(id: String, label: String)] {
        shop.settingsList(.customFields).compactMap { f in
            guard let id = Shop.plainString(f["id"]), !id.isEmpty else { return nil }
            return (id, Shop.plainString(f["label"]) ?? id)
        }
    }

    @ViewBuilder private var custom: some View {
        Text(shop.words.callIt("set.custom_fields_title")).foregroundStyle(.secondary)
        ForEach(customFields, id: \.id) { f in
            LabeledContent(f.label) {
                TextField(f.label, text: Binding(get: { form.custom[f.id] ?? "" },
                                                 set: { form.custom[f.id] = $0 }))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func note(_ key: String, _ text: Binding<String>, hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(shop.words.callIt(key)).foregroundStyle(.secondary)
            if let hint {
                Text(shop.words.callIt(hint)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextEditor(text: text)
                .font(.body).frame(minHeight: 44, maxHeight: 80)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
        }
    }

    private func clientRow(_ id: String?) -> [String: JSONValue]? {
        guard let id else { return nil }
        return shop.clientRows.first { Shop.recordId($0) == id }.flatMap(Shop.asObject)
    }

    // MARK: - Reading and writing

    /// The form as a record opens it.
    static func opening(_ o: [String: JSONValue]) -> Form {
        func text(_ k: String) -> String { Shop.plainString(o[k]) ?? "" }
        var tags: [String] = []
        if case .array(let list)? = o["tags"] { tags = list.compactMap(Shop.plainString) }
        var lines: [Line] = []
        if case .array(let list)? = o["extraLines"] {
            for case .object(let l) in list {
                lines.append(Line(raw: l, label: Shop.plainString(l["label"]) ?? "",
                                  amount: Shop.plainNumber(l["amount"]) ?? 0))
            }
        }
        var custom: [String: String] = [:]
        if case .object(let cd)? = o["customData"] {
            for (k, v) in cd { if let s = Shop.plainString(v) { custom[k] = s } }
        }
        return Form(notes: text("notes"), internalNotes: text("internalNotes"),
                    invoiceNotes: text("invoiceNotes"), tags: tags.joined(separator: ", "),
                    courierName: text("courierName"), trackingNumber: text("trackingNumber"),
                    deliveryAddress: text("deliveryAddress"), operatorId: text("operatorId"),
                    clientId: text("clientId"),
                    discountPct: Shop.plainNumber(o["discountPct"]) ?? 0,
                    shippingCost: Shop.plainNumber(o["shippingCost"]) ?? 0, lines: lines,
                    custom: custom)
    }

    /// What the shared rule is handed: ONLY what the shop changed.
    static func fields(opened: Form, now form: Form) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        let texts: [(String, KeyPath<Form, String>)] = [
            ("notes", \.notes), ("internalNotes", \.internalNotes), ("invoiceNotes", \.invoiceNotes),
            ("courierName", \.courierName), ("trackingNumber", \.trackingNumber),
            ("deliveryAddress", \.deliveryAddress), ("operatorId", \.operatorId),
        ]
        for (key, path) in texts where form[keyPath: path] != opened[keyPath: path] {
            out[key] = .string(key == "notes" ? form[keyPath: path]
                               : form[keyPath: path].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if form.tags != opened.tags { out["tags"] = .string(form.tags) }
        if form.discountPct != opened.discountPct { out["discountPct"] = .number(form.discountPct) }
        if form.shippingCost != opened.shippingCost { out["shippingCost"] = .number(form.shippingCost) }
        // Only the custom fields the shop typed in: `applyDetails` merges them
        // one key at a time, so a value for a field this sheet does not show
        // stays in the book.
        var custom: [String: JSONValue] = [:]
        for (k, v) in form.custom where v != (opened.custom[k] ?? "") { custom[k] = .string(v) }
        if !custom.isEmpty { out["customData"] = .object(custom) }
        if form.lines != opened.lines {
            out["extraLines"] = .array(form.lines.map { line in
                var raw = line.raw
                raw["label"] = .string(line.label)
                // A typed figure replaces a percentage the line was logged
                // with, as the desktop's editor does — keeping both left the
                // invoice showing one number and a re-quote computing another.
                if Shop.plainNumber(raw["amount"]) != line.amount { raw["pct"] = nil }
                raw["amount"] = .number(line.amount)
                if raw["id"] == nil { raw["id"] = .string(Shop.uid("EL")) }
                return .object(raw)
            })
        }
        return out
    }

    /// The people offered: the active staff, and the job's own operator when
    /// they are no longer active — without that, saving for any other reason
    /// would clear who did the job (the desktop's editor learnt this).
    static func operatorChoices(_ rows: [JSONValue], current: String) -> [(id: String, name: String)] {
        var out: [(id: String, name: String)] = []
        for case .object(let o) in rows {
            guard let id = Shop.plainString(o["id"]) else { continue }
            let active: Bool = { if case .bool(false)? = o["active"] { return false }; return true }()
            if active || id == current { out.append((id, Shop.plainString(o["name"]) ?? id)) }
        }
        return out
    }

    /// Whether the customer picker is shut: locked, and the job HAS a
    /// customer — one with none can always be given one.
    static func customerShut(lock: String?, openedWith clientId: String) -> Bool {
        lock != nil && !clientId.isEmpty
    }

    /// The customers offered, by name, with the job's own kept even if it is
    /// no longer in the book (so saving for another reason cannot drop it).
    static func customerChoices(_ clients: [Client], current: String) -> [(id: String, name: String)] {
        var out = clients.map { (id: $0.id, name: $0.anyName) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !current.isEmpty, !out.contains(where: { $0.id == current }) { out.insert((current, current), at: 0) }
        return out
    }

    /// The new customer bills in another currency than the job is priced in.
    /// Nothing is converted — a change of customer is not a new quote — so
    /// the shop is told before it saves.
    ///
    /// The SAME expression as the write's (`lib/order-edit.js changeCustomer`):
    /// a job that carries no currency is read in the currency of the customer
    /// it has NOW (`was`), and only with neither in the shop's. Reading it
    /// straight in the shop's warned on EUR customer → EUR customer and said
    /// nothing on EUR → SAR. `JobCustomerPickerTests` holds it to the lib.
    static func currencyDiffers(job: String, was: String?, shop: String, client: String?) -> Bool {
        guard let client else { return false }
        let shop = shop.isEmpty ? "SAR" : shop
        let j = !job.isEmpty ? job : (was.map { $0.isEmpty ? shop : $0 } ?? shop)
        let c = client.isEmpty ? shop : client
        return j != c
    }

    /// The customer to hand the save: `.none` when unchanged.
    static func customerChange(opened: Form, now form: Form) -> String?? {
        guard form.clientId != opened.clientId else { return .none }
        return .some(form.clientId.isEmpty ? nil : form.clientId)
    }

    /// The customer's saved addresses (`addresses[]` of `{ label, address }`).
    static func savedAddresses(_ client: [String: JSONValue]?) -> [(label: String, address: String)] {
        guard case .array(let list)? = client?["addresses"] else { return [] }
        return list.compactMap { entry in
            guard case .object(let a) = entry, let address = Shop.plainString(a["address"]), !address.isEmpty else { return nil }
            let label = Shop.plainString(a["label"]) ?? ""
            return (label.isEmpty ? address : label, address)
        }
    }

    private func commit() {
        let id = subject.id
        let fields = Self.fields(opened: opened, now: form)
        let customer = Self.customerChange(opened: opened, now: form)
        // The sheet closes when the change is IN the book. It closed first, so
        // a refusal (another computer holds the book, the staff lock, a
        // customer locked since the sheet opened) lost everything typed and
        // said so only behind it.
        guard !saving else { return }
        saving = true
        shop.moveProblem = nil
        Task {
            let wrote = await shop.editOrderDetails(id, fields: fields, customer: customer)
            saving = false
            if wrote { shop.clearQuestion() }
        }
    }
}
