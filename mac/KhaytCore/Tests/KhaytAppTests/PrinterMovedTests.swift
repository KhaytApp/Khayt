import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A printer that answers at a new address (Shop+PrinterMoved.swift).
///
/// The shop's own case: two Snapmaker U1s on one LAN, both answering
/// `"hostname": "lava"`, one of them ("Baby U1") moved by DHCP. Identity is
/// the product serial or the network card; the API key goes nowhere new.
@MainActor
struct PrinterMovedTests {

    static func found(_ engine: KhaytEngine, host: String, product: String, mac: String) async throws -> JSONValue {
        let info: JSONValue = .object(["result": .object([
            "state": .string("ready"), "hostname": .string("lava"), "software_version": .string("1.5.2")])])
        let record = try #require(try await engine.identifySweep(type: "moonraker", host: host, status: 200, body: info))
        let system: JSONValue = .object(["result": .object(["system_info": .object([
            "product_info": .object(["serial_number": .string(product)]),
            "network": .object(["wlan0": .object(["mac_address": .string(mac)])]),
        ])])])
        let id = try await engine.readSweepIdentity(type: "moonraker", body: system)
        guard case .object(var r) = record else { return record }
        r["serial"] = .string(id.serial); r["serials"] = .array(id.serials.map(JSONValue.string))
        r["mac"] = .string(id.mac); r["macs"] = .array(id.macs.map(JSONValue.string))
        return .object(r)
    }

    static func machine(serial: String? = nil, mac: String? = nil) -> JSONValue {
        var api: [String: JSONValue] = ["type": .string("moonraker"), "host": .string("192.168.68.77"),
                                        "port": .number(7125), "apiKey": .string("sealed:secret")]
        if let serial { api["serial"] = .string(serial) }
        if let mac { api["mac"] = .string(mac) }
        return .object(["id": .string("m1"), "name": .string("Baby U1"), "printerApi": .object(api)])
    }

    static let offline: [String: JSONValue] = ["m1": .object(["error": .string("timeout"), "consecutiveFailures": .number(5)])]

    func offers(_ engine: KhaytEngine, _ machine: JSONValue, _ discovered: [JSONValue],
                dismissed: Set<String> = []) async throws -> [KhaytEngine.Relocation] {
        let moves = try await engine.planRelocations(machines: [machine], discovered: discovered, statusCache: Self.offline)
        return Shop.offerable(moves, dismissed: dismissed)
    }

    @Test("two printers both called lava: only the one with the recorded serial is offered")
    func identityDecides() async throws {
        let engine = try KhaytEngine()
        let baby = try await Self.found(engine, host: "192.168.68.74", product: "811002610171", mac: "40:fd:f3:00:00:74")
        let other = try await Self.found(engine, host: "192.168.68.56", product: "811002606081", mac: "40:fd:f3:00:00:56")

        let bySerial = try await offers(engine, Self.machine(serial: "811002610171"), [other, baby])
        #expect(bySerial.map(\.to) == ["192.168.68.74"] && bySerial.allSatisfy(\.isIdentity))
        let byMac = try await offers(engine, Self.machine(mac: "40:FD:F3:00:00:74"), [other, baby])
        #expect(byMac.map(\.to) == ["192.168.68.74"])
        // A different printer at the new address: nothing offered.
        #expect(try await offers(engine, Self.machine(serial: "811002610171"), [other]).isEmpty)
        // Nothing recorded for the machine: whatever the rule might guess is not offered.
        #expect(try await offers(engine, Self.machine(), [other, baby]).isEmpty)
        #expect(try await offers(engine, Self.machine(), [baby]).isEmpty, "one lava on the network is still a guess")
    }

    @Test("Not now is remembered for that address; a move somewhere else asks again")
    func notNow() async throws {
        let engine = try KhaytEngine()
        let baby = try await Self.found(engine, host: "192.168.68.74", product: "811002610171", mac: "40:fd:f3:00:00:74")
        let first = try #require(try await offers(engine, Self.machine(serial: "811002610171"), [baby]).first)
        #expect(try await offers(engine, Self.machine(serial: "811002610171"), [baby], dismissed: [first.id]).isEmpty)
        let movedAgain = try await Self.found(engine, host: "192.168.68.90", product: "811002610171", mac: "40:fd:f3:00:00:74")
        #expect(try await offers(engine, Self.machine(serial: "811002610171"), [movedAgain],
                                 dismissed: [first.id]).map(\.to) == ["192.168.68.90"])
    }

    @Test("what a sweep or an identity question sends: a name, and no key, token or cookie")
    func noKeyGoesOut() throws {
        let request = try #require(PrinterSweep.request("192.168.68.74", port: 7125, path: "/machine/system_info"))
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "http://192.168.68.74:7125/machine/system_info")
        #expect(Set((request.allHTTPHeaderFields ?? [:]).keys) == ["User-Agent"])
        #expect(!request.httpShouldHandleCookies)
        // The source agrees: nothing in the sweep or the search reads a key.
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/KhaytApp")
        for file in ["PrinterSweep.swift", "Shop+PrinterMoved.swift"] {
            let code = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
                .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for secret in ["apiKey", "accessCode", "Secrets.open", "X-Api-Key", "Authorization"] {
                #expect(!code.contains(secret), "\(file) mentions \(secret)")
            }
        }
    }

    @Test("a printer is asked who it is only while it answers, and only once, and only when nothing is recorded")
    func whenToAsk() throws {
        func machine(_ api: [String: Any]) throws -> Machine {
            let data = try JSONSerialization.data(withJSONObject: ["id": "m1", "name": "Baby U1", "printerApi": api])
            return try JSONDecoder().decode(Machine.self, from: data)
        }
        let bare = try machine(["type": "moonraker", "host": "192.168.68.77"])
        #expect(Shop.needsIdentity(bare, answering: true, asked: []))
        #expect(!Shop.needsIdentity(bare, answering: false, asked: []), "not while it is quiet: its address may be stale")
        #expect(!Shop.needsIdentity(bare, answering: true, asked: ["m1"]), "once per launch")
        #expect(!Shop.needsIdentity(try machine(["type": "moonraker", "host": "h", "serial": "811002610171"]), answering: true, asked: []))
        #expect(!Shop.needsIdentity(try machine(["type": "moonraker", "host": "h", "mac": "40:fd:f3:00:00:74"]), answering: true, asked: []))
        #expect(!Shop.needsIdentity(try machine(["type": "moonraker", "host": " "]), answering: true, asked: []))
    }

    @Test("the sample book never asks the network anything")
    func sampleNeverSearches() async throws {
        let shop = Shop()
        await shop.load(.sample)
        shop.watchForMovedPrinters()
        #expect(!shop.movedSearching)
        #expect(shop.movedSearchedAt == nil)
    }
}
