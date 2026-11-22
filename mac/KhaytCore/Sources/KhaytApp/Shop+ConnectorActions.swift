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
        // This Mac's dev connectors, in developer mode only: the review is
        // what developer mode waives (`DevConnectors`).
        for entry in runningDevConnectors where (try? await engine.pluginStateOf(entry, reviewed: true)) == "on" {
            out.append(entry)
        }
        return out
    }

    /// The buttons for a job (`order`) or a customer (`customer`). On a job
    /// with no customer record, a button that sends anything about the
    /// customer carries why it is greyed out (`usesCustomer`).
    func connectorButtons(placement: String, jobId: String? = nil) async -> [ConnectorButton] {
        guard ConnectorsSwitch.isOn() else { return [] }
        let entries = await liveConnectors()
        var out = Self.buttons(in: entries, placement: placement, lang: words.language)
        guard placement == "order", let jobId, let engine, !(await connectorJobHasCustomer(jobId)) else { return out }
        for i in out.indices {
            guard let entry = entries.first(where: { Self.object($0)["id"] == .string(out[i].entryId) }) else { continue }
            let manifest = Self.object(entry)["manifest"] ?? .null
            if (try? await engine.pluginUsesCustomer(manifest, trigger: .object(["action": .string(out[i].actionId)]))) == true {
                out[i].blockedWhy = words.callIt("plg.no_customer")
            }
        }
        return out
    }

    /// Whether a job names a customer record that is in the book.
    func connectorJobHasCustomer(_ jobId: String) async -> Bool {
        guard let build = source.build,
              let root = try? await BookWork.run({
                  try JSONValue.decode([String: JSONValue].self, from: Data(contentsOf: build.storeURL))
              }),
              let job = Self.record(in: root, "printLog", id: jobId),
              let clientId = Shop.plainString(Self.object(job)["clientId"]), !clientId.isEmpty else { return false }
        return Self.record(in: root, "clients", id: clientId) != nil
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
        return Self.fieldRows(connectorEntries + runningDevConnectors, live: live, attach: attach,
                              plugins: plugins, lang: words.language)
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
        // A job with no customer record would send the customer's name, phone
        // and city empty, and a courier turns that down (Lamha E2E, Nov 10).
        // Said here, before anything leaves, as the button already shows.
        if attach == "order", customer == nil,
           (try? await engine.pluginUsesCustomer(Self.object(entry)["manifest"] ?? .null,
                                                 trigger: .object(["action": .string(button.actionId)]))) == true {
            return (false, words.callIt("plg.no_customer"))
        }
        let names = Self.connectorSecretsDeclared(Self.object(entry)["manifest"] ?? .null).map(\.name)
        var secrets: [String: String] = [:]
        for n in names { if let v = await connectorSecrets.value(pluginId: button.entryId, name: n), !v.isEmpty { secrets[n] = v } }

        let outcome = await Self.connectorSend(entry: entry, actionId: button.actionId, order: order, customer: customer, settings: root["settings"],
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
        case .failed(let why, _):
            return (false, words.callIt("plg.err_failed", ["why": .string(why)]))
        case .declined(let said):
            return (false, Self.declinedText(entry: entry, said: said, words: words))
        case .sent(let values):
            if case .object(let v) = values, !v.isEmpty {
                let id = attach == "order" ? jobId : clientKey
                guard let id, await writeConnectorValues(entry: entry, attach: attach, recordId: id, values: values) else {
                    return (false, settingsProblem ?? words.callIt("plg.err_refused", ["why": .string("write")]))
                }
            }
            return (true, words.callIt("plg.sent"))
        case .unconfirmed(let keys):
            // Accepted, but without the order number the button promises: not
            // something the shop should take as done.
            return (false, words.callIt("plg.sent_unconfirmed",
                                        ["name": .string(Self.connectorName(entry, words: words)),
                                         "field": .string(Self.fieldLabel(entry: entry, key: keys.first ?? "", words: words))]))
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
        /// Sent and not accepted, or not answered (`status` nil).
        case failed(String, status: Int?)
        /// Answered 2xx but TURNED DOWN — `{"success": false, "msg": …}`
        /// (`lib/plugin-payload.js replyRefusal`). The service's own words,
        /// maybe empty. Nothing is written, nothing says "Sent", and an event
        /// that gets this is failed rather than retried.
        case declined(String)
        /// Accepted, but a button's reply filled none of the fields it says it
        /// fills (`fields`, their keys): not "Sent".
        case unconfirmed([String])
    }

    /// What made a connector send: a button, an event on a job, or a
    /// refresh asking about one.
    enum ConnectorTrigger: Equatable, Sendable {
        case action(String)
        case event(String)
        case refresh
        var json: JSONValue {
            switch self {
            case .action(let id): return .object(["action": .string(id)])
            case .event(let name): return .object(["event": .string(name)])
            case .refresh: return .object(["refresh": .bool(true)])
            }
        }
        /// `X-Khayt-Event`: the button's id, the event's name, or "refresh".
        var name: String {
            switch self {
            case .action(let s), .event(let s): return s
            case .refresh: return "refresh"
            }
        }
    }

    typealias ConnectorPost = @Sendable (Connectors.Post) async throws -> (status: Int, body: Data?)

    nonisolated static let connectorTimeout: TimeInterval = 15
    nonisolated static let connectorReplyMax = 64 * 1024

    nonisolated static func realConnectorPost(_ engine: KhaytEngine) -> ConnectorPost {
        { post in
            try await WebhookClient.postReading(post.body, to: post.url, headers: post.headers.map { ($0.name, $0.value) },
                                                engine: engine, timeout: connectorTimeout, keep: connectorReplyMax,
                                                method: post.method)
        }
    }

    /// Build, send and read one press. The entry must already be live.
    nonisolated static func connectorSend(entry: JSONValue, actionId: String, order: JSONValue?, customer: JSONValue?,
                                          settings: JSONValue?,
                                          secrets: [String: String], engine: KhaytEngine, post: ConnectorPost,
                                          now: Date) async -> ConnectorOutcome {
        await connectorSend(entry: entry, trigger: .action(actionId), order: order, customer: customer, settings: settings,
                            secrets: secrets,
                            engine: engine, post: post, now: now, delivery: Connectors.newDeliveryId())
    }

    /// Build, send and read one button press, event or refresh. The entry
    /// must already be live. A reply fills the connector's own fields only
    /// where the manifest gave that trigger a `response` (v1.1: events and
    /// refresh too, onto the job), and only with fields.write granted.
    nonisolated static func connectorSend(entry: JSONValue, trigger: ConnectorTrigger, order: JSONValue?, customer: JSONValue?,
                                          settings: JSONValue?,
                                          secrets: [String: String], engine: KhaytEngine, post: ConnectorPost,
                                          now: Date, delivery: String) async -> ConnectorOutcome {
        let e = object(entry)
        let manifest = e["manifest"] ?? .null
        var ctx: [String: JSONValue] = [
            "secrets": .object(secrets.mapValues(JSONValue.string)),
            "config": .object(object(e["config"])),
        ]
        if let order { ctx["order"] = order }
        if let customer { ctx["customer"] = customer }
        // The book's settings, so an amount due is worked out in the shop's
        // tax mode and currency (lib payloadFor refuses order.amountDue* without
        // them), and this attempt's clock for {now…epochMs}. Both per attempt:
        // a retry is built again, with the time it is sent.
        if case .object? = settings { ctx["settings"] = settings }
        ctx["nowMs"] = .number((now.timeIntervalSince1970 * 1000).rounded())
        guard let payload = try? await engine.pluginPayload(manifest, trigger: trigger.json,
                                                           context: .object(ctx)) else {
            return .refused("payload")
        }
        if object(payload)["method"] == .string("OPEN") {
            do { return .open(try Connectors.link(from: payload, manifest: manifest)) }
            catch { return .refused("\(error)") }
        }
        let request: Connectors.Post
        do {
            request = try Connectors.post(from: payload, manifest: manifest, event: trigger.name, secrets: secrets,
                                          delivery: delivery, now: now)
        } catch let refusal as Connectors.Refusal {
            if case .missingSecret(let name) = refusal { return .refused("secret \"\(name)\" is not set") }
            return .refused(refusal.description)
        } catch {
            return .refused("\(error)")
        }
        let answer: (status: Int, body: Data?)
        do { answer = try await post(request) }
        catch let failure as WebhookClient.Failure { return .failed(failure.errorDescription ?? "\(failure)", status: nil) }
        catch { return .failed(error.localizedDescription, status: nil) }
        guard (200..<300).contains(answer.status) else { return .failed("HTTP \(answer.status)", status: answer.status) }
        // What the reply means is the shared rule's (`replyVerdict`): a 2xx can
        // still be a refusal (Lamha answers 200 with `success: false`), and a
        // button's reply that fills none of its declared fields is not "Sent".
        var reply: JSONValue = .object([:])
        if let body = answer.body, let parsed = try? JSONValue.decode(JSONValue.self, from: body), case .object = parsed {
            reply = parsed
        }
        let values = (try? await engine.pluginApplyResponse(manifest, trigger: trigger.json, reply: reply, entry: entry))
            ?? .object([:])
        guard let verdict = try? await engine.pluginReplyVerdict(manifest, trigger: trigger.json, reply: reply,
                                                                 entry: entry, mapped: values) else {
            return .sent(values)
        }
        let v = object(verdict)
        switch Shop.plainString(v["kind"]) {
        case "refused":
            return .declined(Shop.plainString(v["message"]) ?? "")
        case "unconfirmed":
            guard case .array(let keys)? = v["fields"] else { return .unconfirmed([]) }
            return .unconfirmed(keys.compactMap(Shop.plainString))
        default:
            return .sent(values)
        }
    }

    /// The connector's name, in the shop's language.
    static func connectorName(_ entry: JSONValue, words: Words) -> String {
        let manifest = object(object(entry)["manifest"])
        return connectorLabel(manifest["name"], words.language, fallback: Shop.plainString(manifest["id"]) ?? "")
    }

    /// "Lamha said: …" — or that it turned the request down without saying why.
    static func declinedText(entry: JSONValue, said: String, words: Words) -> String {
        let name = connectorName(entry, words: words)
        return said.isEmpty
            ? words.callIt("plg.err_declined_nomsg", ["name": .string(name)])
            : words.callIt("plg.err_declined", ["name": .string(name), "msg": .string(said)])
    }

    /// An own field's label, in the shop's language.
    static func fieldLabel(entry: JSONValue, key: String, words: Words) -> String {
        let manifest = object(object(entry)["manifest"])
        if case .array(let defs)? = manifest["fields"],
           let def = defs.first(where: { object($0)["key"] == .string(key) }) {
            return connectorLabel(object(def)["label"], words.language, fallback: key)
        }
        return key
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
    /// Why it is greyed out on this record, if it is ("This job has no customer").
    var blockedWhy: String?
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

// MARK: - Events

/// A connector event waiting to be sent, as `settings.pluginOutbox` keeps it
/// (`lib/plugin-host.js` withQueued): the same delivery id on every attempt.
struct ConnectorQueued: Equatable, Sendable {
    let delivery: String
    let id: String
    let event: String
    let orderId: String
    let attempt: Int

    var json: JSONValue {
        .object(["delivery": .string(delivery), "id": .string(id), "event": .string(event),
                 "orderId": .string(orderId), "attempt": .number(Double(attempt))])
    }

    init(delivery: String, id: String, event: String, orderId: String, attempt: Int) {
        self.delivery = delivery; self.id = id; self.event = event; self.orderId = orderId; self.attempt = attempt
    }

    init?(_ value: JSONValue) {
        let o = Shop.object(value)
        guard let d = Shop.plainString(o["delivery"]), let id = Shop.plainString(o["id"]),
              let ev = Shop.plainString(o["event"]), let order = Shop.plainString(o["orderId"]) else { return nil }
        self.init(delivery: d, id: id, event: ev, orderId: order, attempt: Int(Shop.plainNumber(o["attempt"]) ?? 1))
    }
}

@MainActor
extension Shop {

    /// What `fire` hands over: the connector items among a move's deliveries.
    /// Each is sent once now; a failure worth retrying waits in the outbox on
    /// the webhook ladder (`lib/webhook-bus.js`), with the same delivery id.
    func deliverConnectorEvents(_ items: [KhaytEngine.WebhookDelivery]) async {
        for item in Self.connectorEvents(items, switchedOn: ConnectorsSwitch.isOn()) {
            await sendConnectorEvent(item)
        }
    }

    /// The events to send now, each with a fresh delivery id. NONE while
    /// connectors are switched off (`ConnectorsSwitch`): nothing is sent and
    /// nothing is queued, because the queue is written only after a send.
    nonisolated static func connectorEvents(_ items: [KhaytEngine.WebhookDelivery], switchedOn: Bool) -> [ConnectorQueued] {
        guard switchedOn else { return [] }
        return items.compactMap { one in
            guard let id = one.connector, let orderId = one.orderId, !orderId.isEmpty else { return nil }
            return ConnectorQueued(delivery: Connectors.newDeliveryId(), id: id, event: one.event, orderId: orderId, attempt: 1)
        }
    }

    /// Send every queued connector event whose time has come.
    func retryDueConnectorEvents() async {
        guard ConnectorsSwitch.isOn(), let engine, let build = source.build, StoreLock.weOwnIt(build) else { return }
        let due = (try? await engine.pluginDue(settingsDict["pluginOutbox"] ?? .array([]),
                                               nowMs: Date().timeIntervalSince1970 * 1000)) ?? []
        for item in due.compactMap(ConnectorQueued.init) where !connectorInFlight.contains(item.delivery) {
            await sendConnectorEvent(item)
        }
    }

    /// One attempt at one event.
    func sendConnectorEvent(_ item: ConnectorQueued) async {
        // Checked here too, not only by the callers: this is the one place a
        // connector event leaves the Mac or reaches the queue.
        guard ConnectorsSwitch.isOn() else { return }
        guard let engine, let build = source.build, StoreLock.weOwnIt(build) else { return }
        guard !connectorInFlight.contains(item.delivery) else { return }
        connectorInFlight.insert(item.delivery)
        defer { connectorInFlight.remove(item.delivery) }

        // Switched off, removed, paused or no longer signed since: dropped,
        // never sent. So is an event about a job that is gone.
        guard let entry = await liveConnectors().first(where: { Self.object($0)["id"] == .string(item.id) }),
              let root = try? await BookWork.run({
                  try JSONValue.decode([String: JSONValue].self, from: Data(contentsOf: build.storeURL))
              }),
              let order = Self.record(in: root, "printLog", id: item.orderId) else {
            await settleConnectorEvent(item, retryAfterMs: nil)
            return
        }
        let customer = Shop.plainString(Self.object(order)["clientId"]).flatMap { Self.record(in: root, "clients", id: $0) }
        var secrets: [String: String] = [:]
        for n in Self.connectorSecretsDeclared(Self.object(entry)["manifest"] ?? .null).map(\.name) {
            if let v = await connectorSecrets.value(pluginId: item.id, name: n), !v.isEmpty { secrets[n] = v }
        }
        let outcome = await Self.connectorSend(entry: entry, trigger: .event(item.event), order: order, customer: customer, settings: root["settings"],
                                               secrets: secrets, engine: engine,
                                               post: connectorPost ?? Self.realConnectorPost(engine),
                                               now: Date(), delivery: item.delivery)
        // v1.1: an event whose manifest gives it a `response` fills the job's
        // own fields from the reply, as a button's does.
        if case .sent(let values) = outcome, case .object(let v) = values, !v.isEmpty {
            _ = await writeConnectorReplies(entry: entry, replies: [ConnectorReply(jobId: item.orderId, values: values)])
        }
        // Turned down: the same request would be turned down again, so it is
        // kept as failed with the service's words, for the shop to see and
        // Retry — never on the backoff ladder.
        if case .declined(let said) = outcome {
            await failConnectorEvent(item, message: said)
            return
        }
        guard case .failed(_, let status) = outcome,
              let next = try? await engine.webhookNext(status: status ?? 0, attempt: item.attempt), next.retry else {
            // Sent, refused (it will not get better by waiting), or out of tries.
            await settleConnectorEvent(item, retryAfterMs: nil)
            return
        }
        await settleConnectorEvent(item, retryAfterMs: next.afterMs)
    }

    /// An event the service turned down, kept in the outbox as failed.
    private func failConnectorEvent(_ item: ConnectorQueued, message: String) async {
        // lock: system — the record of an event the shop's own action sent, which the service turned down
        if isDevConnector(item.id) { return }
        guard let engine, let build = source.build else { return }
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                var settings = Self.settings(root)
                settings["pluginOutbox"] = try await engine.pluginFailed(settings["pluginOutbox"] ?? .array([]),
                                                                         item: item.json, at: StoreWriter.iso(Date()),
                                                                         message: message)
                root["settings"] = .object(settings)
            }
            await load(source)
        } catch {
            return
        }
    }

    /// The events a connector's service turned down, for its settings.
    func failedConnectorEvents(pluginId: String) async -> [(delivery: String, event: String, orderId: String, at: String, message: String)] {
        guard let engine, let list = settingsDict["pluginOutbox"],
              let rows = try? await engine.pluginFailedQueued(list) else { return [] }
        return rows.compactMap { row in
            let o = Self.object(row), f = Self.object(o["failed"])
            guard o["id"] == .string(pluginId), let d = Shop.plainString(o["delivery"]) else { return nil }
            return (d, Shop.plainString(o["event"]) ?? "", Shop.plainString(o["orderId"]) ?? "",
                    Shop.plainString(f["at"]) ?? "", Shop.plainString(f["message"]) ?? "")
        }
    }

    /// Retry: the failed event is due again, and the pass sends it now.
    func retryFailedConnectorEvent(delivery: String) async {
        // lock: system — the shop asked to send again an event its own action made
        guard ConnectorsSwitch.isOn(), let engine, let build = source.build else { return }
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                var settings = Self.settings(root)
                settings["pluginOutbox"] = try await engine.pluginRetried(settings["pluginOutbox"] ?? .array([]),
                                                                          delivery: delivery, nowIso: StoreWriter.iso(Date()))
                root["settings"] = .object(settings)
            }
            await load(source)
        } catch {
            return
        }
        await retryDueConnectorEvents()
    }

    /// Dismiss: the failed event is dropped from the outbox.
    func dismissFailedConnectorEvent(delivery: String) async {
        // lock: system — the shop cleared the record of an event its service turned down
        guard let engine, let build = source.build else { return }
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                var settings = Self.settings(root)
                settings["pluginOutbox"] = try await engine.pluginUnqueued(settings["pluginOutbox"] ?? .array([]),
                                                                           delivery: delivery)
                root["settings"] = .object(settings)
            }
            await load(source)
        } catch {
            return
        }
    }

    /// The outbox after one attempt: the item queued for its next try, or
    /// gone. Queued BEFORE anything waits on it, so a quit mid-backoff
    /// resumes on the next launch (`runIntegrationsPass`).
    private func settleConnectorEvent(_ item: ConnectorQueued, retryAfterMs: Double?) async {
        // lock: system — the retry queue of an event the shop's own action already sent
        // A dev connector's event is sent once: its id never goes into the
        // book, and the queue is the book's (`DevConnectors`).
        if isDevConnector(item.id) { return }
        guard let engine, let build = source.build else { return }
        let had = settingsDict["pluginOutbox"] ?? .array([])
        if retryAfterMs == nil, case .array(let rows) = had,
           !rows.contains(where: { Self.object($0)["delivery"] == .string(item.delivery) }) { return }
        let at = retryAfterMs.map { Date().addingTimeInterval($0 / 1000) }
        let next = ConnectorQueued(delivery: item.delivery, id: item.id, event: item.event, orderId: item.orderId,
                                   attempt: item.attempt + 1)
        do {
            try await StoreWriter.update(
                storeURL: build.storeURL,
                owns: { StoreLock.weOwnIt(build) },
                whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }
            ) { root in
                var settings = Self.settings(root)
                let list = settings["pluginOutbox"] ?? .array([])
                if let at {
                    settings["pluginOutbox"] = try await engine.pluginQueued(list, item: next.json,
                                                                             nextAttemptAt: StoreWriter.iso(at))
                } else {
                    settings["pluginOutbox"] = try await engine.pluginUnqueued(list, delivery: item.delivery)
                }
                root["settings"] = .object(settings)
            }
            await load(source)
        } catch {
            return
        }
        // The early rungs (30 s, 2 min) come before the regular pass.
        if let retryAfterMs, retryAfterMs <= 600_000 {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(retryAfterMs) + 500))
                await self?.retryDueConnectorEvents()
            }
        }
    }
}
