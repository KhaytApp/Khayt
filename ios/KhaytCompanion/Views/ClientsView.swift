import SwiftUI

/// Read-only client directory with one-tap call / WhatsApp / email.
struct ClientsView: View {
    @EnvironmentObject private var api: KhaytAPIClient

    @State private var clients: [Client] = []
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var didLoad = false
    @State private var openByName: [String: Int] = [:]
    /// Every order per client — nil unless the phone holds the whole history,
    /// in which case the screen says "On the Mac" instead of a short count.
    @State private var totalsByName: [String: Int]?
    @State private var contactFor: Client?
    @Environment(\.openURL) private var openURL

    private var displayed: [Client] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let list = q.isEmpty ? clients : clients.filter {
            $0.displayName.lowercased().contains(q)
                || ($0.nameAr ?? "").lowercased().contains(q)
                || ($0.phone ?? "").contains(q)
                || ($0.email ?? "").lowercased().contains(q)
        }
        return list.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    KhaytSearchField(text: $searchText, prompt: L10n.tr("clients.search"))
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 10)
                    content
                    if api.holdsAll("clients"), !clients.isEmpty {
                        windowLine
                    }
                }
                .padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .refreshable { await load() }
            .khaytScreen(title: L10n.tr("tab.clients"))
            .background(KhaytDesign.ground.ignoresSafeArea())
            .task {
                await load()
                didLoad = true
            }
            .confirmationDialog(contactFor?.displayName ?? "", isPresented: contactShown, titleVisibility: .visible,
                                presenting: contactFor) { client in
                if let dial = client.dialNumber, let url = URL(string: "tel:\(dial)") {
                    Button(L10n.tr("clients.call")) { openURL(url) }
                }
                if let wa = client.whatsappNumber, let url = URL(string: "https://wa.me/\(wa)") {
                    Button(L10n.tr("clients.whatsapp")) { openURL(url) }
                }
                if let email = client.email, !email.isEmpty, let url = URL(string: "mailto:\(email)") {
                    Button(L10n.tr("clients.email")) { openURL(url) }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if clients.isEmpty && !didLoad && errorMessage == nil {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 44)
        } else if displayed.isEmpty {
            VStack(spacing: 5) {
                Text(clients.isEmpty ? L10n.tr("clients.none") : L10n.tr("clients.no_match"))
                    .font(.khayt(15, .semibold, relativeTo: .headline))
                    .foregroundStyle(KhaytDesign.ink)
                Text(errorMessage ?? (searchText.isEmpty ? L10n.tr("clients.none.sub")
                                      : String(format: L10n.tr("clients.no_match.sub"), searchText)))
                    .font(.khayt(13, relativeTo: .footnote))
                    .foregroundStyle(KhaytDesign.note)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 44).padding(.horizontal, 16)
        } else {
            LazyVStack(spacing: 8) {
                ForEach(displayed) { client in
                    Button { if client.canBeContacted { contactFor = client } } label: {
                        ClientRow(client: client, open: count(openByName, client),
                                  total: totalsByName.map { count($0, client) })
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// The design's closing line. Every client travels; their totals only when
    /// the whole order history did too.
    private var windowLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(format: L10n.tr("clients.window.count"), clients.count.formatted()))
                .font(.khayt(12.5, .semibold, relativeTo: .footnote).monospacedDigit())
                .foregroundStyle(KhaytDesign.ink)
            if totalsByName == nil {
                Text(L10n.tr("clients.window.body"))
                    .font(.khayt(12, relativeTo: .caption))
                    .foregroundStyle(KhaytDesign.note)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 14)
        .overlay(alignment: .top) { Rectangle().fill(KhaytDesign.hairline).frame(height: 1) }
        .padding(.horizontal, 16)
        .padding(.top, 18)
    }

    private var contactShown: Binding<Bool> {
        Binding(get: { contactFor != nil }, set: { if !$0 { contactFor = nil } })
    }

    /// Orders name their client by name, in whichever language it was typed —
    /// so a client is matched under both of theirs.
    private func count(_ table: [String: Int], _ client: Client) -> Int {
        let names = Set([client.displayName, client.secondaryName].compactMap { $0 })
        return names.reduce(0) { $0 + (table[$1] ?? 0) }
    }

    private func load() async {
        errorMessage = nil
        do {
            clients = try await api.fetchClients()
            let queue = (try? await api.fetchQueue()) ?? []
            openByName = Dictionary(grouping: queue.compactMap(\.client), by: { $0 }).mapValues(\.count)
            if api.holdsAll("printLog") {
                let all = (try? await api.fetchRecentOrders(limit: 1_000_000)) ?? []
                totalsByName = Dictionary(grouping: all.compactMap(\.client), by: { $0 }).mapValues(\.count)
            } else {
                totalsByName = nil
            }
        } catch {
            clients = []
            errorMessage = error.localizedDescription
        }
    }
}

/// A client, as `design/ios-v2/` draws one: an initial, the name, how many of
/// their jobs are open — and, at the end, every order they have placed, or a
/// deferred dash when the phone holds only the newest history.
private struct ClientRow: View {
    let client: Client
    let open: Int
    let total: Int?

    private var initial: String {
        client.displayName.first.map { String($0).uppercased() } ?? "?"
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(initial)
                .font(.khayt(15, .semibold, relativeTo: .body))
                .foregroundStyle(KhaytDesign.note)
                .frame(width: 38, height: 38)
                .background(KhaytDesign.sunk, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(client.displayName)
                    .font(.khayt(15, .medium, relativeTo: .body))
                    .foregroundStyle(KhaytDesign.ink)
                    .lineLimit(1)
                Text(String(format: L10n.tr("clients.open"), open.formatted()))
                    .font(.khayt(12.5, relativeTo: .footnote))
                    .foregroundStyle(KhaytDesign.note)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(total.map { $0.formatted() } ?? "—")
                    .font(.khayt(15, .semibold, relativeTo: .body).monospacedDigit())
                    .foregroundStyle(total == nil ? KhaytDesign.note : KhaytDesign.ink)
                Text(L10n.tr(total == nil ? "pulse.on_the_mac" : "clients.orders"))
                    .font(.khayt(10.5, relativeTo: .caption2))
                    .foregroundStyle(KhaytDesign.note)
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .card(radius: 11)
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .combine)
    }
}

private extension Client {
    var canBeContacted: Bool {
        dialNumber != nil || whatsappNumber != nil || !(email ?? "").isEmpty
    }
}
