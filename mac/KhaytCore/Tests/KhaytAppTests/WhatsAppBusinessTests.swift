import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A canned graph.facebook.com: one answer for every request, every request
/// recorded. No test here reaches Meta.
final class GraphStub: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable { let method: String; let url: String; let auth: String; let body: Data? }
    nonisolated(unsafe) static var answer: (Int, String) = (200, "{}")
    nonisolated(unsafe) static var seen: [Seen] = []
    static let lock = NSLock()

    static func install(_ status: Int, _ body: String) {
        lock.lock(); defer { lock.unlock() }
        answer = (status, body); seen = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GraphStub.self]
        WhatsAppCloud.sessionForTests = URLSession(configuration: config)
    }
    static func remove() { WhatsAppCloud.sessionForTests = nil }
    static func requests() -> [Seen] { lock.lock(); defer { lock.unlock() }; return seen }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            body = data
        }
        Self.lock.lock()
        Self.seen.append(Seen(method: request.httpMethod ?? "GET", url: request.url?.absoluteString ?? "",
                              auth: request.value(forHTTPHeaderField: "authorization") ?? "", body: body))
        let (status, text) = Self.answer
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// WhatsApp updates sent for the shop through its own WhatsApp Business
/// account. The rule and the request are `lib/` and tested in Node; what is
/// pinned here is the Mac's side — that a move sends the template and writes
/// the wamid to the log, that a failure writes nothing and says so, and that
/// consent and the account survive a save.
///
/// Serialized because this file installs `WhatsAppCloud.sessionForTests`.
/// The installs themselves run in `LibraryEditPerfTests` (also serialized),
/// and no test in this suite reads the seam.
@MainActor
@Suite(.serialized)
struct WhatsAppBusinessTests {

    static let token = "EAAG" + String(repeating: "t", count: 40)

    @Test("the engine builds the template request the Node tests pin")
    func engineBuildsTheRequest() async throws {
        let engine = try KhaytEngine()
        let settings: [String: JSONValue] = [
            "bizEn": .string("Athar"),
            "smsConfig": .object(["provider": .string("whatsapp_cloud"),
                                  "phoneNumberId": .string("106540352242922"), "token": .string(Self.token)]),
            "whatsappTemplates": .object(["ready": .object(["name": .string("order_ready"),
                                                            "langs": .array([.string("en")])])]),
        ]
        let client: JSONValue = .object(["id": .string("C1"), "nameEn": .string("Sara"), "phone": .string("0551234567"),
                                         "whatsappOptIn": .object(["at": .string("2026-10-23T09:00:00Z"),
                                                                   "how": .string("asked")])])
        let before: JSONValue = .object(["id": .string("J1"), "status": .string("printing"), "clientId": .string("C1")])
        let after: JSONValue = .object(["id": .string("J1"), "status": .string("completed"), "clientId": .string("C1")])
        let msg = try await engine.whatsAppCloudMessage(before: before, after: after, settings: settings,
                                                        clients: [client], shopLang: "en", values: [:])
        #expect(msg.send)
        #expect(msg.template?.name == "order_ready" && msg.template?.language == "en")
        #expect(msg.to == "966551234567")
        #expect(msg.params == ["Sara", "J1", "Athar"])
        let req = try await engine.whatsAppCloudRequest(phoneNumberId: "106540352242922", token: Self.token, message: msg)
        #expect(req.ok)
        #expect(req.url == "https://graph.facebook.com/v21.0/106540352242922/messages")
        #expect(req.headers?["Authorization"] == "Bearer " + Self.token)
        #expect(req.body?.contains("\"type\":\"template\"") == true)
        #expect(req.body?.contains(Self.token) == false)

        let ok = try await engine.whatsAppCloudResult(
            status: 200, body: .object(["messages": .array([.object(["id": .string("wamid.A")])])]))
        #expect(ok.ok && ok.messageId == "wamid.A")
        let paused = try await engine.whatsAppCloudResult(
            status: 400, body: .object(["error": .object(["code": .number(132015), "message": .string("Paused")])]))
        #expect(!paused.ok && paused.reason == "template_paused" && paused.code == 132015)
    }

    @Test("a request is only ever sent to graph.facebook.com over HTTPS")
    func onlyToMeta() async {
        for url in ["http://graph.facebook.com/v21.0/1/messages", "https://evil.test/v21.0/1/messages"] {
            let req = WhatsAppCloudRequest(ok: true, reason: nil, url: url, method: "POST",
                                           headers: ["Authorization": "Bearer x"], body: "{}")
            await #expect(throws: WhatsAppCloud.Unreachable.self) { try await WhatsAppCloud.perform(req) }
        }
    }

    @Test("every reason Meta's answer or the rule can give has words, in both languages")
    func everyReasonIsSaid() throws {
        let rules = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "lib/whatsapp-send.js"), encoding: .utf8)
        var reasons = Set(["not_set_up", "no_phone_number_id", "no_token", "no_template", "not_opted_in",
                           "no_customer", "already_sent", "no_change", "no_milestone", "token_locked",
                           "unreachable", "failed", "no_message_id", "bad_phone_number_id", "bad_token",
                           "bad_recipient", "bad_template", "bad_language"])
        // Every value in REASONS, read from the file rather than listed again.
        let table = rules.components(separatedBy: "const REASONS = {").last?
            .components(separatedBy: "};").first ?? ""
        let regex = try NSRegularExpression(pattern: "'([a-z_]+)'")
        for m in regex.matches(in: table, range: NSRange(table.startIndex..., in: table)) {
            if let r = Range(m.range(at: 1), in: table) { reasons.insert(String(table[r])) }
        }
        #expect(reasons.count > 25)
        for reason in reasons {
            for lang in ["en", "ar"] {
                #expect(Words.own["mac.wab_r_" + reason]?[lang]?.isEmpty == false,
                        Comment(rawValue: "\(reason) has no \(lang) words"))
            }
        }
    }

    @Test("consent survives the sheet's copies, and withdrawing it is written")
    func consentRoundTrips() throws {
        let at = Date(timeIntervalSince1970: 1_792_000_000)
        let agreed = Client(id: "C1", nameEn: "Sara").optedIntoWhatsApp(true, how: "form", at: at)
        #expect(agreed.whatsAppConsent?.how == "form")
        // Every copy the sheet makes keeps it.
        #expect(agreed.with(\.phone, "0551234567").whatsAppConsent?.how == "form")
        #expect(agreed.marketed(false).whatsAppConsent != nil)
        #expect(agreed.replacing(priceList: []).whatsAppConsent != nil)
        #expect(agreed.replacing(recurring: nil).whatsAppConsent != nil)
        // Changing how keeps when.
        let changed = agreed.optedIntoWhatsApp(true, how: "asked", at: at.addingTimeInterval(86_400))
        #expect(changed.whatsAppConsent?.at == agreed.whatsAppConsent?.at)
        // Read back the way the book is read.
        let read = try #require(Client.decoding(agreed.record))
        #expect(read.whatsAppConsent?.how == "form")
        // Withdrawn is WRITTEN as null: an omitted key would be carried back from disk.
        let withdrawn = agreed.optedIntoWhatsApp(false, how: "", at: at)
        #expect(withdrawn.record["whatsappOptIn"] == .null)
        #expect(Client.decoding(withdrawn.record)?.whatsAppConsent == nil)
    }

    @Test("the account and templates reach the book; the token is kept unless changed")
    func settingsSave() async throws {
        let engine = try KhaytEngine()
        var root: [String: JSONValue] = ["settings": .object([
            "smsConfig": .object(["provider": .string("whatsapp_cloud"), "phoneNumberId": .string("106540352242922"),
                                  "token": .string("__enc__kept")]),
        ])]
        var draft = WhatsAppBusinessSettings.Draft()
        draft.enabled = true
        draft.phoneNumberId = "106540352242922"
        draft.names = ["ready": "order_ready", "shipped": "order_shipped", "received": ""]
        draft.langs = ["ready": "ar, en", "shipped": "ar"]
        var opened = draft
        opened.names = [:]; opened.langs = [:]
        try await Shop.applySettings(to: &root, form: WhatsAppBusinessSettings.form(draft, opened: opened),
                                     opened: WhatsAppBusinessSettings.form(opened, opened: opened),
                                     country: nil, engine: engine)
        guard case .object(let s)? = root["settings"], case .object(let sms)? = s["smsConfig"],
              case .object(let map)? = s["whatsappTemplates"] else {
            Issue.record("nothing was written"); return
        }
        #expect(sms["token"] == .string("__enc__kept"))
        #expect(sms["provider"] == .string("whatsapp_cloud"))
        #expect(map["ready"] == .object(["name": .string("order_ready"), "langs": .array([.string("ar"), .string("en")])]))
        #expect(map["received"] == nil)
        // Off, from WhatsApp Business: the provider goes to none.
        var off = draft; off.enabled = false
        #expect(WhatsAppBusinessSettings.form(off, opened: draft)["smsConfig"]
                .flatMap { if case .object(let o) = $0 { return o["provider"] } else { return nil } } == .string("none"))
        // Off with another provider stored: not this pane's to switch off.
        var never = WhatsAppBusinessSettings.Draft(); never.enabled = false
        #expect(WhatsAppBusinessSettings.form(never, opened: never)["smsConfig"]
                .flatMap { if case .object(let o) = $0 { return o["provider"] } else { return nil } } == nil)
    }

    @Test("the pane, the row, the sheet and every hook are wired")
    func wiredIn() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        func read(_ name: String) throws -> String {
            try String(contentsOf: sources.appending(path: name), encoding: .utf8)
        }
        #expect(try read("Integrations.swift").contains("WhatsAppBusinessSettings(shop: shop)"))
        #expect(try read("WhatsAppJobRow.swift").contains("sendWhatsAppBusiness("))
        #expect(try read("CustomerSheet.swift").contains("optedIntoWhatsApp("))
        #expect(try read("Shop+Jobs.swift").contains("await sendOwedWhatsApp(before: wasOrder, jobId: id)"))
        // markDelivered, markShipped and ship are not status moves: each sends itself.
        let money = try read("Shop+Money.swift")
        #expect(money.components(separatedBy: "await sendOwedWhatsApp(before: before, jobId: id)").count - 1 == 3)
    }
}

/// The send through a real book on disk — in the serialised suite that owns
/// the one global test seam (`PerfBook.install`).
extension LibraryEditPerfTests {

    static func withWhatsAppBook(phone: String = "0551234567",
                                 _ body: (Shop, URL) async throws -> Void) async throws {
        var root = PerfBook.synthesize(models: 0)
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = root["settings"] { settings = s }
        settings["bizEn"] = .string("Athar")
        settings["smsConfig"] = .object([
            "provider": .string("whatsapp_cloud"), "phoneNumberId": .string("106540352242922"),
            // Unsealed: `Secrets.open` hands back a value with no marker as it is.
            "token": .string(WhatsAppBusinessTests.token),
        ])
        settings["whatsappTemplates"] = .object([
            "ready": .object(["name": .string("order_ready"), "langs": .array([.string("en")])]),
            "shipped": .object(["name": .string("order_shipped"), "langs": .array([.string("en")])]),
        ])
        root["settings"] = .object(settings)
        root["clients"] = .array([.object([
            "id": .string("C1"), "nameEn": .string("Sara"), "phone": .string(phone),
            "whatsappOptIn": .object(["at": .string("2026-10-23T09:00:00Z"), "how": .string("asked")]),
            "commLog": .array([]),
        ])])
        root["printLog"] = .array([.object([
            "id": .string("J-WA1"), "status": .string("printing"), "clientId": .string("C1"),
            "client": .string("Sara"), "price": .number(100), "qty": .number(1),
            "date": .string("2026-10-23"), "parts": .array([]),
        ])])
        let support = try PerfBook.install(root)
        let shop = Shop()
        do {
            await shop.load(.store(.shipped))
            try await body(shop, StoreReader.Build.shipped.storeURL)
        } catch {
            Issue.record(error)
        }
        GraphStub.remove()
        await shop.load(.sample)
        StoreReader.Build.supportFolderForTests = nil
        try? FileManager.default.removeItem(at: support.deletingLastPathComponent())
    }

    static func waLog(_ url: URL) throws -> [JSONValue] {
        let book = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        guard case .array(let clients)? = book["clients"], case .object(let c)? = clients.first,
              case .array(let log)? = c["commLog"] else { return [] }
        return log
    }

    @Test("finishing a job sends the approved template and logs the wamid")
    func movingSendsTheTemplate() async throws {
        try await Self.withWhatsAppBook { shop, url in
            GraphStub.install(200, #"{"messaging_product":"whatsapp","contacts":[{"wa_id":"966551234567"}],"messages":[{"id":"wamid.SENT1"}]}"#)
            await shop.moveJob("J-WA1", to: .completed)
            #expect(shop.moveProblem == nil, Comment(rawValue: shop.moveProblem ?? ""))
            let seen = GraphStub.requests()
            #expect(seen.count == 1)
            #expect(seen.first?.method == "POST")
            #expect(seen.first?.url == "https://graph.facebook.com/v21.0/106540352242922/messages")
            #expect(seen.first?.auth == "Bearer " + WhatsAppBusinessTests.token)
            let sent = try JSONDecoder().decode(JSONValue.self, from: try #require(seen.first?.body))
            guard case .object(let o) = sent, case .object(let t)? = o["template"] else {
                Issue.record("not a template message"); return
            }
            #expect(o["type"] == .string("template"))
            #expect(o["to"] == .string("966551234567"))
            #expect(t["name"] == .string("order_ready"))
            let log = try Self.waLog(url)
            #expect(log.count == 1)
            if case .object(let line)? = log.first {
                #expect(line["messageId"] == .string("wamid.SENT1"))
                #expect(line["status"] == .string("sent"))
                #expect(line["milestone"] == .string("ready"))
                #expect(line["orderId"] == .string("J-WA1"))
            }
            #expect(shop.moveNotices.contains { $0.contains(shop.whatsAppMilestoneName("ready")) })

            // Shipping it is the next step: one more message, the shipped template.
            GraphStub.install(200, #"{"messages":[{"id":"wamid.SENT2"}]}"#)
            await shop.markShipped("J-WA1")
            #expect(GraphStub.requests().count == 1)
            let shippedLog = try Self.waLog(url)
            #expect(shippedLog.count == 2)

            // Moving it back and forward again is not news twice.
            GraphStub.install(200, #"{"messages":[{"id":"wamid.SENT3"}]}"#)
            await shop.moveJob("J-WA1", to: .printing)
            await shop.moveJob("J-WA1", to: .completed)
            #expect(GraphStub.requests().isEmpty, "the ready update went a second time")
        }
    }

    @Test("a send Meta refuses writes no line and tells the shop why")
    func aRefusalIsSaid() async throws {
        try await Self.withWhatsAppBook { shop, url in
            GraphStub.install(400, #"{"error":{"message":"Template is Paused","code":132015,"type":"OAuthException"}}"#)
            await shop.moveJob("J-WA1", to: .completed)
            #expect(GraphStub.requests().count == 1)
            let log = try Self.waLog(url)
            #expect(log.isEmpty, "a refused send was logged as sent")
            let said = shop.moveProblem ?? ""
            #expect(said.contains(shop.whatsAppBusinessReason("template_paused")), Comment(rawValue: said))
            #expect(said.contains("132015"))
            // The job is still finished: a message that did not go is not a move undone.
            #expect(shop.orders.first { $0.id == "J-WA1" }?.status == "completed")
        }
    }

    @Test("a customer who agreed with no usable number is named, and nothing is sent")
    func unreachableIsSaid() async throws {
        try await Self.withWhatsAppBook(phone: "12345") { shop, _ in
            GraphStub.install(200, #"{"messages":[{"id":"wamid.X"}]}"#)
            await shop.moveJob("J-WA1", to: .completed)
            #expect(GraphStub.requests().isEmpty)
            #expect(shop.moveProblem?.contains(shop.whatsAppReason("too_short")) == true,
                    Comment(rawValue: shop.moveProblem ?? "nothing said"))
        }
    }
}
