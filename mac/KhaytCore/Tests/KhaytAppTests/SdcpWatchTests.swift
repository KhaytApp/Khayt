import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Asking an Elegoo resin printer, and saying what went wrong when it cannot
/// be asked.
///
/// There is no Elegoo on this bench and there cannot be, so the socket itself
/// is unproven and that is stated rather than hidden. Everything up to it is
/// here: that the machine is asked at all, that the mainboard id is required
/// before the network is touched, and that each failure reads as the thing it
/// actually is.
@MainActor
struct SdcpWatchTests {

    static func elegoo(host: String = "192.168.68.61", board: String? = "ABC123") -> Machine {
        var api: [String: JSONValue] = ["host": .string(host), "type": .string("sdcp"),
                                        "port": .number(3030)]
        if let board { api["serial"] = .string(board) }
        let row: JSONValue = .object([
            "id": .string("M-2"), "name": .string("Saturn"),
            "printerApi": .object(api),
        ])
        return try! JSONDecoder().decode(Machine.self, from: JSONEncoder().encode(row))
    }

    @Test("an Elegoo is a machine this app asks, and that is all seven")
    func sdcpIsSpoken() {
        #expect(PrinterWatch.spoken.contains("sdcp"))
        #expect(PrinterWatch.notWatched(Self.elegoo()) == nil)
        #expect(PrinterWatch.defaultPort("sdcp") == 3030)
        // Every protocol a machine can be set to is now one this app speaks.
        #expect(PrinterWatch.spoken == PrinterWatch.everyProtocol)
    }

    /// The mainboard id is the ADDRESS on this protocol — every frame is
    /// topic-addressed by it. Without one nothing would answer, which would
    /// read as a printer that is switched off.
    @Test("no mainboard id is refused for being missing, not for going quiet")
    func noBoardIsSaidStraightAway() async throws {
        let engine = try KhaytEngine()
        let base = URL(string: "http://192.168.68.61:3030")!
        await #expect(throws: PrinterWatch.Refusal.needsMainboardId) {
            _ = try await PrinterWatch.askSdcp(Self.elegoo(board: nil), engine: engine, base: base)
        }
        await #expect(throws: PrinterWatch.Refusal.needsMainboardId) {
            _ = try await PrinterWatch.askSdcp(Self.elegoo(board: "  "), engine: engine, base: base)
        }
    }

    @Test("the words for a missing mainboard id say how to get one")
    func theBoardRefusalIsUseful() {
        let said = PrinterWatch.Refusal.needsMainboardId.description
        #expect(said.lowercased().contains("mainboard id"))
        // It is not printed on the machine, so "check the label" is useless
        // advice and a scan is the only answer.
        #expect(said.lowercased().contains("scan"))
    }

    /// Three different situations, three different sentences. Collapsing them
    /// into "could not reach the printer" is what makes a diagnostic useless:
    /// a shop cannot tell whether to look at the network, the machine, or the
    /// print it just sent.
    @Test("a refusal, silence and a hang-up read as three different things")
    func eachFailureIsItself() {
        let refused = PrinterWatch.say(SdcpSocket.Trouble.refused("resin low"))
        let silent = PrinterWatch.say(SdcpSocket.Trouble.silent)
        let closed = PrinterWatch.say(SdcpSocket.Trouble.closed)

        // The printer answered, so its own words are what a shop reads.
        #expect(refused.contains("resin low"))
        #expect(silent.lowercased().contains("mainboard id"),
                "silence is the case where a wrong mainboard id looks like a dead printer")
        #expect(!closed.isEmpty)
        #expect(Set([refused, silent, closed]).count == 3)
    }

    @Test("an Elegoo failure goes through the same door as every other one")
    func itIsWiredIntoSay() {
        let said = PrinterWatch.say(SdcpSocket.Trouble.refused("resin low") as any Error)
        #expect(said == PrinterWatch.say(SdcpSocket.Trouble.refused("resin low")))
        #expect(said.contains("resin low"))
    }

    /// SDCP has no credential at all — a machine is reached by address alone.
    /// So the LAN check is the only guard there is, and it matters more here
    /// than on any other protocol.
    @Test("an address off this network is refused before a socket is opened")
    func onlyTheLanIsReachable() async throws {
        let engine = try KhaytEngine()
        await #expect(throws: PrinterWatch.Refusal.self) {
            _ = try await PrinterWatch.baseURL(Self.elegoo(host: "203.0.113.9"), engine: engine)
        }
    }
}
