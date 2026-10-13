import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A request the client has finished sending is not cut off because the
/// SERVER was slow to read it.
///
/// ── THE FLAKE THIS HOLDS ─────────────────────────────────────────────────
///
/// `Alpha63ReviewTests` "the owner PIN quotes a model over a megabyte" failed
/// on CI now and then with `NSURLErrorDomain -1005` ("the network connection
/// was lost"), on PRs that touched nothing near the LAN server. It did not
/// hang: every `@MainActor` test in that run, passing ones included, finished
/// about 1,270 seconds in, because they all share one main actor.
///
/// The server read its request ON the main actor: one hop back to it for
/// every `NWConnection.receive`, which is seventeen or more for a megabyte
/// at 64 KB a read. Its read deadline was a wall clock on the same actor.
/// With the main actor queued deep (a full test run; on a shop's Mac, a busy
/// window), the hops alone outlasted fifteen seconds, the deadline cancelled
/// a connection whose client had long since sent everything, and the client
/// saw the reset. The clock was charging the CLIENT for the SERVER's wait.
///
/// The read now runs on the connection's own queue, so the body costs the
/// main actor nothing, and each phase's deadline runs there too, measuring
/// only the time spent waiting for the client's bytes.
@MainActor
struct LanBusyMainActorTests {

    /// Keep the main actor busy for `seconds`: slices of synchronous work,
    /// each followed by a turn at the back of the queue, like a full run's
    /// thousands of tests each taking their turn.
    static func hogMainActor(for seconds: TimeInterval, slice: TimeInterval = 0.25) async {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            usleep(useconds_t(slice * 1_000_000))   // synchronous, on purpose
            await Task.yield()
        }
    }

    @Test("a megabyte upload is read in full while the main actor is busy")
    func largeBodyWhileBusy() async throws {
        // One second to read: before the fix, seventeen quarter-second waits
        // for the main actor were four seconds, and the upload was reset.
        let bench = try await LanServerTests.Bench(readTimeout: 1)
        defer { bench.stop() }
        bench.book.value = LanServerTests.quotingBook(bench.book.value)
        let big = String(repeating: "s", count: (1 << 20) + 4096)
        async let owner = bench.post("/api/intake/estimate?name=cube.stl", json: big,
                                     headers: ["x-khayt-pin": "24682468"])
        await Self.hogMainActor(for: 6)
        let reply = try await owner
        #expect(reply.status == 200, Comment(rawValue: reply.text))
    }

    @Test("a client that stops halfway through its body is still let go")
    func stalledLargeBodyIsLetGo() async throws {
        // The other half of the bargain: moving the clock off the main actor
        // must not take the slow-client defence with it.
        let bench = try await LanServerTests.Bench(readTimeout: 1)
        defer { bench.stop() }
        bench.book.value = LanServerTests.quotingBook(bench.book.value)
        let port = bench.port
        let head = "POST /api/intake/estimate?name=a.stl HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            + "X-Khayt-Pin: 24682468\r\nContent-Length: \(2 << 20)\r\n\r\n"
            + String(repeating: "s", count: 4096)
        let verdict = await offPool {
            LanStallTests.stall(port: port, send: head, waitFor: LanStallTests.patience)
        }
        #expect(verdict == "closed", Comment(rawValue: "a stalled large body was \(verdict)"))
    }
}
