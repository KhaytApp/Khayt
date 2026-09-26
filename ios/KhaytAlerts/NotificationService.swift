import Foundation
import UserNotifications
import Security
import KhaytCore

/// Turns Khayt Cloud's push into the alert the app would have shown.
///
/// ── WHAT ARRIVES, AND WHAT THIS DOES WITH IT ─────────────────────────────
///
/// The cloud relays the Mac's `print-finished` event without reading it:
/// Apple's visible text is only "A print finished" (`PUSH_*`), and the
/// details ride along sealed under the shop's key in `k.ct` — or, when they
/// would push the payload past 4 KB, are left for the phone to fetch from
/// `GET /events`. This extension opens them with the key this phone already
/// holds, reads the job's stage from the phone's book, and rewrites the alert
/// with the job's name and its one button — the same words and the same rule
/// as `PrintAlertCenter` in the app.
///
/// Anything it cannot do — a phone signed out, a key that does not open it,
/// a fetch that times out — leaves Apple's generic alert as it was. A plain
/// "A print finished" is true; a guessed one is not.
final class NotificationService: UNNotificationServiceExtension {
    private var deliver: ((UNNotificationContent) -> Void)?
    private var fallback: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        deliver = contentHandler
        let original = request.content.mutableCopy() as? UNMutableNotificationContent
        fallback = original
        Task {
            let rewritten = await Self.rewrite(request.content.userInfo)
            contentHandler(rewritten ?? original ?? request.content)
            deliver = nil
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let deliver, let fallback { deliver(fallback) }
        deliver = nil
    }

    /// Only `print-finished` is opened. Every other kind is shown as Apple
    /// delivered it — `intake`, the cloud's own "New order request", carries
    /// no sealed details at all (the cloud holds no shop key), so there is
    /// nothing to open and nothing to fetch.
    static func rewrite(_ info: [AnyHashable: Any]) async -> UNMutableNotificationContent? {
        guard let k = info["k"] as? [String: Any],
              let kind = k["kind"] as? String, kind == "print-finished",
              let shopId = k["shopId"] as? String,
              let shared = SharedCloud.load(), shared.shopId == shopId else { return nil }
        var sealed: Data?
        if let ct = k["ct"], JSONSerialization.isValidJSONObject(ct) {
            sealed = try? JSONSerialization.data(withJSONObject: ct)
        } else if let at = k["at"] as? String {
            sealed = await fetchSealed(shared, kind: kind, at: at)
        }
        guard let sealed,
              let blob = try? JSONDecoder().decode(SyncCrypto.Blob.self, from: sealed),
              let plain = try? SyncCrypto.openStore(blob, dek: shared.dek),
              let event = try? JSONDecoder().decode(PrintFinished.self, from: plain) else { return nil }
        let status = event.orderId.flatMap(BookPeek.status(of:))
        return PrintAlertText.content(for: event, orderStatus: status) {
            NSLocalizedString($0, comment: "")
        }
    }

    /// `GET /v1/shops/{id}/events?since=` — for a push whose details did not
    /// fit in it. The event is the one of this kind at this moment.
    static func fetchSealed(_ shared: SharedCloud, kind: String, at: String) async -> Data? {
        let f = ISO8601DateFormatter()
        guard let when = f.date(from: at) else { return nil }
        let since = f.string(from: when.addingTimeInterval(-2))
        var components = URLComponents(string: shared.url)
        components?.path = "/v1/shops/" + (shared.shopId.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "_-"))) ?? shared.shopId) + "/events"
        components?.queryItems = [URLQueryItem(name: "since", value: since)]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer " + shared.token, forHTTPHeaderField: "Authorization")
        request.setValue("1", forHTTPHeaderField: "x-delta-capable")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              case .object(let root)? = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .array(let events)? = root["events"] else { return nil }
        for case .object(let e) in events where e["kind"] == .string(kind) && e["at"] == .string(at) {
            if let ct = e["ciphertext"] { return try? JSONEncoder().encode(ct) }
        }
        return nil
    }
}

/// The cloud sign-in the app saved, read from where the app keeps it: the
/// address and shop in the App Group, the token and the shop's key in the
/// Keychain group the app shares with this extension. Both are readable
/// after the phone's first unlock — which is when a push to a locked phone
/// needs them.
struct SharedCloud {
    let url: String
    let shopId: String
    let token: String
    let dek: Data

    static let group = "group.com.khaytapp.companion"
    /// The app's Keychain service: its bundle id, which this extension's is not.
    static let service = "com.khaytapp.companion"

    static func load() -> SharedCloud? {
        let defaults = UserDefaults(suiteName: group)
        guard let url = defaults?.string(forKey: "khayt.cloud.url"), !url.isEmpty,
              let shopId = defaults?.string(forKey: "khayt.cloud.shopId"), !shopId.isEmpty,
              let token = secret("khayt.cloud.token"), !token.isEmpty,
              let dekText = secret("khayt.cloud.dek"), let dek = Data(base64Encoded: dekText),
              !dek.isEmpty else { return nil }
        return SharedCloud(url: url, shopId: shopId, token: token, dek: dek)
    }

    private static func secret(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// The stage of one job, read from the phone's book in the App Group — so the
/// alert offers the button that fits the job as it is now.
enum BookPeek {
    static func status(of orderId: String) -> String? {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedCloud.group),
              let data = try? Data(contentsOf: dir.appending(path: "Book/khayt-store.json")),
              case .object(let root)? = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .array(let rows)? = root["printLog"] else { return nil }
        for case .object(let o) in rows where o["id"] == .string(orderId) {
            if case .string(let status)? = o["status"] { return status }
        }
        return nil
    }
}
