import Foundation
import Testing
@testable import KhaytCore

/// Swift and Node must build the same new job.
///
/// A wrong field here does not crash. It produces a record that looks like
/// every other record and is quietly missing the one thing some later screen
/// reads — and it would be a record the Mac app created that Khayt cannot fully
/// work with, which is the exact failure this whole project exists to avoid.
struct NewOrderParityTests {

    static var repoRoot: URL { BundledLogicIsNotAForkTests.repoRoot }

    static func node(_ expression: String) throws -> JSONValue {
        let script = """
        require('./lib/pricing.js'); require('./lib/working-week.js');
        require('./lib/calculator-cost.js'); require('./lib/order-new.js');
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
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// A frozen clock and fixed tokens, so two runtimes can be compared at all.
    static let NOW = "1757063700000"
    static let TOKENS = "{tracking:new Array(16).fill(171), quoteApproval:new Array(16).fill(205), id:[0,1,2,3]}"

    static let CART = """
    [{name:'Bracket',material:'PLA',baseCost:120.5,printTime:4.25,qty:2,printWeight:180},
     {name:'Cap',material:'PETG',baseCost:15,printTime:1.5,qty:1,printWeight:40}]
    """

    static let SHOP = """
    {invNumNext:31,invNumYear:2026,quoteNumNext:7,quoteNumYear:2026,rushFeePct:25,
     quoteValidityDays:14,workingHours:{mon:8,tue:8,wed:8,thu:8,fri:0,sat:4,sun:0}}
    """

    static let QUEUE = """
    [{id:'a',status:'pending',printTime:9},{id:'b',status:'printing',printTime:12},
     {id:'c',status:'completed',printTime:40},{id:'d',status:'on_hold',printTime:99},
     {id:'e',status:'quote',printTime:33}]
    """

    /// `made(form)` — build the order AND report the counters it advanced, because
    /// the settings mutation is half of what the caller has to write down.
    static func made(_ form: String) -> String {
        """
        (function(){
          var s = \(SHOP);
          var o = KhaytOrderNew.newOrder(\(form),
            { settings: s, orders: \(QUEUE), now: \(NOW), tokens: \(TOKENS) });
          return [o, s];
        })()
        """
    }

    static let cases: [String] = [
        made("{parts:\(CART),project:'Bracket set',clientId:'C1',margin:45}"),
        made("{parts:\(CART),project:'Bracket set',margin:45,asQuote:true}"),
        made("{parts:\(CART),margin:45,discountPct:12.5,shippingCost:60,depositAmount:300}"),
        made("{parts:\(CART),margin:45,rushEnabled:true}"),
        made("{parts:\(CART),margin:45,extraLines:[{label:'Design',amount:250},{label:'Card fee',pct:2.75}]}"),
        made("{parts:\(CART),margin:45,components:[{consumableId:'c1',qtyPerUnit:4},{qtyPerUnit:2}],assemblyQty:6}"),
        made("{parts:\(CART),margin:0,depositAmount:1000000}"),
        made("{parts:[],margin:45}"),
        // The counter reset, which is what "{year}-0001" promises.
        """
        (function(){ var s = {invNumNext:340,invNumYear:2025};
          var o = KhaytOrderNew.newOrder({parts:\(CART),margin:10},
            { settings: s, orders: [], now: \(NOW), tokens: \(TOKENS) });
          return [o.id, o.invoiceNumber, s]; })()
        """,
        // The parts of the record that are arithmetic on their own.
        "KhaytOrderNew.avgDailyWorkingHours(\(SHOP))",
        "KhaytOrderNew.avgDailyWorkingHours({})",
        "KhaytOrderNew.estimateDueDate(\(QUEUE), 4.25, \(SHOP), \(NOW))",
        "KhaytOrderNew.estimateDueDate([], 0, \(SHOP), \(NOW))",
        // And what a part costs, which every price is built on.
        """
        [{spoolCost:80,spoolWeight:1000,printWeight:180,supportWeight:20,printTime:4,
          wearRate:0.5,powerDraw:120,elecRate:0.18,prepTime:0.25,postTime:0.5,
          laborRate:40,failureRate:5,qty:2}]
          .map(function(p){ return KhaytCalculatorCost.computePartBaseCost(p, {inventory:[],settings:{}}); })
        """,
    ]

    @Test("Swift and Node build the same new job")
    func parity() async throws {
        let engine = try KhaytEngine()
        for expression in Self.cases {
            let fromNode = try Self.node(expression)
            let fromSwift = try await engine.raw(expression, as: JSONValue.self)
            #expect(fromSwift == fromNode, "diverged for: \(expression)")
        }
    }
}
