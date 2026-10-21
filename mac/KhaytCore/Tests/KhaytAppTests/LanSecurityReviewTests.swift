import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The October 2026 review of the LAN server: each finding, held.
///
/// Most of these call `respond(to:)` directly rather than going through a
/// socket. That is what lets a test be a visitor at sixty addresses, or send
/// sixteen requests that genuinely interleave at the server's `await`s — the
/// two things the findings were about — without depending on how quickly the
/// test runner gets round to sixteen URLSession tasks.
///
/// No `.timeLimit` here, deliberately: a @MainActor test's clock runs while it
/// waits its turn for the main actor, and in a full run that wait alone is
/// twenty minutes — every test in this suite "exceeded" five. The guards
/// against a hang are on the things that can hang: `Gate` lets go by itself,
/// and blocking probes go through `offPool`.
@MainActor
struct LanSecurityReviewTests {

    /// A server that is never started: requests go straight to `respond`.
    /// `now`: a fixed clock, for a test that counts failures inside the
    /// lockout window. On the real clock a slow runner can let the window
    /// lapse between the tenth wrong PIN and the check — which is what failed
    /// `linkLocalLockoutIsPerDevice` on a loaded CI run (alpha.62).
    static func server(pin: String = "24682468", devices: LanDevices? = nil,
                       measureDelay: TimeInterval = 0, now: Date? = nil,
                       book: (([String: JSONValue]) -> [String: JSONValue])? = nil) async throws -> LanServer {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let store = book.map { $0(shop.lanBook) } ?? shop.lanBook
        var host = LanServer.Host(store: { store }, pin: pin, engine: engine)
        if let devices { host.devices = devices }
        if let now { host.now = { now } }
        host.intakeToken = "intake-token-for-tests"
        host.pricing = { store }
        host.measure = { _, _ in
            if measureDelay > 0 { Thread.sleep(forTimeInterval: measureDelay) }
            return LanServerTests.measuredCube
        }
        return LanServer(host: host)
    }

    static func get(_ path: String, from remote: String, headers: [String: String] = [:]) -> LanServer.Request {
        var h = headers
        h["host"] = h["host"] ?? "192.168.1.20:3219"
        return LanServer.Request(method: "GET", path: path, query: [:], headers: h, body: Data(), remote: remote)
    }

    // MARK: 1 — the PIN is long enough, server-side

    @Test("a PIN shorter than eight characters opens nothing, whoever saved it")
    func shortPinOpensNothing() async throws {
        let server = try await Self.server(pin: "2468")
        let reply = await server.respond(to: Self.get("/api/queue", from: "192.168.1.5",
                                                      headers: ["x-khayt-pin": "2468"]))
        #expect(reply.status == 401)
        #expect(String(decoding: reply.body, as: UTF8.self).contains("too short"))
        // The phone keys on this, not the sentence.
        #expect(String(decoding: reply.body, as: UTF8.self).contains(#""reason":"pin-too-short""#))
        let store = await server.respond(to: Self.get("/api/store", from: "192.168.1.5",
                                                      headers: ["x-khayt-pin": "2468"]))
        #expect(store.status == 401, "the short PIN still opened the whole book")
        // The customer surface is not the owner's, and stays up.
        let status = await server.respond(to: LanServer.Request(
            method: "GET", path: "/api/status", query: ["format": "json"], headers: [:], body: Data(),
            remote: "192.168.1.5"))
        #expect(status.status == 200)
    }

    @Test("the pane and the server hold the same minimum")
    func oneMinimum() {
        #expect(OnlinePane.Draft.minimumPin == LanServer.minimumPin)
        #expect(LanServer.pinTooShort("1234"))
        #expect(LanServer.pinTooShort(" 1234567 "))
        #expect(!LanServer.pinTooShort("12345678"))
        #expect(!LanServer.pinTooShort(""), "no PIN is 'not configured', a different message")
    }

    // MARK: 3 — the whole-server budget is armed on the LAN too

    /// ── IT WAS OFF ON THE LAN, AND THAT WAS UNLIMITED GUESSING ──────────
    ///
    /// Off, so a neighbour could not lock the owner out — but then each new
    /// address (and a phone mints link-local and SLAAC ones at will) was a
    /// fresh ten guesses. The owner's phones sign now and never reach the
    /// count, so the budget is armed everywhere. Oct 2026 review.
    @Test("on the LAN, fifty wrong PINs from many addresses lock the PIN, and a signed phone still gets in")
    func globalLockoutOnTheLan() async throws {
        let (devices, sign) = try LanDeviceKeysTests.enrolled()
        let server = try await Self.server(devices: devices, now: LanDeviceKeysTests.at)
        for i in 0..<50 {
            let r = await server.respond(to: Self.get("/api/queue", from: "192.168.\(i / 200).\(i % 200 + 2)",
                                                      headers: ["x-khayt-pin": "wrong-\(i)"]))
            #expect(r.status == 401)
        }
        let stranger = await server.respond(to: Self.get("/api/queue", from: "192.168.9.9",
                                                         headers: ["x-khayt-pin": "24682468"]))
        #expect(stranger.status == 429, "fifty addresses had fifty fresh budgets")
        let phone = await server.respond(to: Self.get(
            "/api/queue", from: "192.168.9.10",
            headers: sign("GET", "/api/queue", Data(), String(repeating: "a1", count: 16), 1_792_396_800)))
        #expect(phone.status == 200, "an enrolled phone was locked out by a neighbour's guesses")
    }

    @Test("each time the whole-server budget trips again, the cooldown doubles")
    func globalCooldownBacksOff() {
        var trips = 0
        var state = KhaytEngine.LanThrottle()
        let t0 = Date(timeIntervalSince1970: 1_788_000_000)
        var minutes: [Double] = []
        for round in 0..<6 {
            let now = t0.addingTimeInterval(Double(round) * 3600)
            let was = state
            var tripped = state
            tripped.blockedUntil = now.timeIntervalSince1970 * 1000 + 60_000
            state = LanServer.backedOff(tripped, was: was, trips: &trips, now: now)
            minutes.append((state.blockedUntil - now.timeIntervalSince1970 * 1000) / 60_000)
            // The next trip lands right as this cooldown ends: no quiet stretch.
            state.blockedUntil = t0.addingTimeInterval(Double(round + 1) * 3600).timeIntervalSince1970 * 1000 - 1
        }
        #expect(minutes == [1, 2, 4, 8, 16, 16])
        // A quiet stretch longer than the longest cooldown starts it again.
        let later = Date(timeIntervalSince1970: state.blockedUntil / 1000 + 17 * 60)
        var tripped = state
        tripped.blockedUntil = later.timeIntervalSince1970 * 1000 + 60_000
        let fresh = LanServer.backedOff(tripped, was: state, trips: &trips, now: later)
        #expect(fresh.blockedUntil == tripped.blockedUntil && trips == 1)
        // Not a trip: passed through untouched.
        #expect(LanServer.backedOff(state, was: state, trips: &trips, now: later) == state && trips == 1)
    }

    @Test("filling the failure map never evicts a live lockout")
    func sweepKeepsLockouts() {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let live = now.timeIntervalSince1970 * 1000 + 30_000
        var map: [String: KhaytEngine.LanFailures] = [:]
        for i in 0..<5 { map["locked-\(i)"] = .init(count: 10, resetAt: live) }
        for i in 0..<10 { map["counting-\(i)"] = .init(count: 1, resetAt: live) }
        map["expired"] = .init(count: 10, resetAt: live - 60_000)
        let out = LanServer.swept(map, now: now, cap: 8)
        #expect(out.count == 8)
        #expect((0..<5).allSatisfy { out["locked-\($0)"] != nil }, "a lockout was dropped to make room")
        #expect(out["expired"] == nil)
        // All lockouts and still over the cap: kept, not evicted.
        let tight = LanServer.swept(map, now: now, cap: 3)
        #expect(tight.count == 5 && tight.keys.allSatisfy { $0.hasPrefix("locked-") })
    }

    @Test("a wrong PIN counts against the caller's whole IPv6 /64, on the shop's network too")
    func pinKeyIsPerPrefix() async throws {
        #expect(LanServer.pinThrottleKey("fe80::1%en0") == LanServer.pinThrottleKey("fe80::2:3:4:5%en1"))
        #expect(LanServer.pinThrottleKey("2001:db8:5:6::a") == LanServer.pinThrottleKey("2001:db8:5:6:ffff::b"))
        #expect(LanServer.pinThrottleKey("2001:db8:5:6::a") != LanServer.pinThrottleKey("2001:db8:5:7::a"))
        #expect(LanServer.pinThrottleKey("::ffff:192.168.1.5") == "192.168.1.5")
        #expect(LanServer.pinThrottleKey("192.168.1.5") == "192.168.1.5")
        // Over the wire: ten guesses from ten link-local addresses are one lockout.
        let server = try await Self.server(now: Date(timeIntervalSince1970: 1_788_000_000))
        for i in 1...10 {
            _ = await server.respond(to: Self.get("/api/queue", from: "fe80::\(String(i, radix: 16))%en0",
                                                  headers: ["x-khayt-pin": "wrong-\(i)"]))
        }
        let next = await server.respond(to: Self.get("/api/queue", from: "fe80::99%en0",
                                                     headers: ["x-khayt-pin": "24682468"]))
        #expect(next.status == 429, "a rotated link-local address bought a fresh ten guesses")
    }

    // MARK: — wrong PINs sent together are each counted

    @Test("sixteen wrong PINs sent at once are sixteen, not one")
    func parallelGuessesAllCount() async throws {
        let server = try await Self.server(now: Date(timeIntervalSince1970: 1_788_000_000))
        let guesses = (0..<16).map { i in
            Task { @MainActor in
                await server.respond(to: Self.get("/api/queue", from: "192.168.1.66",
                                                  headers: ["x-khayt-pin": "guess-\(i)"])).status
            }
        }
        for guess in guesses { _ = await guess.value }
        let right = await server.respond(to: Self.get("/api/queue", from: "192.168.1.66",
                                                      headers: ["x-khayt-pin": "24682468"]))
        #expect(right.status == 429, "parallel guesses were counted as one — the lockout was bypassed")
    }

    // MARK: 4 — customer limits are per /64

    @Test("a visitor rotating through its IPv6 /64 is one visitor to the survey limit")
    func surveyLimitPerPrefix() async throws {
        let server = try await Self.server(now: Date(timeIntervalSince1970: 1_788_000_000))
        var limited = false
        for i in 1...40 {
            let r = await server.respond(to: LanServer.Request(
                method: "POST", path: "/api/survey", query: [:],
                headers: ["content-type": "application/json"], body: Data("{}".utf8),
                remote: "2001:db8:1:2::\(String(i, radix: 16))"))
            if r.status == 429 { limited = true; break }
        }
        #expect(limited, "forty surveys from one /64 were never limited")
    }

    @Test("so is it to the estimate limit")
    func estimateLimitPerPrefix() async throws {
        let server = try await Self.server(now: Date(timeIntervalSince1970: 1_788_000_000), book: LanServerTests.quotingBook)
        var statuses: [Int] = []
        for i in 1...14 {
            let r = await server.respond(to: LanServer.Request(
                method: "POST", path: "/api/intake/estimate", query: ["name": "cube.stl"],
                headers: ["x-khayt-intake-token": "intake-token-for-tests"],
                body: Data(LanServerTests.stlBytes.utf8),
                remote: "2001:db8:1:2:\(String(i, radix: 16))::1"))
            statuses.append(r.status)
        }
        #expect(statuses.prefix(12).allSatisfy { $0 == 200 }, Comment(rawValue: "\(statuses)"))
        #expect(statuses.suffix(2).allSatisfy { $0 == 429 }, Comment(rawValue: "\(statuses)"))
    }

    // MARK: 2 — three measurements at once means three

    final class Labels: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        func add(_ label: String) { lock.lock(); seen.append(label); lock.unlock() }
        var entries: [String] { lock.lock(); defer { lock.unlock() }; return seen }
    }

    /// Counts measurements in progress and holds each until released.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var entered = 0
        let release = DispatchSemaphore(value: 0)
        var inside: Int { lock.lock(); defer { lock.unlock() }; return entered }
        private var expired = 0
        /// How many measurements gave up waiting — a hang turned into a failure.
        var timedOut: Int { lock.lock(); defer { lock.unlock() }; return expired }
        /// Held until released, or for at most ten minutes: a test that
        /// never lets go must FAIL, not hold a thread for the life of the run.
        /// (Generous, because the test that releases it is a main-actor task
        /// in a suite that queues for the main actor.)
        func enter() {
            lock.lock(); entered += 1; lock.unlock()
            if release.wait(timeout: .now() + 600) == .timedOut { lock.lock(); expired += 1; lock.unlock() }
        }
    }

    @Test("a burst of uploads cannot get past the three-at-once cap")
    func measuringCapHoldsUnderABurst() async throws {
        // Deterministic, not timed: every measurement that gets in is HELD
        // until all the others have answered, so a slow runner cannot turn
        // a burst into a queue and pass the test by accident.
        let gate = Gate()
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let store = LanServerTests.quotingBook(shop.lanBook)
        var host = LanServer.Host(store: { store }, pin: "24682468", engine: engine)
        host.intakeToken = "intake-token-for-tests"
        host.pricing = { store }
        let where_ = Labels()
        host.measure = { _, _ in
            where_.add(currentQueueLabel())
            gate.enter()
            return LanServerTests.measuredCube
        }
        let server = LanServer(host: host)
        let answered = LanServerTests.Counter()
        let uploads = (0..<8).map { i in
            Task { @MainActor in
                let status = await server.respond(to: LanServer.Request(
                    method: "POST", path: "/api/intake/estimate", query: ["name": "cube.stl"],
                    headers: ["x-khayt-intake-token": "intake-token-for-tests"],
                    body: Data(LanServerTests.stlBytes.utf8), remote: "192.168.1.\(i + 10)")).status
                answered.n += 1
                return status
            }
        }
        // Wait until every upload has either been answered or is being held
        // at the gate: then all eight have passed the cap's check, and none
        // can slip in once the gate opens. No clock of our own: a deadline
        // here (it was five minutes) ran out on a busy main actor before the
        // eight had all reached the check, the gate opened, and a late one
        // took a freed slot — 4 measured, 4 turned away (Oct 15 2026). The
        // gate's own ten minutes is what stops a hang.
        while answered.n + gate.inside < 8, gate.timedOut == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let inside = gate.inside
        for _ in 0..<8 { gate.release.signal() }
        var statuses: [Int] = []
        for upload in uploads { statuses.append(await upload.value) }
        #expect(inside <= LanServer.maxMeasuring, "\(inside) measured at once")
        #expect(gate.timedOut == 0, "a held measurement was never let go")
        #expect(statuses.filter { $0 == 200 }.count == LanServer.maxMeasuring, Comment(rawValue: "\(statuses)"))
        #expect(statuses.filter { $0 == 503 }.count == 8 - LanServer.maxMeasuring, Comment(rawValue: "\(statuses)"))
        // And the slots came back: the next one is measured.
        gate.release.signal()
        let later = await server.respond(to: LanServer.Request(
            method: "POST", path: "/api/intake/estimate", query: ["name": "cube.stl"],
            headers: ["x-khayt-intake-token": "intake-token-for-tests"],
            body: Data(LanServerTests.stlBytes.utf8), remote: "192.168.1.99"))
        #expect(later.status == 200, Comment(rawValue: String(decoding: later.body, as: UTF8.self)))
        // Every measurement ran on the server's own queue — never on the
        // cooperative pool, where three held measurements hung CI for 6 h.
        #expect(!where_.entries.isEmpty)
        #expect(where_.entries.allSatisfy { $0 == "khayt.lan.measure" }, Comment(rawValue: "\(where_.entries)"))
    }

    @Test("a refused upload gives its slot back")
    func refusedUploadReleasesItsSlot() async throws {
        let server = try await Self.server(book: LanServerTests.quotingBook)
        // A file that is not what its name says is refused by the scan — after
        // the slot is taken. Four of them in a row would be "busy" if the slot
        // leaked.
        for i in 0..<(LanServer.maxMeasuring + 1) {
            let r = await server.respond(to: LanServer.Request(
                method: "POST", path: "/api/intake/estimate", query: ["name": "cube.3mf"],
                headers: ["x-khayt-intake-token": "intake-token-for-tests"],
                body: Data(String(repeating: "x", count: 200).utf8), remote: "192.168.1.\(i + 10)"))
            #expect(r.status == 400, Comment(rawValue: String(decoding: r.body, as: UTF8.self)))
        }
        let ok = await server.respond(to: LanServer.Request(
            method: "POST", path: "/api/intake/estimate", query: ["name": "cube.stl"],
            headers: ["x-khayt-intake-token": "intake-token-for-tests"],
            body: Data(LanServerTests.stlBytes.utf8), remote: "192.168.1.50"))
        #expect(ok.status == 200)
    }

    // MARK: 6 — the upload cap is reachable

    @Test("only the estimate route reads a body over a megabyte")
    func largeBodyRoutes() {
        #expect(LanServer.takesLargeBody(method: "POST", target: "/api/intake/estimate?name=a.stl&qty=2"))
        #expect(LanServer.takesLargeBody(method: "post", target: "/v1/intake/estimate/"))
        #expect(!LanServer.takesLargeBody(method: "GET", target: "/api/intake/estimate"))
        #expect(!LanServer.takesLargeBody(method: "POST", target: "/api/intake"))
        #expect(!LanServer.takesLargeBody(method: "POST", target: "/api/store/deltas"))
        #expect(!LanServer.takesLargeBody(method: "POST", target: "/api/intake/estimate/x"))
    }

    /// Send a request head that PROMISES `length` bytes of body and none of
    /// them, and read the status line. A refusal for size has to come back
    /// before a byte of body is read; sending the body would only race the
    /// server's close (EPIPE). Blocking, so it is run detached — the server
    /// shares the main actor with this test.
    nonisolated static func headOnly(port: UInt16, path: String, length: Int) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return "no socket" }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard ok == 0 else { return "no connect" }
        let head = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(length)\r\n\r\n"
        let data = Data(head.utf8)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        // A guard against a hang, not a deadline on the answer: the refusal
        // is written after a visit to the main actor, and in a full run the
        // main actor's queue alone has outlasted a minute (Oct 15 2026: "no
        // answer" at 60 s while the server was fine).
        var tv = timeval(tv_sec: 900, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 512)
        let n = read(fd, &buf, 512)
        guard n > 0 else { return "no answer" }
        return String(decoding: buf[0..<n], as: UTF8.self)
    }

    @Test("a two-megabyte model is priced over the wire")
    func largeUploadOverTheWire() async throws {
        let bench = try await LanServerTests.Bench()
        defer { bench.stop() }
        bench.book.value = LanServerTests.quotingBook(bench.book.value)
        let (_, cookie) = try await bench.openForm()
        let big = LanServerTests.stlBytes + String(repeating: "s", count: 2 << 20)
        let priced = try await bench.post("/api/intake/estimate?name=cube.stl", json: big,
                                          headers: ["Cookie": cookie])
        #expect(priced.status == 200, Comment(rawValue: priced.text))
    }

    @Test("over a megabyte anywhere else, or over 32 MB to the upload, is refused before the body")
    func largeBodiesRefusedElsewhere() async throws {
        let bench = try await LanServerTests.Bench()
        defer { bench.stop() }
        let port = bench.port
        let elsewhere = await offPool { Self.headOnly(port: port, path: "/api/intake", length: 2 << 20) }
        #expect(elsewhere.hasPrefix("HTTP/1.1 413"), Comment(rawValue: elsewhere))
        let deltas = await offPool {
            Self.headOnly(port: port, path: "/api/store/deltas", length: 2 << 20)
        }
        #expect(deltas.hasPrefix("HTTP/1.1 413"), Comment(rawValue: deltas))
        let huge = await offPool {
            Self.headOnly(port: port, path: "/api/intake/estimate?name=a.stl", length: LanServer.maxUpload + 1)
        }
        #expect(huge.hasPrefix("HTTP/1.1 413"), Comment(rawValue: huge))
        #expect(huge.contains("too-large"), Comment(rawValue: huge))
    }
}
