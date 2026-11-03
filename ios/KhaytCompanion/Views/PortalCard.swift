import SwiftUI

/// The job's customer page on the job: share its link, and the messages on
/// it, answered from here.
struct PortalCard: View {
    let token: String
    @EnvironmentObject private var api: KhaytAPIClient
    @State private var messages: [PortalMessage]?
    @State private var reply = ""
    @State private var sending = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.tr("portal.title"))
                    .font(.khayt(14.5, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(KhaytDesign.ink)
                Spacer()
                if let link = api.customerLink(token: token) {
                    ShareLink(item: link) { Label(L10n.tr("portal.share"), systemImage: "square.and.arrow.up") }
                        .font(.khayt(13, .semibold, relativeTo: .footnote))
                }
            }
            if let messages {
                if messages.isEmpty {
                    Text(L10n.tr("portal.none")).font(.khayt(12.5, relativeTo: .footnote)).foregroundStyle(KhaytDesign.note)
                }
                ForEach(messages.suffix(8)) { m in
                    HStack {
                        if !m.fromCustomer { Spacer(minLength: 40) }
                        Text(m.text)
                            .font(.khayt(13.5, relativeTo: .footnote))
                            .foregroundStyle(KhaytDesign.ink)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background((m.fromCustomer ? KhaytDesign.sunk : KhaytDesign.brand.opacity(0.12)),
                                        in: RoundedRectangle(cornerRadius: 10))
                        if m.fromCustomer { Spacer(minLength: 40) }
                    }
                }
                if api.cloud?.canWrite == true {
                    HStack {
                        TextField(L10n.tr("portal.reply"), text: $reply, axis: .vertical)
                            .lineLimit(1...4)
                            .font(.khayt(14, relativeTo: .body))
                        Button { Task { await send() } } label: {
                            if sending { ProgressView() } else { Image(systemName: "paperplane.fill") }
                        }
                        .disabled(sending || reply.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityLabel(L10n.tr("portal.send"))
                    }
                }
            } else if problem == nil {
                ProgressView()
            }
            if let problem {
                Text(problem).font(.khayt(12, relativeTo: .caption)).foregroundStyle(KhaytDesign.late)
            }
        }
        .padding(14)
        .card()
        .task { await load() }
    }

    private func load() async {
        do { messages = try await api.portalMessages(token: token); problem = nil }
        catch { problem = error.localizedDescription }
    }

    private func send() async {
        sending = true
        defer { sending = false }
        do {
            try await api.replyOnPortal(token: token, text: reply)
            reply = ""
            CompanionHaptics.success()
            await load()
        } catch {
            problem = error.localizedDescription
            CompanionHaptics.warning()
        }
    }
}
