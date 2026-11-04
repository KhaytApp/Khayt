import SwiftUI

/// One customer: how to reach them, what they owe against their limit and
/// terms, their jobs, what they have agreed to pay, and the messages sent
/// them — the Mac's customer page, read from the phone's book.
struct CustomerPage: View {
    let client: Client

    @EnvironmentObject private var api: KhaytAPIClient
    @State private var summary: CustomerSummary?
    @State private var loaded = false
    @State private var openOrder: QueueOrder?
    @State private var newOrder = false
    @State private var machines: [MachineInfo] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                identity
                if client.dialNumber != nil || !(client.email ?? "").isEmpty {
                    ContactCard(client: client)
                }
                if let s = summary {
                    money(s)
                    jobs(L10n.tr("customer.open"), s.openJobs, empty: L10n.tr("customer.open.none"))
                    if !s.agreements.isEmpty { agreements(s) }
                    jobs(L10n.tr("customer.history"), s.finishedJobs, empty: L10n.tr("customer.history.none"))
                    if s.historyWindowed {
                        Text(L10n.tr("customer.history.window"))
                            .font(.khayt(12, relativeTo: .caption)).foregroundStyle(KhaytDesign.note)
                    }
                    messages(s)
                } else if loaded {
                    Text(L10n.tr("customer.needs_book"))
                        .font(.khayt(13, relativeTo: .footnote)).foregroundStyle(KhaytDesign.note)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
                }
            }
            .padding(16)
        }
        .background(KhaytDesign.ground.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        if machines.isEmpty { machines = (try? await api.fetchMachines()) ?? [] }
                        newOrder = true
                    }
                } label: { Image(systemName: "plus") }
                .accessibilityLabel(L10n.tr("customer.new_order"))
            }
        }
        .sheet(isPresented: $newOrder) {
            NewOrderSheet(machines: machines, onCreated: { Task { await load() } }, initial: draft)
        }
        .navigationDestination(item: $openOrder) { order in
            OrderDetailPage(order: order, facts: nil) { await load() }
        }
    }

    /// A new job already made out to this customer, linked by id so the
    /// book never has to guess from the name.
    private var draft: NewOrderDraft {
        var d = NewOrderDraft()
        d.client = client.displayName
        d.clientId = client.id
        return d
    }

    private func load() async {
        summary = await api.fetchCustomer(id: client.id)
        loaded = true
    }

    /// The redesign's header: the customer's initials large, the name in
    /// the display face.
    private var identity: some View {
        VStack(spacing: 10) {
            Text(Initials.of(client.displayName))
                .font(.khaytDisplay(24, .bold, relativeTo: .title2))
                .foregroundStyle(KhaytDesign.brand)
                .frame(width: 76, height: 76)
                .background(KhaytDesign.brand.opacity(0.16), in: Circle())
                .accessibilityHidden(true)
            Text(client.displayName)
                .font(.khaytDisplay(26, .bold, relativeTo: .title))
                .tracking(-0.6)
                .foregroundStyle(KhaytDesign.ink)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private func header(_ text: String) -> some View {
        Text(L10n.usesArabicLayout ? text : text.uppercased())
            .font(L10n.usesArabicLayout ? .khayt(11, .bold, relativeTo: .caption2) : .khaytMono(10.5, .medium, relativeTo: .caption2))
            .khaytTracking(0.8)
            .foregroundStyle(KhaytDesign.note)
    }

    private func money(_ s: CustomerSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(L10n.tr("customer.owes"))
            Text(Money.text(s.owed, s.currency))
                .font(.khaytDisplay(34, .bold, relativeTo: .title).monospacedDigit())
                .tracking(-0.8)
                .foregroundStyle(s.isOverLimit ? KhaytDesign.late : (s.owed > 0.005 ? KhaytDesign.attention : KhaytDesign.done))
            if s.creditLimit > 0 {
                Text(L10n.format(s.isOverLimit ? "customer.over_limit" : "customer.limit",
                                 Money.text(s.creditLimit, s.currency)))
                    .font(.khayt(12.5, relativeTo: .footnote))
                    .foregroundStyle(s.isOverLimit ? KhaytDesign.late : KhaytDesign.note)
            }
            Text(s.paymentTermsDays > 0 ? L10n.format("customer.terms", s.paymentTermsDays)
                                        : L10n.tr("customer.terms.receipt"))
                .font(.khayt(12.5, relativeTo: .footnote)).foregroundStyle(KhaytDesign.note)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        // Outlined in red when the customer is over their limit, as the
        // redesign draws a debt that needs chasing.
        .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(s.isOverLimit ? KhaytDesign.late.opacity(0.7) : KhaytDesign.hairline, lineWidth: 1))
    }

    private func jobs(_ title: String, _ list: [CustomerSummary.Job], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(title).padding(.bottom, 6)
            if list.isEmpty {
                Text(empty).font(.khayt(13, relativeTo: .footnote)).foregroundStyle(KhaytDesign.note)
            }
            ForEach(list) { job in
                Button { Task { openOrder = await order(job.id) } } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.title).font(.khayt(14.5, .medium, relativeTo: .body)).foregroundStyle(KhaytDesign.ink)
                            Text([OrderStatus(rawValue: job.status)?.localizedLabel ?? job.status,
                                  job.dueDate ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.khayt(12, relativeTo: .caption)).foregroundStyle(KhaytDesign.note)
                        }
                        Spacer()
                        if job.owed > 0.005 {
                            Text(Money.text(job.owed, summary?.currency))
                                .font(.khayt(13.5, .medium, relativeTo: .footnote).monospacedDigit())
                                .foregroundStyle(KhaytDesign.attention)
                        }
                    }
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .bottom) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
            }
        }
    }

    private func agreements(_ s: CustomerSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(L10n.tr("customer.agreed")).padding(.bottom, 6)
            ForEach(Array(s.agreements.enumerated()), id: \.offset) { _, a in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.product).font(.khayt(14, .medium, relativeTo: .body)).foregroundStyle(KhaytDesign.ink)
                        if !a.note.isEmpty {
                            Text(a.note).font(.khayt(12, relativeTo: .caption)).foregroundStyle(KhaytDesign.note)
                        }
                    }
                    Spacer()
                    Text(Money.text(a.price, s.currency))
                        .font(.khayt(13.5, .medium, relativeTo: .footnote).monospacedDigit())
                        .foregroundStyle(KhaytDesign.ink)
                }
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
            }
        }
    }

    private func messages(_ s: CustomerSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(L10n.tr("customer.messages")).padding(.bottom, 6)
            if s.messages.isEmpty {
                Text(L10n.tr("customer.messages.none")).font(.khayt(13, relativeTo: .footnote)).foregroundStyle(KhaytDesign.note)
            }
            ForEach(s.messages) { m in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: icon(m.kind)).font(.caption).foregroundStyle(KhaytDesign.note)
                        // The message's day as the book stamps it (yyyy-MM-dd): a
                        // date string, not a number to format.
                        Text(verbatim: String(m.at.prefix(10))).font(.khaytMono(11, .regular, relativeTo: .caption2))
                            .foregroundStyle(KhaytDesign.note)
                        if let order = m.orderId {
                            Text(order).font(.khayt(11.5, relativeTo: .caption2)).foregroundStyle(KhaytDesign.note)
                        }
                    }
                    Text(m.note).font(.khayt(13.5, relativeTo: .footnote)).foregroundStyle(KhaytDesign.ink)
                        .lineLimit(4)
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
            }
        }
    }

    private func icon(_ kind: String) -> String {
        switch kind {
        case "whatsapp": return "message.fill"
        case "call": return "phone.fill"
        case "email": return "envelope.fill"
        case "meeting": return "person.2.fill"
        default: return "note.text"
        }
    }

    private func order(_ id: String) async -> QueueOrder? {
        if let open = (try? await api.fetchQueue())?.first(where: { $0.id == id }) { return open }
        if let done = (try? await api.fetchRecentOrders(limit: 200))?.first(where: { $0.id == id }) {
            return QueueOrder(entry: done)
        }
        return nil
    }
}
