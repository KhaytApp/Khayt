import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A printer named by a host NAME is judged by what the name resolves to, and
/// the request goes to the address that was checked.
@MainActor
struct PrinterHostResolveTests {
    static func machine(_ host: String) throws -> Machine {
        let json = #"{"id":"M","name":"P","printerApi":{"type":"moonraker","host":"\#(host)","port":7125}}"#
        return try JSONDecoder().decode(Machine.self, from: Data(json.utf8))
    }

    @Test("a name that resolves to a public address is refused, and nothing is sent")
    func publicName() async throws {
        let engine = try KhaytEngine()
        await #expect(throws: PrinterWatch.Refusal.self) {
            _ = try await PrinterWatch.baseURL(try Self.machine("attacker.com"), engine: engine,
                                               lookUp: { _ in ["93.184.216.34"] })
        }
        await #expect(throws: PrinterWatch.Refusal.self) {
            _ = try await PrinterWatch.baseURL(try Self.machine("127.0.0.1.nip.io"), engine: engine,
                                               lookUp: { _ in ["127.0.0.1"] })
        }
        await #expect(throws: PrinterWatch.Refusal.self, "half public is public") {
            _ = try await PrinterWatch.baseURL(try Self.machine("mixed.example"), engine: engine,
                                               lookUp: { _ in ["192.168.1.9", "8.8.8.8"] })
        }
        await #expect(throws: PrinterWatch.Refusal.self, "a name that resolves to nothing") {
            _ = try await PrinterWatch.baseURL(try Self.machine("nowhere.local"), engine: engine,
                                               lookUp: { _ in [] })
        }
    }

    @Test("a name on the shop's network is sent to the address that was checked")
    func lanName() async throws {
        let engine = try KhaytEngine()
        let url = try await PrinterWatch.baseURL(try Self.machine("voron.local"), engine: engine,
                                                 lookUp: { _ in ["fe80::1%en0", "192.168.1.50"] })
        #expect(url.absoluteString == "http://192.168.1.50:7125")
        let v6only = try await PrinterWatch.baseURL(try Self.machine("voron.local"), engine: engine,
                                                    lookUp: { _ in ["fe80::1%en0"] })
        #expect(v6only.absoluteString == "http://voron.local:7125", "link-local only: sent by name")
    }

    @Test("an address typed as an address is used as typed, with no lookup")
    func literal() async throws {
        let engine = try KhaytEngine()
        let url = try await PrinterWatch.baseURL(try Self.machine("192.168.1.7"), engine: engine,
                                                 lookUp: { _ in Issue.record("looked up a literal"); return [] })
        #expect(url.absoluteString == "http://192.168.1.7:7125")
    }
}
