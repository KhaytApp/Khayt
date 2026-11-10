import Foundation
import KhaytCore

/// What a connector's 2xx reply came to, before the phone says "Sent."
///
/// An HTTP 2xx alone is not a yes. Lamha answers some refusals with 200 and
/// `success: false` (the studio's working client, athartuwaiq3d
/// lamha/client.ts, treats it as a failure), and in the first end-to-end test
/// (TestFlight 202611091953) that reply showed as "Sent." while Lamha had made
/// nothing. So a reply is only `confirmed` when it fills one of the fields
/// the action says the reply carries, or when the action declares none.
enum ConnectorReply: Equatable {
    /// Filled a declared field, or the action expects nothing back.
    case confirmed
    /// `success: false` (or `status: false`): the service said no. Its own
    /// message, cut short, when it gave one.
    case refused(String?)
    /// The action declares reply fields and the reply filled none of them:
    /// their labels, for "the reply didn't include: …".
    case unconfirmed([String])

    /// The longest service message shown, in characters.
    static let messageLimit = 200

    /// `reply` is the parsed body (nil when empty or not JSON). `mapped` is
    /// what `pluginApplyResponse` made of it.
    static func judge(reply: JSONValue?, mapped: JSONValue?, action: Connector.Action, connector c: Connector) -> ConnectorReply {
        if case .object(let o)? = reply, o["success"] == .bool(false) || o["status"] == .bool(false) {
            return .refused(message(o))
        }
        let expected = expectedFields(action: action, connector: c)
        guard !expected.isEmpty else { return .confirmed }
        if case .object(let m)? = mapped, expected.contains(where: { m[$0.key] != nil && m[$0.key] != .null }) {
            return .confirmed
        }
        return .unconfirmed(expected.map(\.label))
    }

    /// The fields the action's `response.fields` names that this connector
    /// could write: none when the shop never granted fields.write, since then
    /// nothing is ever mapped and nothing can be expected.
    static func expectedFields(action: Connector.Action, connector c: Connector) -> [Connector.Field] {
        guard grantsFieldsWrite(c.granted),
              case .object(let m) = c.manifest, case .array(let actions)? = m["actions"] else { return [] }
        for case .object(let a) in actions where a["id"] == .string(action.id) {
            guard case .object(let response)? = a["response"], case .object(let fields)? = response["fields"] else { return [] }
            return fields.keys.sorted().compactMap { key in
                c.fields.first { $0.key == key && $0.attach == action.placement }
            }
        }
        return []
    }

    static func grantsFieldsWrite(_ granted: JSONValue?) -> Bool {
        guard case .object(let g)? = granted, case .array(let scopes)? = g["scopes"] else { return false }
        return scopes.contains(.string("fields.write"))
    }

    /// The service's own words: `msg`, `message`, `error` or `error.message`,
    /// on one line, at most `messageLimit` characters.
    static func message(_ o: [String: JSONValue]) -> String? {
        var raw: String?
        for key in ["msg", "message", "error"] {
            if case .string(let s)? = o[key] { raw = s; break }
            if case .object(let e)? = o[key], case .string(let s)? = e["message"] { raw = s; break }
        }
        guard let raw else { return nil }
        let line = raw.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        return line.count > messageLimit ? String(line.prefix(messageLimit)) + "…" : line
    }

    /// What the phone shows for a reply that was not a yes.
    func failure(connector c: Connector) -> String? {
        switch self {
        case .confirmed: return nil
        case .refused(let msg?): return L10n.format("connectors.reply.refused_said", c.name, msg)
        case .refused(nil): return L10n.format("connectors.reply.refused", c.name)
        case .unconfirmed(let labels):
            return L10n.format("connectors.reply.unconfirmed", c.name, labels.joined(separator: ", "))
        }
    }

    /// Whether a tap would send customer details (`{customer.…}` anywhere in
    /// the action) from a job that has no customer. Such a send can only be
    /// refused by the service, as Lamha refused ORD-00005B.
    static func needsCustomer(action: Connector.Action, manifest: JSONValue) -> Bool {
        guard action.placement == "order", case .object(let m) = manifest,
              case .array(let actions)? = m["actions"] else { return false }
        for case .object(let a) in actions where a["id"] == .string(action.id) {
            return mentionsCustomer(.object(a))
        }
        return false
    }

    private static func mentionsCustomer(_ v: JSONValue) -> Bool {
        switch v {
        case .string(let s): return s.contains("{customer.")
        case .array(let a): return a.contains(where: mentionsCustomer)
        case .object(let o): return o.values.contains(where: mentionsCustomer)
        default: return false
        }
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
