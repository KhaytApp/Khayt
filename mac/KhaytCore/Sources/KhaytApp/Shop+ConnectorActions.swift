import Foundation
import KhaytCore
#if canImport(AppKit)
import AppKit
#endif

/// A connector at work on a job or a customer: its buttons, its own fields,
/// and what a press does.
///
/// ── THE SAME REQUEST AS EVERY OTHER DEVICE ──────────────────────────────
///
/// The request is `lib/plugin-payload.js` payloadFor's, byte for byte, and the
/// headers are `Connectors.post`'s (KhaytCore, which the phone sends with too).
/// It leaves through `WebhookClient` — DNS pinned and checked, never a private
/// address, no redirect followed — with the desktop's limits: 15 seconds, and
/// a reply over 64 KB is not read.
///
/// ── A REPLY FILLS THE CONNECTOR'S OWN FIELDS, AND NOTHING ELSE ──────────
///
/// `applyResponse` maps the reply into fields the connector declared, and
/// only with fields.write granted. The write goes through `StoreWriter`, which
/// raises the record's `rev`: that is what stops a phone holding an older copy
/// of the job from putting the old value back (`LanServer.foldFromPhone`).
///
/// A press is never retried: a second one is the shop's to make.
@MainActor
extension Shop {

    /// Live connectors on this Mac: switched on, valid, granted, and signed by
    /// Khayt (checked now, never read from a flag).
    func liveConnectors() async -> [JSONValue] {
        guard let engine else { return [] }
        var out: [JSONValue] = []
        for entry in connectorEntries {
            let reviewed = await connectorReviewedBy(Self.object(entry)["manifest"] ?? .null) != nil
            if (try? await engine.pluginStateOf(entry, reviewed: reviewed)) == "on" { out.append(entry) }
        }
        return out
    }

    /// The buttons for a job (`order`) or a customer (`customer`).
    func connectorButtons(placement: String) async -> [ConnectorButton] {
        guard ConnectorsSwitch.isOn() else { return [] }
        return Self.buttons(in: await liveConnectors(), placement: placement, lang: words.language)
    }

    nonisolated static func buttons(in entries: [JSONValue], placement: String, lang: String) -> [ConnectorButton] {
        var out: [ConnectorButton] = []
        for entry in entries {
            let e = object(entry)
            guard case .string(let id)? = e["id"], case .array(let actions)? = object(e["manifest"])["actions"] else { continue }
            for action in actions {
                let a = object(action)
                guard a["placement"] == .string(placement), case .string(let actionId)? = a["id"] else { continue }
                out.append(ConnectorButton(entryId: id, actionId: actionId,
                                           label: connectorLabel(a["label"], lang, fallback: actionId),
                                           opensPage: a["kind"] == .string("open")))
            }
        }
        return out
    }

    /// The connectors' own fields on a record, with their values. Editable
    /// only for a connector that is on.
    func connectorFields(attach: String, plugins: JSONValue?) async -> [ConnectorFieldRow] {
        guard ConnectorsSwitch.isOn() else { return [] }
        let live = Set(await liveConnectors().compactMap { Shop.plainString(Self.object($0)["id"]) })
        return Self.fieldRows(connectorEntries, live: live, attach: attach, plugins: plugins, lang: words.language)
    }

    nonisolated static func fieldRows(_ entries: [JSONValue], live: Set<String>, attach: String,
                                      plugins: JSONValue?, lang: String) -> [ConnectorFieldRow] {
        let values = object(plugins)
        var out: [ConnectorFieldRow] = []
        for entry in entries {
            let e = object(entry)
            guard case .string(let id)? = e["id"], case .array(let fields)? = object(e["manifest"])["fields"] else { continue }
            let mine = object(values[id])
            for field in fields {
                let f = object(field)
                guard f["attach"] == .string(attach), case .string(let key)? = f["key"] else { continue }
                let shown: String
                switch mine[key] {
                case .string(let s)?: shown = s
                case .number(let n)?: shown = Money.fieldValue(n)
                case .bool(let b)?: shown = b ? "✓" : ""
                default: shown = ""
                }
                // Nothing to show for a connector that is not on and has
                // never filled this field in.
                guard live.contains(id) || !shown.isEmpty else { continue }
                out.append(ConnectorFieldRow(entryId: id, key: key,
                                             label: connectorLabel(f["label"], lang, fallback: key),
                                             value: shown, editable: live.contains(id)))
            }
        }
        return out
    }

    // MARK: - A press

    /// A button pressed on a job (`jobId`) or a customer (`clientId`). Returns
    /// what to tell the shop; `ok` is false for anything not sent or refused.
    func pressConnector(_ button: ConnectorButton, jobId: String?, clientId: String?) async -> (ok: Bool, message: String) {
        guard ConnectorsSwitch.isOn() else { return (false, words.callIt("plg.err_refused", ["why": .string("off")])) }
        let attach = jobId != nil ? "order" : "customer"
        guard permitted(attach == "order" ? "orders" : "clients", "edit") else { return (false, moveProblem ?? "") }
        guard let engine else { return (false, words.callIt("mac.move_no_engine")) }
        guard let build = source.build else { return (false, words.callIt("mac.move_sample")) }
        guard let entry = await liveConnectors().first(where: { Self.object($0)["id"] == .string(button.entryId) }) else {
            return (false, words.callIt("plg.err_refused", ["why": .string("off")]))
        }
        let root: [String: JSONValue]
        do {
            root = try await BookWork.run {
                try JSONValue.decode([String: JSONValue].self, from: Data(contentsOf: build.storeURL))
            }
        } catch {
            return (false, said(error))
        }
        let order = jobId.flatMap { Self.record(in: root, "printLog", id: $0) }
        let clientKey = clientId ?? order.flatMap { Shop.plainString(Self.object($0)["clientId"]) }
        let customer = clientKey.flatMap { Self.record(in: root, "clients", id: $0) }
        guard (attach == "order" ? order : customer) != nil else {
            return (false, words.callIt("plg.err_refused", ["why": .string("not found")]))
        }
        let names = Self.connectorSecretsDeclared(Self.object(entry)["manifest"] ?? .null).map(\.name)
        var secrets: [String: String] = [:]
        for n in names { if let v = await connectorSecrets.value(pluginId: button.entryId, name: n), !v.isEmpty { secrets[n] = v } }

        let outcome = await Self.connectorSend(entry: entry, actionId: button.actionId, order: order, customer: customer,
                                               secrets: secrets, engine: engine, post: connectorPost ?? Self.realConnectorPost(engine),
                                               now: Date())
        switch outcome {
        case .refused(let why):
            return (false, Self.refusalText(entry: entry, why: why, words: words))
        case .open(let url):
            #if canImport(AppKit)
            NSWorkspace.shared.open(url)
            #endif
            return (true, "")
        case .failed(let why):
            return (false, words.callIt("plg.err_failed", ["why": .string(why)]))
        case .sent(let values):
            if case .object(let v) = values, !v.isEmpty {
                let id = attach == "order" ? jobId : clientKey
                guard let id, await writeConnectorValues(entry: entry, attach: attach, recordId: id, values: values) else {
                    return (false, settingsProblem ?? words.callIt("plg.err_refused", ["why": .string("write")]))
                }
            }
            return (true, words.callIt("plg.sent"))
        }
    }

    /// The shop typed into a connector's own fields on a job or customer.
    func saveConnectorFields(entryId: String, attach: String, recordId: String, values: [String: String]) async -> Bool {
        guard ConnectorsSwitch.isOn(),
              let entry = await liveConnectors().first(where: { Self.object($0)["id"] == .string(entryId) }) else { return false }
        return await writeConnectorValues(entry: entry, attach: attach, recordId: recordId,
                                          values: .object(values.mapValues(JSONValue.string)))
    }

    /// One read-modify-write of one record's connector values.
    private func writeConnectorValues(entry: JSONValue, attach: String, recordId: String, values: JSONValue) async -> Bool {
        guard permitted(attach == "order" ? "orders" : "clients", "edit") else { return false }
        guard let engine, let build = source.build else { return false }
        let collection = attach == "order" ? "printLog" : "clients"
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                try await Self.withConnectorValues(&root, collection: collection, id: recordId, entry: entry,
                                                   attach: attach, values: values, engine: engine)
            }
            await load(source)
            return true
        } catch {
            settingsProblem = said(error)
            return false
        }
    }

    /// `root` with one record's connector values written. `StoreWriter`
    /// raises its `rev` because its content changed (`stampChanged`).
    nonisolated static func withConnectorValues(_ root: inout [String: JSONValue], collection: String, id: String,
                                                entry: JSONValue, attach: String, values: JSONValue,
                                                engine: KhaytEngine) async throws {
        guard case .array(var rows)? = root[collection],
              let i = rows.firstIndex(where: { object($0)["id"] == .string(id) }) else { return }
        rows[i] = try await engine.pluginWithFieldValues(rows[i], entry: entry, attach: attach, values: values)
        root[collection] = .array(rows)
    }

    nonisolated static func record(in root: [String: JSONValue], _ collection: String, id: String) -> JSONValue? {
        guard case .array(let rows)? = root[collection] else { return nil }
        return rows.first { object($0)["id"] == .string(id) }
    }

    // MARK: - The request, without the window

    enum ConnectorOutcome: Equatable {
        /// Nothing was sent; `why` is the rule's own reason, in English.
        case refused(String)
        case open(URL)
        /// Sent and accepted; `values` is what the reply fills in (maybe none).
        case sent(JSONValue)
        case failed(String)
    }

    typealias ConnectorPost = @Sendable (Connectors.Post) async throws -> (status: Int, body: Data?)

    nonisolated static let connectorTimeout: TimeInterval = 15
    nonisolated static let connectorReplyMax = 64 * 1024

    nonisolated static func realConnectorPost(_ engine: KhaytEngine) -> ConnectorPost {
        { post in
            try await WebhookClient.postReading(post.body, to: post.url, headers: post.headers.map { ($0.name, $0.value) },
                                                engine: engine, timeout: connectorTimeout, keep: connectorReplyMax)
        }
    }

    /// Build, send and read one press. The entry must already be live.
    nonisolated static func connectorSend(entry: JSONValue, actionId: String, order: JSONValue?, customer: JSONValue?,
                                          secrets: [String: String], engine: KhaytEngine, post: ConnectorPost,
                                          now: Date) async -> ConnectorOutcome {
        let e = object(entry)
        let manifest = e["manifest"] ?? .null
        var ctx: [String: JSONValue] = [
            "secrets": .object(secrets.mapValues(JSONValue.string)),
            "config": .object(object(e["config"])),
        ]
        if let order { ctx["order"] = order }
        if let customer { ctx["customer"] = customer }
        guard let payload = try? await engine.pluginPayload(manifest, trigger: .object(["action": .string(actionId)]),
                                                           context: .object(ctx)) else {
            return .refused("payload")
        }
        if object(payload)["method"] == .string("OPEN") {
            do { return .open(try Connectors.link(from: payload, manifest: manifest)) }
            catch { return .refused("\(error)") }
        }
        let request: Connectors.Post
        do {
            request = try Connectors.post(from: payload, manifest: manifest, event: actionId, secrets: secrets,
                                          delivery: Connectors.newDeliveryId(), now: now)
        } catch let refusal as Connectors.Refusal {
            if case .missingSecret(let name) = refusal { return .refused("secret \"\(name)\" is not set") }
            return .refused(refusal.description)
        } catch {
            return .refused("\(error)")
        }
        let answer: (status: Int, body: Data?)
        do { answer = try await post(request) }
        catch let failure as WebhookClient.Failure { return .failed(failure.errorDescription ?? "\(failure)") }
        catch { return .failed(error.localizedDescription) }
        guard (200..<300).contains(answer.status) else { return .failed("HTTP \(answer.status)") }
        guard let body = answer.body, let reply = try? JSONValue.decode(JSONValue.self, from: body),
              case .object = reply,
              let values = try? await engine.pluginApplyResponse(manifest, actionId: actionId, reply: reply, entry: entry) else {
            return .sent(.object([:]))
        }
        return .sent(values)
    }

    /// Why nothing was sent, in the shop's words: a setting or key not filled
    /// in is named by the label the connector gives it, as on the desktop.
    static func refusalText(entry: JSONValue, why: String, words: Words) -> String {
        let manifest = object(object(entry)["manifest"])
        func label(_ list: String, _ idKey: String, _ id: String) -> String? {
            guard case .array(let rows)? = manifest[list],
                  let row = rows.first(where: { object($0)[idKey] == .string(id) }) else { return nil }
            return connectorLabel(object(row)["label"], words.language, fallback: id)
        }
        if let m = why.wholeMatch(of: #/setting (\S+) is not set/#), let name = label("settings", "key", String(m.1)) {
            return words.callIt("plg.err_setting", ["name": .string(name)])
        }
        if let m = why.wholeMatch(of: #/secret "([^"]+)" is not set/#), let name = label("secrets", "name", String(m.1)) {
            return words.callIt("plg.err_secret", ["name": .string(name)])
        }
        return words.callIt("plg.err_refused", ["why": .string(why)])
    }
}

/// A connector's button on a job or a customer.
struct ConnectorButton: Identifiable, Hashable, Sendable {
    let entryId: String
    let actionId: String
    let label: String
    /// Opens a page in the browser rather than sending anything.
    let opensPage: Bool
    var id: String { entryId + "|" + actionId }
}

/// One of a connector's own fields on a record, and its value.
struct ConnectorFieldRow: Identifiable, Hashable, Sendable {
    let entryId: String
    let key: String
    let label: String
    let value: String
    let editable: Bool
    var id: String { entryId + "|" + key }
}

@MainActor
extension Shop {
    /// One record's `plugins` value as the book on disk holds it — the job and
    /// customer models the screens draw do not carry it.
    func connectorValues(collection: String, id: String) async -> JSONValue? {
        guard let build = source.build else { return nil }
        let root = try? await BookWork.run {
            try JSONValue.decode([String: JSONValue].self, from: Data(contentsOf: build.storeURL))
        }
        guard let root, let record = Self.record(in: root, collection, id: id) else { return nil }
        return Self.object(record)["plugins"]
    }
}
