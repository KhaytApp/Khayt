import XCTest
import JavaScriptCore
import KhaytCore
@testable import KhaytCompanion

/**
 * The phone's reading of a print's energy against the shop's own.
 *
 * `EnergyRules` is a Swift port of `lib/print-energy.js` `energyWhOf`,
 * `tariffOf`, `estimatedPowerCost` and `actualPowerCost`, and of
 * `lib/print-rates.js` `shopTariff`. Every answer is asked of the REAL
 * JavaScript in JavaScriptCore and the Swift must give the same one.
 *
 * The fixtures: a whole print metered; a partial one refused; one scaled up;
 * a reading with no coverage; missing fields; values stored as strings,
 * nulls and blanks; the older `energyWh`/`energy` spelling; tariffs on the
 * parts, on the rates, and neither; and the `null` part the JavaScript
 * throws on.
 */
final class PrintEnergyParityTests: XCTestCase {

    private var js: JSContext!

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let ctx = try XCTUnwrap(JSContext())
        var thrown: String?
        ctx.exceptionHandler = { _, e in thrown = e?.toString() }
        for file in ["lib/print-energy.js", "lib/print-rates.js"] {
            let source = try String(contentsOf: root.appending(path: file), encoding: .utf8)
            ctx.evaluateScript(source)
            XCTAssertNil(thrown, "\(file) did not load: \(thrown ?? "")")
        }
        js = ctx
    }

    private func text(_ v: JSONValue) -> String {
        String(data: try! JSONEncoder().encode(v), encoding: .utf8)!
    }

    /// The rule's answer, or `"threw"` when it throws.
    private func ask(_ expression: String) throws -> JSONValue {
        let out = try XCTUnwrap(js.evaluateScript(
            "(function () { try { return JSON.stringify(\(expression)); } catch (e) { return JSON.stringify('threw'); } })()"
        )?.toString(), expression)
        return try JSONDecoder().decode(JSONValue.self, from: Data(out.utf8))
    }

    private func number(_ v: Double?) -> JSONValue { v.map { .number($0) } ?? .null }

    private func close(_ a: Double?, _ b: JSONValue, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        switch (a, b) {
        case (nil, .null): return
        case (let x?, .number(let y)): XCTAssertEqual(x, y, accuracy: 1e-9, what, file: file, line: line)
        default: XCTFail("\(what): swift \(String(describing: a)) js \(b)", file: file, line: line)
        }
    }

    // MARK: - Fixtures

    private func meta(_ coverage: JSONValue?) -> JSONValue {
        var o: [String: JSONValue] = ["source": .string("plug"), "coveredS": .number(3000), "spanS": .number(3600)]
        if let coverage { o["coverage"] = coverage }
        return .object(o)
    }

    private var records: [(String, [String: JSONValue])] {
        [
            ("whole", ["actualEnergyWh": .number(420.5), "actualEnergy": meta(.number(1))]),
            ("partial-refused", ["actualEnergyWh": .number(300), "actualEnergy": meta(.number(0.5))]),
            ("just-under", ["actualEnergyWh": .number(300), "actualEnergy": meta(.number(0.799))]),
            ("at-the-line", ["actualEnergyWh": .number(300), "actualEnergy": meta(.number(0.8))]),
            ("scaled-up", ["actualEnergyWh": .number(1712.6), "actualEnergy": meta(.number(0.96))]),
            ("over-one", ["actualEnergyWh": .number(100), "actualEnergy": meta(.number(1.2))]),
            ("no-coverage", ["actualEnergyWh": .number(250), "actualEnergy": meta(nil)]),
            ("no-meta", ["actualEnergyWh": .number(250)]),
            ("null-coverage", ["actualEnergyWh": .number(250), "actualEnergy": meta(.null)]),
            ("blank-coverage", ["actualEnergyWh": .number(250), "actualEnergy": meta(.string(""))]),
            ("string-coverage", ["actualEnergyWh": .string("500"), "actualEnergy": meta(.string("0.9"))]),
            ("bad-coverage", ["actualEnergyWh": .number(500), "actualEnergy": meta(.string("most"))]),
            ("string-wh", ["actualEnergyWh": .string("88.8")]),
            ("zero-wh", ["actualEnergyWh": .number(0), "actualEnergy": meta(.number(1))]),
            ("negative-wh", ["actualEnergyWh": .number(-5)]),
            ("null-wh-shadows", ["actualEnergyWh": .null, "energyWh": .number(300)]),
            ("older-spelling", ["energyWh": .number(300), "energy": meta(.number(0.85))]),
            ("older-refused", ["energyWh": .number(300), "energy": meta(.number(0.2))]),
            ("meta-is-text", ["actualEnergyWh": .number(90), "actualEnergy": .string("plug")]),
            ("empty-meta-falls-to-energy", ["actualEnergyWh": .number(90), "actualEnergy": .null, "energy": meta(.number(0.1))]),
            ("nothing", [:]),
            ("hours-only", ["actualPrintTime": .number(3.5), "printTime": .number(4)]),
            ("estimate-hours", ["printTime": .string("2.25")]),
        ]
    }

    private var partsSets: [(String, JSONValue?)] {
        [
            ("no-parts", nil),
            ("empty", .array([])),
            ("part-rate", .array([.object(["printTime": .number(2), "powerDraw": .number(200), "elecRate": .number(0.3),
                                           "failureRate": .number(10), "qty": .number(2)])])),
            ("string-rate", .array([.object(["printTime": .string("1.5"), "elecRate": .string("0.25"), "qty": .number(0)])])),
            ("blank-rate", .array([.object(["printTime": .number(1), "elecRate": .string(""), "powerDraw": .string("")]),
                                    .object(["elecRate": .number(0.4)])])),
            ("space-rate", .array([.object(["elecRate": .string(" ")])])),
            ("null-rate", .array([.object(["elecRate": .null, "printTime": .number(3)])])),
            ("negative-rate", .array([.object(["elecRate": .number(-1), "failureRate": .number(-20)])])),
            ("falsy-part", .array([.number(0), .object(["elecRate": .number(0.5)])])),
            ("text-part", .array([.string("x"), .object(["elecRate": .number(0.5)])])),
            ("null-part", .array([.null, .object(["elecRate": .number(0.5)])])),
        ]
    }

    private var rateSets: [[String: JSONValue]] {
        [[:], ["elecRate": .number(0.18), "powerDraw": .number(150)], ["elecRate": .string("0.2")],
         ["elecRate": .number(-3), "powerDraw": .null], ["powerDraw": .string("120"), "failureRate": .number(5)]]
    }

    // MARK: - energyWhOf

    func testEnergyWhOfMatchesTheRule() throws {
        var refused = 0, scaled = 0
        for (name, record) in records {
            for minCoverage in [nil, 0.5, 0.95] as [Double?] {
                let opts = minCoverage.map { "{ minCoverage: \($0) }" } ?? "undefined"
                let rule = try ask("KhaytPrintEnergy.energyWhOf(\(text(.object(record))), \(opts))")
                let swift = EnergyRules.energyWhOf(record, minCoverage: minCoverage)
                close(swift, rule, "\(name) min \(String(describing: minCoverage))")
                if minCoverage == nil {
                    if swift == nil, EnergyRules.pos(record["actualEnergyWh"] ?? record["energyWh"]) != nil { refused += 1 }
                    if let s = swift, let raw = EnergyRules.pos(record["actualEnergyWh"]), s > raw { scaled += 1 }
                }
            }
        }
        XCTAssertGreaterThan(refused, 2, "the fixtures stopped reaching a refusal")
        XCTAssertGreaterThan(scaled, 0, "the fixtures stopped reaching a scaled-up reading")
    }

    // MARK: - tariffOf, estimatedPowerCost, actualPowerCost

    func testCostsMatchTheRule() throws {
        var threw = false
        for (recordName, base) in records {
            for (partsName, parts) in partsSets {
                var order = base
                if let parts { order["parts"] = parts }
                for rates in rateSets {
                    let what = "\(recordName) / \(partsName) / \(rates)"
                    let o = text(.object(order)), r = text(.object(rates))

                    let tariff = try ask("KhaytPrintEnergy.tariffOf(\(o), \(r))")
                    if tariff == .string("threw") {
                        XCTAssertNil(EnergyRules.tariffOf(order, rates: rates), what)
                        threw = true
                    } else {
                        close(EnergyRules.tariffOf(order, rates: rates), tariff, what + " tariff")
                    }

                    close(EnergyRules.estimatedPowerCost(order, rates: rates),
                          try ask("KhaytPrintEnergy.estimatedPowerCost(\(o), \(r))"), what + " estimated")

                    let actual = try ask("KhaytPrintEnergy.actualPowerCost(\(o), \(r))")
                    let swift = EnergyRules.actualPowerCost(order, rates: rates)
                    if case .object(let a) = actual {
                        let s = try XCTUnwrap(swift, what)
                        close(s.cost, a["cost"] ?? .null, what + " cost")
                        XCTAssertEqual(a["measured"], .bool(s.measured), what)
                        close(s.wh, a["wh"] ?? .null, what + " wh")
                        close(s.estimated, a["estimated"] ?? .null, what + " estimated")
                    } else {
                        XCTAssertEqual(actual, .string("threw"), what)
                        XCTAssertNil(swift, what)
                    }
                }
            }
        }
        XCTAssertTrue(threw, "the null part stopped reaching the throw")
    }

    func testShopTariffMatchesTheRule() throws {
        let values: [JSONValue?] = [nil, .number(0.18), .number(0), .number(-0.1), .string("0.25"), .string("  "),
                                    .string(""), .string("abc"), .null, .bool(true), .number(25_000), .array([])]
        for v in values {
            var settings: [String: JSONValue] = [:]
            if let v { settings["elecRate"] = v }
            let rule = try ask("KhaytPrintRates.shopTariff(\(text(.object(settings))))")
            close(EnergyRules.shopTariff(settings), rule, "elecRate \(String(describing: v))")
        }
    }

    // MARK: - The page

    func testTheJobPageShowsWhatTheRuleGives() throws {
        let settings: [String: JSONValue] = ["currency": .string("SAR"), "elecRate": .number(0.2)]
        let metered: [String: JSONValue] = ["id": .string("J"), "actualEnergyWh": .number(420), "actualEnergy": meta(.number(1))]
        let e = try XCTUnwrap(JobEnergy.of(order: metered, settings: settings))
        XCTAssertEqual(e.kWh, 0.42, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(e.cost), 0.084, accuracy: 1e-9)
        XCTAssertEqual(e.currency, "SAR")

        // No tariff anywhere: the energy alone.
        let bare = try XCTUnwrap(JobEnergy.of(order: metered, settings: [:]))
        XCTAssertNil(bare.cost)
        // The job's own part tariff wins over the shop's.
        var own = metered
        own["parts"] = .array([.object(["elecRate": .number(0.5)])])
        XCTAssertEqual(try XCTUnwrap(JobEnergy.of(order: own, settings: settings)?.cost), 0.21, accuracy: 1e-9)

        // Nothing at all without a reading, or with one the rule refuses.
        XCTAssertNil(JobEnergy.of(order: ["id": .string("J")], settings: settings))
        var partial = metered
        partial["actualEnergy"] = meta(.number(0.4))
        XCTAssertNil(JobEnergy.of(order: partial, settings: settings))
    }

    /// The sample shop: two finished jobs show energy, the third was metered
    /// too little and shows nothing, and an open job has none.
    func testTheSampleShopShowsEnergyOnTwoJobs() throws {
        let store = SampleShop.book()
        let planter = try XCTUnwrap(JobEnergy.of(store: store, orderId: "S-1038"))
        XCTAssertEqual(planter.kWh, 0.3184, accuracy: 1e-9)
        XCTAssertNotNil(planter.cost)
        XCTAssertEqual(planter.currency, "USD")
        let gears = try XCTUnwrap(JobEnergy.of(store: store, orderId: "S-1036"))
        XCTAssertGreaterThan(gears.kWh, 1.7126, "scaled up to the whole print")
        XCTAssertNil(JobEnergy.of(store: store, orderId: "S-1031"), "metered too little")
        XCTAssertNil(JobEnergy.of(store: store, orderId: "S-1041"))
    }
}
