import Foundation
import KhaytCore

/// Connectors on the Mac: installing one with the shop's consent, switching it
/// on and off, removing it, and giving it its keys.
///
/// ── THE RULES ARE lib/, THE TRUST IS HERE ─────────────────────────────────
///
/// What a connector is, what it may ask for, what the shop is shown and how a
/// stored entry changes are `lib/plugin-manifest.js` and `lib/plugin-host.js`,
/// the same on every device. What the JavaScript cannot be trusted with stays
/// in Swift: whether a manifest is REVIEWED (an ed25519 signature checked by
/// CryptoKit in `Connectors.reviewedBy`, every time, never a stored flag) and
/// the keys (this Mac's Keychain, `ConnectorSecrets.swift`, never the book).
///
/// ── THE BOOK HOLDS THE ENTRY ─────────────────────────────────────────────
///
/// `settings.plugins[]`: `{ id, version, enabled, manifest, granted, config }`,
/// the shape the desktop writes and the phone reads. The phone asks the Mac
/// for nothing: the grant it honours is the one written here.
@MainActor
extension Shop {

    // MARK: - Reading

    /// The book's installed connectors, as stored.
    var connectorEntries: [JSONValue] {
        if case .array(let rows)? = settingsDict["plugins"] { return rows }
        return []
    }

    /// This Mac's dev connectors (`DevConnectors`), running or not. Never the book's.
    var devConnectorEntries: [JSONValue] { DevConnectors.entries(defaults: devConnectorDefaults) }

    /// The dev connectors that may run now, beside the book's.
    var runningDevConnectors: [JSONValue] {
        DevConnectors.running(besides: connectorEntries, defaults: devConnectorDefaults)
    }

    /// A dev connector, not one the shop installed (the shop's wins on the same id).
    func isDevConnector(_ id: String) -> Bool {
        Self.entry(in: .array(connectorEntries), id: id) == nil && Self.entry(in: .array(devConnectorEntries), id: id) != nil
    }

    /// An installed connector by id: the book's, else this Mac's dev one.
    func anyConnectorEntry(_ id: String) -> JSONValue? {
        Self.entry(in: .array(connectorEntries), id: id) ?? Self.entry(in: .array(devConnectorEntries), id: id)
    }

    /// The id of the Khayt key a manifest's signature verifies against, or nil.
    func connectorReviewedBy(_ manifest: JSONValue) async -> String? {
        guard let engine,
              let canonical = try? await engine.pluginCanonicalJSON(manifest),
              let keys = try? await engine.pluginSigningKeys() else { return nil }
        return Connectors.reviewedBy(manifest: manifest, canonical: canonical, keys: keys)
    }

    /// Each installed connector as the Settings list shows it.
    func connectorRows() async -> [ConnectorRow] {
        guard let engine else { return [] }
        var out: [ConnectorRow] = []
        let devOn = DevConnectors.isOn(defaults: devConnectorDefaults)
        let book = connectorEntries
        let bookIds = Set(book.compactMap { Shop.plainString(Self.object($0)["id"]) })
        let dev = devConnectorEntries.filter { !bookIds.contains(Shop.plainString(Self.object($0)["id"]) ?? "") }
        for (entry, isDev) in book.map({ ($0, false) }) + dev.map({ ($0, true) }) {
            guard case .object(let e) = entry, case .string(let id)? = e["id"] else { continue }
            let manifest = e["manifest"] ?? .null
            // Developer mode waives the review for a dev entry, and only while on.
            let reviewed = isDev ? devOn : await connectorReviewedBy(manifest) != nil
            let state = (try? await engine.pluginStateOf(entry, reviewed: reviewed)) ?? "invalid"
            let declared = Self.connectorSecretsDeclared(manifest)
            let held = await connectorSecrets.held(pluginId: id, names: declared.map(\.name))
            out.append(ConnectorRow(
                id: id,
                name: Self.connectorLabel(Self.object(manifest)["name"], words.language, fallback: id),
                version: Shop.plainString(e["version"]) ?? "",
                state: state,
                secrets: declared.map { .init(name: $0.name, label: Self.connectorLabel($0.label, words.language, fallback: $0.name),
                                              held: held.contains($0.name)) },
                settings: Self.settingRows(entry, lang: words.language),
                dev: isDev))
        }
        return out
    }

    /// A connector's settings as the form shows them, with what is saved.
    nonisolated static func settingRows(_ entry: JSONValue, lang: String) -> [ConnectorRow.Setting] {
        let e = object(entry)
        let saved = object(e["config"])
        guard case .array(let list)? = object(e["manifest"])["settings"] else { return [] }
        return list.compactMap { item in
            let st = object(item)
            guard case .string(let key)? = st["key"], case .string(let type)? = st["type"] else { return nil }
            var options: [ConnectorRow.Setting.Option] = []
            if case .array(let opts)? = st["options"] {
                options = opts.compactMap { o in
                    guard case .string(let v)? = object(o)["value"] else { return nil }
                    return .init(value: v, label: connectorLabel(object(o)["label"], lang, fallback: v))
                }
            }
            let value: String
            switch saved[key] {
            case .string(let s)?: value = s
            case .number(let n)?: value = n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
            case .bool(let b)?: value = b ? "true" : ""
            default: value = ""
            }
            return .init(key: key, label: connectorLabel(st["label"], lang, fallback: key), type: type,
                         required: st["required"] == .bool(true), options: options, value: value)
        }
    }

    /// The shop's settings for a connector, saved into the book (synced, not
    /// secret). Returns false when nothing was written.
    func saveConnectorSettings(_ id: String, _ values: [String: String], ticks: [String: Bool]) async -> Bool {
        guard let engine else { return false }
        var raw: [String: JSONValue] = values.mapValues { .string($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        for (k, v) in ticks { raw[k] = .bool(v) }
        let sent = JSONValue.object(raw)
        return await writeConnectors(dev: isDevConnector(id)) { plugins in
            guard let entry = Self.entry(in: plugins, id: id) else { return plugins }
            let next = try await engine.pluginWithConfig(entry, values: sent)
            return try await engine.pluginWithEntry(plugins, entry: next)
        }
    }

    // MARK: - Installing

    /// Read a connector file and, if it may be installed here, put it in front
    /// of the shop as `connectorOffer`. Returns what to tell the shop when it
    /// may not; nil when the consent sheet is up.
    ///
    /// Only a manifest Khayt has signed is offered: an unreviewed one is
    /// refused here, before anything about it is shown as if it were real.
    /// `dev` is a `.khaytplugin` loaded in developer mode: offered signed or
    /// not, kept on this Mac only, and never over a connector the shop has.
    func offerConnector(_ data: Data, dev: Bool = false) async -> String? {
        guard let engine else { return words.callIt("mac.move_no_engine") }
        guard let manifest = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let m) = manifest,
              let valid = try? await engine.pluginValidate(manifest),
              Self.object(valid)["ok"] == .bool(true),
              case .string(let id)? = m["id"] else {
            return words.callIt("plg.err_invalid")
        }
        let reviewer = await connectorReviewedBy(manifest)
        if dev {
            guard DevConnectors.isOn(defaults: devConnectorDefaults) else { return words.callIt("plg.err_unreviewed") }
            guard Self.entry(in: .array(connectorEntries), id: id) == nil else { return words.callIt("plg.dev_taken") }
        } else if reviewer == nil {
            return words.callIt("plg.err_unreviewed")
        }
        let rows = (try? await engine.pluginConsentRows(manifest)) ?? []
        var scopes: [String] = []
        if case .array(let s)? = m["scopes"] { scopes = s.compactMap { if case .string(let v) = $0 { v } else { nil } } }
        let installed = Self.entry(in: .array(dev ? devConnectorEntries : connectorEntries), id: id)
        connectorOffer = ConnectorOffer(
            manifestId: id,
            name: Self.connectorLabel(m["name"], words.language, fallback: id),
            version: Shop.plainString(m["version"]) ?? "",
            reviewedBy: reviewer,
            manifest: manifest,
            rows: rows.map { row in
                let r = Self.object(row)
                var fields: [String] = []
                if case .array(let fs)? = r["fields"] {
                    fields = fs.map { f in
                        let o = Self.object(f)
                        let key = Shop.plainString(o["key"]) ?? ""
                        let cat = Shop.plainString(o["category"]) ?? ""
                        return "\(connectorFieldLabel(key, manifest: manifest)) (\(words.callIt("plg.cat." + cat)))"
                    }
                }
                return .init(host: Shop.plainString(r["host"]) ?? "", fields: fields)
            },
            scopes: scopes,
            replacing: installed.flatMap { Shop.plainString(Self.object($0)["version"]) },
            dev: dev,
            refreshLine: Self.refreshLine((try? await engine.pluginRefreshConsent(manifest, lang: words.language)) ?? .null,
                                          words: words))
        return nil
    }

    /// The consent sheet's line for a connector that checks on its own.
    static func refreshLine(_ consent: JSONValue, words: Words) -> String? {
        let c = object(consent)
        guard let every = Shop.plainNumber(c["every"]), every > 0, let host = Shop.plainString(c["host"]) else { return nil }
        return words.callIt("plg.consent_refresh", ["n": .string(String(Int(every))), "host": .string(host),
                                                    "field": .string(Shop.plainString(c["fieldLabel"]) ?? "")])
    }

    /// The shop agreed: store the entry, granted exactly what it was shown.
    /// Installing over the same connector keeps its settings, its switch and
    /// this Mac's keys. Returns what to tell the shop.
    func installOfferedConnector() async -> String {
        guard let offer = connectorOffer, let engine else { return words.callIt("mac.move_no_engine") }
        // The signature is checked again at the moment of writing, on the very
        // bytes being stored — not trusted from when the sheet opened.
        if offer.dev {
            guard DevConnectors.isOn(defaults: devConnectorDefaults),
                  Self.entry(in: .array(connectorEntries), id: offer.manifestId) == nil else {
                connectorOffer = nil
                return words.callIt("plg.err_unreviewed")
            }
        } else {
            guard await connectorReviewedBy(offer.manifest) != nil else { return words.callIt("plg.err_unreviewed") }
        }
        let ok = await writeConnectors(dev: offer.dev) { plugins in
            try await Self.withConsented(offer.manifest, in: plugins, engine: engine)
        }
        connectorOffer = nil
        return ok ? words.callIt("plg.installed").replacingOccurrences(of: "{name}", with: offer.name)
                  : (settingsProblem ?? words.callIt("mac.move_sample"))
    }

    /// Switch an installed connector on or off. Its fields stay on the records.
    func setConnector(_ id: String, enabled: Bool) async {
        _ = await writeConnectors(dev: isDevConnector(id)) { plugins in
            guard case .array(var rows) = plugins,
                  let i = rows.firstIndex(where: { Self.object($0)["id"] == .string(id) }),
                  case .object(var e) = rows[i] else { return plugins }
            e["enabled"] = .bool(enabled)
            rows[i] = .object(e)
            return .array(rows)
        }
    }

    /// Remove a connector, and its keys from this Mac. What it filled in on
    /// jobs and customers stays: those values are the shop's.
    func removeConnector(_ id: String) async {
        let manifest = anyConnectorEntry(id).map { Self.object($0)["manifest"] ?? .null }
        guard let engine else { return }
        let ok = await writeConnectors(dev: isDevConnector(id)) { plugins in try await engine.pluginWithoutEntry(plugins, id: id) }
        if ok, let manifest {
            await connectorSecrets.removeAll(pluginId: id, names: Self.connectorSecretsDeclared(manifest).map(\.name))
        }
    }

    /// Keep keys for a connector on this Mac. Only names its manifest declares
    /// are kept; an empty value leaves what is there.
    func saveConnectorKeys(_ id: String, _ values: [String: String]) async -> Bool {
        // lock: the keys are this Mac's, not the book's, but giving a connector
        // the means to act for the shop is a settings change like any other.
        guard permitted("settings", "edit") else { return false }
        guard let entry = anyConnectorEntry(id) else { return false }
        let declared = Set(Self.connectorSecretsDeclared(Self.object(entry)["manifest"] ?? .null).map(\.name))
        for (name, value) in values where declared.contains(name) {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { await connectorSecrets.set(v, pluginId: id, name: name) }
        }
        return true
    }

    // MARK: - Writing

    /// `settings.plugins` once the shop agreed to `manifest`: the entry
    /// granted exactly what was shown, replacing one with the same id and
    /// keeping its settings and switch (`lib/plugin-host.js consentedEntry`).
    nonisolated static func withConsented(_ manifest: JSONValue, in plugins: JSONValue,
                                          engine: KhaytEngine) async throws -> JSONValue {
        guard case .string(let id)? = object(manifest)["id"] else { return plugins }
        let entry = try await engine.pluginConsentedEntry(prev: entry(in: plugins, id: id) ?? .null, manifest: manifest)
        return try await engine.pluginWithEntry(plugins, entry: entry)
    }

    /// One read-modify-write of `settings.plugins`, on the book as it is on disk.
    /// With `dev`, the same change made to this Mac's dev connectors instead:
    /// nothing in the book moves.
    private func writeConnectors(dev: Bool = false,
                                 _ change: @escaping (JSONValue) async throws -> JSONValue) async -> Bool {
        guard permitted("settings", "edit") else { return false }
        if dev {
            do {
                DevConnectors.save(try await change(.array(devConnectorEntries)), defaults: devConnectorDefaults)
                devConnectorsRev += 1
                return true
            } catch {
                settingsProblem = said(error)
                return false
            }
        }
        guard let build = source.build else { settingsProblem = words.callIt("mac.move_sample"); return false }
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                var settings = Self.settings(root)
                settings["plugins"] = try await change(settings["plugins"] ?? .array([]))
                root["settings"] = .object(settings)
            }
            await load(source)
            return true
        } catch {
            settingsProblem = said(error)
            return false
        }
    }

    // MARK: - Labels

    /// What the consent sheet calls a field: Khayt's own word for a book
    /// field, the manifest's label for the connector's own field or setting.
    func connectorFieldLabel(_ key: String, manifest: JSONValue) -> String {
        let m = Self.object(manifest)
        for (prefix, list, idKey) in [("field.", "fields", "key"), ("config.", "settings", "key")] where key.hasPrefix(prefix) {
            let k = String(key.dropFirst(prefix.count))
            if case .array(let rows)? = m[list],
               let row = rows.first(where: { Self.object($0)[idKey] == .string(k) }) {
                return Self.connectorLabel(Self.object(row)["label"], words.language, fallback: k)
            }
            return k
        }
        let word = words.callIt("plg.f." + key)
        return word == "plg.f." + key ? key : word
    }

    /// `lib/plugin-host.js labelOf`, without a trip to the engine: the shop's
    /// language, its base, English, then the first one.
    nonisolated static func connectorLabel(_ label: JSONValue?, _ lang: String, fallback: String) -> String {
        switch label {
        case .string(let s)?: return s
        case .object(let o)?:
            let base = String(lang.split(separator: "-").first ?? "")
            for k in [lang, base, "en"] { if case .string(let s)? = o[k], !s.isEmpty { return s } }
            for k in o.keys.sorted() { if case .string(let s)? = o[k], !s.isEmpty { return s } }
            return fallback
        default: return fallback
        }
    }

    nonisolated static func connectorSecretsDeclared(_ manifest: JSONValue) -> [(name: String, label: JSONValue?)] {
        guard case .array(let rows)? = object(manifest)["secrets"] else { return [] }
        return rows.compactMap { r in
            guard case .string(let n)? = object(r)["name"] else { return nil }
            return (n, object(r)["label"])
        }
    }

    nonisolated static func object(_ v: JSONValue?) -> [String: JSONValue] {
        if case .object(let o)? = v { return o }
        return [:]
    }

    nonisolated static func entry(in plugins: JSONValue, id: String) -> JSONValue? {
        guard case .array(let rows) = plugins else { return nil }
        return rows.first { object($0)["id"] == .string(id) }
    }
}

/// A connector waiting on the shop's OK: everything the consent sheet shows.
struct ConnectorOffer: Identifiable, Equatable {
    var id: String { manifestId }
    let manifestId: String
    let name: String
    let version: String
    /// The Khayt key that signed it — the sheet says "Reviewed by Khayt".
    /// Nil only for a dev connector (`dev`).
    let reviewedBy: String?
    let manifest: JSONValue
    /// One per address: the fields that go there, labelled, with their category.
    let rows: [Row]
    let scopes: [String]
    /// The installed version this replaces, if any.
    let replacing: String?
    /// Loaded in developer mode: kept on this Mac only (`DevConnectors`).
    var dev: Bool = false
    /// "Every 30 min … checks api.example.com …" (`plg.consent_refresh`), for
    /// a connector that checks open jobs on its own; nil when it never does.
    var refreshLine: String? = nil

    struct Row: Equatable, Identifiable {
        var id: String { host }
        let host: String
        let fields: [String]
    }
}

/// One installed connector, as the Settings list shows it.
struct ConnectorRow: Identifiable, Equatable {
    let id: String
    let name: String
    let version: String
    /// 'on', 'off', 'paused', 'unreviewed' or 'invalid' (`lib/plugin-host.js stateOf`).
    let state: String
    let secrets: [Secret]

    struct Secret: Equatable, Identifiable {
        var id: String { name }
        let name: String
        let label: String
        let held: Bool
    }

    var settings: [Setting] = []
    /// A dev connector: this Mac only, not reviewed by Khayt (`DevConnectors`).
    var dev: Bool = false

    /// One of the shop's settings for this connector (manifest `settings[]`).
    struct Setting: Equatable, Identifiable {
        var id: String { key }
        let key: String
        let label: String
        /// text, number, bool or enum.
        let type: String
        let required: Bool
        let options: [Option]
        /// As saved; "" for none, "true" for a ticked box.
        let value: String
        struct Option: Equatable, Hashable { let value: String; let label: String }
    }

    var keysMissing: Bool { secrets.contains { !$0.held } }
    var settingsMissing: Bool { settings.contains { $0.required && $0.value.isEmpty } }
}
