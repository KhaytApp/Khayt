import CryptoKit
import Foundation
import KhaytCore

/**
 * Connectors (plugins v1) on the phone.
 *
 * A connector is a manifest the shop approved on its Mac — pure data, kept in
 * the book at `settings.plugins[]` — plus the developer's own https service.
 * The phone runs nothing it downloaded (App Review 2.5.2): every button and
 * field is drawn by Khayt, every request is built by the shared rule
 * (`lib/plugin-payload.js`, through `KhaytEngine.pluginPayload`), and this
 * file only adds what the phone alone holds — the keys in its Keychain and
 * the HMAC over the body — and sends it.
 *
 * ── WHAT THE PHONE DOES NOT DO ────────────────────────────────────────────
 *
 * - Approve, add or update a connector: that is the Mac's, for the whole book.
 * - Send on an event (`{event: …}` triggers), in the background, or by
 *   itself: only a person tapping a connector's button sends anything.
 * - Open a link inside the app: an "open" button goes to Safari, https only.
 * - Write the connector's own fields (`plugins.<id>.<key>` on a record): the
 *   Mac's delta gate does not take those from a phone yet, so they are shown
 *   read-only, and a reply's fields are shown, not written.
 *
 * ── TWO CONSENTS ──────────────────────────────────────────────────────────
 *
 * The book's: `settings.plugins[].granted`, decided on the Mac. If the
 * manifest now asks for more (`pluginDiff(...).widened`), the connector is
 * PAUSED and sends nothing until the Mac agrees again.
 *
 * This phone's: before the first send from this iPhone, the person sees what
 * goes where (`pluginConsentRows`) and agrees once. Remembered per connector
 * against a fingerprint of the grant, so a new grant asks again. Unpair
 * forgets both the keys and these confirmations.
 */
struct Connector: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable { case active, paused, invalid }

    struct Secret: Equatable, Sendable {
        let name: String
        let label: String
        let kind: String
    }

    struct Field: Equatable, Sendable {
        let key: String
        let label: String
        let type: String
        let attach: String
        /// `value → label`, for an enum.
        let options: [String: String]
    }

    struct Action: Equatable, Sendable, Identifiable {
        let id: String
        let label: String
        let placement: String
        let kind: String
        let url: String
    }

    let id: String
    let name: String
    let publisher: String
    let version: String
    let manifest: JSONValue
    let granted: JSONValue?
    let status: Status
    let reviewed: Bool
    let devMode: Bool
    let secrets: [Secret]
    let fields: [Field]
    let actions: [Action]
    let domains: [String]

    var isActive: Bool { status == .active }
}

/// The phone's rules for connectors, apart from any screen — so they can be
/// tested without a book, a network or a Keychain.
enum ConnectorRules {

    // MARK: Reading the book

    /// The connectors in a book's settings, with their status worked out.
    /// `diff` is `pluginDiff(granted:manifest:)`; `valid` is `pluginValidate`'s `ok`.
    static func connector(entry: [String: JSONValue], valid: Bool, diff: JSONValue?) -> Connector? {
        guard case .object(let m)? = entry["manifest"] else { return nil }
        let id = text(m["id"]) ?? text(entry["id"]) ?? ""
        guard !id.isEmpty else { return nil }
        let granted: JSONValue? = {
            if case .object? = entry["granted"] { return entry["granted"] }
            return nil
        }()
        let status: Connector.Status
        if !valid { status = .invalid }
        else if entry["enabled"] == .bool(false) { status = .paused }
        else { status = isPaused(granted: granted, diff: diff) ? .paused : .active }

        let secrets: [Connector.Secret] = list(m["secrets"]).compactMap {
            guard let n = text($0["name"]) else { return nil }
            return .init(name: n, label: label($0["label"]) ?? n, kind: text($0["kind"]) ?? "")
        }
        let fields: [Connector.Field] = list(m["fields"]).compactMap {
            guard let k = text($0["key"]) else { return nil }
            var options: [String: String] = [:]
            for o in list($0["options"]) { if let v = text(o["value"]) { options[v] = label(o["label"]) ?? v } }
            return .init(key: k, label: label($0["label"]) ?? k, type: text($0["type"]) ?? "text",
                         attach: text($0["attach"]) ?? "", options: options)
        }
        let actions: [Connector.Action] = list(m["actions"]).compactMap {
            guard let a = text($0["id"]) else { return nil }
            return .init(id: a, label: label($0["label"]) ?? a, placement: text($0["placement"]) ?? "",
                         kind: text($0["kind"]) ?? "", url: text($0["url"]) ?? "")
        }
        var domains: [String] = []
        if case .array(let d)? = m["domains"] { domains = d.compactMap { if case .string(let s) = $0 { s } else { nil } } }
        return Connector(id: id, name: label(m["name"]) ?? id, publisher: text(m["publisher"]) ?? "",
                         version: text(m["version"]) ?? "", manifest: .object(m), granted: granted,
                         status: status, reviewed: entry["reviewed"] == .bool(true),
                         devMode: entry["devMode"] == .bool(true),
                         secrets: secrets, fields: fields, actions: actions, domains: domains)
    }

    /// Paused: never granted, or the manifest asks for more than the grant.
    static func isPaused(granted: JSONValue?, diff: JSONValue?) -> Bool {
        guard granted != nil else { return true }
        guard case .object(let d)? = diff else { return true }
        if d["widened"] == .bool(true) { return true }
        for k in ["fields", "domains", "scopes"] {
            if case .array(let a)? = d[k], !a.isEmpty { return true }
        }
        return false
    }

    /// The entries in `settings.plugins`, each an object.
    static func entries(settings: [String: JSONValue]) -> [[String: JSONValue]] {
        guard case .array(let rows)? = settings["plugins"] else { return [] }
        return rows.compactMap { if case .object(let o) = $0 { o } else { nil } }
    }

    /// A plugin's own field value on a record: `plugins.<id>.<key>`.
    static func fieldValue(_ record: [String: JSONValue]?, pluginId: String, key: String) -> JSONValue? {
        guard case .object(let p)? = record?["plugins"], case .object(let mine)? = p[pluginId],
              let v = mine[key], v != .null else { return nil }
        return v
    }

    /// The secret names an action's URL fills in (`{secret.x}`).
    static func secretsInURL(_ url: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"\{secret\.([a-zA-Z0-9_]+)\}"#)
        return re.matches(in: url, range: NSRange(url.startIndex..., in: url)).compactMap {
            Range($0.range(at: 1), in: url).map { String(url[$0]) }
        }
    }

    // MARK: Before anything leaves

    enum Refusal: Error, Equatable {
        /// Not https (or not a URL at all).
        case notHTTPS
        /// A host the manifest did not declare.
        case undeclaredHost(String)
    }

    /// The last check before a request or a link: https, to a declared host,
    /// with no credentials or port slipped in — even though the shared rule
    /// built it. The rule is trusted; a second lock costs nothing.
    static func guardURL(_ string: String, domains: [String]) -> Result<URL, Refusal> {
        guard let url = URL(string: string), let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              comps.scheme?.lowercased() == "https" else { return .failure(.notHTTPS) }
        let host = (comps.host ?? "").lowercased()
        guard !host.isEmpty, comps.user == nil, comps.password == nil,
              comps.port == nil || comps.port == 443 else { return .failure(.undeclaredHost(host)) }
        guard domains.contains(host) else { return .failure(.undeclaredHost(host)) }
        return .success(url)
    }

    /// `X-Khayt-Signature`: lowercase hex HMAC-SHA256 of the exact body bytes.
    static func signature(body: Data, key: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(key.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// The auth header's value: `"<scheme> <secret>"`, or the secret alone
    /// when the manifest names no scheme.
    static func authValue(scheme: String, secret: String) -> String {
        scheme.isEmpty ? secret : "\(scheme) \(secret)"
    }

    /// The Keychain item a connector's secret lives in, on this phone only.
    static func keychainName(pluginId: String, secret: String) -> String {
        "plugin.\(pluginId).\(secret)"
    }

    // MARK: This phone's confirmation

    static let consentPrefix = "plugin.consent."

    static func consentKey(pluginId: String) -> String { consentPrefix + pluginId }

    /// The grant, reduced to what the phone asks again for: its version, the
    /// fields, the domains and the scopes, each sorted.
    static func grantFingerprint(_ granted: JSONValue?) -> String {
        guard case .object(let g)? = granted else { return "" }
        func sorted(_ k: String) -> String {
            list(g[k], strings: true).sorted().joined(separator: ",")
        }
        let canonical = "v=\(text(g["version"]) ?? "")|f=\(sorted("fields"))|d=\(sorted("domains"))|s=\(sorted("scopes"))"
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isConfirmed(_ c: Connector, defaults: UserDefaults = .standard) -> Bool {
        guard c.granted != nil else { return false }
        return defaults.string(forKey: consentKey(pluginId: c.id)) == grantFingerprint(c.granted)
    }

    static func confirm(_ c: Connector, defaults: UserDefaults = .standard) {
        defaults.set(grantFingerprint(c.granted), forKey: consentKey(pluginId: c.id))
    }

    /// Every confirmation on this phone — Unpair.
    static func forgetConfirmations(defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(consentPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: Plain words

    /// A label from a manifest `{en, ar, …}`, in the app's language, else English.
    static func label(_ v: JSONValue?, language: String? = nil) -> String? {
        guard case .object(let o)? = v else { return nil }
        let lang = language ?? L10n.currentLanguage.bundleCode
            ?? Locale.current.language.languageCode?.identifier ?? "en"
        if case .string(let s)? = o[lang], !s.isEmpty { return s }
        let short = String(lang.prefix(2))
        if case .string(let s)? = o[short], !s.isEmpty { return s }
        if case .string(let s)? = o["en"] { return s }
        return nil
    }

    /// A field reference (`order.number`, `field.tracking`) in plain words.
    static func fieldName(_ ref: String, in c: Connector?) -> String {
        if ref.hasPrefix("field.") {
            let key = String(ref.dropFirst(6))
            return c?.fields.first(where: { $0.key == key })?.label ?? key
        }
        let k = "connectors.data." + ref.lowercased()
        let t = L10n.tr(k)
        return t == k ? ref : t
    }

    // MARK: Helpers

    static func text(_ v: JSONValue?) -> String? {
        if case .string(let s)? = v, !s.isEmpty { return s }
        return nil
    }

    private static func list(_ v: JSONValue?) -> [[String: JSONValue]] {
        guard case .array(let a)? = v else { return [] }
        return a.compactMap { if case .object(let o) = $0 { o } else { nil } }
    }

    private static func list(_ v: JSONValue?, strings: Bool) -> [String] {
        guard case .array(let a)? = v else { return [] }
        return a.compactMap { if case .string(let s) = $0 { s } else { nil } }
    }

    /// A field value as text, for a read-only row.
    static func display(_ v: JSONValue, field: Connector.Field) -> String {
        switch v {
        case .string(let s): return field.type == "enum" ? (field.options[s] ?? s) : s
        case .number(let n): return n.formatted(.number.locale(L10n.locale))
        case .bool(let b): return L10n.tr(b ? "connectors.yes" : "connectors.no")
        default: return ""
        }
    }
}

/// A connector's keys, in this iPhone's Keychain. Never synced, never shown
/// back in full.
enum ConnectorKeys {
    static func get(_ pluginId: String, _ name: String) -> String? {
        KeychainHelper.get(ConnectorRules.keychainName(pluginId: pluginId, secret: name)).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func set(_ pluginId: String, _ name: String, _ value: String) {
        KeychainHelper.set(value, for: ConnectorRules.keychainName(pluginId: pluginId, secret: name))
    }

    static func delete(_ pluginId: String, _ name: String) {
        KeychainHelper.delete(ConnectorRules.keychainName(pluginId: pluginId, secret: name))
    }

    static func isSet(_ pluginId: String, _ name: String) -> Bool { get(pluginId, name) != nil }

    /// Every connector key on this phone, whatever connector it was for —
    /// Unpair. Returns how many went.
    @discardableResult
    static func forgetAll() -> Int {
        KeychainHelper.deleteAll(prefix: "plugin.")
    }
}

/// Unpair's share: the keys and this phone's confirmations.
enum ConnectorTraces {
    static func forget(defaults: UserDefaults = .standard) {
        ConnectorKeys.forgetAll()
        ConnectorRules.forgetConfirmations(defaults: defaults)
    }
}

extension KhaytAPIClient {

    /// Where a connector button sits, and the record it acts on.
    enum ConnectorPlace: Equatable {
        case order(String)
        case customer(String)

        var placement: String {
            switch self { case .order: "order"; case .customer: "customer" }
        }
    }

    /// What a tap came to.
    enum ConnectorOutcome: Equatable {
        /// Open this https link in Safari.
        case open(URL)
        /// Sent. `reply` is the connector's fields as the reply would fill
        /// them, by label — shown, not written (see the top of this file).
        case sent(reply: [String])
        case failed(String)
    }

    /// The book's connectors, with their status. Empty without a book.
    func connectors() async -> [Connector] {
        guard let book, book.exists, let reader, let store = try? book.read(),
              case .object(let settings)? = store["settings"] else { return [] }
        let entries = ConnectorRules.entries(settings: settings)
        guard !entries.isEmpty, let engine = try? await reader.sharedEngine() else { return [] }
        var out: [Connector] = []
        for e in entries {
            guard let m = e["manifest"] else { continue }
            var valid = false
            if case .object(let r)? = try? await engine.pluginValidate(m) { valid = r["ok"] == .bool(true) }
            let diff = try? await engine.pluginDiff(granted: e["granted"] ?? .null, manifest: m)
            if let c = ConnectorRules.connector(entry: e, valid: valid, diff: diff) { out.append(c) }
        }
        return out
    }

    /// The records a connector reads at a place: the job and its customer,
    /// or the customer alone.
    func connectorRecords(_ place: ConnectorPlace) -> (order: [String: JSONValue]?, customer: [String: JSONValue]?) {
        guard let book, book.exists, let store = try? book.read() else { return (nil, nil) }
        func row(_ collection: String, _ id: String) -> [String: JSONValue]? {
            guard case .array(let rows)? = store[collection] else { return nil }
            for case .object(let o) in rows where o["id"] == .string(id) { return o }
            return nil
        }
        switch place {
        case .order(let id):
            let order = row("printLog", id)
            let customer = ConnectorRules.text(order?["clientId"]).flatMap { row("clients", $0) }
            return (order, customer)
        case .customer(let id):
            return (nil, row("clients", id))
        }
    }

    /// The consent rows for the confirmation and the Settings page.
    func connectorConsentRows(_ c: Connector) async -> [(host: String, fields: [String])] {
        guard let reader, let engine = try? await reader.sharedEngine(),
              let rows = try? await engine.pluginConsentRows(c.manifest) else { return [] }
        return rows.compactMap { row in
            guard case .object(let r) = row, let host = ConnectorRules.text(r["host"]) else { return nil }
            var fields: [String] = []
            if case .array(let fs)? = r["fields"] {
                for case .object(let f) in fs { if let k = ConnectorRules.text(f["key"]) { fields.append(k) } }
            }
            return (host, fields)
        }
    }

    /// Run one button. The caller has already had this phone's confirmation.
    func runConnector(_ c: Connector, action: Connector.Action, at place: ConnectorPlace) async -> ConnectorOutcome {
        guard c.isActive else { return .failed(L10n.tr("connectors.paused")) }
        // The sample shop promises nothing leaves the phone: not a request,
        // and not a link carrying its made-up records either.
        guard !isSampleShop else { return .failed(L10n.tr("connectors.sample")) }
        guard action.placement == place.placement else { return .failed(L10n.tr("connectors.error.build")) }
        guard let reader, let engine = try? await reader.sharedEngine() else { return .failed(L10n.tr("connectors.error.build")) }

        let records = connectorRecords(place)
        var ctx: [String: JSONValue] = [:]
        if let o = records.order { ctx["order"] = .object(o) }
        if let cu = records.customer { ctx["customer"] = .object(cu) }
        // Only the secrets this URL fills in go into the engine.
        var urlSecrets: [String: JSONValue] = [:]
        for name in ConnectorRules.secretsInURL(action.url) {
            guard let v = ConnectorKeys.get(c.id, name) else {
                return .failed(L10n.format("connectors.error.key_missing", secretLabel(c, name)))
            }
            urlSecrets[name] = .string(v)
        }
        if !urlSecrets.isEmpty { ctx["secrets"] = .object(urlSecrets) }

        guard case .object(let p)? = try? await engine.pluginPayload(
                c.manifest, trigger: .object(["action": .string(action.id)]), context: .object(ctx)),
              p["ok"] == .bool(true), let urlText = ConnectorRules.text(p["url"]) else {
            return .failed(L10n.tr("connectors.error.build"))
        }
        let url: URL
        switch ConnectorRules.guardURL(urlText, domains: c.domains) {
        case .success(let u): url = u
        case .failure(.notHTTPS): return .failed(L10n.tr("connectors.error.scheme"))
        case .failure(.undeclaredHost(let h)): return .failed(L10n.format("connectors.error.host", h))
        }

        if ConnectorRules.text(p["method"]) == "OPEN" { return .open(url) }
        guard ConnectorRules.text(p["method"]) == "POST" else { return .failed(L10n.tr("connectors.error.build")) }

        let body = Data((ConnectorRules.text(p["body"]) ?? "").utf8)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(ConnectorRules.text(p["contentType"]) ?? "application/json", forHTTPHeaderField: "Content-Type")
        request.httpShouldHandleCookies = false
        if case .object(let auth)? = p["auth"], let header = ConnectorRules.text(auth["header"]),
           let name = ConnectorRules.text(auth["secret"]) {
            guard let secret = ConnectorKeys.get(c.id, name) else {
                return .failed(L10n.format("connectors.error.key_missing", secretLabel(c, name)))
            }
            request.setValue(ConnectorRules.authValue(scheme: ConnectorRules.text(auth["scheme"]) ?? "", secret: secret),
                             forHTTPHeaderField: header)
        }
        if let name = ConnectorRules.text(p["signWith"]) {
            guard let key = ConnectorKeys.get(c.id, name) else {
                return .failed(L10n.format("connectors.error.key_missing", secretLabel(c, name)))
            }
            request.setValue(ConnectorRules.signature(body: body, key: key), forHTTPHeaderField: "X-Khayt-Signature")
        }

        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let data: Data, response: URLResponse
        do {
            // No redirect is followed (`NoRedirects`): a 307 would carry the
            // body and the key to a host the shop never agreed to.
            (data, response) = try await session.data(for: request, delegate: NoRedirects())
        } catch {
            return .failed(L10n.format("connectors.error.network", url.host() ?? ""))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            return .failed(L10n.format("connectors.error.server", status))
        }
        // The reply, mapped by the shared rule into the connector's own
        // fields. Shown, NOT written: the Mac does not take a phone's writes
        // under `plugins.<id>` yet.
        var lines: [String] = []
        if !data.isEmpty, let reply = try? JSONValue.parse(data),
           case .object(let mapped)? = try? await engine.pluginApplyResponse(c.manifest, actionId: action.id, reply: reply) {
            for key in mapped.keys.sorted() {
                guard let field = c.fields.first(where: { $0.key == key }), let v = mapped[key] else { continue }
                lines.append("\(field.label): \(ConnectorRules.display(v, field: field))")
            }
        }
        return .sent(reply: lines)
    }

    private func secretLabel(_ c: Connector, _ name: String) -> String {
        c.secrets.first(where: { $0.name == name })?.label ?? name
    }
}
