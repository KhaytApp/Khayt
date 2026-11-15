import SwiftUI
import KhaytCore

/// The job sheet, Edit mode (S1 B3b, Figma Qqxg4imtKVgC3TfNGcRGOk 90:768,
/// "Create and edit · one sheet").
///
/// One sheet for a job: who it is for and when it is due, what is in it, and
/// what it costs — **Job · Parts · Price**, with the total pinned beside
/// Save. It replaces Edit Job (three fields) as what "Edit Job" opens;
/// courier, addresses and the rest stay in Order details… for now, one link
/// away (Turki, Q6).
///
/// ONE SAVE. Everything the shop changed goes through the shared rule in a
/// single write (`Shop.saveJob` → `lib/order-edit.js applyJobEdit`): one
/// undo, and a refusal anywhere leaves the job as it was.
///
/// WHAT IS ON SCREEN IS WHAT SAVE DOES. The pinned total, and the line that
/// says why a save would be refused, are the rule's own answer to the
/// sheet's current contents (`Shop.previewJobSave`), asked again whenever
/// they change — not a second sum kept in Swift.
struct JobSheet: View {
    static let width: CGFloat = 580

    let shop: Shop
    let subject: Shop.PendingHold

    /// One part as the sheet edits it.
    struct PartDraft: Identifiable, Equatable {
        let id: String
        /// The stored part this is; nil for one added here.
        var storedId: String?
        /// Its place among the job's parts as it opened: how a part the book
        /// holds with no id is found again (`Shop.rawPart(_:partId:at:)`).
        var storedIndex: Int?
        var name = ""
        var grams = ""
        var hours = ""
        var qty = 1
        var spoolId: String?
        /// As it opened, for "only what changed" (`EditPartSheet.Opened`).
        var opened: EditPartSheet.Opened?
        /// Already with the customer: fixed.
        var delivered = false

        var fields: EditPartSheet.Opened {
            EditPartSheet.Opened(name: name, grams: grams, hours: hours, qty: qty, spoolId: spoolId)
        }
        /// A figure the cost is made from moved, or the part is new.
        var costMoved: Bool {
            guard let opened else { return true }
            return opened.grams != grams || opened.hours != hours || opened.qty != qty || opened.spoolId != spoolId
        }
    }

    /// Everything but the parts, as one value: what opened, and what is typed.
    struct Form: Equatable {
        var name = ""
        var customerId = ""
        var hasDueDate = false
        var dueDate = Date()
        var priority = "normal"
        var notes = ""
        var nonBusiness = false
        var discount = ""
        /// A typed total. Empty is "leave the price to the arithmetic".
        var price = ""
    }

    @State private var form = Form()
    @State private var opened = Form()
    @State private var parts: [PartDraft] = []
    @State private var openedParts: [PartDraft] = []
    @State private var started = false
    @State private var saving = false
    @State private var lock: KhaytEngine.PartsLock?
    @State private var customerLock: String?
    /// nil = not read yet; .some(nil) = cannot be said (a typed price).
    @State private var margin: Double??
    /// The rule's answer to the sheet as it stands.
    @State private var newTotal: String?
    @State private var refusal: String?
    @State private var askingPrice = false

    private var job: Order? { shop.orders.first { $0.id == subject.id } }
    private var currency: String { (job?.currency.isEmpty == false ? job?.currency : nil) ?? shop.currency }
    private var partsChanged: Bool { parts != openedParts }
    private var partsLocked: Bool { lock?.edit == false }
    private var nameOnly: Bool { lock?.nameOnly == true }
    private var changed: Bool { form != opened || partsChanged }

    var body: some View {
        SheetFrame(width: Self.width) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shop.words.callIt("mac.edit_job")).font(.headline)
                Text([job?.reference, subject.project].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            section("mac.job") { jobFields }
            section("mac.parts") { partRows }
            section("mac.price") { priceFields }
        } footer: {
            footer
        }
        .onAppear(perform: open)
        .task(id: Signature(form: form, parts: parts)) { await preview() }
        .confirmationDialog(shop.words.callIt("mac.parts_price_q"), isPresented: $askingPrice) {
            Button(shop.words.callIt("mac.parts_keep_price")) { commit(keepPrice: true) }
            Button(shop.words.callIt("mac.parts_use_new_price")) { commit(keepPrice: false) }
            Button(shop.words.callIt("common.cancel"), role: .cancel) {}
        }
    }

    private struct Signature: Equatable { let form: Form; let parts: [PartDraft] }

    // MARK: - Job

    private var jobFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 9) {
            GridRow {
                label("common.name")
                TextField(shop.words.callIt("mac.what_is_it"), text: $form.name)
                    .textFieldStyle(.roundedBorder)
            }
            GridRow {
                label("mac.customer")
                VStack(alignment: .leading, spacing: 2) {
                    let shut = OrderDetailsSheet.customerShut(lock: customerLock, openedWith: opened.customerId)
                    Picker("", selection: $form.customerId) {
                        Text(shop.words.callIt("mac.job_customer_none")).tag("")
                        ForEach(OrderDetailsSheet.customerChoices(shop.clients, current: form.customerId), id: \.id) { c in
                            Text(c.name).tag(c.id)
                        }
                    }
                    .labelsHidden()
                    .disabled(shut)
                    if shut, let customerLock {
                        Text(Shop.customerLockWords(shop.words)[customerLock] ?? "")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            GridRow {
                label("doc.due")
                Toggle(isOn: $form.hasDueDate) {
                    if form.hasDueDate {
                        DatePicker("", selection: $form.dueDate, displayedComponents: .date).labelsHidden()
                    } else {
                        Text(shop.words.callIt("mac.no_due_date")).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            GridRow {
                label("waiting.priority_label")
                Picker("", selection: $form.priority) {
                    ForEach(Shop.priorityLevels, id: \.self) { level in
                        Text(shop.words.callIt(EditJobSheet.wordFor(level))).tag(level)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            GridRow {
                label("common.notes")
                TextField("", text: $form.notes, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Toggle(shop.words.callIt("oe.non_business"), isOn: $form.nonBusiness)
                    .toggleStyle(.checkbox)
                    .help(shop.words.callIt("oe.non_business_hint"))
            }
        }
    }

    // MARK: - Parts

    @ViewBuilder private var partRows: some View {
        // What the rule allows, said before the shop tries.
        if let why = lock?.code.flatMap({ Shop.partsRefusalWords(shop.words)[$0] }) {
            Label(why, systemImage: "lock")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // A GRID, with a header row: two bare numbers in a row say nothing
        // about which is grams and which is hours (Dev Hub, on the first
        // capture). The header names each column once, as the Figma frame's
        // add row does, and every field carries the same word for VoiceOver.
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                header("pe.part")
                header("mac.filament")
                header("mac.grams")
                header("mac.hours")
                header("doc.qty")
                Color.clear.frame(width: 1, height: 1)
            }
            ForEach($parts.byID) { $part in
                let fixed = partsLocked || part.delivered
                GridRow {
                    TextField(shop.words.callIt("mac.a_part"), text: $part.name)
                        .textFieldStyle(.roundedBorder)
                        .disabled(partsLocked)
                        .accessibilityLabel(shop.words.callIt("mac.a_part"))
                    Picker("", selection: $part.spoolId) {
                        Text(shop.words.callIt("mac.filament")).tag(String?.none)
                        ForEach(shop.spools) { spool in
                            Text(spool.label(shop.words, unit: shop.unit(of: spool))).tag(String?.some(spool.id))
                        }
                    }
                    .labelsHidden().frame(width: 130)
                    .disabled(fixed || nameOnly)
                    .accessibilityLabel(shop.words.callIt("mac.filament"))
                    TextField("0", text: $part.grams)
                        .textFieldStyle(.roundedBorder).frame(width: 66).monospacedDigit()
                        .disabled(fixed || nameOnly)
                        .accessibilityLabel(shop.words.callIt("mac.grams"))
                    TextField("0", text: $part.hours)
                        .textFieldStyle(.roundedBorder).frame(width: 58).monospacedDigit()
                        .disabled(fixed || nameOnly)
                        .accessibilityLabel(shop.words.callIt("mac.hours"))
                    Stepper("×\(part.qty)", value: $part.qty, in: 1...999)
                        .monospacedDigit().fixedSize()
                        .disabled(fixed || nameOnly)
                        .accessibilityLabel(shop.words.callIt("doc.qty"))
                    if part.delivered {
                        Image(systemName: "shippingbox.fill").foregroundStyle(Role.ok)
                            .help(shop.words.callIt("mac.parts_delivered_fixed"))
                            .accessibilityLabel(shop.words.callIt("mac.parts_delivered_fixed"))
                    } else {
                        Button {
                            parts.removeAll { $0.id == part.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(shop.words.callIt("mac.parts_remove"))
                        .accessibilityLabel(shop.words.callIt("mac.parts_remove"))
                        // The rule refuses the last part and a finished job's.
                        .disabled(lock?.addRemove != true || parts.count <= 1)
                    }
                }
            }
        }
        if lock?.addRemove == true {
            Button {
                parts.append(PartDraft(id: "new-" + UUID().uuidString, spoolId: parts.last?.spoolId))
            } label: {
                Label(shop.words.callIt("mac.add_part"), systemImage: "plus")
            }
            .buttonStyle(.link)
        }
    }

    // MARK: - Price

    private var priceFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 9) {
            GridRow {
                // MARKUP, and called that. The price is cost × (1 + this %)
                // (`lib/pricing.js quoteTotal`), so the figure `marginOf`
                // reads back is a markup on cost — 229% on a 142 part sold
                // at 469 — and a margin (profit as a share of the PRICE)
                // would be 70% for the same job. The Catalogue and the
                // product sheet already say Markup for it (Dev Hub, Nov 14).
                label("mac.markup")
                // Read off the job by the shared rule. Where it cannot be
                // said (a typed price), it says so rather than guessing.
                switch margin {
                case .some(.some(let pct)):
                    Text(verbatim: shop.words.numeral(Int(pct.rounded())) + "%").monospacedDigit()
                case .some(.none):
                    Text(shop.words.callIt("mac.js_margin_typed")).foregroundStyle(.secondary)
                case .none:
                    Text(verbatim: " ")
                }
            }
            GridRow {
                label("oe.discount_pct")
                HStack(spacing: 4) {
                    TextField("0", text: $form.discount)
                        .textFieldStyle(.roundedBorder).frame(width: 64).monospacedDigit()
                    Text(verbatim: "%").foregroundStyle(.secondary)
                }
            }
            GridRow {
                label("pe.price_override")
                TextField(shop.words.callIt("pe.price_override_ph"), text: $form.price)
                    .textFieldStyle(.roundedBorder).frame(width: 110).monospacedDigit()
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                // Shipping, extra charges, courier, addresses, tags: the
                // order editor, one link away (Turki, Q6).
                Button(shop.words.callIt("mac.js_more")) {
                    let details = subject
                    shop.clearQuestion()
                    shop.pendingDetails = details
                }
                .buttonStyle(.link)
                .disabled(changed)
                .help(changed ? shop.words.callIt("common.save") : "")
            }
        }
    }

    // MARK: - Footer: the total, pinned

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let refusal {
                Label(refusal, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(Khayt.late)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(shop.words.callIt(newTotal != nil ? "mac.js_new_total" : "common.total"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(newTotal ?? Money.text(job?.figures?.due ?? job?.price ?? 0, currency))
                        .font(.title3.weight(.semibold)).monospacedDigit()
                }
                Spacer()
                SaveProblem(text: shop.moveProblem)
                Button(shop.words.callIt("common.cancel")) { shop.clearQuestion() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("common.save")) {
                    // The customer has seen this price, and what the parts
                    // cost moved: ask before it does.
                    if lock?.askPrice == true, partsCostMoved { askingPrice = true } else { commit(keepPrice: false) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || !changed || refusal != nil || !shop.canMoveJobs)
            }
        }
    }

    private var partsCostMoved: Bool {
        guard partsChanged else { return false }
        if parts.count != openedParts.count { return true }
        return parts.contains { $0.costMoved }
    }

    // MARK: - Pieces

    private func section<Content: View>(_ key: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(shop.words.callIt(key))
                .textCase(.uppercase)
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            content()
        }
    }

    /// A parts column's name, over the fields it names.
    private func header(_ key: String) -> some View {
        Text(shop.words.callIt(key))
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func label(_ key: String) -> some View {
        Text(shop.words.callIt(key)).foregroundStyle(.secondary).fixedSize()
            .gridColumnAlignment(.trailing)
    }

    // MARK: - Opening, previewing, saving

    private func open() {
        guard !started else { return }
        started = true
        let fields = shop.orderFields(subject.id)
        let due = Order.day(job?.dueDate)
        var was = Form()
        was.name = job?.project ?? subject.project
        was.customerId = Shop.plainString(fields["clientId"]) ?? ""
        was.hasDueDate = due != nil
        if let due { was.dueDate = due }
        was.priority = shop.priorityOf(job)
        was.notes = Shop.plainString(fields["notes"]) ?? ""
        was.nonBusiness = job?.nonBusiness == true
        was.discount = Self.percent(Shop.plainNumber(fields["discountPct"]) ?? 0)
        form = was
        opened = was
        let drafts: [PartDraft] = (job?.parts ?? []).enumerated().map { index, part in
            let o = EditPartSheet.opening(part, raw: shop.rawPart(subject.id, partId: part.id, at: index),
                                          spools: shop.spools)
            return PartDraft(id: part.id, storedId: part.id, storedIndex: index,
                             name: o.name, grams: o.grams, hours: o.hours,
                             qty: o.qty, spoolId: o.spoolId, opened: o, delivered: part.delivered)
        }
        parts = drafts
        openedParts = drafts
        Task {
            lock = await shop.partsLock(subject.id)
            customerLock = await shop.customerLock(subject.id)
            if let engine = shop.engine, let row = shop.orderRow(subject.id) {
                margin = .some(try? await engine.marginOf(row))
            }
        }
    }

    /// A stored discount as the box shows it: "10", "12.5", and "" for none.
    static func percent(_ value: Double) -> String {
        guard value > 0 else { return "" }
        return value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// What the sheet changed, and nothing else — the fields a save names.
    static func fields(opened: Form, now: Form) -> [String: JSONValue] {
        var typedPrice: Double?
        let typed = now.price.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty { typedPrice = TypedNumber.parse(typed) }
        var out = EditJobSheet.fields(
            opened: .init(hasDueDate: opened.hasDueDate, dueDate: opened.hasDueDate ? opened.dueDate : nil,
                          priority: opened.priority),
            hasDueDate: now.hasDueDate, dueDate: now.dueDate, priority: now.priority, price: typedPrice)
        if let renamed = EditJobSheet.renamed(from: opened.name, to: now.name) { out["project"] = .string(renamed) }
        let notes = now.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if notes != opened.notes.trimmingCharacters(in: .whitespacesAndNewlines) { out["notes"] = .string(notes) }
        let was = TypedNumber.parse(opened.discount) ?? 0
        let pct = min(100, max(0, TypedNumber.parse(now.discount) ?? 0))
        if pct != was { out["discountPct"] = .number(pct) }
        return out
    }

    private func save(keepPrice: Bool) async -> Shop.JobSave {
        var save = Shop.JobSave()
        save.fields = Self.fields(opened: opened, now: form)
        if form.customerId != opened.customerId {
            save.customer = .some(form.customerId.isEmpty ? nil : form.customerId)
        }
        if form.nonBusiness != opened.nonBusiness { save.nonBusiness = form.nonBusiness }
        if partsChanged { save.parts = await shop.partsForSave(subject.id, drafts: parts) }
        save.keepPrice = keepPrice
        return save
    }

    /// Ask the rule what a save would do, and show it.
    private func preview() async {
        guard started, changed else { newTotal = nil; refusal = nil; return }
        // A breath, so typing a number is one question, not one per key.
        try? await Task.sleep(for: .milliseconds(250))
        if Task.isCancelled { return }
        let pending = await save(keepPrice: false)
        guard !Task.isCancelled, let answer = await shop.previewJobSave(subject.id, pending) else { return }
        switch answer {
        case .success(let after):
            refusal = nil
            let was = job?.price ?? 0
            let price = Shop.plainNumber(Shop.asObject(after)?["price"]) ?? was
            newTotal = abs(price - was) > 0.004 ? Money.text(price, currency) : nil
        case .failure(let refused):
            refusal = refused.sentence
            newTotal = nil
        }
    }

    private func commit(keepPrice: Bool) {
        saving = true
        shop.moveProblem = nil
        Task {
            let pending = await save(keepPrice: keepPrice)
            let wrote = await shop.saveJob(subject.id, pending)
            saving = false
            if wrote, shop.moveProblem == nil { shop.clearQuestion() }
        }
    }
}
