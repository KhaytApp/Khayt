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
