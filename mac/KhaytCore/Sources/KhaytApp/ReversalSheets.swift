import SwiftUI
import UniformTypeIdentifiers
import KhaytCore

/// The sheets of the desktop's order tools, on the window.
struct OrderToolSheets: ViewModifier {
    @Bindable var shop: Shop

    func body(content: Content) -> some View {
        content
            .shopSheet(item: $shop.pendingDetails) { OrderDetailsSheet(shop: shop, subject: $0) }
            .shopSheet(item: $shop.pendingVoid) { VoidInvoiceSheet(shop: shop, subject: $0) }
            .shopSheet(item: $shop.pendingCredit) { CreditNoteSheet(shop: shop, subject: $0) }
            .shopSheet(item: $shop.creditPaper) { CreditPaperSheet(shop: shop, request: $0) }
            .shopSheet(item: $shop.pendingRma) { RmaSheet(shop: shop, subject: $0) }
            .shopSheet(item: $shop.pendingReprint) { ReprintSheet(shop: shop, subject: $0) }
            .shopSheet(item: $shop.pendingHistory) { OrderHistorySheet(shop: shop, request: $0) }
            .shopSheet(isPresented: $shop.showingIntake) { IntakeSheet(shop: shop) }
            .shopSheet(item: $shop.importingCsv) { CsvImportSheet(shop: shop, kind: $0) }
            .shopSheet(isPresented: $shop.namingFilter) { SaveFilterSheet(shop: shop) }
    }
}

/// What happened to a job, and making it again — for a job's menus.
struct JobRecordItems: View {
    let shop: Shop
    let job: Order

    var body: some View {
        Button(shop.words.callIt("ord.timeline") + "\u{2026}") {
            shop.pendingHistory = Shop.HistoryRequest(id: job.id, project: job.project)
        }
        Button(shop.words.callIt("ord.edit_history") + "\u{2026}") {
            shop.pendingHistory = Shop.HistoryRequest(id: job.id, project: job.project, edits: true)
        }
        Button(shop.words.callIt("oe.reprint") + "\u{2026}") {
            shop.pendingReprint = Shop.PendingHold(id: job.id, project: job.project)
        }
        .disabled(!shop.canMoveJobs || job.status == "quote")
        // Offered once the job has reached the customer, as the desktop does.
        if job.deliveredAt != nil {
            Button(shop.words.callIt("qc.rma_title") + "\u{2026}") {
                shop.pendingRma = Shop.PendingHold(id: job.id, project: job.project)
            }
            .disabled(!shop.canMoveJobs)
        }
    }
}

/// Taking an invoice back — a credit note, or voiding it.
struct JobInvoiceItems: View {
    let shop: Shop
    let job: Order

    var body: some View {
        if Shop.hasInvoice(job) {
            Button(shop.words.callIt("cn.title") + "\u{2026}") {
                shop.pendingCredit = Shop.PendingHold(id: job.id, project: job.project)
            }
            .disabled(!shop.canReverseInvoices || job.voided || job.credited)
            if job.voided {
                Text(shop.words.callIt("inv.already_voided"))
            } else {
                Button(shop.words.callIt("inv.void_btn") + "\u{2026}", role: .destructive) {
                    shop.pendingVoid = Shop.PendingHold(id: job.id, project: job.project)
                }
                .disabled(!shop.canReverseInvoices)
            }
        }
    }
}

/// Voiding an invoice. Asked, because it cannot be taken back on the other
/// app and is the one thing here a customer's accountant will ask about.
///
/// The desktop's sheet: a reason, and — when the job has the weight and
/// material to book — whether to put its filament on the waste log.
struct VoidInvoiceSheet: View {
    static let width: CGFloat = 420

    let shop: Shop
    let subject: Shop.PendingHold

    @State private var reason = ""
    @State private var logWaste = true
    @State private var material: VoidMaterial?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(shop.words.callIt("inv.void_btn")).font(.headline)
            Text(shop.words.callIt("inv.void_confirm", ["id": .string(subject.id)]))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(shop.words.callIt("inv.void_reason")).foregroundStyle(.secondary)
                TextField(shop.words.callIt("inv.void_reason_ph"), text: $reason)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
            }
            if let material, material.loggable {
                Toggle(isOn: $logWaste) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(shop.words.callIt("waste.voided_order"))
                        Text(shop.words.callIt("mac.void_waste_amount", [
                            "grams": .string(String(Int(material.weight.rounded()))),
                            "material": .string(material.material),
                        ]))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .toggleStyle(.checkbox)
            }
            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.clearQuestion() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("inv.void_btn"), role: .destructive, action: commit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: Self.width)
        .onAppear { focused = true }
        .task(id: subject.id) { material = await shop.voidMaterial(subject.id) }
    }

    private func commit() {
        let id = subject.id
        let why = reason
        let waste = logWaste && material?.loggable == true
        shop.clearQuestion()
        Task { await shop.voidInvoice(id, reason: why, logWaste: waste) }
    }
}

/// A credit note: how much, and why. The amount is in the job's own
/// currency and can be no more than what is still uncredited.
struct CreditNoteSheet: View {
    static let width: CGFloat = 420

    let shop: Shop
    let subject: Shop.PendingHold

    @State private var amount = 0.0
    @State private var room = 0.0
    @State private var reason = ""
    @State private var loaded = false

    private var job: Order? { shop.orders.first { $0.id == subject.id } }
    private var code: String { (job?.currency.isEmpty ?? true) ? shop.currency : (job?.currency ?? shop.currency) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(shop.words.callIt("cn.title")).font(.headline)
            if let job {
                Text(shop.words.callIt("cn.ref_order") + ": " + job.reference + " · " + Money.text(job.price, code))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            if loaded && room < 0.01 {
                Text(shop.words.callIt("cn.nothing_left")).foregroundStyle(.secondary)
            } else {
                LabeledContent(shop.words.callIt("cn.credit_amount") + " (\(code))") {
                    TextField("", value: $amount, format: .number.locale(Money.digits).precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder).frame(width: 110).monospacedDigit()
                }
                Text(shop.words.callIt("mac.credit_room", ["amount": .string(Money.text(room, code))]))
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(shop.words.callIt("cn.reason")).foregroundStyle(.secondary)
                    TextField(shop.words.callIt("cn.reason_ph"), text: $reason, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(2...4)
                }
            }
            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.clearQuestion() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("cn.generate"), action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!loaded || room < 0.01 || amount <= 0)
            }
        }
        .padding(18)
        .frame(width: Self.width)
        .task(id: subject.id) {
            room = await shop.creditRoom(subject.id)
            amount = room
            loaded = true
        }
    }

    private func commit() {
        let id = subject.id
        let typed = min(max(0.01, amount), room)
        let why = reason
        shop.clearQuestion()
        Task { await shop.issueCreditNote(id, amount: typed, reason: why) }
    }
}

/// The credit note just issued, to save as a PDF.
struct CreditPaperSheet: View {
    let shop: Shop
    let request: Shop.CreditPaperRequest

    @StateObject private var paper: InvoicePaper
    @State private var saved: String?

    init(shop: Shop, request: Shop.CreditPaperRequest) {
        self.shop = shop
        self.request = request
        _paper = StateObject(wrappedValue: InvoicePaper(document: request.document))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(shop.words.callIt("doc.credit_note")).font(.headline)
                    Text(request.project).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(request.number).font(.callout.monospaced()).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            InvoicePaperView(paper: paper).frame(minWidth: 620, minHeight: 520)
            Divider()
            HStack {
                if let saved { Text(saved).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                Button(shop.words.callIt("common.close")) { shop.clearQuestion() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("mac.save_pdf"), action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!paper.drawn)
            }
            .padding(16)
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = request.number.replacingOccurrences(of: "/", with: "-") + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await paper.pdf().write(to: url, options: .atomic)
                saved = shop.words.callIt("mac.saved_to") + " " + url.lastPathComponent
            } catch {
                saved = error.localizedDescription
            }
        }
    }
}

/// A customer came back about a delivered job — the desktop's RMA sheet.
/// Reprint makes the linked replacement (free within warranty), refund opens
/// the credit note, declined only records it.
struct RmaSheet: View {
    static let width: CGFloat = 440

    let shop: Shop
    let subject: Shop.PendingHold

    @State private var reason = ""
    @State private var resolution = "reprint"
    @State private var within = false
    @State private var inWindow = false
    @State private var started = false

    private var job: Order? { shop.orders.first { $0.id == subject.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(shop.words.callIt("qc.rma_title")).font(.headline)
            Text(subject.project).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Label(shop.words.callIt(inWindow ? "qc.within_warranty" : "qc.out_of_warranty"),
                  systemImage: inWindow ? "checkmark.shield" : "exclamationmark.shield")
                .font(.callout)
            VStack(alignment: .leading, spacing: 4) {
                Text(shop.words.callIt("qc.rma_reason")).foregroundStyle(.secondary)
                TextField(shop.words.callIt("qc.rma_reason_ph"), text: $reason).textFieldStyle(.roundedBorder)
            }
            Picker(shop.words.callIt("qc.rma_resolution"), selection: $resolution) {
                Text(shop.words.callIt("qc.res_reprint")).tag("reprint")
                Text(shop.words.callIt("qc.res_refund")).tag("refund")
                Text(shop.words.callIt("qc.res_declined")).tag("declined")
            }
            Toggle(shop.words.callIt("qc.within_warranty"), isOn: $within).toggleStyle(.checkbox)
            if resolution == "refund" {
                Text(shop.words.callIt("mac.rma_refund_hint")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.clearQuestion() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("common.save"), action: commit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: Self.width)
        .task(id: subject.id) {
            guard !started, let job else { return }
            started = true
            inWindow = await shop.withinWarranty(job)
            within = inWindow
        }
    }

    private func commit() {
        let id = subject.id
        let why = reason, how = resolution, inside = within
        shop.clearQuestion()
        Task { await shop.openRma(id, reason: why, resolution: how, withinWarranty: inside) }
    }
}

/// The same work again, as a new job linked to this one — the desktop's
/// Reprint. Billable by default: the shop changes the price on the new job.
struct ReprintSheet: View {
    static let width: CGFloat = 420

    let shop: Shop
    let subject: Shop.PendingHold

    @State private var cost = "billable"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(shop.words.callIt("oe.reprint")).font(.headline)
            Text(subject.project).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Text(shop.words.callIt("mac.reprint_hint")).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(shop.words.callIt("qc.reprint_cost"), selection: $cost) {
                Text(shop.words.callIt("qc.cost_billable")).tag("billable")
                Text(shop.words.callIt("qc.cost_shop")).tag("shop")
            }
            HStack {
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.clearQuestion() }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("oe.reprint")) {
                    let id = subject.id, how = cost
                    shop.clearQuestion()
                    Task { await shop.reprintJob(id, cost: how) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: Self.width)
    }
}

/// What happened to a job: how long it sat in each stage, and every edit to
/// the fields a customer can be told a different answer about.
struct OrderHistorySheet: View {
    let shop: Shop
    let request: Shop.HistoryRequest

    @State private var edits = false
    @State private var log: [OrderEditEntry] = []
    @State private var line: OrderTimeline?
    @State private var started = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(shop.words.callIt("ord.timeline_title")).font(.headline)
            Text(request.project).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Picker("", selection: $edits) {
                Text(shop.words.callIt("ord.timeline")).tag(false)
                Text(shop.words.callIt("ord.edit_history")).tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if edits { editRows } else { stepRows }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 320)
            HStack {
                Spacer()
                Button(shop.words.callIt("common.close")) { shop.clearQuestion() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        // Esc closes it too: Close is the default button, so it cannot also
        // be the cancel button, and a viewer that ignores Esc feels stuck.
        .onExitCommand { shop.clearQuestion() }
        .frame(width: 480)
        .task(id: request.id) {
            if !started { started = true; edits = request.edits }
            log = await shop.jobEdits(request.id)
            line = await shop.timeline(request.id)
        }
    }

    @ViewBuilder private var stepRows: some View {
        if let line, !line.steps.isEmpty {
            ForEach(Array(line.steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline) {
                    Text(Self.stageWord(step.status, shop.words)).fontWeight(step.current ? .semibold : .regular)
                    Spacer()
                    if let at = Self.date(step.at) {
                        Text(shop.words.say(at, Date.FormatStyle(date: .abbreviated, time: .shortened)))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Text(step.current ? shop.words.callIt("mac.timeline_current")
                                      : Self.span(step.ms, locale: shop.words.locale))
                        .foregroundStyle(.secondary).monospacedDigit()
                        .frame(minWidth: 70, alignment: .trailing)
                }
            }
            Divider()
            HStack {
                Text(shop.words.callIt("ord.timeline_total")).foregroundStyle(.secondary)
                Spacer()
                Text(Self.span(line.totalMs, locale: shop.words.locale)).monospacedDigit()
            }
        } else {
            Text(shop.words.callIt("ord.timeline_empty")).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var editRows: some View {
        if log.isEmpty {
            Text(shop.words.callIt("ord.edit_history_empty")).foregroundStyle(.secondary)
        } else {
            ForEach(log, id: \.listId) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    if let at = entry.at.flatMap(Self.date) {
                        Text(shop.words.say(at, Date.FormatStyle(date: .abbreviated, time: .shortened)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(entry.fields, id: \.field) { f in
                        HStack(spacing: 6) {
                            Text(Shop.historyFieldKey(f.field).map(shop.words.callIt) ?? f.field)
                                .fontWeight(.medium)
                            Text(f.from.isEmpty ? "—" : f.from).foregroundStyle(.secondary)
                            Image(systemName: "arrow.forward")
                                .font(.caption).foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(f.to.isEmpty ? "—" : f.to)
                        }
                        .monospacedDigit()
                    }
                }
                Divider()
            }
        }
    }

    static func stageWord(_ status: String, _ words: Words) -> String {
        let key = "queue." + status
        let said = words.callIt(key)
        return said == key ? status : said
    }

    static func date(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)
    }

    /// "2h 5m", "3d 4h" — the two largest units, in the shop's language and
    /// digits (`words.locale`).
    static func span(_ ms: Double, locale: Locale) -> String {
        let seconds = max(0, Int(saturating: (ms / 1000).rounded()))
        let units: Set<Duration.UnitsFormatStyle.Unit> = seconds >= 86_400 ? [.days, .hours]
            : seconds >= 3600 ? [.hours, .minutes] : [.minutes]
        return Duration.seconds(seconds).formatted(
            .units(allowed: units, width: .abbreviated, maximumUnitCount: 2)
                .locale(locale))
    }

}
