import Foundation
import Testing
@testable import KhaytApp
import KhaytCore

/// Finding a printer on the workshop network.
///
/// The wire codec is `lib/mdns.js`, shared rather than rewritten in Swift: two
/// implementations of DNS name compression is two chances to get a packet from
/// an unauthenticated device on the LAN wrong. It used to be built on Node's
/// `Buffer`, which JavaScriptCore does not have — these prove it now runs here.
@MainActor
struct PrinterFinderTests {

    @Test("the query is built here, and is a well-formed PTR question")
    func query() async throws {
        let engine = try KhaytEngine()
        let q = try await engine.mdnsQuery()
        #expect(q.count > 12, "no query came back")
        // QDCOUNT: one question per service Khayt asks about.
        let qdcount = Int(q[4]) << 8 | Int(q[5])
        #expect(qdcount == 5, "asked about \(qdcount) services")
        // No answers in a question.
        #expect(Int(q[6]) << 8 | Int(q[7]) == 0)
        // The last question's QCLASS is IN, and the QU bit is not set unless asked.
        #expect(Int(q[q.count - 2]) << 8 | Int(q[q.count - 1]) == 1)

        let unicast = try await engine.mdnsQuery(unicast: true)
        #expect(Int(unicast[unicast.count - 2]) << 8 | Int(unicast[unicast.count - 1]) == 0x8001,
                "the QU bit was not set")
    }

    /// A real answer, byte for byte, so the decode is proven rather than assumed.
    /// A device's address, port and TXT record arrive in DIFFERENT datagrams —
    /// which is why every packet is handed over at once.
    @Test("a printer is assembled out of the packets that describe it")
    func assemble() async throws {
        let engine = try KhaytEngine()
        // One PTR/SRV/TXT/A set for a Moonraker printer called "lava".
        var packet: [UInt8] = [0, 0, 0x84, 0, 0, 0, 0, 4, 0, 0, 0, 0]
        func name(_ parts: [String]) -> [UInt8] {
            var out: [UInt8] = []
            for p in parts { out.append(UInt8(p.utf8.count)); out += Array(p.utf8) }
            out.append(0)
            return out
        }
        let service = name(["_moonraker", "_tcp", "local"])
        let instance = name(["lava", "_moonraker", "_tcp", "local"])
        let target = name(["lava", "local"])
        // PTR: the service points at the instance.
        packet += service + [0, 12, 0, 1, 0, 0, 0, 120]
        packet += [UInt8(instance.count >> 8), UInt8(instance.count & 255)] + instance
        // SRV: the instance's port and target host.
        let srv: [UInt8] = [0, 0, 0, 0, 0x1b, 0xcd] + target      // prio, weight, port 7117
        packet += instance + [0, 33, 0, 1, 0, 0, 0, 120]
        packet += [UInt8(srv.count >> 8), UInt8(srv.count & 255)] + srv
        // TXT.
        let txtEntry = "version=1.5.2"
        let txt: [UInt8] = [UInt8(txtEntry.utf8.count)] + Array(txtEntry.utf8)
        packet += instance + [0, 16, 0, 1, 0, 0, 0, 120]
        packet += [UInt8(txt.count >> 8), UInt8(txt.count & 255)] + txt
        // A: the target's address.
        packet += target + [0, 1, 0, 1, 0, 0, 0, 120, 0, 4, 192, 168, 1, 52]

        let found = try await engine.printersFound(in: [packet])
        #expect(found.count == 1, "assembled \(found.count) printers from one device")
        let printer = try #require(found.first)
        #expect(printer.host == "192.168.1.52", "host was \(printer.host)")
        #expect(printer.port == 7117, "port was \(String(describing: printer.port))")
        #expect(printer.connection == "moonraker")
    }

    /// These arrive unauthenticated from the local network, so anything that
    /// throws here is a denial of service any device on the wifi can trigger.
    @Test("malformed and hostile packets yield nothing, never a throw")
    func hostile() async throws {
        let engine = try KhaytEngine()
        let bad: [[UInt8]] = [
            [],
            [0, 0, 0, 0, 0],
            Array("not a dns packet".utf8),
            // A name pointer that jumps to itself — the classic decompression bomb.
            [0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0xc0, 0x0c],
            // rdata longer than the packet.
            [0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0xff, 0xff],
        ]
        for packet in bad {
            let found = try await engine.printersFound(in: [packet])
            #expect(found.isEmpty, "a malformed packet produced \(found.count) printers")
        }
        #expect(try await engine.printersFound(in: []).isEmpty)
    }
}

extension PrinterFinderTests {

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// A service type the app has not DECLARED is one the system will not
    /// browse — and it fails by finding nothing, which looks exactly like a
    /// network with no printers on it.
    ///
    /// So the list in `Info.plist` has to match `lib/printer-discovery.js`'s.
    /// Adding a protocol to the shared list and not to the bundle would ship a
    /// printer Khayt can talk to and will never see.
    @Test("every service the rule asks about is declared in the bundle")
    func bonjourServicesDeclared() async throws {
        let engine = try KhaytEngine()
        let services = try await engine.discoveryServices()
        #expect(!services.isEmpty)

        let script = try String(contentsOf: Self.repoRoot.appending(path: "mac/make-app.sh"),
                                encoding: .utf8)
        for service in services {
            // `_moonraker._tcp.local` in the rule; `_moonraker._tcp` in the plist.
            let declared = service.replacingOccurrences(of: ".local", with: "")
            #expect(script.contains("<string>\(declared)</string>"),
                    "\(declared) is browsed for but not declared in NSBonjourServices")
        }
        #expect(script.contains("NSLocalNetworkUsageDescription"),
                "no usage description — macOS shows its own generic prompt")
        #expect(script.contains("com.apple.security.network.client"),
                "the app is not entitled to reach the local network")
    }

    /// The Electron app puts its own query on the wire. This one asks
    /// `mDNSResponder`, because local network privacy on macOS fails closed on
    /// an IPC bug that is only fixed in 26.5 — and this app runs on 26.0.
    @Test("the Mac app does not open a multicast socket of its own")
    func noRawMulticast() throws {
        let finder = try String(contentsOf: Self.repoRoot.appending(
            path: "mac/KhaytCore/Sources/KhaytApp/PrinterFinder.swift"), encoding: .utf8)
        #expect(finder.contains("NWBrowser"), "discovery no longer goes through Bonjour")
        for raw in ["224.0.0.251", "5353", "joinMulticast", "NWMulticastGroup"] {
            #expect(!finder.contains(raw), "\(raw): a raw multicast socket is back")
        }
    }
}
