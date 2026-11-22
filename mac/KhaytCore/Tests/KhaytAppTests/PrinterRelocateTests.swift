import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A printer that changed address is not a printer that went away.
///
/// A DHCP lease expires overnight, the router hands out a different address,
/// and Khayt polls a host that answers nothing. It says "offline" — which is
/// also what it says when a printer is switched off, and the two have
/// completely different fixes.
///
/// The cost is worse than a wrong badge. `captureCompletion` freezes a job's
/// real filament and duration on the edge out of printing, and the counters
/// reset when the next job starts. Every print that finishes while the address
/// is stale is a measurement that no longer exists — found exactly that way on
/// the bench, when a Snapmaker U1 moved from .77 to .56 and the completion
/// history came back empty rather than short.
///
/// What is pinned here is the DISTINCTION the rule draws, because the Mac has
/// to act on it differently: identity may be applied, resemblance may only be
/// proposed.
@MainActor
struct PrinterRelocateTests {

    static func machine(_ id: String, _ name: String, host: String,
                        type: String = "moonraker", serial: String? = nil,
                        mac: String? = nil) -> JSONValue {
        var api: [String: JSONValue] = ["type": .string(type), "host": .string(host)]
        if let serial { api["serial"] = .string(serial) }
        if let mac { api["mac"] = .string(mac) }
        return .object(["id": .string(id), "name": .string(name),
                        "printerApi": .object(api)])
    }

    static func found(_ host: String, connection: String = "moonraker",
                      serial: String? = nil, model: String? = nil,
                      port: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["host": .string(host), "connection": .string(connection)]
        if let serial { o["serial"] = .string(serial) }
        if let model { o["model"] = .string(model) }
        if let port { o["port"] = .number(Double(port)) }
        return .object(o)
    }

    /// Offline as the poll cache defines it, which took reading to get right.
    ///
    /// `isOffline` wants BOTH a recorded `error` and `consecutiveFailures` at
    /// or past the threshold — a count alone is not enough. My first fixture
    /// set `online: false` with a count and produced no moves at all, which
    /// looked like the rule refusing a good match and was a fixture that never
    /// described an offline machine.
    static func offline(_ id: String) -> [String: JSONValue] {
        [id: .object(["error": .string("connection refused"),
                      "consecutiveFailures": .number(3)])]
    }

    // MARK: - Identity may be applied

    @Test("a serial the printer announced settles it")
    func serialIsIdentity() async throws {
        // "A serial does not move with a lease." So this is identity, not
        // resemblance, and the rule marks it safe to apply without asking.
        let engine = try KhaytEngine()
        let moves = try await engine.planRelocations(
            machines: [Self.machine("M1", "Bench U1", host: "192.168.1.77", serial: "SN-ABC")],
            discovered: [Self.found("192.168.1.56", serial: "SN-ABC")],
            statusCache: Self.offline("M1"))

        let move = try #require(moves.first, "a serial match was not found")
        #expect(move.machineId == "M1")
        #expect(move.from == "192.168.1.77")
        #expect(move.to == "192.168.1.56")
        #expect(move.confidence == "serial")
        #expect(move.isIdentity, "a serial match must be applicable without asking")
        #expect(!move.why.isEmpty, "a move with no reason cannot be weighed")
    }

    @Test("a model match is proposed, never treated as identity")
    func modelIsAGuess() async throws {
        // "Strong, and still a guess: PROPOSE it, never apply it. Retargeting
        // is a write, and the write points the app at a machine it will later
        // send commands to."
        let engine = try KhaytEngine()
        let moves = try await engine.planRelocations(
            machines: [Self.machine("M1", "Bench", host: "192.168.1.77")],
            discovered: [Self.found("192.168.1.56", model: "Snapmaker U1")],
            statusCache: Self.offline("M1"))

        for move in moves {
            #expect(!move.isIdentity,
                    Comment(rawValue: "\(move.confidence) was treated as identity"))
        }
    }

    // MARK: - When it must NOT move a machine

    @Test("a machine that is answering is left alone")
    func onlyOfflineMachines() async throws {
        // Retargeting a working printer would point the app away from the one
        // it is talking to. An empty status cache means nothing is known to be
        // offline, so nothing moves.
        let engine = try KhaytEngine()
        let moves = try await engine.planRelocations(
            machines: [Self.machine("M1", "Bench", host: "192.168.1.77", serial: "SN-ABC")],
            discovered: [Self.found("192.168.1.56", serial: "SN-ABC")],
            statusCache: [:])
        #expect(moves.isEmpty, "a machine with no failures was retargeted")
    }

    @Test("a GUESS never lands on an address another machine holds")
    func guessesRespectClaimedAddresses() async throws {
        // "Moving a machine onto one of these would quietly make two machine
        // records the same printer, and the shop would send one printer both
        // queues."
        //
        // This applies to the fallback path — the machine with no serial
        // recorded, where the rule is guessing from protocol and model.
        let engine = try KhaytEngine()
        let moves = try await engine.planRelocations(
            machines: [Self.machine("M1", "A", host: "192.168.1.77"),
                       Self.machine("M2", "B", host: "192.168.1.56")],
            discovered: [Self.found("192.168.1.56", model: "Snapmaker U1")],
            statusCache: Self.offline("M1"))
        #expect(!moves.contains { $0.to == "192.168.1.56" },
                "a guess was pointed at an address another machine already holds")
    }

    @Test("but IDENTITY outranks an address another machine has written down")
    func identityBeatsAClaim() async throws {
        // MY FIRST VERSION OF THIS ASSERTED THE OPPOSITE AND WAS WRONG.
        //
        // The `claimed` map is consulted only in the fallback path. The serial
        // branch does not look at it, and the rule says why: "A serial match
        // settles it even when the machine is one of five identical printers on
        // the bench."
        //
        // That is right. If the printer at .56 announces the serial recorded
        // for M1, then M1 IS at .56 — and M2's configured address is the stale
        // record, not the serial. Refusing the move would leave the shop with
        // the one thing this feature exists to prevent: a machine polling a
        // host that answers nothing while the printer sits there announcing
        // itself.
        let engine = try KhaytEngine()
        let moves = try await engine.planRelocations(
            machines: [Self.machine("M1", "A", host: "192.168.1.77", serial: "SN-ABC"),
                       Self.machine("M2", "B", host: "192.168.1.56")],
            discovered: [Self.found("192.168.1.56", serial: "SN-ABC")],
            statusCache: Self.offline("M1"))
        let move = try #require(moves.first { $0.machineId == "M1" },
                                "identity was refused because another record claimed the address")
        #expect(move.to == "192.168.1.56")
        #expect(move.confidence == "serial")
        // Which means the UI has to say so: applying this leaves two machines
        // naming one address until the other is repaired too.
        #expect(move.isIdentity)
    }

    @Test("a printer speaking another protocol is not a candidate")
    func protocolMustMatch() async throws {
        let engine = try KhaytEngine()
        let moves = try await engine.planRelocations(
            machines: [Self.machine("M1", "Bench", host: "192.168.1.77",
                                    type: "moonraker", serial: "SN-ABC")],
            discovered: [Self.found("192.168.1.56", connection: "octoprint", serial: "SN-ABC")],
            statusCache: Self.offline("M1"))
        #expect(moves.isEmpty, "a machine was pointed at a printer speaking a different protocol")
    }

    @Test("nothing on the network means nothing to do, not an error")
    func nothingFound() async throws {
        let engine = try KhaytEngine()
        let moves = try await engine.planRelocations(
            machines: [Self.machine("M1", "Bench", host: "192.168.1.77", serial: "SN-ABC")],
            discovered: [],
            statusCache: Self.offline("M1"))
        #expect(moves.isEmpty)
    }

    // MARK: - Applying one

    @Test("applying a move carries the address, the port and the serial, and nothing else")
    func applyKeepsTheRest() async throws {
        let engine = try KhaytEngine()
        var api: [String: JSONValue] = [
            "type": .string("moonraker"), "host": .string("192.168.1.77"),
            "port": .number(7125), "apiKey": .string("__enc__sealed"),
        ]
        let machine = JSONValue.object([
            "id": .string("M1"), "name": .string("Bench"),
            "nozzleDiameter": .number(0.4),
            "printerApi": .object(api),
        ])
        let moves = try await engine.planRelocations(
            machines: [Self.machine("M1", "Bench", host: "192.168.1.77", serial: "SN-ABC")],
            discovered: [Self.found("192.168.1.56", serial: "SN-ABC", port: 7126)],
            statusCache: Self.offline("M1"))
        let move = try #require(moves.first)

        let updated = try await engine.applyRelocation(machine, move)
        guard case .object(let rec) = updated, case .object(let newApi)? = rec["printerApi"]
        else { Issue.record("the updated record is not shaped like a machine"); return }

        #expect(newApi["host"] == JSONValue.string("192.168.1.56"))
        // THE KEY MUST SURVIVE. A repair that loses the printer's credentials
        // turns one broken machine into a differently broken one.
        #expect(newApi["apiKey"] == JSONValue.string("__enc__sealed"),
                "the sealed key was dropped by the repair")
        #expect(newApi["type"] == JSONValue.string("moonraker"))
        // And everything outside printerApi is untouched.
        #expect(rec["nozzleDiameter"] == JSONValue.number(0.4))
        #expect(rec["name"] == JSONValue.string("Bench"))
        api["host"] = .string("ignored")   // silence the unused-mutation warning
    }

    // MARK: - The serial the Mac used to throw away

    @Test("discovery's serial reaches Swift now")
    func foundPrinterCarriesTheSerial() throws {
        // `printer-discovery.js` has always read the serial from the TXT
        // record; `FoundPrinter` had no such field, and Swift's `Decodable`
        // silently ignores a key nobody declared. Without it the strongest
        // match this feature has cannot be made at all.
        let json = """
        [{"name":"Bench","host":"192.168.1.56","port":7125,"connection":"moonraker",
          "serial":"SN-ABC","firmware":"v1.2"}]
        """
        let found = try JSONDecoder().decode([KhaytEngine.FoundPrinter].self,
                                             from: Data(json.utf8))
        #expect(found.first?.serial == "SN-ABC", "the serial is being dropped again")
        #expect(found.first?.firmware == "v1.2")
    }
}
