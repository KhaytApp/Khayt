import SwiftUI
import KhaytCore

/// Writing a customer down.
///
/// Both names, because a Saudi shop keeps both and an invoice may need either —
/// and either one alone is enough, which is Khayt's own rule. The registration
/// numbers are here because they go on an invoice and there is nowhere else in
/// this app to put them.
///
/// Below the contact details, the two things that follow a customer into every
/// job: what they have agreed to pay for particular things, and a standing
/// order. Both used to be "edited in the other app"; a Mac that could store
/// them and not show them was a Mac that lost a shop its price list the day
/// the Windows PC was switched off.
///
/// The communications log is NOT on this sheet. A note about a call is written
/// the moment it is made, in the customer's pane — see `CustomerInspector`.
struct CustomerSheet: View {
    /// How wide this sheet is. A CONSTANT rather than a number in the body,
    /// because `SnapshotTests` photographs the sheet at a size of its own and
    /// the two silently disagreed: the sheet grew and the picture kept the old
    /// width, so the render came back cropped down the middle with no failure.
    static let width: CGFloat = 480

    let shop: Shop
    let existing: Client

    @State private var draft: Client
    @State private var agreements: [AgreementRow]
    @State private var schedule: Recurring
    @State private var hasEnd: Bool
    @State private var started = false
    /// The sources the picker offers, asked of the shared rule on appear.
    @State private var sources: [String] = []
    /// The phone number as WhatsApp would take it, or why it would not.
    @State private var phoneCheck: WhatsAppChat?
    @FocusState private var focused: Bool

    /// A price agreement as the sheet holds it while it is being typed.
    ///
    /// The price is TEXT here: a `Double` behind a text field reformats "12."
    /// to "12" under the cursor. It becomes a number on Save. `raw` is
    /// carried so a field the other app wrote survives the round trip.
    struct AgreementRow: Identifiable {
        let id = UUID()
        var raw: [String: JSONValue]
        var product: String
        var priceText: String
        var note: String

        init(_ a: PriceAgreement) {
            raw = a.raw; product = a.product; note = a.note
            priceText = a.price > 0 ? Money.fieldValue(a.price) : ""
        }
        init() { raw = [:]; product = ""; priceText = ""; note = "" }

        var agreement: PriceAgreement {
            var out = PriceAgreement(raw: raw)
            out.product = product
            out.price = Double(priceText.replacingOccurrences(of: ",", with: "")) ?? 0
            out.note = note
            return out
        }
    }

    init(shop: Shop, existing: Client) {
        self.shop = shop
        self.existing = existing
        _draft = State(initialValue: existing)
        _agreements = State(initialValue: existing.priceList.map(AgreementRow.init))
        let rec = existing.recurring ?? .fresh
        _schedule = State(initialValue: rec)
        _hasEnd = State(initialValue: rec.endDate != nil)
    }

    private var isNew: Bool { shop.clients.allSatisfy { $0.id != existing.id } }

    private var canSave: Bool {
        !draft.nameEn.trimmingCharacters(in: .whitespaces).isEmpty
            || !draft.nameAr.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        // Four sections now, so it fits the screen the way the product sheet
        // does: the content scrolls, the buttons do not. See `SheetFrame`.
        SheetFrame(width: Self.width) {
            Text(shop.words.callIt(isNew ? "mac.new_customer" : "mac.edit_customer"))
                .font(.headline)
            details
            Divider()
            priceAgreements
            Divider()
            standingOrder
        } footer: {
            HStack {
                if !canSave {
                    Text(shop.words.callIt("ce.need_name"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.editingCustomer = nil }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("common.save")) {
                    let saving = draft
                        .replacing(priceList: agreements.map(\.agreement).filter { !$0.isBlank })
                        .replacing(recurring: schedule)
                    Task { await shop.saveCustomer(saving) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            focused = true
        }
        .task {
            // Empty on failure, not a hardcoded fallback list: a second copy
            // of these seven written down here is the exact fault that lost
            // every intake-form customer from the report. The picker then
            // offers only what the customer already has, which is visibly
            // wrong rather than quietly wrong.
            sources = (try? await shop.engine?.clientSourceNames()) .flatMap { $0 } ?? []
        }
    }

    // MARK: - Who they are

    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Text(shop.words.callIt("ce.name_en")).gridColumnAlignment(.trailing)
                    .foregroundStyle(.secondary)
                TextField("", text: binding(\.nameEn)).textFieldStyle(.roundedBorder)
                    .focused($focused)
            }
            GridRow {
                Text(shop.words.callIt("ce.name_ar")).gridColumnAlignment(.trailing)
                    .foregroundStyle(.secondary)
                // Right to left whatever the app is set to: the field holds
                // Arabic by definition, and typing into a left-aligned box
                // puts the cursor in the wrong place.
                TextField("", text: binding(\.nameAr)).textFieldStyle(.roundedBorder)
                    .environment(\.layoutDirection, .rightToLeft)
            }
            GridRow {
                Text(shop.words.callIt("ce.phone")).gridColumnAlignment(.trailing)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    TextField("+966 5x xxx xxxx", text: binding(\.phone))
                        .textFieldStyle(.roundedBorder)
                    // What WhatsApp will dial, worked out as it is typed — so
                    // `0712345678` from abroad is caught here, not at the
                    // moment a customer is waiting for their update.
                    if let phoneCheck, !draft.phone.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(phoneCheck.ok
                             ? shop.words.callIt("mac.wa_number_ok",
                                                 ["number": .string("\u{2066}" + phoneCheck.e164 + "\u{2069}")])
                             : shop.whatsAppReason(phoneCheck.reason))
                            .font(.caption)
                            .foregroundStyle(phoneCheck.ok ? AnyShapeStyle(.secondary)
                                                           : AnyShapeStyle(Khayt.attention))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .task(id: draft.phone) {
                    phoneCheck = await shop.whatsAppRecipient(phone: draft.phone)
                }
            }
            GridRow {
                // The language WhatsApp updates go out in. Automatic reads the
                // names and then the shop's language.
                Text(shop.words.callIt("mac.wa_messages_in")).gridColumnAlignment(.trailing)
                    .foregroundStyle(.secondary)
                Picker("", selection: binding(\.messageLang)) {
                    Text(shop.words.callIt("mac.wa_lang_auto")).tag("")
                    Text(shop.words.callIt("mac.wa_lang_ar")).tag("ar")
                    Text(shop.words.callIt("mac.wa_lang_en")).tag("en")
                }
                .labelsHidden()
                .fixedSize()
            }
            GridRow {
                Text(shop.words.callIt("ce.email")).gridColumnAlignment(.trailing)
                    .foregroundStyle(.secondary)
                TextField("", text: binding(\.email)).textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text(shop.words.callIt("ce.cr")).gridColumnAlignment(.trailing)
                    .foregroundStyle(.secondary)
                TextField("", text: binding(\.cr)).textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text(shop.words.callIt("ce.vat")).gridColumnAlignment(.trailing)
                    .foregroundStyle(.secondary)
                TextField("", text: binding(\.vat)).textFieldStyle(.roundedBorder)
            }
            GridRow {
                // ── WHERE THEY CAME FROM ──────────────────────────────────
                //
                // The one field on this sheet that is not about reaching the
                // customer. It is here because nothing else can put it there:
                // the Reports screen counts customers by source, and with no
                // way to set one every shop that does not also run the other
                // app read "Other" for all of them.
                //
                // The list is the RULE's, fetched rather than written down —
                // this is the field that broke by having two lists of it, one
                // of which had never heard of the intake form's `online`.
                Text(shop.words.callIt("cl.source")).gridColumnAlignment(.trailing)
                    .foregroundStyle(.secondary)
                Picker("", selection: binding(\.source)) {
                    // A customer whose source was never asked. Not the same as
                    // "Other", which is a shop saying it asked and none of
                    // these fitted — so the report can tell them apart.
                    Text(shop.words.callIt("mac.cs_unset")).tag("")
                    if !sources.isEmpty { Divider() }
                    ForEach(sources, id: \.self) { source in
                        Text(shop.words.callIt("cl.source_" + source)).tag(source)
                    }
                    // A value this build does not know — written by a newer
                    // Khayt, or by hand. Shown as itself and kept on save
                    // rather than silently becoming "Other".
                    if !draft.source.isEmpty, !sources.contains(draft.source) {
                        Divider()
                        Text(draft.source).tag(draft.source)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            GridRow {
                Text(shop.words.callIt("ce.notes")).gridColumnAlignment(.trailing)
                    .foregroundStyle(.secondary)
                TextField("", text: binding(\.notes), axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...4)
            }
            // ── ASKED NOT TO BE MARKETED TO ───────────────────────────────
            //
            // `lib/campaigns.js` has always refused to put this customer on a
            // list, whatever the segment says. What was missing is that this
            // app could not SET it — so a shop that sent a campaign from here
            // and then read "please stop emailing me" had to open the other
            // app to honour it. Sending in one place and recording consent in
            // another is the wrong way round, and it is the sort of thing a
            // shop discovers only after the second email.
            //
            // The word is the other app's (`camp.opt_out`), which carries it
            // in nine languages; a Mac-only phrasing would be English for
            // seven of them.
            GridRow {
                Color.clear.frame(height: 0)
                Toggle(shop.words.callIt("camp.opt_out"), isOn: Binding(
                    get: { draft.marketingOptOut },
                    set: { draft = draft.marketed(!$0) }))
                    .toggleStyle(.checkbox)
            }
        }
    }

    // MARK: - What they pay

    /// What this customer pays for particular things.
    ///
    /// A row is a product WORD, a price and a note. The word is matched
    /// against a part's name when a job is taken for them, by the shared rule
    /// — "bracket" covers "Wall bracket, steel" — and the figure becomes what
    /// that part costs on the job. Rows with neither a word nor a price are
    /// dropped on Save, as the other app drops them.
    private var priceAgreements: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(shop.words.callIt("ce.price_list")).font(.subheadline.weight(.semibold))
            if agreements.isEmpty {
                Text(shop.words.callIt("ce.price_list_empty"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach($agreements) { $row in
                HStack(spacing: 8) {
                    TextField(shop.words.callIt("ce.pl_product"), text: $row.product)
                        .textFieldStyle(.roundedBorder)
                    TextField(shop.words.callIt("ce.pl_price"), text: $row.priceText)
                        .textFieldStyle(.roundedBorder).frame(width: 84).monospacedDigit()
                    TextField(shop.words.callIt("ce.pl_note"), text: $row.note)
                        .textFieldStyle(.roundedBorder).frame(width: 120)
                    Button {
                        agreements.removeAll { $0.id == row.id }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                        .help(shop.words.callIt("common.delete"))
                }
            }
            Button(shop.words.callIt("common.add")) { agreements.append(AgreementRow()) }
            Text(shop.words.callIt("ce.price_list_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - The standing order

    /// The same job again, on a schedule.
    ///
    /// Switching it on shows the schedule; the record keeps the schedule
    /// either way, so a shop that pauses a customer for the summer and
    /// switches them back on in September gets September's dates, not a
    /// blank form. "Skip next cycle" moves the date on by the shared rule —
    /// the one that knows the 31st of January is followed by the 28th of
    /// February.
    private var standingOrder: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(shop.words.callIt("rec.enable"), isOn: $schedule.enabled)
                .font(.subheadline.weight(.semibold))
            if schedule.enabled {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        Text(shop.words.callIt("rec.interval")).gridColumnAlignment(.trailing)
                            .foregroundStyle(.secondary)
                        Picker("", selection: $schedule.interval) {
                            ForEach(Recurring.intervals, id: \.self) { interval in
                                Text(shop.words.callIt("rec.interval.\(interval)")).tag(interval)
                            }
                            // A schedule set to `daily` or `yearly` elsewhere
                            // keeps its word rather than being silently
                            // changed to the first thing in the menu.
                            if !Recurring.intervals.contains(schedule.interval) {
                                Text(schedule.interval).tag(schedule.interval)
                            }
                        }
                        .labelsHidden().frame(width: 170, alignment: .leading)
                    }
                    GridRow {
                        Text(shop.words.callIt("rec.next_due")).gridColumnAlignment(.trailing)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            DatePicker("", selection: dayBinding(\.nextDue), displayedComponents: .date)
                                .labelsHidden()
                            Button(shop.words.callIt("rec.skip_next")) {
                                let from = schedule.nextDue ?? Recurring.string(Date())
                                let interval = schedule.interval
                                Task {
                                    if let next = await shop.nextCycle(after: from, interval: interval) {
                                        schedule.nextDue = next
                                    }
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                    GridRow {
                        Color.clear.frame(width: 0, height: 0)
                        Toggle(shop.words.callIt("rec.paused"), isOn: $schedule.paused)
                    }
                    GridRow {
                        Color.clear.frame(width: 0, height: 0)
                        HStack(spacing: 10) {
                            Toggle(shop.words.callIt("rec.end_date"), isOn: $hasEnd)
                                .onChange(of: hasEnd) { _, on in
                                    if !on { schedule.endDate = nil }
                                    else if schedule.endDate == nil { schedule.endDate = Recurring.string(Date()) }
                                }
                            if hasEnd {
                                DatePicker("", selection: dayBinding(\.endDate), displayedComponents: .date)
                                    .labelsHidden()
                            }
                        }
                    }
                }
                Text(shop.words.callIt("rec.hint"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A text binding onto one field of the draft.
    ///
    /// `Client` is a value with `let` fields — it is a record, not a form — so
    /// editing rebuilds it. That keeps the record's shape in one place rather
    /// than growing a second mutable copy of it.
    private func binding(_ key: KeyPath<Client, String>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: key] },
            set: { draft = draft.with(key, $0) }
        )
    }

    /// A date picker onto a `YYYY-MM-DD` field of the schedule. An unset day
    /// shows today, and picking writes the day — never an instant.
    private func dayBinding(_ key: WritableKeyPath<Recurring, String?>) -> Binding<Date> {
        Binding(
            get: { schedule[keyPath: key].flatMap(Recurring.day) ?? Date() },
            set: { schedule[keyPath: key] = Recurring.string($0) }
        )
    }
}
