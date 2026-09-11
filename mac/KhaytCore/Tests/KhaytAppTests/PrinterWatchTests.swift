import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Asking the shop's printers what they are doing.
///
/// The reading itself is `lib/moonraker.js`'s and is pinned in
/// `test/moonraker.test.js` against the literal bytes of the Snapmaker U1 on
/// this bench. What is tested here is what this app puts around it: which
/// machines it is willing to ask, which addresses it is willing to connect to,
/// and what it says when a machine does not answer.
@MainActor
struct PrinterWatchTests {

    static func machine(_ type: String?, host: String = "192.168.68.56", port: Int? = 7125) -> Machine {
        var api: [String: JSONValue] = ["host": .string(host)]
        if let type { api["type"] = .string(type) }
        if let port { api["port"] = .number(Double(port)) }
        let row: JSONValue = .object([
            "id": .string("M-1"), "name": .string("Bench"),
            "printerApi": .object(api),
        ])
        return try! JSONDecoder().decode(Machine.self, from: JSONEncoder().encode(row))
    }

    // MARK: - Which machines it will ask

    @Test("a machine with no connection set up is not polled, and is not an error")
    func noConnection() {
        #expect(PrinterWatch.notWatched(Self.machine(nil)) == .noConnection)
        #expect(PrinterWatch.notWatched(Self.machine("")) == .noConnection)
        #expect(PrinterWatch.notWatched(Self.machine("none")) == .noConnection)
    }

    @Test("a protocol this app does not speak is SAID, not silently skipped")
    func otherProtocol() {
        // Khayt speaks seven; there is one printer on this bench and it is
        // Klipper, so it is the one that could be verified against a machine
        // rather than a document. A card that silently shows nothing looks
        // broken, and a shop would go back to the other app not knowing why.
        // Bambu is MQTT over TLS and Elegoo is a WebSocket — neither is HTTP,
        // so neither is a longer version of this poller.
        //
        // Repetier and then Duet have both left this list. Duet's absence was
        // real — it needs `rr_connect` before any read — and was worth the
        // conversation rather than the exclusion. Repetier's was a mistake: a
        // note grouped it with Duet as "both need a handshake" and it needs an
        // `x-api-key` header and nothing else.
        #expect(PrinterWatch.notWatched(Self.machine("bambu")) == .otherProtocol("bambu"))
        for spoken in PrinterWatch.spoken {
            #expect(PrinterWatch.notWatched(Self.machine(spoken)) == nil, "\(spoken) is not asked")
        }
    }

    // MARK: - Which addresses it will connect to

    @Test("only an address on this network")
    func lanOnly() async throws {
        let engine = try KhaytEngine()
        let ok = try await PrinterWatch.baseURL(Self.machine("moonraker"), engine: engine)
        #expect(ok.absoluteString == "http://192.168.68.56:7125")

        for public_ in ["8.8.8.8", "203.0.113.5"] {
            await #expect(throws: PrinterWatch.Refusal.self) {
                try await PrinterWatch.baseURL(Self.machine("moonraker", host: public_), engine: engine)
            }
        }
    }

    @Test("loopback, however it is spelled")
    func loopbackSpellings() async throws {
        // `connect()` goes through inet_aton, which takes a bare 32-bit integer,
        // hex, octal and short forms. All four of these reach 127.0.0.1 and none
        // of them looks like a dotted quad — which is why the guard is
        // `lib/printer-host.js`'s and not a regex written here.
        let engine = try KhaytEngine()
        for spelling in ["127.0.0.1", "2130706433", "0x7f000001", "127.1", "0177.0.0.1", "localhost"] {
            await #expect(throws: PrinterWatch.Refusal.self, "\(spelling) was allowed") {
                try await PrinterWatch.baseURL(Self.machine("moonraker", host: spelling), engine: engine)
            }
        }
    }

    @Test("the cloud metadata endpoint is not a printer")
    func metadata() async throws {
        let engine = try KhaytEngine()
        await #expect(throws: PrinterWatch.Refusal.self) {
            try await PrinterWatch.baseURL(Self.machine("moonraker", host: "169.254.169.254"), engine: engine)
        }
        // …but an ordinary link-local address is a printer plugged straight in.
        let direct = try await PrinterWatch.baseURL(
            Self.machine("moonraker", host: "169.254.10.20"), engine: engine)
        #expect(direct.absoluteString == "http://169.254.10.20:7125")
    }

    @Test("a host cannot smuggle a second address into the URL")
    func noUrlInjection() async throws {
        // `192.168.1.5@evil.example` is, as a URL authority, a request to
        // evil.example with `192.168.1.5` as userinfo. The characters that make
        // that possible come out first, so the name connected to is the one
        // that was checked — a single nonsense hostname that resolves to
        // nothing, rather than an attacker's domain wearing a LAN address.
        let engine = try KhaytEngine()
        for smuggled in ["192.168.1.5@evil.example", "192.168.1.5/../evil", "192.168.1.5:9/x"] {
            let url = try await PrinterWatch.baseURL(
                Self.machine("moonraker", host: smuggled), engine: engine)
            let authority = url.absoluteString.replacingOccurrences(of: "http://", with: "")
            #expect(!authority.contains("@"), "\(smuggled) kept its userinfo")
            #expect(!authority.contains("/"), "\(smuggled) kept a path")
            #expect(url.port == 7125, "\(smuggled) moved the port")
            #expect(url.host == authority.replacingOccurrences(of: ":7125", with: ""))
        }
    }

    @Test("a port that is not a port")
    func badPort() async throws {
        let engine = try KhaytEngine()
        for port in [0, -1, 70000] {
            await #expect(throws: PrinterWatch.Refusal.self) {
                try await PrinterWatch.baseURL(Self.machine("moonraker", port: port), engine: engine)
            }
        }
        // Absent means Moonraker's own default rather than a refusal.
        let d = try await PrinterWatch.baseURL(Self.machine("moonraker", port: nil), engine: engine)
        #expect(d.absoluteString.hasSuffix(":7125"))
    }

    // MARK: - What it says

    @Test("a failure is a sentence, not a socket's vocabulary")
    func failuresAreSentences() {
        // `explainPrinterHttp` exists in the Electron app for this exact reason:
        // the two most ordinary states a printer server reports reached the
        // owner as "HTTP 409" and "HTTP 403".
        let timedOut = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        #expect(PrinterWatch.say(timedOut).contains("asleep"))
        let refused = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        #expect(PrinterWatch.say(refused).contains("on this network"))
        #expect(PrinterWatch.say(PrinterWatch.Refusal.redirected).contains("somewhere else"))
        #expect(PrinterWatch.say(PrinterWatch.Refusal.notALanAddress("8.8.8.8")).contains("8.8.8.8"))
    }

    // MARK: - What the dashboard reads

    @Test("the fleet tile counts a machine that answered as live")
    func fleetCountsLive() async throws {
        // `dashboard-facts` reads this cache, and without it every machine is
        // neither live nor offline — the tile said 0/1 with the machine beside
        // it demonstrably printing.
        let engine = try KhaytEngine()
        let machines: [JSONValue] = [.object(["id": .string("M-1"), "name": .string("Bench")])]
        let cache: [String: JSONValue] = ["M-1": .object(["state": .string("printing")])]

        let blind = try await engine.dashboardFacts(orders: [], machines: machines, settings: [:])
        #expect(blind.fleet.live == 0, "a fleet counted without a cache is not counted at all")

        let seeing = try await engine.dashboardFacts(orders: [], machines: machines,
                                                     settings: [:], statusCache: cache)
        #expect(seeing.fleet.live == 1)
        #expect(seeing.fleet.total == 1)
    }

    @Test("a machine that did not answer is offline, not absent")
    func fleetCountsOffline() async throws {
        // Absent means "not counted"; the shop's question is "is my printer
        // reachable", and silence is an answer to it.
        let watch = PrinterWatch()
        watch.setReadingForTesting("M-1", .init(status: nil, problem: "did not answer", at: Date()))
        let cache = watch.statusCache
        guard case .object(let row)? = cache["M-1"] else { Issue.record("no row"); return }
        #expect(row["state"] == .string("offline"))

        let engine = try KhaytEngine()
        let facts = try await engine.dashboardFacts(
            orders: [], machines: [.object(["id": .string("M-1")])], settings: [:], statusCache: cache)
        #expect(facts.fleet.live == 0)
        #expect(facts.fleet.offline == 1)
    }

    @Test("a machine that has not been asked yet is absent from the cache")
    func silentUntilAsked() {
        // Neither live nor offline: nothing is known about it, and guessing
        // either way puts a wrong figure on the screen a shop opens on.
        let watch = PrinterWatch()
        #expect(watch.statusCache.isEmpty)
    }

    @Test("time left is rounded to something worth reading")
    func spellsTheEta() {
        // Extrapolated from progress, so it does not deserve seconds.
        #expect(PrinterWatch.spell(18_420) == "5h 7m")
        #expect(PrinterWatch.spell(840) == "14m")
        #expect(PrinterWatch.spell(20) == "<1m")
    }
}
