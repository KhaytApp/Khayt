import Foundation
import KhaytCore

/// One line in the Notifications screen.
struct FeedItem: Codable, Identifiable, Equatable, Sendable {
    enum Tone: String, Codable, Sendable { case late, attention, done, none }

    var id: String
    var kind: String
    var title: String
    var at: Date
    var tone: Tone
    var unread: Bool
    /// The job it is about, when there is one — tapping opens it.
    var orderId: String?
}

/// Everything this phone has been told about the shop, newest first — the
/// design's Notifications screen.
///
/// ── WHERE IT COMES FROM ─────────────────────────────────────────────────
///
/// Three places, into one list: the alerts the phone raises itself (a print
/// ending, a job going late, filament running low, the shop going out of
/// reach), the shop events Khayt Cloud relays while the app is open (a print
/// ending, a customer's order request), and — when the screen opens — the
/// cloud's own record of the last day's events, so an alert that came while
/// the phone was off is here too. Each has an id, and an id is listed once.
///
/// Kept on this phone only, and only the last hundred: it is a list of what
/// happened, not a record anyone reconciles against.
@MainActor
final class ShopFeed: ObservableObject {
    static let shared = ShopFeed()

    @Published private(set) var items: [FeedItem] = []
    var unreadCount: Int { items.filter(\.unread).count }

    static let cap = 100
    private let url: URL?

    init(url: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "khayt-feed.json")) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([FeedItem].self, from: data) {
            items = saved
        }
    }

    func add(_ item: FeedItem) {
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.append(item)
        items.sort { $0.at > $1.at }
        if items.count > Self.cap { items.removeLast(items.count - Self.cap) }
        save()
    }

    func markAllRead() {
        guard items.contains(where: \.unread) else { return }
        for i in items.indices { items[i].unread = false }
        save()
    }

    private func save() {
        guard let url, let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: - From shop events

    /// A shop event as a line: a print ending (opened with the shop's key) or
    /// a customer's order request (which carries nothing to open). Nil for a
    /// kind this phone does not describe yet, or one it cannot open.
    nonisolated static func item(eventId: String, kind: String, at: String, ciphertext: Data?,
                                 dek: Data?, tr: (String) -> String) -> FeedItem? {
        let when = ISO8601DateFormatter().date(from: at) ?? Date()
        switch kind {
        case "intake":
            return FeedItem(id: eventId, kind: kind, title: tr("PUSH_INTAKE"), at: when, tone: .attention,
                            unread: true, orderId: nil)
        case "print-finished":
            guard let ciphertext, let dek,
                  let event = PrintAlertCenter.open(kind: kind, ciphertext: ciphertext, dek: dek) else { return nil }
            return item(for: event, id: eventId, tr: tr)
        default:
            return nil
        }
    }

    nonisolated static func item(for event: PrintFinished, id: String, tr: (String) -> String) -> FeedItem {
        let content = PrintAlertText.content(for: event, orderStatus: nil, tr: tr)
        let tone: FeedItem.Tone = event.outcome == .finished ? .done : .late
        return FeedItem(id: id, kind: event.kind, title: content.title + " — " + content.body,
                        at: ISO8601DateFormatter().date(from: event.at) ?? Date(), tone: tone,
                        unread: true, orderId: event.orderId)
    }

    /// The cloud's last day of events (`GET /events`), for alerts that came
    /// while this phone was not listening.
    func backfill(api: KhaytAPIClient) async {
        guard let session = api.cloud else { return }
        let since = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-24 * 3600))
        guard let events = try? await CloudSync.events(session, since: since) else { return }
        for e in events {
            if let item = Self.item(eventId: "evt:" + e.id, kind: e.kind, at: e.at,
                                    ciphertext: e.ciphertext, dek: session.dek, tr: L10n.tr) {
                var seen = item
                // Already said on this phone — by the stream, or its own
                // reading — under its own id: the cloud's copy adds nothing.
                if items.contains(where: { $0.kind == item.kind && abs($0.at.timeIntervalSince(item.at)) < 120
                                           && $0.orderId == item.orderId }) { continue }
                seen.unread = true
                add(seen)
            }
        }
    }
}
