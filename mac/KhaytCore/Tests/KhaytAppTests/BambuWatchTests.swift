import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Asking a Bambu, and saying what went wrong when it cannot be asked.
///
/// No printer answers on this Mac's network and none can be made to, so what is
/// checked here is everything up to the socket: that a Bambu is asked at all,
/// that it is asked the right way, and — mostly — that each failure is reported
/// as the thing it actually is. A diagnostic that sends a shop to check what is
/// already correct is worse than no diagnostic, and that is the specific trap
/// Bambu sets.
@MainActor
struct BambuWatchTests {

    static func bambu(host: String = "192.168.68.56", serial: String? = "01P00A000000000",
                      port: Int? = 8883) -> Machine {
        var api: [String: JSONValue] = ["host": .string(host), "type": .string("bambu")]
        if let port { api["port"] = .number(Double(port)) }
        if let serial { api["serial"] = .string(serial) }
        let row: JSONValue = .object([
            "id": .string("M-1"), "name": .string("X1C"),
            "printerApi": .object(api),
        ])
        return try! JSONDecoder().decode(Machine.self, from: JSONEncoder().encode(row))
    }

    @Test("a Bambu is a machine this app asks")
    func bambuIsSpoken() {
        #expect(PrinterWatch.spoken.contains("bambu"))
        #expect(PrinterWatch.notWatched(Self.bambu()) == nil)
        // MQTT over TLS. The FTPS the other app uploads over is 990 and is not
        // this, so a default of 990 here would connect to the wrong service.
        #expect(PrinterWatch.defaultPort("bambu") == 8883)
    }

    /// The serial is not a credential — it is printed on the machine — but
    /// every topic is addressed by it, so without one there is nothing to
    /// subscribe to. Left unchecked this would run the full eight seconds and
    /// then blame Developer Mode, which would be a lie.
    @Test("a Bambu with no serial is refused for having no serial, not for going quiet")
    func noSerialIsSaidStraightAway() async throws {
        let engine = try KhaytEngine()
        let base = URL(string: "http://192.168.68.56:8883")!
        // WHICH error, not how long it took. The first version of this timed
        // the call and asserted under a second; it passed alone and took 17s
        // under the full suite, because a stopwatch in a parallel test suite
        // measures the other tests. What is actually being claimed is that the
        // serial is checked BEFORE the network — and the name of the error is
        // exactly that claim, with no clock in it.
        await #expect(throws: PrinterWatch.Refusal.needsSerial) {
            _ = try await PrinterWatch.askBambu(Self.bambu(serial: nil),
                                                engine: engine, base: base, accessCode: "x")
        }
        // A serial of spaces is no serial. It would otherwise be subscribed to
        // as `device/   /report` and go unanswered, which reads as silence.
        await #expect(throws: PrinterWatch.Refusal.needsSerial) {
            _ = try await PrinterWatch.askBambu(Self.bambu(serial: "   "),
                                                engine: engine, base: base, accessCode: "x")
        }
    }

    @Test("the words for a missing serial say where to find one")
    func theSerialRefusalIsUseful() {
        let said = PrinterWatch.Refusal.needsSerial.description
        #expect(said.contains("serial"))
        #expect(said.lowercased().contains("printed on the machine"))
    }

    /// THE ONE MESSAGE THAT MATTERS MOST IN THIS PROTOCOL.
    ///
    /// With LAN-only Mode on and Developer Mode off, the printer accepts the
    /// TLS connection AND the CONNACK and then never speaks. Nothing is
    /// refused, so there is no error — the attempt just runs out its clock.
    /// Reaching that state means Developer Mode and ONLY Developer Mode: a
    /// wrong access code is refused with a CONNACK and a wrong address never
    /// connects. So the message must name it, and must not send a shop to
    /// re-check three things that are all already correct.
    @Test("a silent printer is blamed on Developer Mode, and nothing else")
    func silenceNamesDeveloperMode() {
        let said = PrinterWatch.say(BambuMqtt.Trouble.silent)
        #expect(said.contains("Developer Mode"))
        #expect(said.contains("LAN"), "it does not say that LAN mode alone is not enough")
        // The three correct things, which this message must NOT tell a shop to
        // go and check.
        #expect(!said.lowercased().contains("access code"))
        #expect(!said.lowercased().contains("address"))
    }

    /// A refused access code is a different situation and must read as one.
    @Test("a refused access code says so, and says where to find the right one")
    func aRefusalNamesTheAccessCode() {
        let said = PrinterWatch.say(BambuMqtt.Trouble.refused(4))
        #expect(said.lowercased().contains("access code"))
        #expect(said.contains("4"), "the CONNACK code is what tells the two refusals apart")
        #expect(!said.contains("Developer Mode"), "a refusal is not silence")
    }

    @Test("every way this can fail has its own words")
    func nothingFallsThrough() {
        let all: [BambuMqtt.Trouble] = [.malformed, .refused(5), .silent,
                                        .closed("hungUp"), .closed("cancelled"),
                                        .closed("network went away")]
        var said: Set<String> = []
        for trouble in all {
            let words = PrinterWatch.say(trouble)
            #expect(words.count > 20, "\(trouble) has no real message")
            #expect(!words.contains("hungUp"), "a reason code reached the screen")
            #expect(!words.contains("cancelled"), "a reason code reached the screen")
            said.insert(words)
        }
        #expect(said.count == all.count, "two different failures read the same")
    }

    /// `say(_:)` is the one place an error becomes words. A `Trouble` that
    /// reached it as a bare `Error` would print Swift's own description —
    /// "silent" — which is not a sentence.
    @Test("a Bambu failure goes through the same door as every other one")
    func itIsWiredIntoSay() {
        let said = PrinterWatch.say(BambuMqtt.Trouble.silent as any Error)
        #expect(said == PrinterWatch.say(BambuMqtt.Trouble.silent))
        #expect(said.contains("Developer Mode"))
    }
}
