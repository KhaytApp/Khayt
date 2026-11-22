import Foundation
import Testing
@testable import KhaytApp

/// Connectors are hidden from shops until v1 ships with its /privacy page.
struct ConnectorsSwitchTests {
    @Test("off unless a developer switches it on, by variable or by defaults")
    func gate() throws {
        let suite = "ConnectorsSwitchTests.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        #expect(ConnectorsSwitch.isOn(environment: [:], defaults: d) == false)
        #expect(ConnectorsSwitch.isOn(environment: ["KHAYT_CONNECTORS": "0"], defaults: d) == false)
        #expect(ConnectorsSwitch.isOn(environment: ["KHAYT_CONNECTORS": "1"], defaults: d))
        d.set(true, forKey: "KhaytConnectors")
        #expect(ConnectorsSwitch.isOn(environment: [:], defaults: d))
    }
}
