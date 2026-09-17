import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Finding a printer that announces nothing.
///
/// `lib/printer-sweep.js` was written for the Snapmaker U1 — which advertises
/// neither `_moonraker._tcp` nor `_octoprint._tcp`, so mDNS finds it never —
/// and then wired NOWHERE: not here, not in the other app, not in another
/// module. These cover the seam this app now gives it.
///
/// The network half is not tested here and cannot honestly be: what is checked
/// is what gets ASKED, what counts as an answer, and the guard in front of both.
@MainActor
struct PrinterSweepTests {

    @Test("the protocols asked are the ones the rule knows, on their own ports")
    func probesComeFromTheRule() async throws {
        let engine = try KhaytEngine()
        let probes = try await engine.sweepProbes()
        #expect(!probes.isEmpty)
        let moonraker = try #require(probes.first { $0.type == "moonraker" })
        #expect(moonraker.port == 7125)
        // Unauthenticated on purpose: identification has to work before
        // credentials are known, or a moved printer with a password stays lost.
        #expect(moonraker.path == "/printer/info")
        for probe in probes {
            #expect(probe.port > 0 && probe.port < 65_536)
            #expect(probe.path.hasPrefix("/"))
        }
    }

    @Test("the addresses tried are the machine's own /24, nearest first")
    func candidatesStayInTheSubnet() async throws {
        let engine = try KhaytEngine()
        let hosts = try await engine.sweepCandidates(lastKnownHost: "192.168.68.77", limit: 254)
        #expect(!hosts.isEmpty)
        // ONLY the subnet it was already on. Wandering further is a network
        // scan rather than looking for one's own printer.
        #expect(hosts.allSatisfy { $0.hasPrefix("192.168.68.") },
                "the sweep left the machine's own subnet")
        #expect(!hosts.contains("192.168.68.77"), "the address that already failed is asked again")
        // Nearest first: a re-lease is usually next door, and finding it in the
        // first few probes rather than the last is the whole difference.
        #expect(hosts.prefix(4).contains("192.168.68.76"))
        #expect(hosts.prefix(4).contains("192.168.68.78"))
        #expect(hosts.count <= 253)
    }

    @Test("a limit is honoured, so a sweep can be made smaller but never wider")
    func limitHolds() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.sweepCandidates(lastKnownHost: "10.0.0.5", limit: 12).count == 12)
        #expect(try await engine.sweepCandidates(lastKnownHost: "10.0.0.5", limit: 0).isEmpty)
    }

    @Test("something that is not an address is swept nowhere")
    func rubbishSeedSweepsNothing() async throws {
        let engine = try KhaytEngine()
        for seed in ["", "not-an-address", "printer.local", "999.1.1.1"] {
            #expect(try await engine.sweepCandidates(lastKnownHost: seed, limit: 254).isEmpty,
                    Comment(rawValue: "\(seed) produced candidates"))
        }
    }

    @Test("a real Moonraker answer becomes a discovery record; anything else does not")
    func identification() async throws {
        let engine = try KhaytEngine()
        // Verified against a Snapmaker U1 running Moonraker 1.5.2.
        let real = JSONValue.object(["result": .object([
            "state": .string("ready"),
            "hostname": .string("lava"),
            "software_version": .string("1.5.2.13"),
        ])])
        let record = try #require(try await engine.identifySweep(
            type: "moonraker", host: "192.168.68.56", status: 200, body: real))
        guard case .object(let r) = record else { Issue.record("not an object"); return }
        #expect(r["host"] == .string("192.168.68.56"))
        #expect(r["port"] == .number(7125))
        #expect(r["name"] == .string("lava"))
        #expect(r["firmware"] == .string("1.5.2.13"))
        // The shape matches `lib/printer-discovery.js` so `planRelocations`
        // cannot tell a swept printer from an announced one.
        #expect(r["connection"] == .string("moonraker"))

        // A web server that is not a printer, a 404, and a body of the wrong
        // shape all answer nothing rather than a maybe.
        #expect(try await engine.identifySweep(type: "moonraker", host: "192.168.68.10",
                                               status: 200, body: .object(["hello": .string("world")])) == nil)
        #expect(try await engine.identifySweep(type: "moonraker", host: "192.168.68.10",
                                               status: 404, body: real) == nil)
        #expect(try await engine.identifySweep(type: "nonsense", host: "192.168.68.10",
                                               status: 200, body: real) == nil)
    }

    @Test("every protocol this shop's machines use can be swept for")
    func bothProtocolsAreSweepable() async throws {
        // A sweep that knew only Moonraker would find a U1 and never a
        // PrusaLink machine beside it, and the shop would be told one printer
        // had moved and the other had vanished.
        let engine = try KhaytEngine()
        let types = Set(try await engine.sweepProbes().map(\.type))
        for used in ["moonraker", "prusalink", "octoprint", "duet"] {
            #expect(types.contains(used), Comment(rawValue: "\(used) cannot be swept for"))
        }
    }

    @Test("a swept printer relocates a machine exactly as an announced one would")
    func sweptEvidenceIsEvidence() async throws {
        // The point of matching the discovery shape. A machine configured at
        // .77, the printer answering at .56, and the plan should offer the move.
        let engine = try KhaytEngine()
        let swept = try #require(try await engine.identifySweep(
            type: "moonraker", host: "192.168.68.56", status: 200,
            body: .object(["result": .object([
                "state": .string("ready"), "hostname": .string("lava"),
                "software_version": .string("1.5.2.13"),
            ])])))
        let machines: [JSONValue] = [.object([
            "id": .string("M1"), "name": .string("Snapmaker U1"),
            // `type`, which is what a real machine record carries and what
            // `isControllable` reads — a fixture saying `protocol` is simply
            // not a controllable machine, and the plan skips it in silence.
            "printerApi": .object(["type": .string("moonraker"),
                                   "host": .string("192.168.68.77"),
                                   "port": .number(7125)]),
        ])]
        let moves = try await engine.planRelocations(
            machines: machines, discovered: [swept],
            statusCache: ["M1": .object(["error": .string("timed out"),
                                         "consecutiveFailures": .number(5)])])
        #expect(moves.count == 1, "a printer found by asking was not offered as a move")
        #expect(moves.first?.to.contains("192.168.68.56") == true,
                Comment(rawValue: "got \(moves.first?.to ?? "nothing")"))
    }

    @Test("only the machines that are actually quiet are swept for")
    func onlyTheQuietOnes() async throws {
        let shop = Shop()
        await shop.load(.sample)
        // Nothing in the sample has failed three times, so nothing is swept
        // for — a sweep of a printer that is answering asks 254 questions to
        // learn something already known.
        #expect(shop.offlineMachineHosts().isEmpty,
                "a shop whose printers are all fine would sweep its LAN anyway")
    }
}
