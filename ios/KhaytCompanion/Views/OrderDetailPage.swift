import SwiftUI
import KhaytCore

/// One job, as the 2026 redesign draws it (Figma R9W19Jakt19nKs1yM5GEde 38:93
/// light, 39:136 dark; the shared rules on 39:265 and the Mac's 90:865): a
/// PAGE pushed onto the stack, in six regions and in this order —
///
/// 1. the header: the job's name, `S-1041 · customer · due`, ONE stage pill
///    in its stage colour and, only when late, "N days late" beside it;
/// 2. the next step: ONE verb for this stage (`JobNextStep`), pinned at the
///    bottom above the tab bar so it is always in view, with More beside it
///    for everything else the page can do;
/// 3. the stage track: the five stages, tappable — for the job sent back
///    from QC;
/// 4. parts: what is being made, on which printer, and how far it is;
/// 5. money: Price, Paid and Owing — Owing red only when it is overdue;
/// 6. activity: shipping, the customer, the messages, the photos and the
///    shop's connectors.
///
/// A QUOTE has no stages to pick yet. Its next step is Approve; Decline sits
/// in More behind a confirmation, and its price and how long it stands are in
/// the money region when the Quotes list handed the record over.
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
    /// What the print drew from a metering plug, when one measured it.
    @State private var energy: JobEnergy?
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
    @State private var revising: RevisingQuote?
    @State private var showingHistory = false
    @State private var followingUp = false
    @State private var confirmingDecline = false
    /// For a held job, the stage Resume takes it back to.
    @State private var heldFrom: OrderStatus?
    @Environment(\.openURL) private var openURL

    init(order: QueueOrder, facts: OrderFacts?, quote: OrderLogEntry? = nil,
         onChanged: @escaping () async -> Void) {
        _order = State(initialValue: order)
        self.facts = facts
        _quote = State(initialValue: quote)
        self.onChanged = onChanged
    }

    private var isQuote: Bool { order.status == OrderStatus.quote.rawValue }
    private var isCancelled: Bool { order.status == "cancelled" }
    private var canShip: Bool { !(shipChoices ?? []).isEmpty }
    private var canRecordPayment: Bool { payment.map { $0.status != "paid" } ?? false }

    /// The page's one next step (`JobNextStep`).
    private var nextStep: JobNextStep? {
        JobNextStep.next(status: order.status, voided: order.voided,
                         owed: payment?.owed ?? 0, canHandOver: canShip, heldFrom: heldFrom)
    }

    /// Whether the activity region has anything to show.
    private var hasActivity: Bool {
        whatsApp != nil || canShip
            || (customer.map { $0.dialNumber != nil || !($0.email ?? "").isEmpty } ?? false)
            || api.holdsBook
            || photoAccess.map { $0 != .notPublished } ?? false
    }

    var body: some View {
        ScrollViewReader { scroller in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 1 · Header. Asked where the sale is, as on the Mac: a model
                // that may not be sold has a designer on the other end.
                OrderDetailHeader(order: order)
                if !saleProblems.isEmpty {
                    LicenceNote(problems: saleProblems)
                }
                // 2 · The next step is the bar pinned below (`nextBar`).
                // 3 · Stage track · 4 · Parts.
                OrderDetailContent(order: order, facts: facts,
                                   live: order.status == "printing" ? printers.reading(for: order.machineId) : nil,
                                   isUpdating: isUpdating, machines: machines,
                                   onSetStatus: { st in Task { await setStatus(st) } },
                                   onAssignMachine: { id in Task { await assignMachine(id) } })
                    // A viewer's cloud sign-in moves nothing (`ReadOnlyGate`).
                    .disabled(!api.canWrite)
                partsExtras
                // 5 · Money.
                moneyRegion
                // 6 · Activity.
                if hasActivity { activityRegion }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 20)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { nextBar }
        .sheet(isPresented: $recordingPayment) {
            if let payment {
                RecordPaymentSheet(orderId: order.id, state: payment, currency: currency) {
                    await loadPayment()
                    await onChanged()
                }
            }
        }
        .sheet(isPresented: $shipping) {
            if let shipChoices {
                ShipSheet(orderId: order.id, carriers: shipChoices) {
                    self.shipChoices = await api.shipChoices(orderId: order.id)
                }
            }
        }
        .sheet(isPresented: $writingWhatsApp, onDismiss: { Task { whatsApp = await api.whatsAppOffer(orderId: order.id) } }) {
            WhatsAppSheet(orderId: order.id)
        }
        .confirmationDialog(L10n.tr("quote.decline_q"), isPresented: $confirmingDecline, titleVisibility: .visible) {
            Button(L10n.tr("quote.decline"), role: .destructive) { Task { await answerQuote(.decline) } }
            Button(L10n.tr("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("quote.decline_body"))
        }
        .navigationDestination(isPresented: $showingInvoice) { InvoicePage(orderId: order.id) }
        .navigationDestination(isPresented: $showingProforma) { InvoicePage(orderId: order.id, proforma: true) }
        .navigationDestination(item: $paper) { ShopPaperPage(subject: $0) }
        .sheet(item: $revising) { r in
            // Revise is the Edit sheet with the quote's own terms below
            // (`EditOrderSheet`'s note).
            EditOrderSheet(orderId: order.id, start: r.edit, currency: currency, revising: r.state) {
                await quoteRevised()
            }
        }
        .sheet(isPresented: $showingHistory) {
            if let quoteState { QuoteHistorySheet(state: quoteState, currency: currency) }
        }
        .background(KhaytDesign.ground.ignoresSafeArea())
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if api.holdsBook, !isCancelled {
                    Button(L10n.tr("edit.title")) { Task { await startEditing() } }
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
            energy = api.jobEnergy(orderId: order.id)
            saleProblems = api.saleProblems(orderId: order.id)
            heldFrom = api.stageBeforeHold(orderId: order.id)
            if isQuote { quoteState = await api.quoteState(orderId: order.id) }
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
            // `-KhaytRevise YES` on a quote: its Revise sheet, for screenshots.
            if quoteState != nil, UserDefaults.standard.bool(forKey: "KhaytRevise") { await startRevising() }
            // `-KhaytScrollEnergy YES`: the energy card in view, for screenshots.
            // `-KhaytScrollConnectors YES`: the connectors card in view, for screenshots.
            if UserDefaults.standard.bool(forKey: "KhaytScrollConnectors") {
                try? await Task.sleep(for: .milliseconds(600))
                scroller.scrollTo("connectors", anchor: .center)
            }
            if energy != nil, UserDefaults.standard.bool(forKey: "KhaytScrollEnergy") {
                try? await Task.sleep(for: .milliseconds(300))
                scroller.scrollTo("energy", anchor: .center)
            }
            #endif
        }
        .watchesPrinters(when: order.status == "printing" && order.machineId != nil)
        }
    }

    // MARK: - 4 · Parts, the cards beside the parts card

    @ViewBuilder
    private var partsExtras: some View {
        // What the print drew from the wall, when a smart plug metered
        // enough of it. Nothing at all otherwise.
        if let energy {
            EnergyCard(energy: energy).id("energy")
        }
        // The finished print, as the Mac and the desktop keep it — the
        // printer's own snapshot at the end of a print among them.
        if !printPhotos.isEmpty || canAddPhoto {
            PrintPhotosCard(photos: printPhotos, add: canAddPhoto ? { jpeg in
                let reply = await api.addJobPhoto(orderId: order.id, jpeg: jpeg)
                printPhotos = api.printPhotos(orderId: order.id)
                return reply
            } : nil)
        }
        // The papers besides the invoice, from the book. A quote is not
        // work yet; a cancelled job is nothing to pack or make.
        if api.holdsBook, !isQuote, !isCancelled {
            JobPapersCard { kind in paper = .job(kind, orderId: order.id) }
        }
    }

    // MARK: - 5 · Money

    @ViewBuilder
    private var moneyRegion: some View {
        if payment != nil || (isQuote && quote != nil) {
            JobMoneyCard(order: order, payment: payment, quote: isQuote ? quote : nil, currency: currency,
                         onRecord: canRecordPayment && api.canWrite ? { recordingPayment = true } : nil)
        }
        if isQuote {
            Text(L10n.tr("quote.approve_note"))
                .font(.khayt(12, relativeTo: .caption))
                .foregroundStyle(KhaytDesign.note)
                .fixedSize(horizontal: false, vertical: true)
            if let quoteState {
                QuoteToolsCard(state: quoteState, followingUp: followingUp,
                               onRevise: { Task { await startRevising() } },
                               onFollowUp: { Task { await followUp() } },
                               onHistory: { showingHistory = true })
                    .disabled(!api.canWrite)
            } else if !api.holdsBook {
                // No LAN route revises or follows up a quote: say so, rather
                // than offer what this phone cannot do.
                V2Note(text: L10n.tr("quote.needs_book"), tone: KhaytDesign.note)
            }
        }
        // A quote or a cancelled job has no invoice; the page says why for
        // the rarer cases (waiting for approval, not numbered yet).
        if !isQuote, !isCancelled {
            Button { showingInvoice = true } label: { InvoiceCard() }
                .buttonStyle(.plain)
        }
        // Accepted, not yet finished: a proforma to ask for payment with.
        if BookReader.offersProforma(status: order.status) {
            Button { showingProforma = true } label: { InvoiceCard(proforma: true) }
                .buttonStyle(.plain)
        }
    }

    // MARK: - 6 · Activity

    private var activityRegion: some View {
        VStack(alignment: .leading, spacing: 16) {
            JobRegionTitle(text: L10n.tr("job.section.activity"))
            if canShip {
                Button { shipping = true } label: { ShipCard() }
                    .buttonStyle(.plain)
                    .disabled(!api.canWrite)
            }
            if let whatsApp {
                WhatsAppCard(offer: whatsApp) { writingWhatsApp = true }
            }
            if let customer, customer.dialNumber != nil || !(customer.email ?? "").isEmpty {
                ContactCard(client: customer)
            }
            // Only an order the Mac has published has a page to put a photo on.
            if let photoAccess, photoAccess != .notPublished {
                OrderPhotosCard(access: photoAccess)
            }
            // The customer's page: its link, and the messages on it.
            if case .ready(let token)? = photoAccess {
                PortalCard(token: token)
            } else if case .viewOnly(let token)? = photoAccess {
                PortalCard(token: token)
            }
            // The shop's connectors: their buttons for a job, and their own
            // fields on it (read-only). Nothing is drawn without one.
            if api.holdsBook {
                ConnectorsCard(place: .order(order.id), outer: EdgeInsets())
                    .id("connectors")
            }
        }
    }

    // MARK: - 2 · The next step, pinned

    /// "Next" and the verb, More for everything else, and the verb's button.
    /// Pinned above the tab bar so it never scrolls away. A step the phone
    /// may not take says why in a quiet line under it.
    private var nextBar: some View {
        JobNextBar(step: nextStep, stageDone: !isCancelled && !isQuote,
                   isUpdating: isUpdating, canWrite: api.canWrite,
                   refusal: errorMessage,
                   onPrimary: { runNextStep() }) {
            moreMenu
        }
    }

    /// Everything else the page can do, besides the one next step.
    @ViewBuilder
    private var moreMenu: some View {
        if isQuote {
            if quoteState != nil {
                Button { Task { await startRevising() } } label: { Label(L10n.tr("quote.revise"), systemImage: "pencil.and.list.clipboard") }
                    .disabled(!api.canWrite)
                Button { Task { await followUp() } } label: { Label(L10n.tr("quote.followup"), systemImage: "message") }
                    .disabled(!api.canWrite || followingUp)
                Button { showingHistory = true } label: { Label(L10n.tr("quote.history"), systemImage: "clock.arrow.circlepath") }
            }
            Button(role: .destructive) { confirmingDecline = true } label: { Label(L10n.tr("quote.decline"), systemImage: "xmark") }
                .disabled(!api.canWrite || isUpdating)
        }
        if canRecordPayment, nextStep != .recordPayment {
            Button { recordingPayment = true } label: { Label(L10n.tr("pay.modal_title"), systemImage: "banknote") }
                .disabled(!api.canWrite)
        }
        if canShip, nextStep != .handOver {
            Button { shipping = true } label: { Label(L10n.tr("ship.open"), systemImage: "shippingbox") }
                .disabled(!api.canWrite)
        }
        if whatsApp != nil {
            Button { writingWhatsApp = true } label: { Label(L10n.tr("wa.update"), systemImage: "message.fill") }
        }
        if !isQuote, !isCancelled {
            Button { showingInvoice = true } label: { Label(L10n.tr("invoice.open"), systemImage: "doc.text") }
        }
        if BookReader.offersProforma(status: order.status) {
            Button { showingProforma = true } label: { Label(L10n.tr("proforma.open"), systemImage: "doc.text.below.ecg") }
        }
        if api.holdsBook, !isQuote, !isCancelled {
            Menu {
                ForEach(KhaytEngine.ShopPaper.allCases, id: \.self) { kind in
                    Button(L10n.tr(PaperSubject.titleKey(kind))) { paper = .job(kind, orderId: order.id) }
                }
            } label: { Label(L10n.tr("paper.section"), systemImage: "doc.on.doc") }
        }
        if api.holdsBook, !isCancelled {
            Button { Task { await startEditing() } } label: { Label(L10n.tr("edit.title"), systemImage: "square.and.pencil") }
                .disabled(!api.canWrite)
        }
    }

    private func runNextStep() {
        switch nextStep {
        case .approveQuote?: Task { await answerQuote(.approve) }
        case .advance(let to)?, .resume(let to)?: Task { await setStatus(to.rawValue) }
        case .handOver?: shipping = true
        case .recordPayment?: recordingPayment = true
        case nil: break
        }
    }

    private func startEditing() async {
        editing = await api.editState(orderId: order.id)
    }

    private func loadPayment() async {
        currency = await api.orderCurrency(orderId: order.id)
        payment = await api.paymentState(orderId: order.id)
        #if DEBUG
        // `-KhaytPaySheet YES` with `-KhaytOpen order:<id>`: the sheet, for screenshots.
        if payment != nil, UserDefaults.standard.bool(forKey: "KhaytPaySheet") { recordingPayment = true }
        #endif
    }

    /// Open Revise on the quote as the book holds it now.
    private func startRevising() async {
        guard let state = quoteState, let edit = await api.editState(orderId: order.id) else { return }
        revising = RevisingQuote(state: state, edit: edit)
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
            var kept = QueueOrder(id: order.id, project: order.project, client: order.client, status: status,
                                  machine: machine, machineId: machineId, dueDate: order.dueDate,
                                  priority: order.priority, jobNumber: order.jobNumber)
            kept.voided = order.voided
            order = kept
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

/// A stage's look, by the shared rules: one pill in the stage's own colour.
enum JobStageLook {
    /// Waiting on someone else.
    static let steel = Color(light: 0x5E6C84, dark: 0xA9B8CF)
    static let steelWash = Color(light: 0xEDF0F4, dark: 0x3A4658)

    /// The pill's words and its wash: the stage's own colour
    /// (`KhaytDesign.statusColor` / `statusSoft`, where Printing is amber and
    /// On hold violet). A quote waits on the customer, so it is steel.
    static func pill(_ status: String) -> (text: Color, wash: Color) {
        if status == "quote" { return (steel, steelWash) }
        return (KhaytDesign.statusColor(for: status), KhaytDesign.statusSoft(for: status))
    }

    /// The stage track's thread colour, up to the job's stage.
    static func track(_ status: String) -> Color { KhaytDesign.statusColor(for: status) }

    static func name(_ status: String) -> String {
        OrderStatus(rawValue: status)?.localizedLabel ?? (status == "cancelled" ? L10n.tr("status.cancelled") : status)
    }
}

/// A region's small heading: "PARTS", "MONEY", "ACTIVITY".
struct JobRegionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.khayt(10.5, .bold, relativeTo: .caption2))
            .khaytTracking(1.05)
            .foregroundStyle(KhaytDesign.note)
            .padding(.horizontal, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// 1 · The header: the job's name, `S-1041 · customer · due`, ONE stage pill
/// in its stage colour, and "N days late" beside it only when late.
struct OrderDetailHeader: View {
    let order: QueueOrder
    var today = Date()

    private var line: String {
        var parts = [order.reference, order.displayClient]
        if let due = order.formattedDueDate { parts.append(L10n.format("job.header.due", due)) }
        return parts.joined(separator: " · ")
    }

    private var daysLate: Int? {
        order.isOverdue ? JobNextStep.daysLate(due: order.dueDate, today: today) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(order.displayTitle)
                .font(.khaytDisplay(28, .semibold, relativeTo: .largeTitle))
                .tracking(-0.6)
                .foregroundStyle(KhaytDesign.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(line)
                .font(.khayt(13.5, relativeTo: .subheadline))
                .foregroundStyle(KhaytDesign.note)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                let look = JobStageLook.pill(order.status)
                HStack(spacing: 6) {
                    Circle().fill(look.text).frame(width: 6, height: 6).accessibilityHidden(true)
                    Text(JobStageLook.name(order.status))
                        .font(.khayt(12.5, .semibold, relativeTo: .caption))
                        .foregroundStyle(look.text)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(look.wash, in: Capsule())
                .accessibilityElement(children: .combine)
                if let daysLate {
                    Text(daysLate == 1 ? L10n.tr("job.day_late") : L10n.format("job.days_late", daysLate))
                        .font(.khayt(12.5, .semibold, relativeTo: .caption))
                        .foregroundStyle(KhaytDesign.late)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(KhaytDesign.late.opacity(0.12), in: Capsule())
                }
                if order.isRush { RushBadge() }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }
}

/// 3 · The stage track and 4 · the parts card. Its own view so the layout can
/// be rendered and checked on its own — `ImageRenderer` draws no navigation
/// stack.
struct OrderDetailContent: View {
    let order: QueueOrder
    var facts: OrderFacts? = nil
    /// The printer's live reading, while this job is printing on it.
    var live: MachineLiveStatus? = nil
    let isUpdating: Bool
    var machines: [MachineInfo] = []
    let onSetStatus: (String) -> Void
    var onAssignMachine: ((String?) -> Void)? = nil

    private static let stages: [OrderStatus] = [.pending, .printing, .post, .qc, .completed]

    private var current: OrderStatus? { OrderStatus(rawValue: order.status) }
    private var isQuote: Bool { current == .quote }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !isQuote, order.status != "cancelled" {
                StageStepper(stages: Self.stages, current: current, disabled: isUpdating) { onSetStatus($0.rawValue) }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(L10n.tr("pulse.move_to"))
            }
            parts
        }
    }

    // MARK: - Parts

    private var parts: some View {
        VStack(alignment: .leading, spacing: 0) {
            JobRegionTitle(text: L10n.tr("job.section.parts"))
                .padding(.horizontal, 14).padding(.vertical, 12)
            Divider().overlay(KhaytDesign.hairline)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(order.displayTitle)
                        .font(.khayt(15.5, .semibold, relativeTo: .headline))
                        .foregroundStyle(KhaytDesign.ink)
                    if let quantity = facts?.quantity {
                        Text("×\(quantity)")
                            .font(.khayt(15.5, .semibold, relativeTo: .headline).monospacedDigit())
                            .foregroundStyle(KhaytDesign.ink)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
                if let material = facts?.material {
                    Text(material)
                        .font(.khayt(13, relativeTo: .footnote))
                        .foregroundStyle(KhaytDesign.note)
                }
                if let live, live.isPrinting, let progress = live.progress {
                    printProgress(live, progress)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider().overlay(KhaytDesign.hairline)
            printerRow
        }
        .background(KhaytDesign.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
    }

    /// The design's print progress: a thin amber bar, and the printer, the
    /// figure and how long is left — or, for a print that has only just
    /// started, that there is no estimate yet.
    private func printProgress(_ live: MachineLiveStatus, _ progress: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LevelBar(fraction: Double(min(100, max(0, progress))) / 100, color: KhaytDesign.thread, height: 4)
                .animation(.easeOut(duration: 0.45), value: progress)
                .accessibilityLabel(L10n.tr("order.detail.print_progress"))
                .accessibilityValue("\(progress)%")
            Text(progressLine(live, progress))
                .font(.khayt(12.5, .medium, relativeTo: .footnote).monospacedDigit())
                .foregroundStyle(KhaytDesign.attention)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    /// "On Bambu X1C · 28% · 2 h 8 m left · done at 14:20", or no estimate yet.
    private func progressLine(_ live: MachineLiveStatus, _ progress: Int) -> String {
        var parts: [String] = []
        if let machine = order.machine { parts.append(L10n.format("job.parts.on_machine", machine)) }
        parts.append("\(progress)%")
        if let eta = live.etaLocalized, let done = live.finishesAt() {
            parts.append(L10n.format("machines.left_until", eta,
                done.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale))))
        } else {
            parts.append(L10n.tr("order.detail.no_estimate"))
        }
        return parts.joined(separator: " · ")
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
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }
}

/// 5 · Money: Price, Paid, Owing. Owing is red only when it is overdue. A
/// quote shows its price, when it was made and how long it stands.
struct JobMoneyCard: View {
    let order: QueueOrder
    let payment: BookWriter.PaymentState?
    var quote: OrderLogEntry? = nil
    let currency: String?
    /// Record payment, when the job owes and the phone may write.
    var onRecord: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            JobRegionTitle(text: L10n.tr("job.section.money"))
                .padding(.horizontal, 14).padding(.vertical, 12)
            if let quote {
                if let price = quote.price {
                    line(L10n.tr("job.money.price")) { Text(Money.text(price, currency)).foregroundStyle(KhaytDesign.ink) }
                }
                if let made = DueDateParser.display(quote.date) {
                    line(L10n.tr("quote.field.made")) { Text(made).foregroundStyle(KhaytDesign.ink) }
                }
                if let sent = DueDateParser.display(quote.quoteSentAt) {
                    line(L10n.tr("job.money.quote_sent")) { Text(sent).foregroundStyle(KhaytDesign.ink) }
                }
                if let last = DueDateParser.display(quote.quoteExpiresAt) {
                    let expired = quote.isQuoteExpired()
                    line(L10n.tr("quote.field.valid_until")) {
                        Text(expired ? L10n.format("quote.expired_on", last) : last)
                            .foregroundStyle(expired ? KhaytDesign.late : KhaytDesign.ink)
                    }
                }
            } else if let payment {
                let overdue = JobNextStep.owingIsOverdue(owed: payment.owed, due: order.dueDate)
                line(L10n.tr("job.money.price")) { Text(Money.text(payment.billed, currency)).foregroundStyle(KhaytDesign.ink) }
                line(L10n.tr("job.money.paid")) {
                    Text(payment.paid > 0 ? "− " + Money.text(payment.paid, currency) : Money.text(0, currency))
                        .foregroundStyle(payment.paid > 0 ? KhaytDesign.done : KhaytDesign.ink)
                }
                line(overdue ? L10n.tr("job.money.owing_overdue") : L10n.tr("job.money.owing")) {
                    Text(Money.text(payment.owed, currency))
                        .fontWeight(.semibold)
                        .foregroundStyle(overdue ? KhaytDesign.late : KhaytDesign.ink)
                }
                if let onRecord {
                    Divider().overlay(KhaytDesign.hairline)
                    Button(action: onRecord) {
                        Text(L10n.tr("pay.modal_title"))
                            .font(.khayt(14.5, .semibold, relativeTo: .subheadline))
                            .foregroundStyle(KhaytDesign.brand)
                            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                            .padding(.horizontal, 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(KhaytDesign.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
    }

    private func line<V: View>(_ label: String, @ViewBuilder value: () -> V) -> some View {
        VStack(spacing: 0) {
            Divider().overlay(KhaytDesign.hairline)
            HStack(spacing: 12) {
                Text(label)
                    .font(.khayt(14.5, relativeTo: .subheadline))
                    .foregroundStyle(KhaytDesign.note)
                Spacer(minLength: 12)
                value()
                    .font(.khayt(14.5, .medium, relativeTo: .subheadline).monospacedDigit())
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 2 · The next step, pinned above the tab bar: "Next" and the verb, More,
/// and the verb's own button. With no next step it says the job is done (or
/// that there is nothing to do), and More stays.
struct JobNextBar<More: View>: View {
    let step: JobNextStep?
    /// A job past its stages (done and paid) rather than a cancelled one.
    let stageDone: Bool
    let isUpdating: Bool
    let canWrite: Bool
    /// The last write's refusal, said at the control.
    var refusal: String? = nil
    let onPrimary: () -> Void
    @ViewBuilder let more: () -> More

    @Environment(\.dynamicTypeSize) private var typeSize

    private var verb: String? {
        guard let step else { return nil }
        if case .advance(let to) = step, step.verbKey == "order.detail.move_to" {
            return L10n.format("order.detail.move_to", to.localizedLabel)
        }
        return L10n.tr(step.verbKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if verb == nil || !typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.tr("job.next"))
                            .font(.khayt(11.5, relativeTo: .caption))
                            .foregroundStyle(KhaytDesign.note)
                        Text(verb ?? L10n.tr(stageDone ? "job.next.done" : "job.next.none"))
                            .font(.khayt(15, .semibold, relativeTo: .subheadline))
                            .foregroundStyle(verb == nil && stageDone ? KhaytDesign.done : KhaytDesign.ink)
                            .lineLimit(2)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 4)
                }
                Menu { more() } label: {
                    Text(L10n.tr("job.more"))
                        .font(.khayt(15.5, .semibold, relativeTo: .body))
                        .foregroundStyle(KhaytDesign.ink)
                        .padding(.horizontal, 18)
                        .frame(minWidth: 44, minHeight: 50)
                        .background(KhaytDesign.sunk, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .accessibilityLabel(L10n.tr("job.more.label"))
                if let verb {
                    Button(action: onPrimary) {
                        ZStack {
                            if isUpdating { ProgressView().tint(KhaytDesign.onBrand) }
                            Text(verb).opacity(isUpdating ? 0 : 1)
                        }
                        .font(.khayt(15.5, .semibold, relativeTo: .body))
                        .foregroundStyle(KhaytDesign.onBrand)
                        .lineLimit(2).multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .frame(minWidth: 44, maxWidth: typeSize.isAccessibilitySize ? .infinity : nil, minHeight: 50)
                        .background(KhaytDesign.brand.opacity(canWrite ? 1 : 0.4),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isUpdating || !canWrite)
                    .accessibilityLabel(verb)
                }
            }
            // Anything that can refuse says why, quietly, at the control.
            if let refusal {
                Text(refusal)
                    .font(.khayt(12, relativeTo: .caption))
                    .foregroundStyle(KhaytDesign.late)
                    .fixedSize(horizontal: false, vertical: true)
            } else if step != nil, !canWrite {
                Text(L10n.tr("cloud.read_only.line"))
                    .font(.khayt(12, relativeTo: .caption))
                    .foregroundStyle(KhaytDesign.note)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KhaytDesign.surface.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
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
        let tone = JobStageLook.track((current ?? stage).rawValue)
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
    let edit: KhaytAPIClient.OrderEditState
    var id: Int { state.version }
}

private struct EditingJob: Identifiable {
    let state: KhaytAPIClient.OrderEditState
    var id: String { "\(state.dueDate ?? "")|\(state.priorityLevel)|\(state.price)" }
}
