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
        /// The book the server reads — mutable, so an approval shows on the next read.
        let book = Book()
        var tokens = 0

        init(pin: String = "2468", intakeToken: String = "", recordFails: Bool = false,
             calendarToken: String = "", measures: Bool = true, sliced: Bool = false,
             readTimeout: TimeInterval = 15) async throws {
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
            let book = self.book
            book.value = shop.lanBook
            var host = LanServer.Host(
                store: { book.value }, pin: pin, engine: engine,
                now: { box.now }, nowText: { "09:16" },
                icon: { LanServer.bundledIcon($0) })
            host.intakeToken = intakeToken
            host.calendarToken = calendarToken
            // Per BENCH, not per process: the stall tests run in parallel and a
            // shared static put one test's restore in the middle of another
            // test's wait.
            host.readTimeout = readTimeout
            host.mintId = { "intake-fixed" }
            // The reader is Swift and file-backed; the bench stands in for it
            // so these tests are about the ROUTE, not about mesh arithmetic.
            host.measure = { _, _ in measures ? LanServerTests.measuredCube : nil }
            // A slicer is not on a test machine, so the slice is stood in for
            // — what is proved here is that the route PREFERS it and falls
            // back cleanly when it is not there.
            host.sliceUpload = { _, _ in sliced ? LanServerTests.slicedFigures : nil }
            host.record = { entry in
                if recordFails { throw CocoaError(.fileWriteUnknown) }
                recorded.entries.append(entry)
            }
            host.survey = { token, rating, comment, nowIso in
                if recordFails { throw CocoaError(.fileWriteUnknown) }
                guard case .array(var log)? = book.value["printLog"] else { return false }
                for i in log.indices {
                    guard case .object(let o) = log[i], case .string(let held)? = o["surveyToken"],
                          LanServer.constantTimeEqual(token, held) else { continue }
                    log[i] = try await engine.lanSurveyPatch(order: .object(o), rating: rating, comment: comment, nowIso: nowIso)
                    book.value["printLog"] = .array(log)
                    return true
                }
                return false
            }
            host.approve = { id, nowIso in
                if recordFails { throw CocoaError(.fileWriteUnknown) }
                let result = try await engine.lanQuoteApply(store: .object(book.value), orderId: id, nowIso: nowIso)
                guard result.found, result.error == nil, let log = result.printLog else { return nil }
                book.value["printLog"] = log
                return result.order
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
    final class Book: @unchecked Sendable {
        var value: [String: JSONValue] = [:]
        /// Put one job into the book, replacing any with the same id.
        func put(_ job: [String: JSONValue]) {
            var log: [JSONValue] = []
            if case .array(let had)? = value["printLog"] { log = had }
            log.removeAll { if case .object(let o) = $0 { return o["id"] == job["id"] } else { return false } }
            log.append(.object(job))
            value["printLog"] = .array(log)
        }
        func job(_ id: String) -> [String: JSONValue]? {
            guard case .array(let log)? = value["printLog"] else { return nil }
            for row in log { if case .object(let o) = row, o["id"] == .string(id) { return o } }
            return nil
        }
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

    @Test("a phone is sent a working set, not the whole book, with the shop's secrets masked")
    func workingSetBehindPin() async throws {
        let bench = try await Bench()
        defer { bench.stop() }

        // A shop with a printer's access code and a bot token in it — two of the
        // paths `lib/store-secret-paths.js` names. This app reads the store from
        // disk, so unlike the renderer it is genuinely holding them.
        bench.book.value["settings"] = .object([
            "shopName": .string("Ward"),
            "telegram": .object(["botToken": .string("__enc__BOTSECRET")]),
        ])
        bench.book.value["machines"] = .array([.object([
            "id": .string("m1"),
            "name": .string("X1C"),
            "printerApi": .object(["accessCode": .string("__enc__12345678")]),
        ])])
        // Put the history in the book on purpose rather than relying on the
        // sample having it: what is being tested is that this is left behind,
        // and a fixture that never had it would pass by accident.
        bench.book.value["printFiles"] = .array([.object(["id": .string("f1")])])
        bench.book.value["auditLog"] = .array([.object(["id": .string("a1")])])

        let none = try await bench.get("/api/store")
        #expect(none.status == 401, "the shop's book must never be open on the LAN")

        let reply = try await bench.get("/api/store", headers: ["x-khayt-pin": "2468"])
        #expect(reply.status == 200, Comment(rawValue: reply.text))

        struct Envelope: Decodable {
            let whole: Bool
            let scope: BookScope.Taken
            let store: [String: JSONValue]
        }
        let sent = try #require(try? JSONDecoder().decode(Envelope.self, from: Data(reply.text.utf8)))

        #expect(sent.whole == false, "the phone was sent the whole book")

        // The history that is half a real shop's store and that no companion
        // screen has ever shown. Withheld, and SAID to be withheld — a phone
        // cannot tell "not sent" from "there are none" by looking.
        #expect(sent.store["printFiles"] == nil)
        #expect(sent.store["auditLog"] == nil)
        #expect(sent.scope.omitted.contains("printFiles"))
        #expect(sent.scope.omitted.contains("auditLog"))

        // What it does get, and the settings without which it can price nothing.
        #expect(sent.store["settings"] != nil)
        #expect(sent.store["printLog"] != nil)
        #expect(sent.store["inventory"] != nil)

        // Said as a fact rather than a comparison, because a comparison against
        // `forCloud` would still pass if `forCloud` stopped masking.
        guard case .object(let settings)? = sent.store["settings"],
              case .object(let telegram)? = settings["telegram"],
              case .array(let machines)? = sent.store["machines"],
              case .object(let machine) = machines[0],
              case .object(let api)? = machine["printerApi"] else {
            Issue.record("the book did not arrive in the shape it was sent in")
            return
        }
        #expect(telegram["botToken"] == .string("__KHAYT_MASKED__"),
                "a shop's bot token went out over the LAN")
        #expect(api["accessCode"] == .string("__KHAYT_MASKED__"),
                "a printer's access code went out over the LAN")
        #expect(settings["shopName"] == .string("Ward"), "masking took something that was not a secret")
    }

    @Test("`?scope=whole` still exists for the caller that genuinely wants everything")
    func wholeOnRequest() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        let reply = try await bench.get("/api/store?scope=whole", headers: ["x-khayt-pin": "2468"])
        #expect(reply.status == 200, Comment(rawValue: reply.text))

        struct Envelope: Decodable {
            let whole: Bool
            let store: [String: JSONValue]
        }
        let sent = try #require(try? JSONDecoder().decode(Envelope.self, from: Data(reply.text.utf8)))
        #expect(sent.whole)
        // Masked all the same: wanting everything is not the same as being
        // entitled to the shop's credentials.
        let expected = try await bench.engine.storeForCloud(bench.book.value)
        #expect(sent.store == expected)
    }

    @Test("the shop is advertised under its own name, and an Arabic one is not cut in half")
    func advertisedName() {
        // What somebody standing in the shop recognises in a list.
        #expect(LanServer.advertisedName(["settings": .object(["shopName": .string("Ward")])]) == "Ward")

        // A shop that has not named itself gets the product, not an empty row —
        // an unselectable blank in a list reads as a broken app.
        #expect(LanServer.advertisedName([:]) == "Khayt")
        #expect(LanServer.advertisedName(["settings": .object(["shopName": .string("   ")])]) == "Khayt")

        // Bonjour allows 63 BYTES. Arabic is two bytes a letter, so a name well
        // under 63 characters is over the limit — and the failure is not a
        // shortened label, it is a service that never registers and a shop that
        // simply does not appear on the phone.
        let arabic = String(repeating: "ورشة", count: 12)          // 48 chars, 96 bytes
        #expect(arabic.count == 48)
        #expect(arabic.utf8.count == 96)
        let cut = LanServer.advertisedName(["settings": .object(["shopName": .string(arabic)])])
        #expect(cut.utf8.count <= 63)
        // And it is still a string: truncating bytes can split a character in
        // half, which produces bytes no reader can decode.
        #expect(!cut.isEmpty)
        #expect(arabic.hasPrefix(cut), "the shortened name is not a prefix of the shop's")

        // An ASCII name at the boundary keeps every byte it is entitled to.
        let long = String(repeating: "a", count: 70)
        #expect(LanServer.advertisedName(["settings": .object(["shopName": .string(long)])]).count == 63)
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

    // MARK: - The customer's quote

    static let quoteJob: [String: JSONValue] = [
        "id": .string("Q-77"), "project": .string("Bracket <v2>"), "client": .string("Sara"),
        "status": .string("quote"), "price": .number(140), "date": .string("2027-01-10"),
        "quoteExpiresAt": .string("2027-01-31"), "quoteApprovalToken": .string("abcdef0123456789abcdef0123456789"),
        "parts": .array([.object(["name": .string("Bracket"), "qty": .number(2)])]),
    ]

    @Test("the quote page is the module's, behind the job's own token")
    func quotePage() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        bench.book.put(Self.quoteJob)
        let missing = try await bench.get("/order/NOPE/quote?token=x")
        #expect(missing.status == 404)
        #expect(missing.text == (try await bench.engine.lanQuoteNotice("quote_not_found")))
        let noToken = try await bench.get("/order/Q-77/quote")
        #expect(noToken.status == 403)
        #expect(noToken.text == (try await bench.engine.lanQuoteNotice("invalid_link")))
        let wrong = try await bench.get("/order/Q-77/quote?token=abcdef0123456789abcdef0123456789ff")
        #expect(wrong.status == 403)
        let page = try await bench.get("/order/Q-77/quote?token=abcdef0123456789abcdef0123456789")
        #expect(page.status == 200)
        #expect(page.headers["content-type"] == "text/html; charset=utf-8")
        #expect(page.headers["cache-control"] == "no-cache")
        #expect(page.headers["x-frame-options"] == "DENY")
        let shopName = try await bench.engine.lanQuoteShopName(store: .object(bench.book.value))
        let expected = try await bench.engine.lanQuotePage(
            order: .object(Self.quoteJob), shopName: shopName, approvePath: "/order/Q-77/approve",
            approvalToken: "abcdef0123456789abcdef0123456789", alreadyApproved: false, expired: false,
            currencyLabel: Shop.plainString(bench.shop.settingsDict["currency"]) ?? "")
        #expect(page.text == expected)
        #expect(page.text.contains("Approve Quote"))
        #expect(page.text.contains("Bracket &lt;v2&gt;"), "the project name was not escaped")
        #expect(!shopName.isEmpty && shopName != "Khayt", Comment(rawValue: "the sample shop's name did not come through: \(shopName)"))
    }

    @Test("approving from the page moves the job to pending, once")
    func approve() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        bench.book.put(Self.quoteJob)
        let body = #"{"action":"approve","approvalToken":"abcdef0123456789abcdef0123456789"}"#
        let reply = try await bench.post("/order/Q-77/approve", json: body)
        #expect(reply.status == 200, Comment(rawValue: reply.text))
        #expect(reply.text == (try await bench.engine.lanQuoteNotice("approved", project: "Bracket <v2>")))
        #expect(reply.text.contains("Bracket &lt;v2&gt;"))
        let job = try #require(bench.book.job("Q-77"))
        #expect(job["status"] == .string("pending"))
        #expect(job["clientApprovedAt"] == .string(LanServer.isoNow(Bench.start)))
        #expect(job["quoteAcceptedAt"] == .string("2027-01-15"))
        // The page now says approved rather than offering the button.
        let page = try await bench.get("/order/Q-77/quote?token=abcdef0123456789abcdef0123456789")
        #expect(page.text.contains("Quote approved"))
        #expect(!page.text.contains("approveBtn"))
        // A second approval is refused: the job is no longer awaiting one.
        let again = try await bench.post("/order/Q-77/approve", json: body)
        #expect(again.status == 409)
        #expect(again.text == (try await bench.engine.lanQuoteNotice("cannot_approve")))
    }

    @Test("the approve route's refusals are the Node route's: bad link, expired, wrong action, missing")
    func approveRefusals() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        bench.book.put(Self.quoteJob)
        let bad = try await bench.post("/order/Q-77/approve", json: #"{"approvalToken":"nope"}"#)
        #expect(bad.status == 403)
        #expect(bad.text == (try await bench.engine.lanQuoteNotice("invalid_link_approve")))
        let action = try await bench.post("/order/Q-77/approve", json: #"{"action":"decline","approvalToken":"abcdef0123456789abcdef0123456789"}"#)
        #expect(action.status == 400)
        let missing = try await bench.post("/order/NOPE/approve", json: "")
        #expect(missing.status == 404)
        // The token may travel in the query, as the page's link does.
        var expired = Self.quoteJob
        expired["id"] = .string("Q-78"); expired["quoteExpiresAt"] = .string("2027-01-01")
        bench.book.put(expired)
        let gone = try await bench.post("/order/Q-78/approve?token=abcdef0123456789abcdef0123456789", json: "")
        #expect(gone.status == 410)
        #expect(gone.text == (try await bench.engine.lanQuoteNotice("expired")))
        // And the page for it says so, without a button.
        let page = try await bench.get("/order/Q-78/quote?token=abcdef0123456789abcdef0123456789")
        #expect(page.text.contains("This quote has expired"))
        #expect(bench.book.job("Q-78")?["status"] == .string("quote"))
    }

    @Test("a book that cannot take the approval is a 500, and the job is untouched")
    func approveWriteFailure() async throws {
        let bench = try await Bench(recordFails: true)
        defer { bench.stop() }
        bench.book.put(Self.quoteJob)
        let reply = try await bench.post("/order/Q-77/approve", json: #"{"approvalToken":"abcdef0123456789abcdef0123456789"}"#)
        #expect(reply.status == 500)
        #expect(bench.book.job("Q-77")?["status"] == .string("quote"))
    }

    @Test("the order path keeps only the characters the Node route keeps")
    func orderPaths() {
        #expect(LanServer.quotePath("/order/Q-77/quote") == "Q-77")
        #expect(LanServer.quotePath("/order/a b%2F..;/quote") == "ab2F")
        #expect(LanServer.quotePath("/order//quote") == nil)
        #expect(LanServer.quotePath("/order/x/y/quote") == nil)
        #expect(LanServer.approvePath("/order/Q-77/approve") == "Q-77")
        #expect(LanServer.approvePath("/order/Q-77/quote") == nil)
    }

    // MARK: - The customer's order page

    static let trackedJob: [String: JSONValue] = [
        "id": .string("T-5"), "project": .string("Vase <b>"), "client": .string("Sara"), "status": .string("printing"),
        "material": .string("PETG"), "dueDate": .string("2027-02-01"),
        "trackingToken": .string("0123456789abcdef0123456789abcdef"),
        "shippingStatus": .string("in_transit"), "trackingNumber": .string("TN-1"), "carrier": .string("smsa"),
    ]

    @Test("the tracking page is the module's, behind the order's tracking token")
    func trackingPage() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        bench.book.put(Self.trackedJob)
        let missing = try await bench.get("/order/NOPE?token=x")
        #expect(missing.status == 404)
        #expect(missing.text == (try await bench.engine.lanOrderNotice("order_not_found")))
        let noToken = try await bench.get("/order/T-5")
        #expect(noToken.status == 403)
        #expect(noToken.text == (try await bench.engine.lanOrderNotice("invalid_tracking_link")))
        let page = try await bench.get("/order/T-5?token=0123456789abcdef0123456789abcdef")
        #expect(page.status == 200)
        #expect(page.headers["content-type"] == "text/html; charset=utf-8")
        #expect(page.headers["x-frame-options"] == "DENY")
        let expected = try await bench.engine.lanTrackingPage(order: .object(Self.trackedJob), store: .object(bench.book.value))
        #expect(page.text == expected)
        #expect(page.text.contains("Vase &lt;b&gt;"))
        #expect(page.text.contains("Printing"))
        // The carriers directory came along: a carrier name and its tracking link.
        #expect(page.text.contains("SMSA"), "the carrier's name is missing — lib/carriers.js is not loaded")
        #expect(page.text.contains("TN-1"))
        // `/status` and a trailing slash are the same page.
        let alias = try await bench.get("/order/T-5/status?token=0123456789abcdef0123456789abcdef")
        #expect(alias.status == 200)
    }

    @Test("a quote's order page sends the customer to the quote page")
    func trackingRedirectsQuotes() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        bench.book.put(Self.quoteJob)
        let reply = try await bench.get("/order/Q-77")
        #expect(reply.status == 302)
        #expect(reply.headers["location"] == "/order/Q-77/quote")
    }

    @Test("a finished order's page offers the survey, and the survey lands on the order once")
    func survey() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        var done = Self.trackedJob
        done["status"] = .string("completed"); done["surveyToken"] = .string("survey-tok-1")
        bench.book.put(done)
        let page = try await bench.get("/order/T-5?token=0123456789abcdef0123456789abcdef")
        #expect(page.text.contains(#"id="surveyCard""#))
        let reply = try await bench.post("/api/survey", json: #"{"token":"survey-tok-1","orderId":"T-5","rating":4,"comment":"  lovely  "}"#)
        #expect(reply.status == 200, Comment(rawValue: reply.text))
        #expect(reply.text == #"{"ok":true}"#)
        #expect(reply.headers["access-control-allow-origin"] == "*")
        let job = try #require(bench.book.job("T-5"))
        #expect(job["surveyToken"] == nil, "the token was not spent")
        if case .object(let survey)? = job["survey"] {
            #expect(survey["rating"] == .number(4))
            #expect(survey["comment"] == .string("lovely"))
            #expect(survey["submittedAt"] == .string(LanServer.isoNow(Bench.start)))
        } else { Issue.record("no survey on the order") }
        // The page now thanks rather than asks.
        let after = try await bench.get("/order/T-5?token=0123456789abcdef0123456789abcdef")
        #expect(after.text.contains("Thank you for your feedback"))
        #expect(!after.text.contains(#"id="surveyCard""#))
        // A spent token is a 404, as on the Node server.
        let again = try await bench.post("/api/survey", json: #"{"token":"survey-tok-1","rating":5}"#)
        #expect(again.status == 404)
        #expect(again.text == #"{"error":"Invalid or expired survey token"}"#)
    }

    @Test("the survey refuses what the Node route refuses, and is rate-limited")
    func surveyRefusals() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        let noRating = try await bench.post("/api/survey", json: #"{"token":"t"}"#)
        #expect(noRating.status == 400)
        #expect(noRating.text == #"{"error":"Invalid payload — token and rating (1-5) are required"}"#)
        let six = try await bench.post("/api/survey", json: #"{"token":"t","rating":6}"#)
        #expect(six.status == 400)
        let unknown = try await bench.post("/api/survey", json: #"{"token":"nobody","rating":3}"#)
        #expect(unknown.status == 404)
        let limit = try await bench.engine.lanSurveyLimit()
        #expect(limit == 30)
        // Three used above; the rest of the bucket, then a 429.
        for _ in 0..<(limit - 3) {
            _ = try await bench.post("/api/survey", json: #"{"token":"nobody","rating":3}"#)
        }
        let over = try await bench.post("/api/survey", json: #"{"token":"nobody","rating":3}"#)
        #expect(over.status == 429)
        #expect(over.text.contains("Too many attempts"))
    }

    @Test("the tracking path keeps only what the Node route keeps")
    func trackingPaths() {
        #expect(LanServer.trackingPath("/order/T-5") == "T-5")
        #expect(LanServer.trackingPath("/order/T-5/") == "T-5")
        #expect(LanServer.trackingPath("/order/T-5/status") == "T-5")
        #expect(LanServer.trackingPath("/order/T-5/status/") == "T-5")
        #expect(LanServer.trackingPath("/order/a b;/") == "ab")
        #expect(LanServer.trackingPath("/order/x/y") == nil)
        #expect(LanServer.trackingPath("/order/") == nil)
        // The quote and approve routes take theirs first; this one never sees them.
        #expect(LanServer.quotePath("/order/T-5/quote") == "T-5")
    }

    // MARK: - Pricing a model the customer uploaded

    /// A payload the scan will accept as a binary STL: the 80-byte header
    /// every one carries, then a count, then something. The scan refuses
    /// anything shorter, which is right — and which the four-byte "MESH" these
    /// tests used to post was not.
    static let stlBytes = String(repeating: "s", count: 120)

    /// What a slicer says about the same model — the figures the shape cannot
    /// reach, because geometry knows nothing about purge.
    static let slicedFigures: JSONValue = .object([
        "exact": .bool(true), "source": .string("slicer"),
        "printTimeMins": .number(272), "filamentGrams": .number(57.18),
        "slicer": .string("SnapmakerOrca"),
    ])

    /// A cube 50mm on a side, as this app's own reader measures one.
    static let measuredCube: JSONValue = .object([
        "source": .string("geometry"), "exact": .bool(false),
        "geometry": .object([
            "volumeMm3": .number(125_000), "areaMm2": .number(15_000),
            "triangleCount": .number(12),
            "bbox": .object(["x": .number(50), "y": .number(50), "z": .number(50)]),
        ]),
    ])

    /// A shop that has switched public pricing on and chosen a preset.
    static func quotingBook(_ base: [String: JSONValue]) -> [String: JSONValue] {
        var book = base
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = book["settings"] { settings = s }
        settings["currency"] = .string("SAR")
        var lan: [String: JSONValue] = [:]
        if case .object(let l)? = settings["lanApi"] { lan = l }
        lan["intakeQuote"] = .object([
            "enabled": .bool(true), "presetId": .string("PRESET-1"),
            "spoolCost": .number(75), "spoolWeight": .number(1000),
            "marginPct": .number(30), "minPrice": .number(0), "wastePct": .number(0.05),
            "hourlyLimit": .number(12),
        ])
        settings["lanApi"] = .object(lan)
        book["settings"] = .object(settings)
        book["printers"] = .array([.object([
            "id": .string("PRESET-1"), "name": .string("U1"),
            "wearRate": .number(0.75), "powerDraw": .number(150), "elecRate": .number(0.18),
            "laborRate": .number(90), "failureRate": .number(10),
            "prepTime": .number(0.1), "postTime": .number(0.1),
        ])])
        return book
    }

    @Test("a measured model comes back priced, and the form offers the upload")
    func estimatePrices() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        bench.book.value = Self.quotingBook(bench.book.value)
        // The widget appears exactly when the route would answer.
        let (form, cookie) = try await bench.openForm()
        #expect(form.text.contains(#"id="modelFile""#), "the form did not offer the upload")

        let reply = try await bench.post("/api/intake/estimate?name=cube.stl", json: Self.stlBytes,
                                         headers: ["Cookie": cookie])
        #expect(reply.status == 200, Comment(rawValue: reply.text))
        guard case .object(let q) = try JSONDecoder().decode(JSONValue.self, from: reply.body) else {
            Issue.record("not an object: \(reply.text)"); return
        }
        #expect(q["ok"] == .bool(true), Comment(rawValue: reply.text))
        guard case .number(let price)? = q["price"] else { Issue.record("no price: \(reply.text)"); return }
        #expect(price > 0)
        #expect(q["currency"] == .string("SAR"))
        #expect(q["binding"] == .bool(false), "a public figure must never be a promise")
        guard case .string(let ref)? = q["ref"] else { Issue.record("no reference"); return }

        // And the SHOP's figure is what lands on the request, by reference.
        let body = #"{"name":"Sara","description":"the cube","consent":true,"estimateRef":"\#(ref)"}"#
        let sent = try await bench.post("/api/intake", json: body, headers: ["Cookie": cookie])
        #expect(sent.status == 200, Comment(rawValue: sent.text))
        guard case .object(let entry)? = bench.recorded.entries.first else { Issue.record("no entry"); return }
        #expect(entry["estValue"] == .number(price), Comment(rawValue: "\(entry["estValue"] ?? .null)"))
        if case .object(let model)? = entry["modelQuote"] {
            #expect(model["binding"] == .bool(false))
            #expect(model["price"] == .number(price))
        } else { Issue.record("the quote was not attached to the request") }
    }

    @Test("a price the browser makes up is not the price the shop sees")
    func postedPriceIsIgnored() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        bench.book.value = Self.quotingBook(bench.book.value)
        let (_, cookie) = try await bench.openForm()
        // A reference that was never issued, and a price posted beside it.
        let body = #"{"name":"A","description":"B","consent":true,"estimateRef":"made-up","price":9999}"#
        let sent = try await bench.post("/api/intake", json: body, headers: ["Cookie": cookie])
        #expect(sent.status == 200)
        guard case .object(let entry)? = bench.recorded.entries.first else { Issue.record("no entry"); return }
        #expect(entry["estValue"] == .number(0), Comment(rawValue: "\(entry["estValue"] ?? .null)"))
        #expect(entry["modelQuote"] == nil, "a made-up reference produced a quote")
    }

    @Test("a file that is not what it claims is refused before it is measured")
    func scanRefusesImposters() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        bench.book.value = Self.quotingBook(bench.book.value)
        let (_, cookie) = try await bench.openForm()

        // A PNG called a 3MF. The reader would have been handed it.
        let png = "\u{89}PNG\r\n\u{1A}\n" + String(repeating: "x", count: 200)
        let fake = try await bench.post("/api/intake/estimate?name=model.3mf", json: png, headers: ["Cookie": cookie])
        #expect(fake.status == 400)
        #expect(fake.text.contains("not-what-it-says"), Comment(rawValue: fake.text))
        // And nothing was measured: the stand-in reader was never reached.
        #expect(bench.recorded.entries.isEmpty)

        // Too short to be a binary STL and not ASCII either.
        let stub = try await bench.post("/api/intake/estimate?name=tiny.stl", json: "\u{FF}\u{FE}",
                                        headers: ["Cookie": cookie])
        #expect(stub.status == 400)
        #expect(stub.text.contains("not-what-it-says"))

        // An honest STL of a believable size still gets through to the reader.
        let real = try await bench.post("/api/intake/estimate?name=cube.stl",
                                        json: String(repeating: "m", count: 200), headers: ["Cookie": cookie])
        #expect(real.status == 200, Comment(rawValue: real.text))
    }

    @Test("what the facts are read from a file, without unpacking it")
    func uploadFacts() throws {
        // The opening bytes, as the scan wants them.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(LanServer.uploadFacts(png, ext: "stl").header.hasPrefix("89504e47"))
        // A non-archive is not asked for members at all.
        #expect(LanServer.uploadFacts(png, ext: "stl").entries == nil)
        // Something calling itself a 3MF that is not a zip yields no members,
        // which the rule reads as "not what it says" rather than as cleared.
        #expect(LanServer.uploadFacts(png, ext: "3mf").entries?.isEmpty == true)
    }

    @Test("the refusals come before the bytes, and in the Node route's order")
    func estimateRefusals() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        let (_, cookie) = try await bench.openForm()
        // Off: answered before a single byte is read, so an off switch is not
        // an upload target.
        let off = try await bench.post("/api/intake/estimate?name=cube.stl", json: Self.stlBytes,
                                       headers: ["Cookie": cookie])
        #expect(off.status == 403)
        #expect(off.text == #"{"ok":false,"reason":"off"}"#)
        // And the form does not offer a widget whose request would be refused.
        let (form, _) = try await bench.openForm()
        #expect(!form.text.contains(#"id="modelFile""#))

        bench.book.value = Self.quotingBook(bench.book.value)
        let noSession = try await bench.post("/api/intake/estimate?name=cube.stl", json: Self.stlBytes)
        #expect(noSession.status == 401)
        let odd = try await bench.post("/api/intake/estimate?name=drawing.pdf", json: "X", headers: ["Cookie": cookie])
        #expect(odd.status == 400)
        #expect(odd.text == #"{"ok":false,"reason":"unsupported"}"#)
        let empty = try await bench.post("/api/intake/estimate?name=cube.stl", json: "", headers: ["Cookie": cookie])
        #expect(empty.status == 400)
        #expect(empty.text == #"{"ok":false,"reason":"no-numbers"}"#)
    }

    @Test("a file this app cannot measure is refused rather than guessed at")
    func unmeasurable() async throws {
        let bench = try await Bench(measures: false)
        defer { bench.stop() }
        bench.book.value = Self.quotingBook(bench.book.value)
        let (_, cookie) = try await bench.openForm()
        let reply = try await bench.post("/api/intake/estimate?name=cube.stl", json: Self.stlBytes,
                                         headers: ["Cookie": cookie])
        #expect(reply.status == 400)
        #expect(reply.text == #"{"ok":false,"reason":"no-numbers"}"#)
    }

    @Test("where the shop slices uploads, the slicer's figures beat the shape's")
    func slicingBeatsGeometry() async throws {
        let bench = try await Bench(sliced: true)
        defer { bench.stop() }
        bench.book.value = Self.quotingBook(bench.book.value)
        let (_, cookie) = try await bench.openForm()
        let reply = try await bench.post("/api/intake/estimate?name=dragon.stl", json: Self.stlBytes,
                                         headers: ["Cookie": cookie])
        #expect(reply.status == 200, Comment(rawValue: reply.text))
        guard case .object(let q) = try JSONDecoder().decode(JSONValue.self, from: reply.body) else {
            Issue.record("not an object"); return
        }
        #expect(q["ok"] == .bool(true), Comment(rawValue: reply.text))
        // The slicer's own weight, not an estimate from the shape — and said
        // to be exact, which the geometric answer never is.
        #expect(q["exact"] == .bool(true))
        #expect(q["slicer"] == .string("SnapmakerOrca"))
        // 57.18 g plus the shop's 5% slack, where the shape would have given
        // a far smaller number.
        #expect(q["grams"] == .number(60), Comment(rawValue: "\(q["grams"] ?? .null)"))
    }

    @Test("with slicing off, or a slice that produced nothing, the shape still answers")
    func slicingFallsBack() async throws {
        // Off: the default, and the same answer the route always gave.
        let off = try await Bench()
        defer { off.stop() }
        off.book.value = Self.quotingBook(off.book.value)
        let (_, cookie) = try await off.openForm()
        let reply = try await off.post("/api/intake/estimate?name=cube.stl", json: Self.stlBytes,
                                       headers: ["Cookie": cookie])
        #expect(reply.status == 200, Comment(rawValue: reply.text))
        guard case .object(let q) = try JSONDecoder().decode(JSONValue.self, from: reply.body) else {
            Issue.record("not an object"); return
        }
        #expect(q["ok"] == .bool(true))
        // Measured, not sliced: an estimate is never called exact.
        #expect(q["exact"] != .bool(true))
    }

    @Test("a shop that has not asked for slicing does not get it, whatever else is set")
    func slicingIsOffUntilAsked() async throws {
        let shop = Shop()
        await shop.load(.sample)
        // Nothing is written and no slicer is consulted: the switch decides
        // first, before the slicer, the file or anything else is looked at.
        let answer = await shop.sliceCustomerUpload(Data("x".utf8), ext: "stl")
        #expect(answer == nil, "a sample book with no setting sliced a stranger's file")
    }

    @Test("a sliced file is quoted on the slicer's own figures")
    func slicedUpload() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        bench.book.value = Self.quotingBook(bench.book.value)
        let (_, cookie) = try await bench.openForm()
        let gcode = "; estimated printing time (normal mode) = 4h 32m 11s\n; filament used [g] = 140.91\n"
        let reply = try await bench.post("/api/intake/estimate?name=part.gcode", json: gcode, headers: ["Cookie": cookie])
        #expect(reply.status == 200, Comment(rawValue: reply.text))
        guard case .object(let q) = try JSONDecoder().decode(JSONValue.self, from: reply.body) else {
            Issue.record("not an object"); return
        }
        #expect(q["ok"] == .bool(true), Comment(rawValue: reply.text))
        #expect(q["exact"] == .bool(true), "a sliced file was estimated instead of read")
        // The slicer's 140.91 g plus the shop's own 5% purge and brim slack,
        // which the rule adds because the customer's file does not account
        // for it. The shop's allowance, not this app's.
        #expect(q["grams"] == .number(148), Comment(rawValue: "\(q["grams"] ?? .null)"))
    }

    @Test("what a name is allowed to mean, and what the readers are")
    func uploadNames() {
        #expect(LanServer.uploadExtension("cube.STL") == "stl")
        #expect(LanServer.uploadExtension("a/../b.3mf") == "3mf")
        // A name with no extension yields whatever is left after the filter,
        // which is not a reader this app has — so it is refused.
        #expect(LanServer.uploadExtension("no-dot") == "nodot")
        #expect(!LanServer.readableUploads.contains(LanServer.uploadExtension("no-dot")))
        #expect(LanServer.uploadExtension("odd.st l;") == "stl")
        #expect(LanServer.readableUploads == ["stl", "obj", "3mf", "gcode", "gco"])
        #expect(!LanServer.quotingIsOn([:]))
    }

    // MARK: - The calendar

    @Test("the calendar feed is the module's, for the subscription token or the owner PIN")
    func calendarFeed() async throws {
        let bench = try await Bench(calendarToken: "cal-token-1")
        defer { bench.stop() }
        bench.book.put(["id": .string("D-1"), "project": .string("Bracket"), "client": .string("Sara"),
                        "status": .string("printing"), "dueDate": .string("2027-02-01")])
        let none = try await bench.get("/calendar.ics")
        #expect(none.status == 401)
        #expect(none.headers["content-type"] == "text/plain; charset=utf-8")
        #expect(none.text.contains("calendar subscription link"))
        let wrong = try await bench.get("/calendar.ics?token=cal-token-2")
        #expect(wrong.status == 401)
        let byToken = try await bench.get("/calendar.ics?token=cal-token-1")
        #expect(byToken.status == 200)
        #expect(byToken.headers["content-type"] == "text/calendar; charset=utf-8")
        #expect(byToken.headers["content-disposition"]?.contains("khayt-orders.ics") == true)
        let expected = try await bench.engine.lanCalendarFeed(store: .object(bench.book.value))
        #expect(byToken.text == expected)
        #expect(byToken.text.contains("BEGIN:VCALENDAR") && byToken.text.contains("UID:khayt-D-1@khaytapp.com"))
        #expect(byToken.text.contains("DTSTART;VALUE=DATE:20270201"))
        #expect(byToken.text.contains("SUMMARY:Bracket (Sara)"))
        let byPin = try await bench.get("/calendar.ics", headers: ["x-khayt-pin": "2468"])
        #expect(byPin.status == 200)
        #expect(byPin.text == expected)
    }

    @Test("with no calendar token the feed opens only to the PIN")
    func calendarNeedsAToken() async throws {
        let bench = try await Bench()
        defer { bench.stop() }
        let empty = try await bench.get("/calendar.ics?token=")
        #expect(empty.status == 401)
        let byPin = try await bench.get("/calendar.ics?pin=2468")
        #expect(byPin.status == 200)
    }

    // MARK: - The pane that makes public pricing reachable

    @Test("the pricing settings survive a save, including a field the pane never showed")
    func quoteSettingsSave() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        var root: [String: JSONValue] = ["settings": .object([
            "lanApi": .object([
                "enabled": .bool(true), "port": .number(3219), "pin": .string("sealed"),
                "intakeQuote": .object(["enabled": .bool(false), "marginPct": .number(30),
                                        "somethingNewer": .number(7)]),
            ]),
        ])]
        var draft = OnlinePane.Draft()
        draft.enabled = true
        draft.quoteOn = true
        draft.presetId = "PRESET-1"
        draft.margin = "40"
        draft.waste = "5"          // shown as a percentage…
        draft.spoolCost = "75"
        try await Shop.applySettings(to: &root,
                                     form: ["lanApi": .object([
                                        "enabled": .bool(true),
                                        "intakeQuote": .object(draft.quoteForm()),
                                     ])],
                                     country: nil, engine: engine)
        guard case .object(let settings)? = root["settings"], case .object(let lan)? = settings["lanApi"],
              case .object(let q)? = lan["intakeQuote"] else { Issue.record("no pricing block"); return }
        #expect(q["enabled"] == .bool(true))
        #expect(q["presetId"] == .string("PRESET-1"))
        #expect(q["marginPct"] == .number(40))
        // …and stored as a fraction, or every shop's allowance would be ×100.
        #expect(q["wastePct"] == .number(0.05), Comment(rawValue: "\(q["wastePct"] ?? .null)"))
        #expect(q["spoolCost"] == .number(75))
        #expect(q["somethingNewer"] == .number(7), "a field a newer build wrote was dropped")
        #expect(lan["pin"] == .string("sealed"), "the PIN was lost saving the pricing block")
    }

    @Test("the pane reads the block back the way it stores it")
    func quoteSettingsRead() async throws {
        let shop = Shop()
        await shop.load(.sample)
        var draft = OnlinePane.Draft()
        OnlinePane.Draft.readQuote(["lanApi": .object(["intakeQuote": .object([
            "enabled": .bool(true), "presetId": .string("P1"), "filamentId": .string("seed-1"),
            "spoolCost": .number(75), "spoolWeight": .number(1000), "marginPct": .number(30),
            "minPrice": .number(20), "wastePct": .number(0.05), "hourlyLimit": .number(6),
        ])])], into: &draft)
        #expect(draft.quoteOn && draft.presetId == "P1" && draft.filamentId == "seed-1")
        #expect(draft.margin == "30" && draft.spoolCost == "75" && draft.minPrice == "20")
        // A fraction on the way in, a percentage on the way out, and back again.
        #expect(draft.waste == "5", Comment(rawValue: draft.waste))
        #expect(draft.quoteForm()["wastePct"] == .number(0.05))
        #expect(draft.limit == "6")
        // A book that has never had the block reads as off, with the defaults.
        var fresh = OnlinePane.Draft()
        OnlinePane.Draft.readQuote([:], into: &fresh)
        #expect(!fresh.quoteOn && fresh.spoolWeight == "1000" && fresh.limit == "12")
        #expect(fresh.quoteForm()["wastePct"] == .number(0))
    }

    @Test("a preset is a name and the seven figures, and the same name replaces rather than doubles")
    func presetShape() async throws {
        let one = try #require(Shop.Preset.from(.object([
            "id": .string("PRNTR-1"), "name": .string("U1"),
            "wearRate": .number(0.75), "powerDraw": .number(150), "elecRate": .number(0.18),
            "laborRate": .number(90), "failureRate": .number(10),
            "prepTime": .number(0.1), "postTime": .number(0.1),
        ])))
        #expect(one.name == "U1" && one.rates["laborRate"] == 90)
        guard case .object(let back) = one.record else { Issue.record("not an object"); return }
        // Every one of the seven, because `lib/public-quote.js` reads them all
        // and a missing rate is silently costed at nothing.
        for key in Shop.Preset.rateKeys {
            #expect(back[key] != nil, Comment(rawValue: "\(key) missing from a saved preset"))
        }
        #expect(back["id"] == .string("PRNTR-1"))
        // A row with no id is not a preset: the quote rule finds presets BY id.
        #expect(Shop.Preset.from(.object(["name": .string("no id")])) == nil)
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
