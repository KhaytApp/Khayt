import Foundation
import Testing
@testable import KhaytCore

/// Swift and Node must agree about money, to the byte.
///
/// The Mac app and the Electron app compute a shop's figures from the SAME
/// JavaScript. That is the whole point of running it in JavaScriptCore rather
/// than reimplementing it: a Swift `computeTax` would earn the right to be wrong
/// in a second, different way, and every fix from the twenty-two review passes
/// would have to be made twice.
///
/// "Same code" is a claim, though, not a guarantee. The bundle could go stale,
/// JavaScriptCore and V8 could round differently, the JSON boundary could lose
/// precision. So this runs the same inputs through both and compares the
/// answers — including the exact cases the review passes were about.
struct MoneyParityTests {

    static var repoRoot: URL { BundledLogicIsNotAForkTests.repoRoot }

    /// Run an expression under Node, with the same modules loaded.
    static func node(_ expression: String) throws -> String {
        let script = """
        require('./lib/tax.js'); require('./lib/pricing.js'); require('./lib/payment-plan.js');
        require('./lib/split-order.js'); require('./lib/business-scope.js');
        require('./lib/order-progress.js'); require('./lib/loyalty.js');
        process.stdout.write(String(JSON.stringify(\(expression))));
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", script]
        process.currentDirectoryURL = repoRoot
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw KhaytJSError.evaluationFailed("node exited \(process.terminationStatus) for: \(expression)")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// The same expression through JavaScriptCore.
    static func swift(_ expression: String, _ engine: KhaytEngine) async throws -> JSONValue {
        try await engine.raw(expression, as: JSONValue.self)
    }

    /// Node's answer, parsed rather than left as text.
    ///
    /// COMPARING THE STRINGS DOES NOT WORK, and the first version of this test
    /// did. Eight cases "failed" with identical values, because
    /// `JSON.stringify` preserves insertion order and Swift's `JSONEncoder`
    /// does not, and because JS writes `1e-7` where Swift writes `1e-07`.
    /// Neither is a disagreement about money. Parsing both sides and comparing
    /// the VALUES asks the question this test is actually for — and a real
    /// divergence, in a number or a missing field, still fails.
    static func nodeValue(_ expression: String) throws -> JSONValue {
        let text = try node(expression)
        guard let data = text.data(using: .utf8) else {
            throw KhaytJSError.unexpectedResult("node returned nothing for: \(expression)")
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Every case below is one a review pass got wrong, plus the boundaries.
    static let cases: [String] = [
        // Pass 2: a nil VAT return on SAR 400,000 of inclusive sales.
        "[200000,150000,50000].reduce(function(a,g){var t=KhaytTax.computeTax(g,KhaytTax.profileFromSettings({enableVat:true,vatRate:15}));return [a[0]+t.subtotal,a[1]+t.taxTotal];},[0,0])",
        // Pass 12: exclusive pricing — the tax goes ON TOP, not out of the price.
        "KhaytTax.computeTax(1000, KhaytTax.profileFromSettings({tax:{country:'US',name:'Sales Tax',mode:'exclusive',rates:[{id:'s',label:'Sales Tax',percent:8.875}]}}))",
        "KhaytTax.computeTax(1000, KhaytTax.profileFromSettings({tax:{country:'GB',name:'VAT',mode:'inclusive',rates:[{id:'v',label:'VAT',percent:20}]}}))",
        // Pass 6: a plan must bill the BALANCE, and the parts must add back up.
        "KhaytPaymentPlan.buildSchedule({total:2000,depositAmount:0,installments:3,firstDueDate:'2026-09-03',intervalDays:30}).map(function(r){return r.amount;})",
        "KhaytPaymentPlan.buildSchedule({total:1000.03,depositAmount:0,installments:3,firstDueDate:'2026-09-03',intervalDays:30}).map(function(r){return r.amount;})",
        // Pass 10/11: the split, and its remainder rule.
        "KhaytSplitOrder.splitMoney({price:3000,paid:1000,credited:0,costs:[60,40]})",
        "KhaytSplitOrder.splitMoney({price:999.99,paid:1000.03,credited:0,costs:[1,1,1]})",
        "KhaytSplitOrder.splitMoney({price:100,paid:50,credited:0,costs:[0,0]})",
        "KhaytSplitOrder.paymentStatusFor(1800, 600)",
        // The quote engine, order of operations intact.
        "KhaytPricing.quoteTotal({baseCost:100,qty:2,margin:40,discountPct:10,rushEnabled:true,rushPct:25,shippingCost:30,business:true})",
        "KhaytPricing.quoteTotal({baseCost:0,qty:1,margin:0,business:false})",
        // The customer tracker moved to Swift — `OrderProgress` — so the check
        // that it agrees moved with it, to `OrderProgressParityTests`, which
        // asks about more statuses than this line did and about the names that
        // only break one language. This comparison is Swift against NODE; a
        // rule that no longer runs in the engine has nothing to compare here.
        // Pass 6: what counts as trade.
        "[{},{nonBusiness:true},{status:'split',splitInto:['a']}].map(function(o){return [KhaytBusinessScope.countsForBusiness(o),KhaytBusinessScope.isSuperseded(o)];})",
        // Floating point at the edges — where two engines are likeliest to part company.
        "[0.1+0.2, 1/3, 1e21, 1e-7, 2**53, -0].map(function(n){return n;})",
        "KhaytTax.computeTax(0.01, KhaytTax.profileFromSettings({enableVat:true,vatRate:15}))",
    ]

    @Test("Swift and Node compute the same money")
    func parity() async throws {
        let engine = try KhaytEngine()
        for expression in Self.cases {
            let nodeText = try Self.node(expression)
            let fromNode = try Self.nodeValue(expression)
            let fromSwift = try await Self.swift(expression, engine)
            #expect(fromSwift == fromNode, """
                JavaScriptCore and Node disagree about a value.
                  expression: \(expression)
                  Node:       \(nodeText)
                  Swift:      \(fromSwift)
                """)
        }
    }

    @Test("the typed Swift API returns what the raw call does")
    func typedMatchesRaw() async throws {
        // The typed methods add a JSON round-trip and a Decodable. That is where
        // a field gets dropped or a Double becomes an Int without anyone noticing.
        let engine = try KhaytEngine()
        let profile = try await engine.taxProfile(settings: ["enableVat": .bool(true), "vatRate": .number(15)])
        #expect(profile.mode == .inclusive)
        #expect(profile.totalPercent == 15)
        #expect(profile.isRegistered)

        let split = try await engine.computeTax(1000, profile: profile)
        let raw = try Self.nodeValue("KhaytTax.computeTax(1000, KhaytTax.profileFromSettings({enableVat:true,vatRate:15}))")
        if case .object(let fields) = raw {
            #expect(fields["taxTotal"] == .number(split.taxTotal), "the typed tax split lost precision")
            #expect(fields["subtotal"] == .number(split.subtotal))
        } else {
            Issue.record("computeTax no longer returns an object")
        }

        let schedule = try await engine.buildSchedule(total: 2000, installments: 3,
                                                      firstDueDate: "2026-09-03", intervalDays: 30)
        #expect(schedule.map(\.amount) == [666.67, 666.67, 666.66])

        let shares = try await engine.splitMoney(price: 3000, paid: 1000, credited: 0, costs: [60, 40])
        #expect(shares.map(\.paidAmount) == [600, 400], "the deposit did not travel with the price")
        #expect(shares.map(\.price).reduce(0, +) == 3000)

        #expect(try await engine.progressIndex(status: "delivered") == 4)
        #expect(try await engine.progressIndex(status: "qc") == 3)
    }

    @Test("a module that fails to load says so, loudly")
    func missingModuleThrows() {
        #expect(throws: KhaytJSError.self) {
            _ = try JSRuntime(modules: ["not-a-real-module"])
        }
    }
}
