import Foundation
import KhaytCore

/// The customer's page for a job, from the owner's side: its link to share,
/// and the messages on it — read, and answered — through Khayt Cloud's owner
/// routes ("Customer pages" in khayt-cloud's contract):
/// `GET /v1/shops/{id}/published/{token}/messages` and
/// `POST /v1/shops/{id}/published/{token}/message {text}` (write role).
struct PortalMessage: Decodable, Identifiable, Equatable, Sendable {
    let from: String
    let text: String
    let at: String
    var id: String { at + from + String(text.prefix(16)) }
    var fromCustomer: Bool { from == "customer" }
}

extension KhaytAPIClient {

    /// The page's public link, `/p/{token}` on the cloud's own address.
    func customerLink(token: String) -> URL? {
        guard let cloud, var root = URL(string: cloud.url)?.absoluteString, root.hasPrefix("https://") else { return nil }
        while root.hasSuffix("/") { root.removeLast() }
        return URL(string: root + "/p/" + Self.segment(token))
    }

    func portalMessages(token: String) async throws -> [PortalMessage] {
        guard let cloud else { throw KhaytAPIError.server(L10n.tr("cloud.signed_out")) }
        let request = try CloudReader.request(
            CloudReader.Connection(url: cloud.url, shopId: cloud.shopId, storedToken: ""),
            token: cloud.token, method: "GET", tail: "/published/" + Self.segment(token) + "/messages")
        let (data, response) = try await CloudReader.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw KhaytAPIError.server(L10n.tr("portal.messages.failed"))
        }
        struct Reply: Decodable { let messages: [PortalMessage]? }
        return ((try JSONDecoder().decode(Reply.self, from: data)).messages ?? []).sorted { $0.at < $1.at }
    }

    func replyOnPortal(token: String, text: String) async throws {
        guard let cloud else { throw KhaytAPIError.server(L10n.tr("cloud.signed_out")) }
        guard cloud.canWrite else { throw KhaytAPIError.server(L10n.tr("portal.reply.viewer")) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var request = try CloudReader.request(
            CloudReader.Connection(url: cloud.url, shopId: cloud.shopId, storedToken: ""),
            token: cloud.token, method: "POST", tail: "/published/" + Self.segment(token) + "/message")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["text": String(trimmed.prefix(2000))])
        let (_, response) = try await CloudReader.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw KhaytAPIError.server(L10n.tr("portal.reply.failed"))
        }
    }
}
