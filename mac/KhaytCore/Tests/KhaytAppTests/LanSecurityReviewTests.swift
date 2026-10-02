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
@MainActor
struct LanSecurityReviewTests {

    /// A server that is never started: requests go straight to `respond`.
    static func server(pin: String = "24682468", exposed: Bool = false,
                       measureDelay: TimeInterval = 0,
                       book: (([String: JSONValue]) -> [String: JSONValue])? = nil) async throws -> LanServer {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let store = book.map { $0(shop.lanBook) } ?? shop.lanBook
        var host = LanServer.Host(store: { store }, pin: pin, engine: engine)
        host.exposedBeyondLan = exposed
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

    // MARK: 3 — the global throttle is not armed on the LAN

    @Test("on the LAN, wrong PINs from many addresses do not lock the owner out")
    func noGlobalLockoutOnTheLan() async throws {
        let server = try await Self.server()
        for i in 0..<60 {
            let r = await server.respond(to: Self.get("/api/queue", from: "192.168.\(i / 200).\(i % 200 + 2)",
                                                      headers: ["x-khayt-pin": "wrong-\(i)"]))
            #expect(r.status == 401)
        }
        let owner = await server.respond(to: Self.get("/api/queue", from: "192.168.9.9",
                                                      headers: ["x-khayt-pin": "24682468"]))
        #expect(owner.status == 200, "a neighbour on the Wi-Fi locked the owner's phone out")
    }

    @Test("exposed beyond the LAN, the whole-server budget is still armed")
    func globalLockoutWhenExposed() async throws {
        let server = try await Self.server(exposed: true)
        for i in 0..<50 {
            _ = await server.respond(to: Self.get("/api/queue", from: "10.0.\(i).1",
                                                  headers: ["x-khayt-pin": "wrong-\(i)"]))
        }
        let after = await server.respond(to: Self.get("/api/queue", from: "10.9.9.9",
                                                      headers: ["x-khayt-pin": "24682468"]))
        #expect(after.status == 429)
    }

    // MARK: — wrong PINs sent together are each counted

    @Test("sixteen wrong PINs sent at once are sixteen, not one")
    func parallelGuessesAllCount() async throws {
        let server = try await Self.server()
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
        let server = try await Self.server()
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
        let server = try await Self.server(book: LanServerTests.quotingBook)
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

    /// Counts measurements in progress and holds each until released.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var entered = 0
        let release = DispatchSemaphore(value: 0)
        var inside: Int { lock.lock(); defer { lock.unlock() }; return entered }
        func enter() { lock.lock(); entered += 1; lock.unlock(); release.wait() }
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
        host.measure = { _, _ in gate.enter(); return LanServerTests.measuredCube }
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
        // Wait (generously) for the five that should be turned away.
        let deadline = Date().addingTimeInterval(120)
        while answered.n < 8 - LanServer.maxMeasuring, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let inside = gate.inside
        for _ in 0..<8 { gate.release.signal() }
        var statuses: [Int] = []
        for upload in uploads { statuses.append(await upload.value) }
        #expect(inside <= LanServer.maxMeasuring, "\(inside) measured at once")
        #expect(statuses.filter { $0 == 200 }.count == LanServer.maxMeasuring, Comment(rawValue: "\(statuses)"))
        #expect(statuses.filter { $0 == 503 }.count == 8 - LanServer.maxMeasuring, Comment(rawValue: "\(statuses)"))
        // And the slots came back: the next one is measured.
        gate.release.signal()
        let later = await server.respond(to: LanServer.Request(
            method: "POST", path: "/api/intake/estimate", query: ["name": "cube.stl"],
            headers: ["x-khayt-intake-token": "intake-token-for-tests"],
            body: Data(LanServerTests.stlBytes.utf8), remote: "192.168.1.99"))
        #expect(later.status == 200, Comment(rawValue: String(decoding: later.body, as: UTF8.self)))
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
        var tv = timeval(tv_sec: 60, tv_usec: 0)
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
        let elsewhere = await Task.detached { Self.headOnly(port: port, path: "/api/intake", length: 2 << 20) }.value
        #expect(elsewhere.hasPrefix("HTTP/1.1 413"), Comment(rawValue: elsewhere))
        let deltas = await Task.detached {
            Self.headOnly(port: port, path: "/api/store/deltas", length: 2 << 20)
        }.value
        #expect(deltas.hasPrefix("HTTP/1.1 413"), Comment(rawValue: deltas))
        let huge = await Task.detached {
            Self.headOnly(port: port, path: "/api/intake/estimate?name=a.stl", length: LanServer.maxUpload + 1)
        }.value
        #expect(huge.hasPrefix("HTTP/1.1 413"), Comment(rawValue: huge))
        #expect(huge.contains("too-large"), Comment(rawValue: huge))
    }
}
