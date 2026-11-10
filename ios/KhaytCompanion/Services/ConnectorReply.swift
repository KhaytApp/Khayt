import Foundation
import KhaytCore

/// What a connector's 2xx reply came to, before the phone says "Sent."
///
/// An HTTP 2xx alone is not a yes. Lamha answers some refusals with 200 and
/// `success: false`, and in the first end-to-end test (TestFlight
/// 202611091953) that reply showed as "Sent." while Lamha had made nothing.
///
/// The rule is the shared one (`lib/plugin-payload.js replyVerdict`, run in
/// the engine) so the phone, the Mac and the desktop judge a reply the same
/// way, and the words are the shared `plg.*` ones.
enum ConnectorReply: Equatable {
    /// Filled a declared field, or the action expects nothing back.
    case confirmed
    /// `success: false` (or `status: false`): the service said no. Its own
    /// message, already cut short by the shared rule, when it gave one.
    case refused(String?)
    /// The action declares reply fields and the reply filled none of them:
    /// their labels.
    case unconfirmed([String])

    /// `reply` is the parsed body (nil when empty or not JSON). `mapped` is
    /// what `pluginApplyResponse` made of it.
    static func judge(reply: JSONValue?, mapped: JSONValue?, action: Connector.Action, connector c: Connector,
                      engine: KhaytEngine) async -> ConnectorReply {
        let trigger = JSONValue.object(["action": .string(action.id)])
        guard case .object(let v)? = try? await engine.pluginReplyVerdict(
                c.manifest, trigger: trigger, reply: reply ?? .null, entry: c.entry, mapped: mapped ?? .null) else {
            // No verdict is not a yes.
            return .unconfirmed([])
        }
        if v["ok"] == .bool(true) { return .confirmed }
        if v["kind"] == .string("refused") {
            if case .string(let m)? = v["message"], !m.isEmpty { return .refused(m) }
            return .refused(nil)
        }
        var labels: [String] = []
        if case .array(let keys)? = v["fields"] {
            for case .string(let key) in keys {
                labels.append(c.fields.first { $0.key == key && $0.attach == action.placement }?.label ?? key)
            }
        }
        return .unconfirmed(labels)
    }

    /// What the phone shows for a reply that was not a yes, in the shared
    /// connector words.
    func failure(connector c: Connector) -> String? {
        switch self {
        case .confirmed: return nil
        case .refused(let msg?): return L10n.format("plg.err_declined", c.name, msg)
        case .refused(nil): return L10n.format("plg.err_declined_nomsg", c.name)
        case .unconfirmed(let labels) where labels.isEmpty:
            return L10n.format("connectors.reply.unchecked", c.name)
        case .unconfirmed(let labels):
            let list = ListFormatter()
            list.locale = L10n.locale
            let field = list.string(from: labels) ?? labels.joined(separator: ", ")
            return L10n.format("plg.sent_unconfirmed", c.name, field)
        }
    }

    /// Whether a tap would send customer details from a job that has no
    /// customer (shared `usesCustomer`). Such a send can only be refused by
    /// the service, as Lamha refused ORD-00005B.
    static func needsCustomer(action: Connector.Action, connector c: Connector, engine: KhaytEngine) async -> Bool {
        (try? await engine.pluginUsesCustomer(c.manifest, trigger: .object(["action": .string(action.id)]))) ?? false
    }
}

/// The last connector reply this phone got, for Diagnostics: when, the HTTP
/// status, the body's `success` and its top-level KEYS. Never a value, never
/// a key or token, never a connector id: a person testing a connector can
/// tell "refused", "answered with something else" and "never answered" apart.
struct ConnectorReplyNote: Equatable, Sendable, Codable {
    var at: Date
    /// 0 when there was no HTTP answer at all.
    var status: Int
    /// "true", "false", or nil when the body has no boolean `success`.
    var success: String?
    var keys: [String]

    static let key = SyncDiagnostics.Keys.connectorReply
    static let maxKeys = 20
    static let maxKeyLength = 40

    init(at: Date = Date(), status: Int, body: Data?) {
        self.at = at
        self.status = status
        var success: String?
        var keys: [String] = []
        if let body, !body.isEmpty, case .object(let o)? = try? JSONValue.parse(body) {
            if case .bool(let b)? = o["success"] { success = b ? "true" : "false" }
            keys = o.keys.sorted().prefix(Self.maxKeys).map { String($0.prefix(Self.maxKeyLength)) }
        }
        self.success = success
        self.keys = keys
    }

    static func record(_ note: ConnectorReplyNote, defaults: UserDefaults = SyncDiagnostics.defaults) {
        if let data = try? JSONEncoder().encode(note) { defaults.set(data, forKey: key) }
    }

    static func recorded(defaults: UserDefaults = SyncDiagnostics.defaults) -> ConnectorReplyNote? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ConnectorReplyNote.self, from: data)
    }

    /// "200 · success false · msg, success", without the time.
    var summary: String {
        var parts = [status == 0 ? L10n.tr("diag.reply.no_answer") : String(status)]
        if let success { parts.append("success " + success) }
        parts.append(keys.isEmpty ? L10n.tr("diag.reply.no_keys") : keys.joined(separator: ", "))
        return parts.joined(separator: " · ")
    }
}
