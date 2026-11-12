import SwiftUI

/// "Who owes": the open jobs behind Home's Owed figure, most owed first.
/// Each opens its job (Record payment is there) or sends the customer a
/// WhatsApp reminder, logged to the customer like any other message.
struct OwedView: View {
    @EnvironmentObject private var api: KhaytAPIClient
    @Environment(\.openURL) private var openURL
    @State private var lines: [OwedLine]?
    @State private var currency: String?
    @State private var openOrder: QueueOrder?
    @State private var problem: String?
    /// The book could not be read: say so, never "Nothing is owed" (F3).
    @State private var unreadable = false

    private var total: Double { (lines ?? []).reduce(0) { $0 + $1.owed } }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if unreadable {
                    LoadFailedView(message: L10n.tr("load.book_unavailable")) { await load() }
                } else if let lines {
                    if lines.isEmpty {
                        Text(L10n.tr("owed.empty"))
                            .font(.khayt(15, .semibold, relativeTo: .headline))
                            .foregroundStyle(KhaytDesign.note)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else {
                        Text(L10n.format("owed.total", Money.text(total, currency), lines.count))
                            .font(.khayt(13, relativeTo: .footnote))
                            .foregroundStyle(KhaytDesign.note)
                            .padding(.horizontal, 4)
                        ForEach(lines) { row($0) }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(16)
        }
        .background(KhaytDesign.ground.ignoresSafeArea())
        .navigationTitle(L10n.tr("owed.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .navigationDestination(item: $openOrder) { order in
            OrderDetailPage(order: order, facts: nil) { await load() }
        }
        .alert(problem ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button(L10n.tr("common.close"), role: .cancel) {}
        }
    }

    private func load() async {
        currency = await api.shopCurrency()
        if let read = await api.fetchOwing() {
            lines = read
            unreadable = false
        } else {
            unreadable = true
        }
    }

    /// The job behind a line: every owed job is open, so it is in the queue.
    private func order(_ id: String) async -> QueueOrder? {
        (try? await api.fetchQueue())?.first { $0.id == id }
    }

    private func row(_ line: OwedLine) -> some View {
        HStack(spacing: 12) {
            Button { Task { openOrder = await order(line.id) } } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(line.project.isEmpty ? (line.reference.isEmpty ? line.id : line.reference) : line.project)
                        .font(.khayt(15, .semibold, relativeTo: .body))
                        .foregroundStyle(KhaytDesign.ink)
                    Text([line.client, line.dueDate.map { L10n.format("owed.due", $0) } ?? ""]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.khayt(12.5, relativeTo: .footnote))
                        .foregroundStyle(KhaytDesign.note)
                    Text(Money.text(line.owed, currency))
                        .font(.khayt(16, .semibold, relativeTo: .body).monospacedDigit())
                        .foregroundStyle(KhaytDesign.attention)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { Task { await remind(line) } } label: {
                Label(L10n.tr("owed.remind"), systemImage: "message.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 17))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(KhaytDesign.done)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.format("owed.remind.a11y", line.client.isEmpty ? line.project : line.client))
        }
        .padding(14)
        .background(KhaytDesign.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(KhaytDesign.hairline, lineWidth: 1))
    }

    /// The reminder, in the shop's words, through the shared WhatsApp rule —
    /// then written to the customer's message log, as every send is.
    private func remind(_ line: OwedLine) async {
        let text = L10n.format("owed.remind.text", line.project.isEmpty ? (line.reference.isEmpty ? line.id : line.reference) : line.project,
                               Money.text(line.owed, currency))
        let (url, reason) = await api.whatsAppLink(orderId: line.id, text: text)
        guard let url else {
            problem = L10n.tr(reason == "no_customer" ? "owed.remind.no_customer" : "owed.remind.no_phone")
            return
        }
        openURL(url)
        await api.logWhatsApp(orderId: line.id, text: text, milestone: nil, lang: nil)
    }
}
