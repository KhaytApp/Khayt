import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The phone's way in, held to the Node server.
///
/// ── WHAT A MAC-ONLY SHOP COULD NOT DO ─────────────────────────────────────
///
/// Put the queue on a phone. `lib/lan-server.js` served it to every Windows
/// and Linux shop and cannot run here, so a Mac shop had the queue on one
/// screen in one room. `LanServer` is a listener and a route table over the
/// SAME modules that server now reads its pages and its lockout from, so the
/// bytes a phone receives are the bytes the other app sends — which is what
/// these tests compare: every body against the module the Node server calls,
/// through the engine, not against a copy pasted into the test.
@MainActor
struct LanServerTests {

    /// A server on loopback, an ephemeral port, the sample book, a fixed clock.
    @MainActor final class Bench {
        let shop: Shop
        let engine: KhaytEngine
        let server: LanServer
        let port: UInt16
        var clock: Date
        static let start = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15

        /// What `/api/intake` wrote into the book.
        let recorded = Recorded()
        var tokens = 0

        init(pin: String = "2468", intakeToken: String = "", recordFails: Bool = false) async throws {
            let shop = Shop()
            await shop.load(.sample)
            let engine = try #require(shop.engine)
            self.shop = shop
            self.engine = engine
            var clock = Self.start
            self.clock = clock
            let box = ClockBox(clock)
            self.box = box
            let recorded = self.recorded
            var host = LanServer.Host(
                store: { shop.lanBook }, pin: pin, engine: engine,
                now: { box.now }, nowText: { "09:16" },
                icon: { LanServer.bundledIcon($0) })
            host.intakeToken = intakeToken
            host.mintId = { "intake-fixed" }
            host.record = { entry in
                if recordFails { throw CocoaError(.fileWriteUnknown) }
                recorded.entries.append(entry)
            }
            let server = LanServer(host: host)
            self.server = server
            port = try await server.start(port: 0, bind: .loopback)
            clock = Self.start
        }
        let box: ClockBox

        func post(_ path: String, json: String, headers: [String: String] = [:]) async throws -> Reply {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = "POST"
            request.httpBody = Data(json.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            let (data, response) = try await NoRedirect.session.data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            var out: [String: String] = [:]
            for (k, v) in http.allHeaderFields { out[String(describing: k).lowercased()] = String(describing: v) }
            return Reply(status: http.statusCode, headers: out, body: data)
        }

        /// Open the form and come back with its session cookie.
        func openForm() async throws -> (Reply, cookie: String) {
            let reply = try await get("/intake")
            let setCookie = reply.headers["set-cookie"] ?? ""
            let cookie = String(setCookie.split(separator: ";").first ?? "")
            return (reply, cookie)
        }
        func advance(seconds: TimeInterval) { box.now = box.now.addingTimeInterval(seconds) }

        struct Reply { let status: Int; let headers: [String: String]; let body: Data
                       var text: String { String(decoding: body, as: UTF8.self) } }

        func get(_ path: String, headers: [String: String] = [:], method: String = "GET") async throws -> Reply {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            let (data, response) = try await NoRedirect.session.data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            var out: [String: String] = [:]
            for (k, v) in http.allHeaderFields { out[String(describing: k).lowercased()] = String(describing: v) }
            return Reply(status: http.statusCode, headers: out, body: data)
        }
        func stop() { server.stop() }
    }

    final class ClockBox: @unchecked Sendable {
        var now: Date
        init(_ d: Date) { now = d }
    }
    final class Recorded: @unchecked Sendable {
        var entries: [JSONValue] = []
    }

    /// URLSession follows a 302 by itself; the test wants to see the 302.
    final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        static let session: URLSession = {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            config.httpShouldSetCookies = false
            config.httpCookieAcceptPolicy = .never
            return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        }()
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    // MARK: - The bodies are the module's

    @Test("the status API serves the shared module's JSON, with the four security headers")
    func statusIsTheModules() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        let reply = try await bench.get("/api/status?format=json")
        #expect(reply.status == 200)
        let expected = try await bench.engine.lanStatusBody(store: .object(bench.shop.lanBook),
                                                            today: LanServer.localDay(Bench.start))
        #expect(reply.text == expected)
        #expect(reply.headers["content-type"] == "application/json")
        let security = try await bench.engine.lanSecurityHeaders()
        #expect(security.count == 4, Comment(rawValue: "\(security)"))
        for (name, value) in security {
            #expect(reply.headers[name.lowercased()] == value, Comment(rawValue: "missing \(name)"))
        }
        // Not empty: the sample book has jobs in the queue, so the counts are real.
        #expect(reply.text.contains("\"queued\":"), Comment(rawValue: reply.text))
        #expect(!reply.text.contains("\"queued\":0"), "the sample book's queue came out empty")
    }

    @Test("a browser asking for /api/status is sent to the intake form, as on the PC")
    func statusRedirectsBrowsers() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        let reply = try await bench.get("/api/status")
        #expect(reply.status == 302)
        #expect(reply.headers["location"] == "/intake")
    }

    @Test("the queue API is the module's JSON behind the PIN, by header or by query")
    func queueBehindPin() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        let expected = try await bench.engine.lanQueueBody(store: .object(bench.shop.lanBook))
        let byHeader = try await bench.get("/api/queue", headers: ["x-khayt-pin": "2468"])
        #expect(byHeader.status == 200)
        #expect(byHeader.text == expected)
        let byQuery = try await bench.get("/api/queue?pin=2468")
        #expect(byQuery.status == 200)
        #expect(byQuery.text == expected)
        let none = try await bench.get("/api/queue")
        #expect(none.status == 401)
        #expect(none.text == #"{"error":"Unauthorized"}"#)
        let wrong = try await bench.get("/api/queue", headers: ["x-khayt-pin": "0000"])
        #expect(wrong.status == 401)
        // The refusal carries the security headers too — set once, not per route.
        #expect(wrong.headers["x-content-type-options"] == "nosniff")
    }

    @Test("the live queue page is the module's HTML, with the clock it was given")
    func queuePageIsTheModules() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        let reply = try await bench.get("/", headers: ["x-khayt-pin": "2468"])
        #expect(reply.status == 200)
        #expect(reply.headers["content-type"] == "text/html; charset=utf-8")
        let expected = try await bench.engine.lanQueuePage(store: .object(bench.shop.lanBook), now: "09:16")
        #expect(reply.text == expected)
        #expect(reply.text.contains("09:16"))
        // And behind the PIN: it shows customers' names.
        let none = try await bench.get("/")
        #expect(none.status == 401)
    }

    @Test("the manifest, the service worker and three different icons make it installable")
    func installable() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        let manifest = try await bench.get("/manifest.json")
        #expect(manifest.status == 200)
        #expect(manifest.headers["content-type"] == "application/manifest+json")
        #expect(manifest.text == (try await bench.engine.lanManifestBody(store: .object(bench.shop.lanBook))))
        let sw = try await bench.get("/sw.js")
        #expect(sw.status == 200)
        #expect(sw.headers["content-type"] == "application/javascript")
        #expect(sw.headers["service-worker-allowed"] == "/")
        #expect(sw.text == (try await bench.engine.lanServiceWorker()))
        var icons: [Data] = []
        for name in ["icon-192.png", "icon-512.png", "icon-maskable-512.png"] {
            let icon = try await bench.get("/\(name)")
            #expect(icon.status == 200, Comment(rawValue: name))
            #expect(icon.headers["content-type"] == "image/png")
            #expect(icon.body.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]), Comment(rawValue: "\(name) is not a PNG"))
            #expect(icon.body.count > 1000, Comment(rawValue: "\(name) is the one-pixel fallback: \(icon.body.count) bytes"))
            icons.append(icon.body)
        }
        // The size the manifest asked for, not one file for all three.
        #expect(Set(icons).count == 3, "the three icons are the same bytes")
    }

    @Test("anything else is the module's 404, and /v1 is /api")
    func notFoundAndAlias() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        let missing = try await bench.get("/nothing/here")
        #expect(missing.status == 404)
        #expect(missing.text == (try await bench.engine.lanNotFoundBody()))
        #expect(missing.headers["content-type"] == "application/json")
        let v1 = try await bench.get("/v1/status?format=json")
        let api = try await bench.get("/api/status?format=json")
        #expect(v1.status == 200)
        #expect(v1.text == api.text)
        // A trailing slash is the same route.
        let slash = try await bench.get("/api/status/?format=json")
        #expect(slash.status == 200)
        // HEAD carries the headers and no body.
        let head = try await bench.get("/manifest.json", method: "HEAD")
        #expect(head.status == 200)
        #expect(head.body.isEmpty)
    }

    // MARK: - The gate

    @Test("ten wrong PINs lock an address out for a minute — the shared rule, not a Swift one")
    func lockout() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        for i in 1...10 {
            let wrong = try await bench.get("/api/queue", headers: ["x-khayt-pin": "wrong\(i)"])
            #expect(wrong.status == 401, Comment(rawValue: "attempt \(i) gave \(wrong.status)"))
        }
        // The eleventh, RIGHT PIN included, is refused.
        let locked = try await bench.get("/api/queue", headers: ["x-khayt-pin": "2468"])
        #expect(locked.status == 429, Comment(rawValue: locked.text))
        #expect(locked.text.contains("Too many attempts"))
        // A minute later the address may try again, and the right PIN opens it.
        bench.advance(seconds: 61)
        let after = try await bench.get("/api/queue", headers: ["x-khayt-pin": "2468"])
        #expect(after.status == 200, Comment(rawValue: after.text))
        // And a success clears the count: nine more wrong ones do not lock.
        for _ in 1...9 {
            _ = try await bench.get("/api/queue", headers: ["x-khayt-pin": "no"])
        }
        let still = try await bench.get("/api/queue", headers: ["x-khayt-pin": "2468"])
        #expect(still.status == 200)
    }

    @Test("with no PIN configured the owner routes say so rather than opening")
    func noPinConfigured() async throws {
        let bench = try await Bench(pin: "")
        defer { bench.stop() }
        let reply = try await bench.get("/api/queue", headers: ["x-khayt-pin": ""])
        #expect(reply.status == 401)
        #expect(reply.text.contains("Configure a LAN PIN"))
        // The public surface stays public.
        let status = try await bench.get("/api/status?format=json")
        #expect(status.status == 200)
    }

    @Test("the PIN comparison is byte-for-byte and length-aware")
    func constantTime() {
        #expect(LanServer.constantTimeEqual("2468", "2468"))
        #expect(!LanServer.constantTimeEqual("2468", "2469"))
        #expect(!LanServer.constantTimeEqual("246", "2468"))
        #expect(!LanServer.constantTimeEqual("", "2468"))
        #expect(LanServer.constantTimeEqual("", ""))
    }

    // MARK: - The intake form

    @Test("the intake form is the module's page, and the first visit sets the session cookie")
    func intakeForm() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        let (first, cookie) = try await bench.openForm()
        #expect(first.status == 200)
        #expect(first.headers["content-type"] == "text/html; charset=utf-8")
        #expect(first.headers["cache-control"] == "no-cache")
        let expected = try await bench.engine.lanIntakePage(store: .object(bench.shop.lanBook), quoteEnabled: false)
        #expect(first.text == expected)
        #expect(first.text.contains("Order Intake"))
        // No upload widget: the estimate route is not served here.
        #expect(!first.text.contains(#"id="modelFile""#))
        #expect(cookie.hasPrefix("khayt_intake="), Comment(rawValue: cookie))
        #expect(first.headers["set-cookie"]?.contains("HttpOnly") == true)
        #expect(first.headers["set-cookie"]?.contains("Max-Age=14400") == true)
        // A visitor with a live session is not handed a second cookie.
        let again = try await bench.get("/intake", headers: ["Cookie": cookie])
        #expect(again.status == 200)
        #expect(again.headers["set-cookie"] == nil)
        // The public status route sends browsers here, and now there is a here.
        #expect(try await bench.get("/api/status").headers["location"] == "/intake")
    }

    @Test("a submission with the session cookie lands in the book as the module's entry")
    func intakeSubmission() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        let (_, cookie) = try await bench.openForm()
        let body = #"{"name":"Sara","description":"Two brackets in PETG","email":"s@example.com","consent":true,"referenceLink":"https://example.com/x"}"#
        let reply = try await bench.post("/api/intake", json: body, headers: ["Cookie": cookie])
        #expect(reply.status == 200, Comment(rawValue: reply.text))
        #expect(reply.text == #"{"ok":true}"#)
        #expect(reply.headers["access-control-allow-origin"] == "*")
        #expect(bench.recorded.entries.count == 1)
        // The SAME entry the rule builds, from the same inputs.
        let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(body.utf8))
        let expected = try await bench.engine.lanIntakeSubmission(body: parsed, shopName: "this shop", id: "intake-fixed",
                                                                  nowIso: LanServer.isoNow(Bench.start))
        #expect(bench.recorded.entries.first == expected.entry)
        guard case .object(let entry)? = bench.recorded.entries.first else { Issue.record("no entry"); return }
        #expect(entry["clientName"] == .string("Sara"))
        #expect(entry["source"] == .string("intake_form"))
        #expect(entry["status"] == .string("active"))
        #expect(entry["submittedAt"] == .string("2027-01-15T08:00:00.000Z"))
        if case .object(let consent)? = entry["consent"] { #expect(consent["agreed"] == .bool(true)) }
        else { Issue.record("no consent record") }
    }

    @Test("without a session or the intake token a submission is refused; with the token it is taken")
    func intakeGate() async throws {
        let bench = try await Bench(intakeToken: "tok-9")
        defer { bench.stop() }
        let body = #"{"name":"A","description":"B","consent":true}"#
        let none = try await bench.post("/api/intake", json: body)
        #expect(none.status == 401)
        #expect(none.text == #"{"error":"Unauthorized"}"#)
        let wrong = try await bench.post("/api/intake", json: body, headers: ["x-khayt-intake-token": "tok-8"])
        #expect(wrong.status == 401)
        let right = try await bench.post("/api/intake", json: body, headers: ["x-khayt-intake-token": "tok-9"])
        #expect(right.status == 200, Comment(rawValue: right.text))
        // A cookie from another address does not travel: the session is bound to the ip that opened it.
        #expect(bench.recorded.entries.count == 1)
    }

    @Test("the rule's refusals and a bad body come back as the Node server's answers")
    func intakeRefusals() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        let (_, cookie) = try await bench.openForm()
        let noName = try await bench.post("/api/intake", json: #"{"description":"B","consent":true}"#, headers: ["Cookie": cookie])
        #expect(noName.status == 400)
        #expect(noName.text == #"{"error":"name is required"}"#)
        let noConsent = try await bench.post("/api/intake", json: #"{"name":"A","description":"B"}"#, headers: ["Cookie": cookie])
        #expect(noConsent.status == 400)
        #expect(noConsent.text == #"{"error":"Please agree to the privacy notice to submit your request."}"#)
        let garbage = try await bench.post("/api/intake", json: "not json", headers: ["Cookie": cookie])
        #expect(garbage.status == 400)
        #expect(garbage.text.contains("Invalid request"))
        #expect(bench.recorded.entries.isEmpty)
    }

    @Test("a book that cannot be written is OUR failure, told as a 500, not the customer's")
    func intakeWriteFailure() async throws {
        let bench = try await Bench(recordFails: true)
        defer { bench.stop() }
        let (_, cookie) = try await bench.openForm()
        let reply = try await bench.post("/api/intake", json: #"{"name":"A","description":"B","consent":true}"#,
                                         headers: ["Cookie": cookie])
        #expect(reply.status == 500)
        #expect(reply.text.contains("could not record your request"))
    }

    @Test("opening the form too often gets the module's too-many page; submitting too often a 429")
    func intakeRates() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        let limits = try await bench.engine.lanIntakeLimits()
        for _ in 0..<Int(limits.SESSION_GRANT_LIMIT) {
            let ok = try await bench.get("/intake")
            #expect(ok.status == 200)
        }
        let tooMany = try await bench.get("/intake")
        #expect(tooMany.status == 429)
        #expect(tooMany.text == (try await bench.engine.lanIntakeTooManyPage()))
        // Submissions have their own bucket, so the last cookie still submits — up to its limit.
        bench.advance(seconds: 3601)
        let (_, cookie) = try await bench.openForm()
        for _ in 0..<Int(limits.SUBMIT_LIMIT) {
            let ok = try await bench.post("/api/intake", json: #"{"name":"A","description":"B","consent":true}"#,
                                          headers: ["Cookie": cookie])
            #expect(ok.status == 200, Comment(rawValue: ok.text))
        }
        let over = try await bench.post("/api/intake", json: #"{"name":"A","description":"B","consent":true}"#,
                                        headers: ["Cookie": cookie])
        #expect(over.status == 429)
        #expect(over.text.contains("Too many submissions"))
    }

    @Test("a session expires after four hours, and an expired cookie is refused")
    func intakeSessionExpiry() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        let (_, cookie) = try await bench.openForm()
        bench.advance(seconds: 4 * 3600 + 1)
        let reply = try await bench.post("/api/intake", json: #"{"name":"A","description":"B","consent":true}"#,
                                         headers: ["Cookie": cookie])
        #expect(reply.status == 401)
    }

    @Test("the clock prints as JavaScript's toISOString and the id as uniqueLanId")
    func intakeSmallThings() {
        #expect(LanServer.isoNow(Date(timeIntervalSince1970: 1_800_000_000)) == "2027-01-15T08:00:00.000Z")
        #expect(LanServer.isoNow(Date(timeIntervalSince1970: 1_800_000_000.5)) == "2027-01-15T08:00:00.500Z")
        let id = LanServer.uniqueId("intake")
        #expect(id.range(of: #"^intake-\d{13}-[0-9a-f]{4}$"#, options: .regularExpression) != nil, Comment(rawValue: id))
        #expect(LanServer.randomToken().count == 64)
        #expect(LanServer.cookies("a=1; khayt_intake=abc; c=x=y") == ["a": "1", "khayt_intake": "abc", "c": "x=y"])
    }

    // MARK: - The shop's side

    @Test("the settings pane's block saves through the shared rule and keeps what it did not show")
    func paneSavesThroughTheRule() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        var root: [String: JSONValue] = ["settings": .object([
            "lanApi": .object(["enabled": .bool(false), "port": .number(3219), "pin": .string("sealed:old"),
                               "webhookToken": .string("wh-1")]),
        ])]
        try await Shop.applySettings(to: &root,
                                     form: ["lanApi": .object(["enabled": .bool(true), "port": .number(4000),
                                                               "bindLan": .bool(true)])],
                                     country: nil, engine: engine)
        guard case .object(let settings)? = root["settings"], case .object(let lan)? = settings["lanApi"] else {
            Issue.record("no lanApi after the save"); return
        }
        #expect(lan["enabled"] == .bool(true))
        #expect(lan["port"] == .number(4000))
        #expect(lan["bindLan"] == .bool(true))
        #expect(lan["pin"] == .string("sealed:old"), "a blank PIN did not keep the stored one")
        #expect(lan["webhookToken"] == .string("wh-1"), "a field the pane never showed was lost")
    }

    @Test("the draft reads the block the way the page shows it")
    func draftReads() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let draft = OnlinePane.Draft.read(["lanApi": .object(["enabled": .bool(true), "port": .number(8080),
                                                              "pin": .string("x"), "bindLan": .bool(true)])], shop: shop)
        #expect(draft.enabled && draft.bindLan && draft.pinStored)
        #expect(draft.port == "8080")
        #expect(draft.pin.isEmpty, "the stored PIN is never shown back")
        let empty = OnlinePane.Draft.read([:], shop: shop)
        #expect(!empty.enabled && !empty.pinStored && empty.port == "3219")
        #expect(OnlinePane.Draft(port: "abc").portNumber == 3219)
    }

    @Test("the sample book never starts a listener, and the config reads its defaults")
    func sampleDoesNotAutostart() async throws {
        let shop = Shop()
        await shop.load(.sample)
        #expect(shop.lanServer == nil)
        #expect(shop.lanURL == nil)
        let config = shop.lanConfig
        #expect(config.enabled == false && config.port == 3219)
    }

    @Test("the LAN address, when there is one, is a private IPv4 and never loopback")
    func lanAddress() {
        guard let address = LanServer.lanIPv4() else { return }   // a Mac with no network
        #expect(!address.hasPrefix("127."), Comment(rawValue: address))
        #expect(address.split(separator: ".").count == 4, Comment(rawValue: address))
    }
}
