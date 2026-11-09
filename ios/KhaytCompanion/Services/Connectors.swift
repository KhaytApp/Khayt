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
 * (`lib/plugin-payload.js`, through `KhaytEngine.pluginPayload`), its
 * headers and host check by the Mac's own code (`KhaytCore.Connectors`:
 * auth, X-Khayt-Signature/-Timestamp/-Signature-V2, X-Khayt-Delivery), and
 * this file only opens the keys the tap needs from its Keychain and sends it.
 *
 * ── WHAT THE PHONE DOES NOT DO ────────────────────────────────────────────
 *
 * - Approve, add or update a connector: that is the Mac's, for the whole book.
 * - Send on an event (`{event: …}` triggers), in the background, or by
 *   itself: only a person tapping a connector's button sends anything.
 * - Open a link inside the app: an "open" button goes to Safari, https only.
 *
 * ── THE CONNECTOR'S OWN FIELDS ARE WRITTEN, ONLY FOR AN ACTIVE ONE ────────
 *
 * A connector's own fields (`plugins.<id>.<key>` on a job or a customer) are
 * written on the phone: typed in on the card (`ConnectorRules.canEditFields`:
 * an active connector, on a phone that may edit), and a 2xx reply's mapped
 * fields (`pluginApplyResponse`, which maps nothing without fields.write) are
 * saved on the record the button was pressed on, as well as shown. Both go
 * through `BookWriter.setConnectorValues`, which keeps every other key and
 * every other connector's values and never drops `plugins`. The Mac takes
 * them (`lib/plugin-host.js` `phoneRecord`) only for a connector that is on
 * there and whose signature verifies there, only for the fields it declares
 * for that record, each checked by `coerceField` — the phone runs the same
 * `coerceField` first (`ConnectorRules.coerce`). A reply that cannot be saved still
 * counts as sent, and says so.
 *
 * ── TWO CONSENTS ──────────────────────────────────────────────────────────
 *
 * The book's: `settings.plugins[].granted`, decided on the Mac. If the
 * manifest now asks for more (`pluginCheckEntry(...).paused`), the connector is
 * PAUSED and sends nothing until the Mac agrees again.
 *
 * This phone's: before the first send from this iPhone, the person sees what
 * goes where (`pluginConsentRows`) and agrees once. Remembered per connector
 * against a fingerprint of the grant, so a new grant asks again. Unpair
 * forgets both the keys and these confirmations.
 */
struct Connector: Identifiable, Equatable, Sendable {
    /// Strongest first: an unreadable manifest, one turned off on the Mac,
    /// one not reviewed by Khayt, one waiting for the shop to agree to more.
    enum Status: Equatable, Sendable { case active, paused, notReviewed, off, invalid }

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

    /// One of the shop's settings for the connector (`settings[]`): typed
    /// on the Mac, kept in the book at `entry.config`, read-only here.
    struct Setting: Equatable, Sendable {
        let key: String
        let label: String
        let type: String
        let required: Bool
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
    /// The stored `settings.plugins[]` entry, as the book has it: what
    /// `pluginApplyResponse` checks its fields.write grant against.
    let entry: JSONValue
    let status: Status
    /// Khayt's signature over the manifest verifies (`Connectors.reviewedBy`, shared with the Mac).
    let reviewed: Bool
    let secrets: [Secret]
    let fields: [Field]
    let actions: [Action]
    let domains: [String]
    var settings: [Setting] = []
    /// The book's `entry.config`: the settings' values, as the Mac saved them.
    var config: [String: JSONValue] = [:]

    /// Whether its buttons work: active, and nothing else. Every send checks it.
    var isActive: Bool { status == .active }
}

/// The phone's rules for connectors, apart from any screen — so they can be
/// tested without a book, a network or a Keychain.
enum ConnectorRules {

    // MARK: Reading the book

    /// The connectors in a book's settings, with their status worked out.
    /// `check` is `engine.pluginCheckEntry(entry)`: `{ok, errors, paused}`.
    ///
    /// An entry is `{id, version, enabled, manifest, granted, config}`, with
    /// the full signed manifest under `manifest`. The shared check refuses any
    /// other key (a `reviewed` or `devMode` flag among them), a manifest that
    /// does not validate, an id or version that is not the manifest's, and a
    /// grant wider than the manifest declares: each is `.invalid`. Its
    /// `paused` is the manifest asking for more than the grant.
    ///
    /// `reviewed` is `Connectors.reviewedBy(...) != nil`, worked out by the
    /// caller (the canonical bytes come from the engine), and is a separate
    /// requirement: a valid, granted connector Khayt has not signed still sends
    /// nothing.
    static func connector(entry: [String: JSONValue], check: JSONValue?,
                          reviewed: Bool = false) -> Connector? {
        guard case .object(let m)? = entry["manifest"] else { return nil }
        let id = text(m["id"]) ?? text(entry["id"]) ?? ""
        guard !id.isEmpty else { return nil }
        let granted: JSONValue? = {
            if case .object? = entry["granted"] { return entry["granted"] }
            return nil
        }()
        var ok = false, paused = true
        if case .object(let c)? = check {
            ok = c["ok"] == .bool(true)
            paused = c["paused"] != .bool(false)
        }
        let status: Connector.Status
        if !ok { status = .invalid }
        else if entry["enabled"] == .bool(false) { status = .off }
        else if !reviewed { status = .notReviewed }
        else { status = paused ? .paused : .active }

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
        let settings: [Connector.Setting] = list(m["settings"]).compactMap {
            guard let k = text($0["key"]) else { return nil }
            return .init(key: k, label: label($0["label"]) ?? k, type: text($0["type"]) ?? "text",
                         required: $0["required"] == .bool(true))
        }
        var config: [String: JSONValue] = [:]
        if case .object(let o)? = entry["config"] { config = o }
        var domains: [String] = []
        if case .array(let d)? = m["domains"] { domains = d.compactMap { if case .string(let s) = $0 { s } else { nil } } }
        return Connector(id: id, name: label(m["name"]) ?? id, publisher: text(m["publisher"]) ?? "",
                         version: text(m["version"]) ?? "", manifest: .object(m), granted: granted,
                         entry: .object(entry),
                         status: status, reviewed: reviewed,
                         secrets: secrets, fields: fields, actions: actions, domains: domains,
                         settings: settings, config: config)
    }

    /// Khayt's connector signing keys: `[{id, key}]`, `key` base64 of the
    /// raw 32-byte ed25519 public key (`lib/plugin-manifest.js`
    /// SIGNING_KEYS, through the engine). The one place the phone reads them;
    /// whether a manifest verifies is `Connectors.reviewedBy`, shared with the Mac.
    static func signingKeys(_ engine: KhaytEngine) async -> [JSONValue] {
        (try? await engine.pluginSigningKeys()) ?? []
    }

    /// What the engine is given for one tap: the records, the shop's settings
    /// for the connector (`entry.config`, as `ctx.config`; `{}` when it has
    /// none — the lib then refuses a required one by name), and (for a POST
    /// only) the secrets its URL fills in. An "open" link never gets a
    /// secret, whatever its URL says; the lib refuses one too, and this is
    /// the phone's own lock. `secret` reads this phone's Keychain; a missing
    /// one is returned by name.
    static func context(action: Connector.Action, order: [String: JSONValue]?, customer: [String: JSONValue]?,
                        config: [String: JSONValue] = [:],
                        secret: (String) -> String?) -> (context: JSONValue, missing: String?) {
        var ctx: [String: JSONValue] = ["config": .object(config)]
        if let order { ctx["order"] = .object(order) }
        if let customer { ctx["customer"] = .object(customer) }
        guard action.kind == "post" else { return (.object(ctx), nil) }
        var urlSecrets: [String: JSONValue] = [:]
        for name in secretsInURL(action.url) {
            guard let v = secret(name) else { return (.object(ctx), name) }
            urlSecrets[name] = .string(v)
        }
        if !urlSecrets.isEmpty { ctx["secrets"] = .object(urlSecrets) }
        return (.object(ctx), nil)
    }

    /// A status in one word or two, for a list row or a badge.
    static func statusName(_ s: Connector.Status) -> String {
        switch s {
        case .active: return L10n.tr("connectors.status.active")
        case .paused: return L10n.tr("connectors.status.paused")
        case .notReviewed: return L10n.tr("connectors.status.not_reviewed")
        case .off: return L10n.tr("connectors.status.off")
        case .invalid: return L10n.tr("connectors.status.invalid")
        }
    }

    /// Whether a connector's own fields can be typed in on this phone: an
    /// active connector (`isActive`), on a phone that may edit the shop
    /// (`KhaytAPIClient.canWrite`). Otherwise they are shown read-only.
    static func canEditFields(_ c: Connector, canWrite: Bool) -> Bool {
        c.isActive && canWrite
    }

    /// Why a connector's buttons are off, or nil when they work.
    static func disabledReason(_ c: Connector) -> String? {
        switch c.status {
        case .active: return nil
        case .paused: return L10n.tr("connectors.paused")
        case .notReviewed: return L10n.tr("connectors.not_reviewed")
        case .off: return L10n.tr("connectors.off")
        case .invalid: return L10n.tr("connectors.error.build")
        }
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

    /// Every secret one tap needs, by name: for a POST, those its URL fills
    /// in, its `auth.secret` and its `signWith`, read from the manifest's own
    /// action. An "open" link needs none. Only these are read from the Keychain.
    static func secretNames(for action: Connector.Action, manifest: JSONValue) -> [String] {
        guard action.kind == "post" else { return [] }
        var names = secretsInURL(action.url)
        if case .object(let m) = manifest, case .array(let actions)? = m["actions"] {
            for case .object(let a) in actions where a["id"] == .string(action.id) {
                if case .object(let auth)? = a["auth"], let n = text(auth["secret"]) { names.append(n) }
                if let n = text(a["signWith"]) { names.append(n) }
            }
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// What one tap comes to, once the shared code has checked it.
    enum Prepared: Equatable {
        case open(URL)
        case post(Connectors.Post)
    }

    /// The request a built payload makes, through the shared code
    /// (`KhaytCore.Connectors`): `link` for an "open" button, `post` for a
    /// POST, with the auth and signature headers the Mac sends too. `event`
    /// is the action's id, as the Mac names a press. Both re-check https, the
    /// exact declared host, no user or password and no port but 443 — all in
    /// the shared `Connectors.checkHost`; the phone adds no check of its own.
    static func prepare(payload: JSONValue, manifest: JSONValue, action: Connector.Action,
                        secrets: [String: String], delivery: String, now: Date) throws -> Prepared {
        if case .object(let p) = payload, p["method"] == .string("OPEN") {
            return .open(try Connectors.link(from: payload, manifest: manifest))
        }
        return .post(try Connectors.post(from: payload, manifest: manifest, event: action.id,
                                         secrets: secrets, delivery: delivery, now: now))
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

    /// A field reference (`order.number`, `field.tracking`, `config.sender`) in plain words.
    static func fieldName(_ ref: String, in c: Connector?) -> String {
        if ref.hasPrefix("field.") {
            let key = String(ref.dropFirst(6))
            return c?.fields.first(where: { $0.key == key })?.label ?? key
        }
        if ref.hasPrefix("config.") {
            let key = String(ref.dropFirst(7))
            return c?.settings.first(where: { $0.key == key })?.label ?? key
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

    /// A setting's value from `entry.config` as text, or nil when it is not
    /// set (missing, null or empty — what the lib counts as unset).
    static func settingValue(_ s: Connector.Setting, in c: Connector) -> String? {
        switch c.config[s.key] {
        case .string(let v)?: return v.isEmpty ? nil : v
        case .number(let n)?: return n.formatted(.number.locale(L10n.locale))
        case .bool(let b)?: return L10n.tr(b ? "connectors.yes" : "connectors.no")
        default: return nil
        }
    }

    /// The required settings the Mac has not filled in, by label: a button
    /// that uses one is refused by the shared rule until they are.
    static func missingSettings(_ c: Connector) -> [String] {
        c.settings.filter { $0.required && settingValue($0, in: c) == nil }.map(\.label)
    }

    /// The setting key in the lib's "setting <key> is not set", else nil.
    static func unsetSetting(_ error: String) -> String? {
        guard error.hasPrefix("setting "), error.hasSuffix(" is not set") else { return nil }
        let key = error.dropFirst(8).dropLast(11)
        return key.isEmpty ? nil : String(key)
    }

    /// The manifest's own `fields[]` entry for a field, as lib reads it.
    static func manifestField(_ field: Connector.Field, in c: Connector) -> JSONValue? {
        guard case .object(let m) = c.manifest, case .array(let fs)? = m["fields"] else { return nil }
        return fs.first {
            if case .object(let f) = $0 { return f["key"] == .string(field.key) && f["attach"] == .string(field.attach) }
            return false
        }
    }

    /// A value for one of a connector's own fields, checked against its type
    /// by lib's own `coerceField` (`lib/plugin-host.js`, through
    /// `KhaytEngine.pluginCoerceField`) — the rule the Mac's `phoneRecord`
    /// runs on everything a phone sends under `plugins`. The ONE place the
    /// phone coerces. nil means "no value": the key is removed. A field the
    /// manifest does not hold, or an engine that cannot answer, is nil too.
    static func coerce(_ field: Connector.Field, _ raw: JSONValue?, in c: Connector,
                       engine: KhaytEngine) async -> JSONValue? {
        guard let raw, let f = manifestField(field, in: c),
              let v = try? await engine.pluginCoerceField(f, raw: raw), v != .null else { return nil }
        return v
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

        /// The job's or the customer's id.
        var recordId: String {
            switch self { case .order(let id), .customer(let id): id }
        }
    }

    /// What a tap came to.
    enum ConnectorOutcome: Equatable {
        /// Open this https link in Safari.
        case open(URL)
        /// Sent. `reply` is the connector's fields as the reply filled them,
        /// by label. `saved` is false when they could not be written on the
        /// record (the send still happened).
        case sent(reply: [String], saved: Bool = true)
        case failed(String)
    }

    /// The book's connectors, with their status. Empty without a book.
    func connectors() async -> [Connector] {
        guard let book, book.exists, let reader, let store = try? book.read(),
              case .object(let settings)? = store["settings"] else { return [] }
        let entries = ConnectorRules.entries(settings: settings)
        guard !entries.isEmpty, let engine = try? await reader.sharedEngine() else { return [] }
        let keys = await ConnectorRules.signingKeys(engine)
        var out: [Connector] = []
        for e in entries {
            guard let m = e["manifest"] else { continue }
            let check = try? await engine.pluginCheckEntry(.object(e))
            var reviewed = false
            if let canonical = try? await engine.pluginCanonicalJSON(m) {
                reviewed = Connectors.reviewedBy(manifest: m, canonical: canonical, keys: keys) != nil
            }
            if let c = ConnectorRules.connector(entry: e, check: check, reviewed: reviewed) { out.append(c) }
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
        if let why = ConnectorRules.disabledReason(c) { return .failed(why) }
        // The sample shop promises nothing leaves the phone: not a request,
        // and not a link carrying its made-up records either.
        guard !isSampleShop else { return .failed(L10n.tr("connectors.sample")) }
        guard action.placement == place.placement else { return .failed(L10n.tr("connectors.error.build")) }
        guard let reader, let engine = try? await reader.sharedEngine() else { return .failed(L10n.tr("connectors.error.build")) }

        let records = connectorRecords(place)
        // Only the secrets this tap needs are read from the Keychain; none
        // for a link. The URL's go into the engine, the rest stay in Swift.
        var secrets: [String: String] = [:]
        for name in ConnectorRules.secretNames(for: action, manifest: c.manifest) {
            guard let v = ConnectorKeys.get(c.id, name) else {
                return .failed(L10n.format("connectors.error.key_missing", secretLabel(c, name)))
            }
            secrets[name] = v
        }
        let made = ConnectorRules.context(action: action, order: records.order, customer: records.customer,
                                          config: c.config) { secrets[$0] }

        guard let payload = try? await engine.pluginPayload(
                c.manifest, trigger: .object(["action": .string(action.id)]), context: made.context) else {
            return .failed(L10n.tr("connectors.error.build"))
        }
        let prepared: ConnectorRules.Prepared
        do {
            prepared = try ConnectorRules.prepare(payload: payload, manifest: c.manifest, action: action,
                                                  secrets: secrets, delivery: Connectors.newDeliveryId(), now: Date())
        } catch let refusal as Connectors.Refusal {
            switch refusal {
            case .notBuilt(let why):
                // A required setting the Mac has not filled in, by its label.
                if let key = ConnectorRules.unsetSetting(why) {
                    let name = c.settings.first(where: { $0.key == key })?.label ?? key
                    return .failed(L10n.format("connectors.error.setting", name))
                }
                return .failed(L10n.tr("connectors.error.build"))
            case .undeclaredHost(let h) where h.isEmpty: return .failed(L10n.tr("connectors.error.scheme"))
            case .undeclaredHost(let h): return .failed(L10n.format("connectors.error.host", h))
            case .missingSecret(let n): return .failed(L10n.format("connectors.error.key_missing", secretLabel(c, n)))
            }
        } catch {
            return .failed(L10n.tr("connectors.error.build"))
        }

        let post: Connectors.Post
        switch prepared {
        case .open(let url): return .open(url)
        case .post(let p): post = p
        }
        var request = URLRequest(url: post.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = post.body
        request.httpShouldHandleCookies = false
        for h in post.headers { request.setValue(h.value, forHTTPHeaderField: h.name) }

        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let data: Data, response: URLResponse
        do {
            // No redirect is followed (`NoRedirects`): a 307 would carry the
            // body and the key to a host the shop never agreed to.
            (data, response) = try await session.data(for: request, delegate: NoRedirects())
        } catch {
            return .failed(L10n.format("connectors.error.network", post.url.host() ?? ""))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            return .failed(L10n.format("connectors.error.server", status))
        }
        // The reply, mapped by the shared rule into the connector's own
        // fields, then written on the record and shown. The shared rule maps
        // nothing unless the stored entry grants fields.write and is not paused.
        var mapped: JSONValue?
        if !data.isEmpty, let reply = try? JSONValue.parse(data) {
            mapped = try? await engine.pluginApplyResponse(c.manifest, actionId: action.id, reply: reply, entry: c.entry)
        }
        let lines = Self.replyLines(mapped, connector: c)
        var saved = lines.isEmpty
        if let book, book.exists {
            saved = await Self.saveReply(mapped, connector: c, at: place, book: book, engine: engine)
        }
        if saved, !lines.isEmpty {
            await refreshPendingCount()
            await deliverPending()
        }
        return .sent(reply: lines, saved: saved)
    }

    /// A reply's mapped fields as "Label: value" lines, by key.
    nonisolated static func replyLines(_ mapped: JSONValue?, connector c: Connector) -> [String] {
        guard case .object(let m)? = mapped else { return [] }
        return m.keys.sorted().compactMap { key in
            guard let field = c.fields.first(where: { $0.key == key }), let v = m[key] else { return nil }
            return "\(field.label): \(ConnectorRules.display(v, field: field))"
        }
    }

    /// Write a reply's mapped fields (`pluginApplyResponse`'s answer) on the
    /// record the button was pressed on. Nothing mapped is nothing to write,
    /// and counts as saved. False when the write failed — the send happened
    /// all the same.
    nonisolated static func saveReply(_ mapped: JSONValue?, connector c: Connector, at place: ConnectorPlace,
                          book: CompanionBook, engine: KhaytEngine) async -> Bool {
        guard case .object(let values)? = mapped, !values.isEmpty else { return true }
        do {
            try await BookWriter(book: book).setConnectorValues(values, connector: c, attach: place.placement,
                                                                recordId: place.recordId, engine: engine)
            return true
        } catch {
            return false
        }
    }

    /// Type a connector's own field values on a job or a customer
    /// (`BookWriter.setConnectorValues`), and send them on with the phone's
    /// other edits. Only an active connector's, on a phone that may edit.
    func setConnectorFields(_ c: Connector, at place: ConnectorPlace, values: [String: JSONValue]) async throws {
        guard ConnectorRules.canEditFields(c, canWrite: canWrite) else {
            throw KhaytAPIError.server(ConnectorRules.disabledReason(c) ?? L10n.tr("connectors.error.build"))
        }
        guard let book, book.exists, let reader else { throw BookWriter.Refusal.noSuchRecord }
        let engine = try await reader.sharedEngine()
        let changed = try await BookWriter(book: book).setConnectorValues(values, connector: c, attach: place.placement,
                                                                          recordId: place.recordId, engine: engine)
        guard changed else { return }
        await refreshPendingCount()
        await deliverPending()
    }

    /// `ConnectorRules.coerce` with this book's engine, for a sheet that
    /// greys out Save on a value the field would not take.
    func coerceConnectorField(_ field: Connector.Field, _ raw: JSONValue, in c: Connector) async -> JSONValue? {
        guard let reader, let engine = try? await reader.sharedEngine() else { return nil }
        return await ConnectorRules.coerce(field, raw, in: c, engine: engine)
    }

    private func secretLabel(_ c: Connector, _ name: String) -> String {
        c.secrets.first(where: { $0.name == name })?.label ?? name
    }
}
