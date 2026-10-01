import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The shop-wide electricity tariff (`settings.elecRate`), on the Mac, held to
/// what Node makes of the same book.
///
/// The three paths this was built for have NO preset: a part costed on a
/// machine, power by machine, and a failed print. Before the tariff existed
/// every one of them was charged Khayt's 0.18 whatever the shop paid. Each is
/// run here through the Mac's own seam and through the real `lib/` modules
/// under Node, and the figures must be the same — and must not be the 0.18 ones.
@MainActor
struct ElecRateParityTests {

    static let settings: [String: JSONValue] = ["currency": .string("SAR"), "elecRate": .number(0.3)]
    static let machine: JSONValue = .object(["id": .string("M1"), "wearRate": .number(2),
                                             "powerDraw": .number(250)])
    /// A finished job with a metered reading and nothing typed for the tariff.
    static let order: [String: JSONValue] = [
        "id": .string("J1"), "machineId": .string("M1"), "status": .string("completed"),
        "printTime": .number(10), "actualPrintTime": .number(9),
        "actualEnergyWh": .number(2000), "actualEnergy": .object(["coverage": .number(1)]),
        "parts": .array([.object(["printTime": .number(10), "powerDraw": .number(250)])]),
    ]

    static func json(_ value: JSONValue) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    /// An expression against the real modules, under Node.
    static func node(_ expression: String) throws -> JSONValue {
        let script = """
        const R = require('./lib/print-rates.js');
        const E = require('./lib/print-energy.js');
        const F = require('./lib/failed-print-cost.js');
        const C = require('./lib/calculator-cost.js');
        process.stdout.write(JSON.stringify(\(expression)));
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", script]
        process.currentDirectoryURL = LibraryLocationParityTests.repoRoot
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let problem = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LibraryLocationParityTests.Failure.node(String(decoding: problem, as: UTF8.self))
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    @Test("a part on a machine, no preset: the Mac's costing is Node's, at the shop's tariff")
    func costPart() async throws {
        let engine = try KhaytEngine()
        let part = Shop.costInput(spool: nil, grams: 272, hours: 14.9, qty: 1, extra: [:])
        let mac = try await engine.costPart(part, inventory: [], settings: Self.settings,
                                            machine: Self.machine)
        let s = try Self.json(.object(Self.settings)), m = try Self.json(Self.machine), p = try Self.json(part)
        let fromNode = try Self.node("""
            (() => { const r = R.ratesFor({ machine: \(m), settings: \(s) });
              return { cost: C.computePartBaseCost(Object.assign({}, r, \(p)), { inventory: [], settings: \(s) }),
                       elecRate: r.elecRate }; })()
            """)
        guard case .object(let n) = fromNode else { Issue.record("no answer"); return }
        #expect(mac.rates.elecRate == 0.3)
        #expect(n["elecRate"] == .number(0.3))
        let nodeCost = try #require(Shop.plainNumber(n["cost"]))
        #expect(abs(mac.cost - nodeCost) < 1e-9, Comment(rawValue: "mac \(mac.cost) node \(nodeCost)"))
        // And it is not the 0.18 figure.
        let before = try await engine.costPart(part, inventory: [], settings: [:], machine: Self.machine)
        #expect(mac.cost > before.cost)
    }

    @Test("power by machine: the Mac's rows are Node's, at the shop's tariff")
    func powerByMachine() async throws {
        let engine = try KhaytEngine()
        let rows = try await engine.powerByMachine(orders: [.object(Self.order)], machines: [Self.machine],
                                                   settings: Self.settings)
        let s = try Self.json(.object(Self.settings)), m = try Self.json(Self.machine)
        let o = try Self.json(.object(Self.order))
        let fromNode = try Self.node("E.powerByMachine([\(o)], () => R.ratesFor({ machine: \(m), settings: \(s) }))")
        guard case .array(let n) = fromNode, case .object(let row)? = n.first else {
            Issue.record("no rows from node"); return
        }
        let mac = try #require(rows.first)
        #expect(mac.actCost == Shop.plainNumber(row["actCost"]))
        #expect(mac.estCost == Shop.plainNumber(row["estCost"]))
        // 2 kWh metered × 0.3
        #expect(mac.actCost == 0.6)
    }

    @Test("a failed print, through the Mac's costing seam: Node's breakdown, at the shop's tariff")
    func failedPrint() async throws {
        let engine = try KhaytEngine()
        let costing = Shop.failedCosting(order: Self.order, machines: [Self.machine], settings: Self.settings,
                                         ended: nil, live: nil, attempt: nil, inspected: true)
        // Only the tariff travels — not the whole settings object.
        guard case .object(let c) = costing else { Issue.record("not an object"); return }
        #expect(c["settings"] == .object(["elecRate": .number(0.3)]))

        let input: [String: JSONValue] = ["material": .string("PLA"), "weight": .number(100),
                                          "cost": .number(8), "orderId": .string("J1")]
        let shelf: [JSONValue] = [.object(["id": .string("s1"), "material": .string("PLA"),
                                           "cost": .number(80), "weight": .number(1000),
                                           "spoolWeight": .number(1000)])]
        let made = try await engine.newWasteEntry(input, id: "W1", today: "2026-10-01", inventory: shelf,
                                                  order: .object(Self.order), costing: costing)
        guard case .object(let w)? = made.entry else { Issue.record("no entry"); return }

        let s = try Self.json(.object(Self.settings)), m = try Self.json(Self.machine)
        let o = try Self.json(.object(Self.order)), k = try Self.json(costing)
        let fromNode = try Self.node("""
            F.breakdown(\(o), Object.assign({ materialCost: 8 }, \(k)), { machine: \(m), settings: \(s) })
            """)
        guard case .object(let n) = fromNode else { Issue.record("no answer"); return }
        #expect(w["costPower"] == n["power"])
        #expect(w["costMachine"] == n["machine"])
        #expect(w["costFull"] == n["full"])
        // The plug's 2 kWh × 0.3, not × 0.18.
        #expect(w["costPower"] == .number(0.6))

        // The QC path reaches the same figure, from its own settings argument too.
        let bare: JSONValue = .object(["machine": Self.machine, "progress": .number(100),
                                       "energy": .object(["wh": .number(2000), "coverage": .number(1)])])
        let qc = try await engine.recordQcFailure(
            order: .object(Self.order), failureType: "warping", severity: "major", reason: "",
            weight: 0, inspector: nil, inventory: [], now: Date(timeIntervalSince1970: 1_790_000_000),
            wasteId: "W2", defaultReason: "QC", settings: Self.settings, costing: bare)
        guard case .object(let q) = qc.waste else { Issue.record("no waste"); return }
        #expect(q["costPower"] == .number(0.6))
    }
}
