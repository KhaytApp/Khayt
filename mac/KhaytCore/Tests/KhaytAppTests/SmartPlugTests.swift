import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A printer's smart plug on the Mac. No plug on the bench: the vendors'
/// documented answers are the fixture (see test/smart-plug.test.js), and these
/// prove the Mac reaches the shared rule and never skips it.
@MainActor
struct SmartPlugTests {

    static func source(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/\(name)"), encoding: .utf8)
    }

    @Test("the rule runs on the Mac: a Home Assistant switch, and its answer")
    func throughTheEngine() async throws {
        let engine = try KhaytEngine()
        let machine: JSONValue = .object(["id": .string("M1"), "smartPlug": .object([
            "type": .string("homeassistant"), "host": .string("http://ha.local:8123"),
            "entity": .string("switch.core_one"), "token": .string("T")])])
        let off = try #require(try await engine.plugRequest(machine: machine, action: "off"))
        #expect(off.method == "POST")
        #expect(off.url == "http://ha.local:8123/api/services/switch/turn_off")
        #expect(off.headers["Authorization"] == "Bearer T")
        let state = try await engine.plugAnswer(machine: machine, answer: .object([
            "entity_id": .string("switch.core_one"), "state": .string("on"),
            "attributes": .object(["current_power_w": .number(25.3)])]))
        #expect(state == KhaytEngine.PlugState(on: true, watts: 25.3))
    }

    @Test("power is never cut mid-print, silent or hot — on the Mac too")
    func theGuard() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.plugCanTurnOff(live: .object(["state": .string("printing")])).reason == "plug.printing")
        #expect(try await engine.plugCanTurnOff(live: .object(["state": .string("idle"), "error": .string("x")])).reason
                == "plug.not_answering")
        #expect(try await engine.plugCanTurnOff(live: nil).reason == "plug.no_reading")
        #expect(try await engine.plugCanTurnOff(live: .object(["state": .string("standby"), "tempNozzle": .number(30)])).ok)
    }

    @Test("switching off always asks the rule, and the reading it asks carries the nozzle temperature")
    func wired() throws {
        let shop = try Self.source("Shop.swift")
        #expect(shop.contains("engine.plugCanTurnOff(live: printers.statusCache[machine.id])"),
                "a plug could be switched off without the rule")
        #expect(shop.contains("startWatchingPlugs()"))
        let watch = try Self.source("PrinterWatch.swift")
        #expect(watch.contains("\"tempNozzle\": status.tempNozzle.map(JSONValue.number)"),
                "without the temperature, the rule cannot refuse a hot end")
        let sheet = try Self.source("MachineSheet.swift")
        #expect(sheet.contains("Secrets.seal(typed, for: build)"), "a plug secret would go into the book in the clear")
        #expect(sheet.contains("input[\"smartPlug\"]"))
        for key in ["plug.printing", "plug.not_answering", "plug.no_reading", "plug.hot", "plug.unreachable"] {
            #expect(try Self.source("Words.swift").contains("\"\(key)\""), "\(key) would render as its own name")
        }
    }
}
