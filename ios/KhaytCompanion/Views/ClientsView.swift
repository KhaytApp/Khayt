import SwiftUI

/// Read-only client directory with one-tap call / WhatsApp / email.
struct ClientsView: View {
    @EnvironmentObject private var api: KhaytAPIClient

    @State private var clients: [Client] = []
    @State private var searchText = ""
    @State private var errorMessage: String?
    @State private var didLoad = false

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
            VStack(spacing: 0) {
                KhaytSearchField(text: $searchText, prompt: L10n.tr("clients.search"))
                    .padding(.horizontal, KhaytDesign.pad)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                content
            }
            .khaytScreen(title: L10n.tr("tab.clients"))
            .task {
                await load()
                didLoad = true
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if clients.isEmpty && !didLoad && errorMessage == nil {
            Spacer(); ProgressView(); Spacer()
        } else if displayed.isEmpty {
            ContentUnavailableView(
                clients.isEmpty ? L10n.tr("clients.none") : L10n.tr("clients.no_match"),
                systemImage: "person.2",
                description: Text(errorMessage ?? (searchText.isEmpty ? L10n.tr("clients.none.sub") : String(format: L10n.tr("clients.no_match.sub"), searchText)))
            )
        } else {
            List(displayed) { client in
                ClientRow(client: client)
                    .listRowBackground(KhaytDesign.surface)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .refreshable { await load() }
        }
    }

    private func load() async {
        errorMessage = nil
        do {
            clients = try await api.fetchClients()
        } catch {
            clients = []
            errorMessage = error.localizedDescription
        }
    }
}

private struct ClientRow: View {
    let client: Client

    private var initials: String {
        let words = client.displayName.split(separator: " ").prefix(2)
        let chars = words.compactMap { $0.first }
        return chars.isEmpty ? "?" : String(chars).uppercased()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(initials)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(KhaytDesign.brand)
                .frame(width: 40, height: 40)
                .background(KhaytDesign.brand.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(client.displayName)
                    .font(.headline)
                    .foregroundStyle(KhaytDesign.text)
                if let secondary = client.secondaryName {
                    Text(secondary)
                        .font(.subheadline)
                        .foregroundStyle(KhaytDesign.textDim)
                }
                if let phone = client.phone, !phone.isEmpty {
                    Text(phone)
                        .font(.caption)
                        .foregroundStyle(KhaytDesign.textMuted)
                } else if let email = client.email, !email.isEmpty {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(KhaytDesign.textMuted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                if let dial = client.dialNumber, let url = URL(string: "tel:\(dial)") {
                    contactButton("phone.fill", url, KhaytDesign.ok)
                }
                if let wa = client.whatsappNumber, let url = URL(string: "https://wa.me/\(wa)") {
                    contactButton("message.fill", url, KhaytDesign.brand)
                }
                if let email = client.email, !email.isEmpty, let url = URL(string: "mailto:\(email)") {
                    contactButton("envelope.fill", url, KhaytDesign.textDim)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func contactButton(_ icon: String, _ url: URL, _ color: Color) -> some View {
        Link(destination: url) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.14), in: Circle())
        }
        .buttonStyle(.plain)
    }
}
