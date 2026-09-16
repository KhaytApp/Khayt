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

        init(pin: String = "2468") async throws {
            let shop = Shop()
            await shop.load(.sample)
            let engine = try #require(shop.engine)
            self.shop = shop
            self.engine = engine
            var clock = Self.start
            self.clock = clock
            let box = ClockBox(clock)
            self.box = box
            let server = LanServer(host: LanServer.Host(
                store: { shop.lanBook }, pin: pin, engine: engine,
                now: { box.now }, nowText: { "09:16" },
                icon: { LanServer.bundledIcon($0) }))
            self.server = server
            port = try await server.start(port: 0, bind: .loopback)
            clock = Self.start
        }
        let box: ClockBox
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

    /// URLSession follows a 302 by itself; the test wants to see the 302.
    final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        static let session: URLSession = {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
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
