import SwiftUI
import KhaytCore

/// One job, as `design/ios-v2/` draws it: a PAGE pushed onto the stack — not a
/// sheet — with the job and who it is for, the few facts a shop floor needs,
/// the five stages to put it in directly, and ONE button that moves it on.
///
/// There is no on-hold chip. The design has five stages and so does this page;
/// holding a job is the Mac's.
///
/// A QUOTE has no stages to pick yet. Its page asks for the customer's answer
/// instead — Approve, or Decline behind a confirmation — and shows the price
/// and how long it stands, when the Quotes list handed the record over.
struct OrderDetailPage: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @EnvironmentObject private var printers: LivePrinters

    @State private var order: QueueOrder
    let facts: OrderFacts?
    /// The quote's own record, from the Quotes list: its price and last day.
    /// Read again after a revision moves its price.
    @State private var quote: OrderLogEntry?
    /// Called after a write, so the screen underneath is current when the page
    /// is popped.
    let onChanged: () async -> Void

    @State private var machines: [MachineInfo] = []
    @State private var isUpdating = false
    @State private var errorMessage: String?
    @State private var payment: BookWriter.PaymentState?
    @State private var currency: String?
    @State private var recordingPayment = false
    @State private var whatsApp: KhaytAPIClient.WhatsAppOffer?
    @State private var writingWhatsApp = false
    @State private var photoAccess: KhaytAPIClient.PhotoAccess?
    /// The job's own photos of the finished print, from the book.
    @State private var printPhotos: [JobPrintPhoto] = []
    /// A phone the Mac enrolled can send a photo of the print (not a quote).
    private var canAddPhoto: Bool { api.canAddJobPhoto && order.status != "quote" && order.status != "cancelled" }
    @State private var showingInvoice = false
    @State private var showingProforma = false
    /// The carriers to ship with, when this job is finished and not yet sent.
    @State private var shipChoices: [KhaytEngine.CarrierChoice]?
    @State private var shipping = false
    @State private var editing: KhaytAPIClient.OrderEditState?
    /// The job's saved customer, for Call / WhatsApp / Email.
    @State private var customer: Client?
    @State private var saleProblems: [ModelLicence.SaleProblem] = []
    @State private var moveNotes: [String] = []
    /// A packing slip, delivery note or work order, being shown.
    @State private var paper: PaperSubject?
    /// A quote's version, follow-ups and kept versions, from the book.
    @State private var quoteState: KhaytAPIClient.QuoteState?
    @State private var revising: KhaytAPIClient.QuoteState?
    @State private var showingHistory = false
    @State private var followingUp = false
    @Environment(\.openURL) private var openURL

    init(order: QueueOrder, facts: OrderFacts?, quote: OrderLogEntry? = nil,
         onChanged: @escaping () async -> Void) {
        _order = State(initialValue: order)
        self.facts = facts
        _quote = State(initialValue: quote)
        self.onChanged = onChanged
    }

    var body: some View {
        ScrollView {
            // Asked where the sale is, as on the Mac: a model that may not be
            // sold, printed and handed over, has a designer on the other end.
            if !saleProblems.isEmpty {
                LicenceNote(problems: saleProblems)
                    .padding(.horizontal, 16).padding(.top, 12)
            }
            OrderDetailContent(order: order, facts: facts,
                               live: order.status == "printing" ? printers.reading(for: order.machineId) : nil,
                               isUpdating: isUpdating, machines: machines,
                               errorMessage: errorMessage,
                               onAdvance: { Task { await advance() } },
                               onSetStatus: { st in Task { await setStatus(st) } },
                               onAssignMachine: { id in Task { await assignMachine(id) } },
                               quote: order.status == OrderStatus.quote.rawValue ? quote : nil,
                               currency: currency,
                               onAnswer: { answer in Task { await answerQuote(answer) } })
                // A viewer's cloud sign-in moves nothing (`ReadOnlyGate`).
                .disabled(!api.canWrite)
            if order.status == OrderStatus.quote.rawValue, let quoteState {
                QuoteToolsCard(state: quoteState, followingUp: followingUp,
                               onRevise: { revising = quoteState },
                               onFollowUp: { Task { await followUp() } },
                               onHistory: { showingHistory = true })
                    .disabled(!api.canWrite)
                    .padding(.horizontal, 16).padding(.bottom, 16)
            } else if order.status == OrderStatus.quote.rawValue, !api.holdsBook {
                // No LAN route revises or follows up a quote: say so, rather
                // than offer what this phone cannot do.
                V2Note(text: L10n.tr("quote.needs_book"), tone: KhaytDesign.note)
                    .padding(.horizontal, 16).padding(.bottom, 16)
            }
            if let payment {
                PaymentCard(state: payment, currency: currency) { recordingPayment = true }
                    .disabled(!api.canWrite)
                    .padding(.horizontal, 16).padding(.bottom, 16)
            }
            // A quote or a cancelled job has no invoice; the page says why for
            // the rarer cases (waiting for approval, not numbered yet).
            if order.status != "quote", order.status != "cancelled" {
                Button { showingInvoice = true } label: { InvoiceCard() }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16).padding(.bottom, 16)
            }
            // Accepted, not yet finished: a proforma to ask for payment with.
            if BookReader.offersProforma(status: order.status) {
                Button { showingProforma = true } label: { InvoiceCard(proforma: true) }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16).padding(.bottom, 16)
            }
            if let shipChoices, !shipChoices.isEmpty {
                Button { shipping = true } label: { ShipCard() }
                    .buttonStyle(.plain)
                    .disabled(!api.canWrite)
                    .padding(.horizontal, 16).padding(.bottom, 16)
                    .sheet(isPresented: $shipping) {
                        ShipSheet(orderId: order.id, carriers: shipChoices) {
                            self.shipChoices = await api.shipChoices(orderId: order.id)
                        }
                    }
            }
            // The papers besides the invoice, from the book. A quote is not
            // work yet; a cancelled job is nothing to pack or make.
            if api.holdsBook, order.status != "quote", order.status != "cancelled" {
                JobPapersCard { kind in paper = .job(kind, orderId: order.id) }
                    .padding(.horizontal, 16).padding(.bottom, 16)
            }
            if let whatsApp {
                WhatsAppCard(offer: whatsApp) { writingWhatsApp = true }
                    .padding(.horizontal, 16).padding(.bottom, 16)
            }
            if let customer, customer.dialNumber != nil || !(customer.email ?? "").isEmpty {
                ContactCard(client: customer)
                    .padding(.horizontal, 16).padding(.bottom, 16)
            }
            // The finished print, as the Mac and the desktop keep it — the
            // printer's own snapshot at the end of a print among them.
            if !printPhotos.isEmpty || canAddPhoto {
                PrintPhotosCard(photos: printPhotos, add: canAddPhoto ? { jpeg in
                    let reply = await api.addJobPhoto(orderId: order.id, jpeg: jpeg)
                    printPhotos = api.printPhotos(orderId: order.id)
                    return reply
                } : nil)
                    .padding(.horizontal, 16).padding(.bottom, 16)
            }
            // Only an order the Mac has published has a page to put a photo on.
            if let photoAccess, photoAccess != .notPublished {
                OrderPhotosCard(access: photoAccess)
                    .padding(.horizontal, 16).padding(.bottom, 16)
            }
            // The customer's page: its link, and the messages on it.
            if case .ready(let token)? = photoAccess {
                PortalCard(token: token).padding(.horizontal, 16).padding(.bottom, 16)
            } else if case .viewOnly(let token)? = photoAccess {
                PortalCard(token: token).padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
        .sheet(isPresented: $recordingPayment) {
            if let payment {
                RecordPaymentSheet(orderId: order.id, state: payment, currency: currency) {
                    await loadPayment()
                    await onChanged()
                }
            }
        }
        .sheet(isPresented: $writingWhatsApp, onDismiss: { Task { whatsApp = await api.whatsAppOffer(orderId: order.id) } }) {
            WhatsAppSheet(orderId: order.id)
        }
        .navigationDestination(isPresented: $showingInvoice) { InvoicePage(orderId: order.id) }
        .navigationDestination(isPresented: $showingProforma) { InvoicePage(orderId: order.id, proforma: true) }
        .navigationDestination(item: $paper) { ShopPaperPage(subject: $0) }
        .sheet(item: Binding(get: { revising.map { RevisingQuote(state: $0) } },
                             set: { if $0 == nil { revising = nil } })) { r in
            ReviseQuoteSheet(orderId: order.id, start: r.state, currency: currency) { await quoteRevised() }
        }
        .sheet(isPresented: $showingHistory) {
            if let quoteState { QuoteHistorySheet(state: quoteState, currency: currency) }
        }
        .background(KhaytDesign.ground.ignoresSafeArea())
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            // The design's two-line title: the job's number and who it is for.
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(order.displayTitle)
                        .font(.khayt(16, .semibold, relativeTo: .headline))
                        .lineLimit(1)
                        .foregroundStyle(KhaytDesign.ink)
                    Text("#\(order.reference) · \(order.displayClient)")
                        .font(.khayt(11.5, relativeTo: .caption))
                        .foregroundStyle(KhaytDesign.note)
                        .lineLimit(1)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if api.holdsBook, order.status != "cancelled" {
                    Button(L10n.tr("edit.title")) { Task { editing = await api.editState(orderId: order.id) } }
                        .disabled(!api.canWrite)
                }
            }
        }
        .sheet(item: Binding(get: { editing.map(EditingJob.init) }, set: { if $0 == nil { editing = nil } })) { e in
            EditOrderSheet(orderId: order.id, start: e.state, currency: currency) { await onChanged() }
        }
        .moveNotes($moveNotes)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            machines = (try? await api.fetchMachines()) ?? []
            await loadPayment()
            whatsApp = await api.whatsAppOffer(orderId: order.id)
            shipChoices = await api.shipChoices(orderId: order.id)
            customer = api.customer(orderId: order.id)
            photoAccess = api.photoAccess(orderId: order.id)
            printPhotos = api.printPhotos(orderId: order.id)
            saleProblems = api.saleProblems(orderId: order.id)
            if order.status == OrderStatus.quote.rawValue { quoteState = await api.quoteState(orderId: order.id) }
            #if DEBUG
            // `-KhaytWASheet YES` with `-KhaytOpen order:<id>`: the sheet, for screenshots.
            if whatsApp != nil, UserDefaults.standard.bool(forKey: "KhaytWASheet") { writingWhatsApp = true }
            // `-KhaytInvoice YES` with `-KhaytOpen order:<id>`: the invoice, for screenshots.
            if UserDefaults.standard.bool(forKey: "KhaytInvoice") { showingInvoice = true }
            // `-KhaytPaper packingSlip|deliveryNote|workOrder`: that paper, for screenshots.
            if let k = UserDefaults.standard.string(forKey: "KhaytPaper"), let kind = KhaytEngine.ShopPaper(rawValue: k) {
                paper = .job(kind, orderId: order.id)
            }
            // `-KhaytQuoteHistory YES` on a quote: its history, for screenshots.
            if quoteState != nil, UserDefaults.standard.bool(forKey: "KhaytQuoteHistory") { showingHistory = true }
            #endif
        }
        .watchesPrinters(when: order.status == "printing" && order.machineId != nil)
    }

    private func loadPayment() async {
        currency = await api.orderCurrency(orderId: order.id)
        payment = await api.paymentState(orderId: order.id)
        #if DEBUG
        // `-KhaytPaySheet YES` with `-KhaytOpen order:<id>`: the sheet, for screenshots.
        if payment != nil, UserDefaults.standard.bool(forKey: "KhaytPaySheet") { recordingPayment = true }
        #endif
    }

    /// A revision landed: the quote's tools, its price and the list under
    /// the page read again.
    private func quoteRevised() async {
        quoteState = await api.quoteState(orderId: order.id)
        if let fresh = (try? await api.fetchRecentOrders(limit: 200, status: OrderStatus.quote.rawValue))?
            .first(where: { $0.id == order.id }) { quote = fresh }
        await onChanged()
    }

    /// Follow up on the quote: recorded in the book first, then WhatsApp
    /// opens with the shop's words, and the message goes in the customer's
    /// log — as the Mac's Follow up does.
    private func followUp() async {
        guard !followingUp else { return }
        followingUp = true
        defer { followingUp = false }
        do {
            let chat = try await api.followUpQuote(orderId: order.id)
            errorMessage = nil
            openURL(chat.url)
            await api.logWhatsApp(orderId: order.id, text: chat.text, milestone: nil, lang: nil)
            CompanionHaptics.success()
            quoteState = await api.quoteState(orderId: order.id)
            await onChanged()
        } catch {
            errorMessage = error.localizedDescription
            CompanionHaptics.warning()
        }
    }

    private func advance() async {
        guard let next = OrderStatus(rawValue: order.status)?.nextInQueue else { return }
        await setStatus(next.rawValue)
    }

    /// The customer's answer. Only from a quote: a second tap after the first
    /// has landed finds a pending or cancelled job and writes nothing.
    private func answerQuote(_ answer: QuoteAnswer) async {
        guard order.status == OrderStatus.quote.rawValue else { return }
        await setStatus(answer.status)
    }

    private func setStatus(_ status: String) async {
        // One write at a time: a double tap must not send two moves.
        guard status != order.status, !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        do {
            moveNotes = try await api.updateOrderStatus(orderId: order.id, status: status)
            CompanionHaptics.success()
            errorMessage = nil
            await refresh(status: status, machineId: order.machineId, machine: order.machine)
        } catch {
            errorMessage = error.localizedDescription
            CompanionHaptics.warning()
        }
    }

    private func assignMachine(_ machineId: String?) async {
        isUpdating = true
        defer { isUpdating = false }
        do {
            try await api.assignMachine(orderId: order.id, machineId: machineId)
            CompanionHaptics.success()
            errorMessage = nil
            let name = machines.first { $0.id == machineId }?.name
            await refresh(status: order.status, machineId: machineId, machine: machineId == nil ? nil : name)
        } catch {
            errorMessage = error.localizedDescription
            CompanionHaptics.warning()
        }
    }

    /// The written job, re-read from the queue when it is still in it. A job
    /// moved to Done leaves the queue, so the page keeps what it wrote rather
    /// than going blank under the person who just finished it.
    private func refresh(status: String, machineId: String?, machine: String?) async {
        await onChanged()
        if let fresh = (try? await api.fetchQueue())?.first(where: { $0.id == order.id }) {
            order = fresh
        } else {
            order = QueueOrder(id: order.id, project: order.project, client: order.client, status: status,
                               machine: machine, machineId: machineId, dueDate: order.dueDate,
                               priority: order.priority, jobNumber: order.jobNumber)
        }
    }
}

/// "Ship it": carrier and tracking number, for a finished job not yet sent.
struct ShipCard: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox.fill").foregroundStyle(KhaytDesign.brandV2)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("ship.open"))
                    .font(.khayt(14.5, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(KhaytDesign.ink)
                Text(L10n.tr("ship.open.sub"))
                    .font(.khayt(12, relativeTo: .caption))
                    .foregroundStyle(KhaytDesign.note)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward")
                .font(.caption).foregroundStyle(KhaytDesign.note)
        }
        .padding(14)
        .card()
    }
}

/// Call, WhatsApp or email the job's customer, straight from the job.
struct ContactCard: View {
    let client: Client
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(client.displayName)
                .font(.khayt(14.5, .semibold, relativeTo: .subheadline))
                .foregroundStyle(KhaytDesign.ink)
            HStack(spacing: 10) {
                if let dial = client.dialNumber, let url = URL(string: "tel:\(dial)") {
                    button(L10n.tr("clients.call"), "phone.fill") { openURL(url) }
                }
                if let wa = client.whatsappNumber, let url = URL(string: "https://wa.me/\(wa)") {
                    button(L10n.tr("clients.whatsapp"), "message.fill") { openURL(url) }
                }
                if let email = client.email, !email.isEmpty, let url = URL(string: "mailto:\(email)") {
                    button(L10n.tr("clients.email"), "envelope.fill") { openURL(url) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .card()
    }

    private func button(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.khayt(13.5, .semibold, relativeTo: .subheadline))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(KhaytDesign.brand)
                .background(KhaytDesign.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

/// The way into a job's invoice.
struct InvoiceCard: View {
    var proforma = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.fill").foregroundStyle(KhaytDesign.brandV2)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr(proforma ? "proforma.open" : "invoice.open"))
                    .font(.khayt(14.5, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(KhaytDesign.ink)
                Text(L10n.tr(proforma ? "proforma.open.sub" : "invoice.open.sub"))
                    .font(.khayt(12, relativeTo: .caption))
                    .foregroundStyle(KhaytDesign.note)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward")
                .font(.caption).foregroundStyle(KhaytDesign.note)
        }
        .padding(14)
        .card()
    }
}

/// What the page shows, apart from the page. Its own view so the layout can be
/// rendered and checked on its own — `ImageRenderer` draws no navigation stack.
struct OrderDetailContent: View {
    let order: QueueOrder
    var facts: OrderFacts? = nil
    /// The printer's live reading, while this job is printing on it.
    var live: MachineLiveStatus? = nil
    let isUpdating: Bool
    var machines: [MachineInfo] = []
    var errorMessage: String? = nil
    let onAdvance: () -> Void
    let onSetStatus: (String) -> Void
    var onAssignMachine: ((String?) -> Void)? = nil
    /// Set only while the job is a quote, by a page that has its record.
    var quote: OrderLogEntry? = nil
    var currency: String? = nil
    /// Approve or Decline. Nil draws neither — a rendering of the layout alone.
    var onAnswer: ((QuoteAnswer) -> Void)? = nil

    @State private var confirmingDecline = false

    private static let stages: [OrderStatus] = [.pending, .printing, .post, .qc, .completed]

    private var current: OrderStatus? { OrderStatus(rawValue: order.status) }
    private var isQuote: Bool { current == .quote }
    /// The stage's name. `cancelled` is not an `OrderStatus` — the phone only
    /// ever writes it as a quote's Decline — but it is a stage a page can show.
    private var stageName: String {
        current?.localizedLabel ?? (order.status == "cancelled" ? L10n.tr("status.cancelled") : order.status)
    }
    private var next: OrderStatus? { current?.nextInQueue }
    private var tone: Color { KhaytDesign.statusColor(for: order.status) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            fields
            if !isQuote { picker }
            if let errorMessage {
                Text(errorMessage)
                    .font(.khayt(12.5, relativeTo: .footnote))
                    .foregroundStyle(KhaytDesign.late)
            }
            if isQuote {
                if let onAnswer { answers(onAnswer).padding(.top, 6) }
            } else {
                action.padding(.top, 6)
            }
        }
        .padding(16)
    }

    // MARK: - Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(order.reference)
                    .font(.khaytMono(12, .medium))
                    .foregroundStyle(KhaytDesign.note)
                    .environment(\.layoutDirection, .leftToRight)
                // The redesign's pill: a dot in the stage colour, ink words.
                HStack(spacing: 5) {
                    Circle().fill(tone).frame(width: 6, height: 6)
                    Text(stageName)
                        .font(.khayt(12, .semibold, relativeTo: .caption))
                        .foregroundStyle(KhaytDesign.ink)
                }
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(tone.opacity(0.16), in: Capsule())
                if order.isRush { RushBadge() }
                if order.isOverdue {
                    Text(L10n.tr("orders.late"))
                        .font(.khayt(11, .bold, relativeTo: .caption2))
                        .khaytTracking(0.6)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .foregroundStyle(KhaytDesign.late)
                        .background(KhaytDesign.late.opacity(0.14), in: Capsule())
                }
            }
            .padding(.bottom, 11)
            Text(order.displayTitle)
                .font(.khaytDisplay(26, .semibold, relativeTo: .title))
                .tracking(-0.6)
                .foregroundStyle(KhaytDesign.ink)
            Text(order.displayClient)
                .font(.khayt(14.5, relativeTo: .subheadline))
                .foregroundStyle(KhaytDesign.note)
                .padding(.top, 6)
            if let live, live.isPrinting, let progress = live.progress {
                printProgress(live, progress)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(order.isOverdue ? KhaytDesign.late.opacity(0.7) : KhaytDesign.hairline, lineWidth: 1))
    }

    /// The design's print progress: the figure, a bar, and how long is left —
    /// or, for a print that has only just started, that there is no estimate
    /// yet. "— left" would be the same lie as a zero, one step quieter.
    private func printProgress(_ live: MachineLiveStatus, _ progress: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.tr("order.detail.print_progress").uppercased())
                    .font(.khayt(10.5, .bold, relativeTo: .caption2))
                    .khaytTracking(1.05)
                    .foregroundStyle(KhaytDesign.note)
                Spacer()
                Text("\(progress)%")
                    .font(.khayt(17, .semibold, relativeTo: .headline).monospacedDigit())
                    .foregroundStyle(KhaytDesign.ink)
                    .environment(\.layoutDirection, .leftToRight)
            }
            LevelBar(fraction: Double(min(100, max(0, progress))) / 100, color: KhaytDesign.thread, height: 7)
                .animation(.easeOut(duration: 0.45), value: progress)
            if let eta = live.etaLocalized, let done = live.finishesAt() {
                Text(L10n.format("machines.left_until", eta,
                            done.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale))))
                    .font(.khayt(12.5, relativeTo: .footnote).monospacedDigit())
                    .foregroundStyle(KhaytDesign.note)
            } else {
                Text(L10n.tr("order.detail.no_estimate"))
                    .font(.khayt(12.5, relativeTo: .footnote))
                    .foregroundStyle(KhaytDesign.note)
            }
        }
        .padding(.top, 18)
    }

    /// Due, Filament, Quantity, Printer, Client — the design's five, less any
    /// the phone does not know. A row with nothing in it is not drawn; a dash
    /// would say the job has no filament, which is not what the phone knows.
    private var fields: some View {
        VStack(spacing: 0) {
            if let quote {
                if let price = quote.price {
                    row(L10n.tr("order.new.price")) {
                        Text(Money.text(price, currency)).foregroundStyle(KhaytDesign.ink).monospacedDigit()
                    }
                    Divider().overlay(KhaytDesign.hairline)
                }
                if let made = DueDateParser.display(quote.date) {
                    row(L10n.tr("quote.field.made")) { Text(made).foregroundStyle(KhaytDesign.ink) }
                    Divider().overlay(KhaytDesign.hairline)
                }
                if let last = DueDateParser.display(quote.quoteExpiresAt) {
                    let expired = quote.isQuoteExpired()
                    row(L10n.tr("quote.field.valid_until")) {
                        Text(expired ? L10n.format("quote.expired_on", last) : last)
                            .foregroundStyle(expired ? KhaytDesign.late : KhaytDesign.ink)
                    }
                    Divider().overlay(KhaytDesign.hairline)
                }
            }
            if let due = order.formattedDueDate {
                row(L10n.tr("order.detail.due_date")) {
                    Text(due).foregroundStyle(order.isOverdue ? KhaytDesign.late : KhaytDesign.ink)
                }
                Divider().overlay(KhaytDesign.hairline)
            }
            if let material = facts?.material {
                row(L10n.tr("order.field.filament")) { Text(material).foregroundStyle(KhaytDesign.ink) }
                Divider().overlay(KhaytDesign.hairline)
            }
            if let quantity = facts?.quantity {
                row(L10n.tr("order.field.quantity")) {
                    Text("×\(quantity)").foregroundStyle(KhaytDesign.ink).environment(\.layoutDirection, .leftToRight)
                }
                Divider().overlay(KhaytDesign.hairline)
            }
            printerRow
            Divider().overlay(KhaytDesign.hairline)
            row(L10n.tr("field.client")) { Text(order.displayClient).foregroundStyle(KhaytDesign.ink) }
        }
        .background(KhaytDesign.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
    }

    @ViewBuilder
    private var printerRow: some View {
        if let onAssignMachine, !machines.isEmpty {
            Menu {
                Button { onAssignMachine(nil) } label: {
                    Label(L10n.tr("common.unassigned"), systemImage: order.machineId == nil ? "checkmark" : "circle")
                }
                ForEach(machines.filter { $0.isAssignable || $0.id == order.machineId }) { m in
                    Button { onAssignMachine(m.id) } label: {
                        Label(m.name ?? m.id, systemImage: order.machineId == m.id ? "checkmark" : "printer")
                    }
                }
            } label: {
                row(L10n.tr("order.detail.printer")) {
                    HStack(spacing: 6) {
                        Text(order.machine ?? "—").foregroundStyle(KhaytDesign.ink)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2).foregroundStyle(KhaytDesign.note)
                    }
                }
            }
            .disabled(isUpdating)
        } else {
            row(L10n.tr("order.detail.printer")) { Text(order.machine ?? "—").foregroundStyle(KhaytDesign.ink) }
        }
    }

    private func row<V: View>(_ label: String, @ViewBuilder value: () -> V) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.khayt(14, relativeTo: .subheadline))
                .foregroundStyle(KhaytDesign.note)
            Spacer(minLength: 12)
            value()
                .font(.khayt(14.5, .medium, relativeTo: .subheadline))
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }

    /// Any of the five stages, directly — for the job sent back from QC.
    private var picker: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(L10n.tr("pulse.move_to").uppercased())
                .font(.khayt(10.5, .bold, relativeTo: .caption2))
                .khaytTracking(1.05)
                .foregroundStyle(KhaytDesign.note)
                .padding(.horizontal, 2)
            StageStepper(stages: Self.stages, current: current, disabled: isUpdating) { onSetStatus($0.rawValue) }
        }
    }

    /// The one thing most people open this page to do: brand blue, whatever
    /// the stage — the design keeps colour for state, not for buttons.
    @ViewBuilder
    private var action: some View {
        if let next {
            Button(action: onAdvance) {
                HStack(spacing: 9) {
                    if isUpdating {
                        ProgressView().tint(KhaytDesign.onBrand)
                    } else {
                        Text(next == .completed ? L10n.tr("order.detail.mark_done")
                                                : L10n.format("order.detail.move_to", next.localizedLabel))
                        Image(systemName: "arrow.forward")
                    }
                }
                .font(.khayt(17, .semibold, relativeTo: .headline))
                .foregroundStyle(KhaytDesign.onBrand)
                .frame(maxWidth: .infinity, minHeight: 62)
                .background(KhaytDesign.brand, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(isUpdating)
        }
    }
}

extension OrderDetailContent {
    /// A quote's two answers. Approve is the page's one brand button, as
    /// "Move to" is on a job; Decline is quieter and asks first, because a
    /// declined quote leaves the list and its customer is not asked again.
    fileprivate func answers(_ onAnswer: @escaping (QuoteAnswer) -> Void) -> some View {
        VStack(spacing: 10) {
            Button { onAnswer(.approve) } label: {
                HStack(spacing: 9) {
                    if isUpdating {
                        ProgressView().tint(KhaytDesign.onBrand)
                    } else {
                        Text(L10n.tr("quote.approve"))
                        Image(systemName: "checkmark")
                    }
                }
                .font(.khayt(17, .semibold, relativeTo: .headline))
                .foregroundStyle(KhaytDesign.onBrand)
                .frame(maxWidth: .infinity, minHeight: 62)
                .background(KhaytDesign.brand, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(isUpdating)
            Button { confirmingDecline = true } label: {
                Text(L10n.tr("quote.decline"))
                    .font(.khayt(15.5, .semibold, relativeTo: .body))
                    .foregroundStyle(KhaytDesign.late)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(isUpdating)
            .confirmationDialog(L10n.tr("quote.decline_q"), isPresented: $confirmingDecline, titleVisibility: .visible) {
                Button(L10n.tr("quote.decline"), role: .destructive) { onAnswer(.decline) }
                Button(L10n.tr("common.cancel"), role: .cancel) {}
            } message: {
                Text(L10n.tr("quote.decline_body"))
            }
            Text(L10n.tr("quote.approve_note"))
                .font(.khayt(12, relativeTo: .caption))
                .foregroundStyle(KhaytDesign.note)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The redesign's stage track: the five stages as dots on one thread, the ones
/// behind the job filled, the job's own ringed in its colour. Any dot can be
/// tapped to put the job there directly — for the job sent back from QC.
private struct StageStepper: View {
    let stages: [OrderStatus]
    let current: OrderStatus?
    let disabled: Bool
    let onPick: (OrderStatus) -> Void

    private var at: Int { current.flatMap { stages.firstIndex(of: $0) } ?? -1 }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(stages.enumerated()), id: \.offset) { i, stage in
                step(i, stage)
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 6)
        .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
    }

    private func step(_ i: Int, _ stage: OrderStatus) -> some View {
        let on = i == at
        let passed = at >= 0 && i < at
        let tone = KhaytDesign.statusColor(for: (current ?? stage).rawValue)
        return Button { onPick(stage) } label: {
            VStack(spacing: 7) {
                ZStack {
                    // The thread either side of the dot, coloured up to the job.
                    HStack(spacing: 0) {
                        Rectangle().fill(i == 0 ? .clear : (i <= at ? tone : KhaytDesign.hairline))
                        Rectangle().fill(i == stages.count - 1 ? .clear : (i < at ? tone : KhaytDesign.hairline))
                    }
                    .frame(height: 2)
                    Circle()
                        .fill(on || passed ? tone : KhaytDesign.surface)
                        .frame(width: on ? 16 : 12, height: on ? 16 : 12)
                        .overlay(Circle().strokeBorder(on || passed ? tone : KhaytDesign.note.opacity(0.6), lineWidth: 1.5))
                        .background(Circle().fill(tone.opacity(on ? 0.25 : 0)).frame(width: 26, height: 26))
                }
                .frame(height: 26)
                Text(stage.localizedLabel)
                    .font(.khayt(11.5, on ? .semibold : .medium, relativeTo: .caption2))
                    .foregroundStyle(on ? KhaytDesign.ink : KhaytDesign.note)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled || on)
        .accessibilityLabel(stage.localizedLabel)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The Edit sheet's subject, identified for `.sheet(item:)`.
private struct RevisingQuote: Identifiable {
    let state: KhaytAPIClient.QuoteState
    var id: Int { state.version }
}

private struct EditingJob: Identifiable {
    let state: KhaytAPIClient.OrderEditState
    var id: String { "\(state.dueDate ?? "")|\(state.priorityLevel)|\(state.price)" }
}
