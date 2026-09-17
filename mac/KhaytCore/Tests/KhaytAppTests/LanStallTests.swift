import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A client that connects and then says nothing does not get to hold the door.
///
/// ── WHAT A HAND-ROLLED LISTENER DOES NOT GET ──────────────────────────────
///
/// Node's http server applies `headersTimeout` and `requestTimeout` by itself,
/// so the other app has always been covered by machinery nobody had to ask for.
/// `NWListener` gives nothing. A client that opened a connection and sent
/// nothing — or sent `Content-Length: 1000` and then no body — was waited on
/// for ever: no answer, no close, the connection and its task held until the
/// app quit. This server binds to the shop's Wi-Fi, so anybody on it could hold
/// as many as they liked.
///
/// ── THE MEASUREMENT WAS WRONG BEFORE THE FIX WAS ──────────────────────────
///
/// The first version of this probe called a blocking `read(2)` straight from
/// the test body. The test and the server share the MainActor, so it was the
/// TEST that stopped the server answering, and it would have "proved" the bug
/// whether or not it existed — and then "proved" the fix did not work when it
/// did. Anything that blocks goes through `Task.detached` here for that reason.
@MainActor
struct LanStallTests {

    /// Open a socket, optionally send some bytes, and report what the server
    /// does within `waitFor` seconds. Blocking, so callers run it detached.
    nonisolated static func stall(port: UInt16, send: String?, waitFor: TimeInterval) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return "could not open a socket" }
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
        guard ok == 0 else { return "could not connect" }
        if let send, let data = send.data(using: .utf8) {
            _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        }
        var tv = timeval(tv_sec: Int(waitFor), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 256)
        let n = read(fd, &buf, 256)
        if n > 0 { return "answered" }
        if n == 0 { return "closed" }
        return "held open"
    }

    /// ── WHY THE TIMEOUT IS SET PER BENCH AND NOT ONCE ─────────────────────
    ///
    /// This used to lower `LanServer.readTimeout`, a static, and put it back in
    /// a `defer`. Swift Testing runs these three tests in PARALLEL, so one
    /// test's restore landed while another was still waiting: that connection
    /// got the full fifteen seconds, outlived its eight-second probe, and
    /// reported "held open". A green local run and a red CI run, with nothing
    /// wrong in the server — which is what a shared mutable static looks like
    /// when it finally bites.
    ///
    /// Each bench now carries its own.
    private static let short: TimeInterval = 1

    @Test("a connection that sends nothing is let go, not held for ever")
    func silentConnection() async throws {
        let bench = try await LanServerTests.Bench(readTimeout: Self.short)
        let port = bench.port
        let verdict = await Task.detached { Self.stall(port: port, send: nil, waitFor: 8) }.value
        #expect(verdict == "closed",
                Comment(rawValue: "a silent client was \(verdict) — it holds a connection and a task"))
    }

    @Test("a client that promises a body and never sends it is let go too")
    func stalledBody() async throws {
        let bench = try await LanServerTests.Bench(readTimeout: Self.short)
        let port = bench.port
        let head = "POST /api/intake HTTP/1.1\r\nHost: x\r\nContent-Length: 1000\r\n\r\n"
        let verdict = await Task.detached { Self.stall(port: port, send: head, waitFor: 8) }.value
        #expect(verdict == "closed", Comment(rawValue: "a stalled body was \(verdict)"))
    }

    @Test("a head that never reaches its blank line is let go too")
    func partialHead() async throws {
        let bench = try await LanServerTests.Bench(readTimeout: Self.short)
        let port = bench.port
        let head = "GET /api/status HTTP/1.1\r\nHost: x\r\n"
        let verdict = await Task.detached { Self.stall(port: port, send: head, waitFor: 8) }.value
        #expect(verdict == "closed", Comment(rawValue: "a partial head was \(verdict)"))
    }

    @Test("a complete request is still answered, and the clock does not cut it off")
    func completeRequestSurvives() async throws {
        // The guard against fixing the stall by breaking the server: the
        // watchdog is cancelled the moment the request is fully read, so a slow
        // READER is never killed halfway through the answer it asked for.
        let bench = try await LanServerTests.Bench(readTimeout: Self.short)
        let reply = try await bench.get("/api/status?format=json")
        #expect(reply.status == 200)
        // And again after more than the read timeout has passed on an idle
        // server, which must not have closed anything it should not have.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(try await bench.get("/api/status?format=json").status == 200)
    }
}
