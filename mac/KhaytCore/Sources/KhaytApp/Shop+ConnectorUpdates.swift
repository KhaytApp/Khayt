import Foundation
import CryptoKit
import KhaytCore

/// Connector updates on the Mac: the check against Khayt's signed index, and
/// the shop's Agree, Revert and switch on what a check found.
///
/// ── THE RULES ARE lib/, THE TRUST IS HERE ─────────────────────────────────
///
/// `lib/plugin-update.js` decides what an index means for the book (an update
/// that asks for nothing new installs by itself; one that asks for more waits
/// for the shop; a withdrawn version is paused), and does no cryptography.
/// What it cannot be trusted with is done here, the way the desktop's
/// `lib/main/connector-updates.js` does it:
///
///   - THE INDEX: its ed25519 signature must verify over
///     `indexSigningMessage(index)` with one of the built-in `SIGNING_KEYS`,
///     and the key that verifies must be the one the index names
///     (`Connectors.indexSignedBy`). No verified signer → `signedBy: null` →
///     the lib changes nothing.
///   - EVERY MANIFEST: the sha256 of the downloaded BYTES must match the
///     index row, then the manifest must validate and carry Khayt's signature
///     (`connectorReviewedBy`, the very check a hand install passes). Either
///     fails → not handed over; the lib treats it as a download that did not
///     arrive.
///   - WHERE IT IS WRITTEN: the network half runs first; the pure half
///     (`applyIndex`) runs again INSIDE the book's write, on the settings as
///     they are on disk, so a change made during the download is not lost.
///
/// A key goes only where it was entered for: when an update the shop agrees
/// to (or a revert) sends a key to a different set of hosts, that key is
/// removed from this Mac's Keychain, to be entered again (`keysToForget`).
///
/// Switched off like the desktop's: the check needs `KHAYT_CONNECTOR_UPDATES=1`
/// (or `defaults write <bundle id> KhaytConnectorUpdates -bool YES`) on top of
/// the connectors' own switch. The shop's answers only ever act on state a
/// check wrote, so they follow the connectors' switch alone.
@MainActor
extension Shop {

    /// Where the index lives. The desktop reads the same one.
    static let connectorIndexURL = URL(string: "https://khaytapp.com/connectors/index.json")!
    static let connectorIndexMaxBytes = 512 * 1024
    /// The hand-install limit.
    static let connectorManifestMaxBytes = 256 * 1024

    // MARK: - Reading

    /// `settings.connectorUpdates`, as the book holds it.
    var connectorUpdatesValue: JSONValue { settingsDict["connectorUpdates"] ?? .null }

    /// What a check left for one connector (`{}` for none).
    func connectorUpdateState(_ id: String) async -> [String: JSONValue] {
        guard let engine else { return [:] }
        return Self.object(try? await engine.pluginUpdateState(connectorUpdates: connectorUpdatesValue, id: id))
    }

    /// What the connector row says about updates.
    func connectorUpdateLine(_ entry: JSONValue) async -> ConnectorRow.Update {
        guard let engine, case .string(let id)? = Self.object(entry)["id"] else { return .init() }
        let state = await connectorUpdateState(id)
        let version = Shop.plainString(Self.object(entry)["version"]) ?? ""
        let waiting = (try? await engine.pluginUpdateWaiting(entry: entry, connectorUpdates: connectorUpdatesValue))
            .flatMap { Shop.plainString(Self.object($0)["version"]) }
        let revoked = Self.object(state["revoked"])
        let withdrawn = Shop.plainString(revoked["version"]) == version && !version.isEmpty
        let previous = Shop.plainString(Self.object(state["previous"])["version"])
        let updatedFrom = Shop.plainString(state["updatedFrom"])
        let canRevert = updatedFrom != nil && previous != nil
        let prevWithdrawn = Shop.plainString(state["previousWithdrawn"]).flatMap { $0.isEmpty ? nil : $0 }
        return .init(
            waiting: waiting,
            revertTo: canRevert ? previous : nil,
            updatedFrom: canRevert ? updatedFrom : nil,
            revertWithdrawn: canRevert ? nil : prevWithdrawn,
            withdrawn: withdrawn ? .init(version: version, reason: Shop.plainString(revoked["reason"]) ?? "") : nil,
            // While its version is withdrawn the entry is off whatever the shop
            // chose; the switch says what the shop chose (kept for the fix).
            switchedOn: withdrawn ? revoked["wasEnabled"] != .bool(false) : nil)
    }

    /// How many installed connectors have an update waiting on the shop's
    /// yes: the steel count on Settings ▸ Integrations.
    func refreshConnectorUpdatesWaiting(switchedOn: Bool = ConnectorsSwitch.isOn()) async {
        guard switchedOn, let engine else { connectorUpdatesWaiting = 0; return }
        var n = 0
        for entry in connectorEntries {
            if let w = try? await engine.pluginUpdateWaiting(entry: entry, connectorUpdates: connectorUpdatesValue), w != .null { n += 1 }
        }
        connectorUpdatesWaiting = n
    }

    /// What the update sheet shows for this connector, or nil when nothing waits.
    func connectorUpdateReview(_ id: String) async -> ConnectorUpdateReview? {
        guard let engine, let entry = Self.entry(in: .array(connectorEntries), id: id),
              let pending = try? await engine.pluginUpdateWaiting(entry: entry, connectorUpdates: connectorUpdatesValue),
              pending != .null,
              let sheet = try? await engine.pluginUpdateSheet(entry: entry, pending: pending) else { return nil }
        let manifest = Self.object(pending)["manifest"] ?? .null
        return ConnectorUpdateReview(
            id: id,
            name: Self.connectorLabel(Self.object(manifest)["name"], words.language, fallback: id),
            sheet: sheet,
            manifest: manifest,
            reviewed: await connectorReviewedBy(manifest) != nil)
    }

    /// The words for one line of the sheet.
    func connectorUpdateItemName(_ item: KhaytEngine.PluginUpdateSheet.Item, manifest: JSONValue) -> String {
        switch item.kind {
        case "link": return words.callIt("plg.consent_link_only")
        case "secret":
            let declared = Self.connectorSecretsDeclared(manifest).first { $0.name == item.key }
            return declared.map { Self.connectorLabel($0.label, words.language, fallback: item.key) } ?? item.key
        default: return connectorFieldLabel(item.key, manifest: manifest)
        }
    }

    // MARK: - Checking

    /// One check against the signed index: download, verify, then apply on the
    /// book as it is on disk. Returns what to tell the shop (one line per
    /// connector that updated or was withdrawn), empty when nothing changed.
    @discardableResult
    func checkConnectorUpdates() async -> [String] {
        // lock: system — the app's own hourly check of Khayt's signed index, not
        // a person's action; what it may write is only what the index and
        // the shop's earlier grants allow (an update that asks for more waits
        // for the shop's Agree, which asks the lock).
        guard ConnectorUpdatesSwitch.isOn(), let engine, source.build != nil else { return [] }
        guard let prepared = await prepareConnectorCheck(engine: engine) else { return [] }
        var notes: [JSONValue] = []
        let ok = await writeConnectorState({ settings in
            let r = Self.object(try await engine.pluginApplyIndex(settings: .object(settings), index: prepared.index,
                                                                   ctx: prepared.ctx, fetched: prepared.fetched))
            guard r["ok"] == .bool(true), r["changed"] == .bool(true) else { return nil }
            if case .array(let n)? = r["notes"] { notes = n }
            return Self.object(r["settings"])
        })
        await refreshConnectorUpdatesWaiting()
        guard ok else { return [] }
        return notes.compactMap { note in
            let n = Self.object(note)
            let id = Shop.plainString(n["id"]) ?? ""
            let name = Self.entry(in: .array(connectorEntries), id: id)
                .map { Self.connectorLabel(Self.object(Self.object($0)["manifest"])["name"], words.language, fallback: id) } ?? id
            switch Shop.plainString(n["kind"]) {
            case "updated":
                return words.callIt("plg.upd_updated", ["name": .string(name), "v": .string(Shop.plainString(n["to"]) ?? "")])
            case "revoked":
                let why = Shop.plainString(n["reason"]) ?? ""
                return words.callIt("plg.upd_revoked", ["v": .string(Shop.plainString(n["from"]) ?? "")]) + (why.isEmpty ? "" : " " + why)
            default: return nil
            }
        }
    }

    struct PreparedConnectorCheck: Sendable {
        let index: JSONValue
        let ctx: JSONValue
        let fetched: JSONValue
    }

    /// The network half: the index and every VERIFIED manifest it points this
    /// book to. Nil when the index cannot be fetched or read.
    func prepareConnectorCheck(engine: KhaytEngine) async -> PreparedConnectorCheck? {
        let fetch = connectorFetch ?? Self.fetchConnectorBytes
        guard let bytes = try? await fetch(Self.connectorIndexURL, Self.connectorIndexMaxBytes),
              let index = try? JSONDecoder().decode(JSONValue.self, from: bytes),
              let message = try? await engine.pluginIndexMessage(index),
              let keys = try? await engine.pluginSigningKeys() else { return nil }
        let signedBy = Connectors.indexSignedBy(index: index, message: message, keys: keys)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let ctx = JSONValue.object([
            "signedBy": signedBy.map(JSONValue.string) ?? .null,
            "nowMs": .number((Date().timeIntervalSince1970 * 1000).rounded()),
            "platform": .string("mac"),
            "appVersion": .string(version),
            "schema": .number(Double((try? await engine.pluginUpdateSchema()) ?? 1)),
        ])
        var fetched: [String: JSONValue] = [:]
        if case .array(let rows)? = try? await engine.pluginUpdateFetches(settings: settingsValue, index: index, ctx: ctx) {
            for row in rows {
                let r = Self.object(row)
                guard let id = Shop.plainString(r["id"]), let urlText = Shop.plainString(r["url"]),
                      let url = URL(string: urlText), let sha = Shop.plainString(r["sha256"]),
                      let data = try? await fetch(url, Self.connectorManifestMaxBytes),
                      let manifest = await verifiedConnectorManifest(data, sha256: sha, engine: engine) else { continue }
                fetched[id] = manifest
            }
        }
        return PreparedConnectorCheck(index: index, ctx: ctx, fetched: .object(fetched))
    }

    /// The manifest in these bytes, when they are the bytes the index promised
    /// AND the manifest is valid and signed by Khayt; else nil.
    func verifiedConnectorManifest(_ data: Data, sha256: String, engine: KhaytEngine) async -> JSONValue? {
        guard data.count <= Self.connectorManifestMaxBytes else { return nil }
        let got = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard got == sha256.lowercased(),
              let manifest = try? JSONDecoder().decode(JSONValue.self, from: data),
              let valid = try? await engine.pluginValidate(manifest),
              Self.object(valid)["ok"] == .bool(true),
              await connectorReviewedBy(manifest) != nil else { return nil }
        return manifest
    }

    /// HTTPS only, no redirects, a size cap and a 15-second limit.
    nonisolated static func fetchConnectorBytes(_ url: URL, _ maxBytes: Int) async throws -> Data {
        guard url.scheme == "https" else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        // A redirect is refused, not followed (`RefuseRedirects`, Camera.swift):
        // the index and manifests come from where Khayt says, or not at all.
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request, delegate: RefuseRedirects.shared)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        guard data.count <= maxBytes else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }

    // MARK: - The shop's answers

    /// The shop agreed to the waiting version. Returns what to tell the shop.
    func agreeConnectorUpdate(_ id: String) async -> String {
        guard let engine else { return words.callIt("mac.move_no_engine") }
        let name = Self.entry(in: .array(connectorEntries), id: id)
            .map { Self.connectorLabel(Self.object(Self.object($0)["manifest"])["name"], words.language, fallback: id) } ?? id
        let r = await applyConnectorAnswer(id) { settings in
            try await engine.pluginAgreeUpdate(settings: .object(settings), id: id, now: Date())
        }
        guard case .done(let after) = r else { return failure(r) }
        let version = Shop.plainString(Self.object(after)["version"]) ?? ""
        return words.callIt("plg.upd_updated", ["name": .string(name), "v": .string(version)])
    }

    /// Back to the version before the last update. Returns what to tell the shop.
    func revertConnectorUpdate(_ id: String) async -> String {
        guard let engine else { return words.callIt("mac.move_no_engine") }
        let r = await applyConnectorAnswer(id) { settings in
            try await engine.pluginRevertUpdate(settings: .object(settings), id: id)
        }
        switch r {
        case .done(let after):
            return words.callIt("plg.upd_reverted", ["v": .string(Shop.plainString(Self.object(after)["version"]) ?? "")])
        case .refused("revoked"):
            // Khayt withdrew the version it would go back to: say so.
            let st = await connectorUpdateState(id)
            let v = Shop.plainString(st["previousWithdrawn"]) ?? Shop.plainString(Self.object(st["previous"])["version"]) ?? ""
            return words.callIt("plg.upd_revert_withdrawn", ["v": .string(v)])
        default:
            return failure(r)
        }
    }

    /// The shop's switch on a book connector, through the lib: while its
    /// version is withdrawn the entry stays off and the choice is kept for the
    /// fixed version (`setSwitch`).
    func switchConnector(_ id: String, enabled: Bool) async {
        guard let engine else { return }
        _ = await applyConnectorAnswer(id) { settings in
            try await engine.pluginSetSwitch(settings: .object(settings), id: id, enabled: enabled)
        }
    }

    enum ConnectorAnswer { case done(JSONValue), refused(String), failed }

    private func failure(_ r: ConnectorAnswer) -> String {
        if case .refused(let why) = r, !why.isEmpty { return words.callIt("plg.err_failed", ["why": .string(why)]) }
        return settingsProblem ?? words.callIt("plg.err_failed", ["why": .string("?")])
    }

    /// One of the lib's answers (`{ ok, settings, reason? }`) applied to the
    /// book on disk, then the keys whose hosts moved dropped from the Keychain.
    private func applyConnectorAnswer(_ id: String,
                                      _ answer: @escaping ([String: JSONValue]) async throws -> JSONValue) async -> ConnectorAnswer {
        guard permitted("settings", "edit"), let engine else { return .failed }
        var before: JSONValue?
        var after: JSONValue?
        var refused: String?
        let ok = await writeConnectorState({ settings in
            let r = Self.object(try await answer(settings))
            guard r["ok"] == .bool(true) else {
                refused = Shop.plainString(r["reason"]) ?? ""
                return nil
            }
            let next = Self.object(r["settings"])
            before = Self.entry(in: settings["plugins"] ?? .null, id: id)
            after = Self.entry(in: next["plugins"] ?? .null, id: id)
            return next
        })
        await refreshConnectorUpdatesWaiting()
        if let refused { return .refused(refused) }
        guard ok, let after else { return .failed }
        if let before, let forget = try? await engine.pluginKeysToForget(before: before, after: after), !forget.isEmpty {
            await connectorSecrets.removeAll(pluginId: id, names: forget)
        }
        return .done(after)
    }

    /// One read-modify-write of the book's `plugins` and `connectorUpdates`,
    /// on the settings as they are on disk. `change` returns the new settings,
    /// or nil to write nothing; ONLY those two keys are taken from it.
    private func writeConnectorState(_ change: @escaping ([String: JSONValue]) async throws -> [String: JSONValue]?) async -> Bool {
        // lock: callers — checkConnectorUpdates, applyConnectorAnswer
        guard let build = source.build else { settingsProblem = words.callIt("mac.move_sample"); return false }
        var wrote = false
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                var settings = Self.settings(root)
                guard let next = try await change(settings) else { return }
                settings = Self.withConnectorState(settings, from: next)
                root["settings"] = .object(settings)
                wrote = true
            }
            if wrote { await load(source) }
            return wrote
        } catch {
            settingsProblem = said(error)
            return false
        }
    }
}

extension Shop {
    /// `settings` with ONLY `plugins` and `connectorUpdates` taken from `next`
    /// (a key `next` dropped is dropped): an update never writes the rest of
    /// the shop's settings, whatever the lib handed back.
    nonisolated static func withConnectorState(_ settings: [String: JSONValue],
                                               from next: [String: JSONValue]) -> [String: JSONValue] {
        var out = settings
        for key in ["plugins", "connectorUpdates"] {
            if let v = next[key] { out[key] = v } else { out.removeValue(forKey: key) }
        }
        return out
    }
}

/// The check against the signed index is off until updates ship, like the
/// desktop's `KHAYT_CONNECTOR_UPDATES=1`, and only ever on top of the
/// connectors' own switch. `defaults write <bundle id> KhaytConnectorUpdates
/// -bool YES` for a build opened from Finder.
enum ConnectorUpdatesSwitch {
    nonisolated static func isOn(environment: [String: String] = ProcessInfo.processInfo.environment,
                                 defaults: UserDefaults = .standard) -> Bool {
        ConnectorsSwitch.isOn(environment: environment, defaults: defaults)
            && (environment["KHAYT_CONNECTOR_UPDATES"] == "1" || defaults.bool(forKey: "KhaytConnectorUpdates"))
    }
}

/// What the update sheet shows (Figma 70:284).
struct ConnectorUpdateReview: Identifiable, Equatable {
    let id: String
    let name: String
    let sheet: KhaytEngine.PluginUpdateSheet
    let manifest: JSONValue
    /// Khayt's signature on the waiting manifest verifies.
    let reviewed: Bool
}
