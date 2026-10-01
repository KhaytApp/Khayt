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

    // MARK: - One bound, and blank read the same everywhere

    @Test("the bound is one figure: the Mac's restated one is the JavaScript's, and both clamp to it")
    func oneBound() async throws {
        let fromNode = try Self.node("R.MAX_ELEC_RATE")
        #expect(fromNode == .number(Shop.maxElecRate))
        #expect(Shop.maxElecRate == 10_000)
        let engine = try KhaytEngine()
        // A KRW/NGN shop's real tariff stands; a figure over the bound is clamped TO it.
        #expect(try await engine.printRates(settings: ["elecRate": .number(250)])["elecRate"] == 250)
        let over: [String: JSONValue] = ["elecRate": .number(250_000)]
        #expect(try await engine.printRates(settings: over)["elecRate"] == Shop.maxElecRate)
        let node = try Self.node("R.ratesFor({ settings: { elecRate: 250000 } }).elecRate")
        #expect(node == .number(Shop.maxElecRate))
        // Junk is refused on both sides, whitespace included.
        for bad: JSONValue in [.string(" "), .string("abc"), .number(-1), .bool(true), .null] {
            #expect(try await engine.printRates(settings: ["elecRate": bad])["elecRate"] == 0.18,
                    Comment(rawValue: "\(bad)"))
        }
    }

    @Test("whitespace parity: a blank preset tariff defers to the shop's on the Mac, in Node and in the public quote")
    func blankPresetDefers() async throws {
        let engine = try KhaytEngine()
        for blank in ["", " ", "   ", "\t"] {
            let preset: JSONValue = .object(["id": .string("P1"), "elecRate": .string(blank),
                                             "laborRate": .string(blank)])
            let mac = try await engine.printRates(preset: preset, settings: Self.settings)
            #expect(mac["elecRate"] == 0.3, Comment(rawValue: "mac \(blank.debugDescription)"))
            #expect(mac["laborRate"] == 90, "a blank labour rate is not a free hour either")
            let p = try Self.json(preset), st = try Self.json(.object(Self.settings))
            let fromNode = try Self.node("""
                (() => { const PQ = require('./lib/public-quote.js');
                  return { rates: R.ratesFor({ preset: \(p), settings: \(st) }).elecRate,
                           quote: PQ.elecRateFor(\(p), \(st)) }; })()
                """)
            #expect(fromNode == .object(["rates": .number(0.3), "quote": .number(0.3)]),
                    Comment(rawValue: "node \(blank.debugDescription)"))
        }
    }

    @Test("the setup's preset is held to the same bound: over it is clamped, junk writes nothing")
    func setupPresetBounded() {
        var root: [String: JSONValue] = ["printers": .array([])]
        let id = Shop.writeSetupPreset(into: &root, name: "Shop rates", aliases: [], tariff: 1e9,
                                       openers: ["laborRate": 90])
        #expect(id != nil)
        guard case .array(let rows)? = root["printers"], case .object(let row)? = rows.first else {
            Issue.record("no preset"); return
        }
        #expect(row["elecRate"] == .number(Shop.maxElecRate))
        for bad in [Double.nan, .infinity, -1] {
            var untouched = root
            #expect(Shop.writeSetupPreset(into: &untouched, name: "Shop rates", aliases: [], tariff: bad,
                                          openers: ["laborRate": 90]) == nil)
            #expect(untouched == root, Comment(rawValue: "\(bad)"))
        }
    }

    // MARK: - Settings › Business keeps the old setup preset in step

    /// A book an alpha.56 setup wrote: its tariff on a MARKED preset, with the
    /// shop's own labour rate (as text) and a field this app does not model.
    static func bookWithSetupPreset(settings: [String: JSONValue] = ["currency": .string("SAR")]) -> [String: JSONValue] {
        ["settings": .object(settings),
         "printers": .array([
            .object(["id": .string("PRNTR-setup"), "name": .string("Shop rates"),
                     Shop.setupPresetMarker: .bool(true), "elecRate": .number(0.18),
                     "laborRate": .string("40"), "wearRate": .number(0.75), "notes": .string("mine")]),
            .object(["id": .string("PRNTR-hand"), "name": .string("Shop rates (old)"),
                     "elecRate": .number(0.5)]),
         ])]
    }

    static func preset(_ root: [String: JSONValue], _ id: String) -> [String: JSONValue]? {
        guard case .array(let rows)? = root["printers"] else { return nil }
        for row in rows { if case .object(let o) = row, o["id"] == .string(id) { return o } }
        return nil
    }

    /// The Business pane's save, exactly: the draft's form against what it opened.
    func saveBusinessPane(_ root: inout [String: JSONValue], engine: KhaytEngine,
                          edit: (inout BusinessPane.Draft) -> Void) async throws {
        let shop = Shop()
        let original = BusinessPane.Draft.read(Shop.settings(root), shop: shop)
        var draft = original
        edit(&draft)
        try await Shop.applySettings(to: &root, form: draft.form(), opened: original.form(),
                                     country: nil, engine: engine)
    }

    @Test("a new price in Settings › Business goes onto the marked setup preset too, and only its tariff")
    func businessSaveUpdatesSetupPreset() async throws {
        let engine = try KhaytEngine()
        var root = Self.bookWithSetupPreset()
        let hand = Self.preset(root, "PRNTR-hand")
        try await saveBusinessPane(&root, engine: engine) { $0.elecRate = 0.3 }

        guard case .object(let settings)? = root["settings"] else { Issue.record("no settings"); return }
        #expect(settings["elecRate"] == .number(0.3))
        let marked = try #require(Self.preset(root, "PRNTR-setup"))
        #expect(marked["elecRate"] == .number(0.3), "the old setup preset no longer beats the new price")
        #expect(marked["laborRate"] == .string("40"), "the rest of the preset as the book spells it")
        #expect(marked["notes"] == .string("mine"))
        #expect(marked[Shop.setupPresetMarker] == .bool(true))
        #expect(Self.preset(root, "PRNTR-hand") == hand, "a preset the shop named itself is its own figure")
        // So the preset, picked, now costs at the shop's price.
        let rates = try await engine.printRates(preset: .object(marked), settings: settings)
        #expect(rates["elecRate"] == 0.3)

        // A KRW-sized price is not cut to 100 on the way.
        try await saveBusinessPane(&root, engine: engine) { $0.elecRate = 250 }
        #expect(Self.preset(root, "PRNTR-setup")?["elecRate"] == .number(250))
        if case .object(let s)? = root["settings"] { #expect(s["elecRate"] == .number(250)) }
    }

    @Test("clearing the price takes it off the setup preset, which then falls back to Khayt's")
    func businessClearRemovesFromSetupPreset() async throws {
        let engine = try KhaytEngine()
        var root = Self.bookWithSetupPreset(settings: ["currency": .string("SAR"), "elecRate": .number(0.3)])
        try await saveBusinessPane(&root, engine: engine) { $0.elecRate = nil }

        guard case .object(let settings)? = root["settings"] else { Issue.record("no settings"); return }
        #expect(settings["elecRate"] == nil)
        let marked = try #require(Self.preset(root, "PRNTR-setup"))
        #expect(marked["elecRate"] == nil, "removed, not written as 0 — 0 would be a free kWh")
        #expect(marked["laborRate"] == .string("40"))
        #expect(try await engine.printRates(preset: .object(marked), settings: settings)["elecRate"] == 0.18)
        // And the next price set reaches it again.
        try await saveBusinessPane(&root, engine: engine) { $0.elecRate = 0.22 }
        #expect(Self.preset(root, "PRNTR-setup")?["elecRate"] == .number(0.22))
    }

    @Test("saving the Business pane without touching the price leaves it, and the preset, byte-identical")
    func untouchedPriceRoundTrips() async throws {
        let engine = try KhaytEngine()
        for stored: JSONValue in [.string("abc"), .string("inf"), .string("nan"), .string(" "), .string("0.30"),
                                  .number(250_000), .number(-2), .object([:])] {
            var root = Self.bookWithSetupPreset(settings: ["currency": .string("SAR"), "elecRate": stored,
                                                           "phone": .string("1")])
            let before = root
            // Another field changes; the price field is never touched.
            try await saveBusinessPane(&root, engine: engine) { $0.phone = "2" }
            guard case .object(let s)? = root["settings"] else { Issue.record("no settings"); continue }
            #expect(s["elecRate"] == stored, Comment(rawValue: "\(stored)"))
            #expect(s["phone"] == .string("2"))
            #expect(root["printers"] == before["printers"], Comment(rawValue: "\(stored)"))
        }
        // A junk value shows empty rather than as a number the field invented.
        let shop = Shop()
        for junk: JSONValue in [.string("abc"), .string("inf"), .string("nan")] {
            #expect(BusinessPane.Draft.read(["elecRate": junk], shop: shop).elecRate == nil)
        }
    }
}
