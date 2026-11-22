import Foundation
import Testing
@testable import KhaytCore

/// Swift and Node must agree about what a finished job takes off the shelf.
///
/// A deduction bug does not crash. It reports a shop 400g of PETG it does not
/// have, or charges a re-opened job twice, and surfaces as a print that stops
/// half way — weeks later, with nothing to connect it to. The two apps
/// computing it from the same JavaScript is the point; this checks that they
/// actually get the same answers out of it.
///
/// `apply` in `order-status` asks for these deductions as effects. Nothing on
/// the Mac side performs them yet, and that is exactly why they are tested
/// now: finding a JavaScriptCore divergence while writing the drag would be
/// the wrong time to find it.
struct DeductionParityTests {

    static var repoRoot: URL { BundledLogicIsNotAForkTests.repoRoot }

    static func node(_ expression: String) throws -> JSONValue {
        let script = """
        require('./lib/order-deduction.js');
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

    /// A shelf with the awkward cases on it: an empty spool, a nearly-empty
    /// one, spools at two branches and one shared, and two materials.
    static let SHELF = """
    [{id:'f1',material:'PLA',weight:0,locationId:'riyadh'},
     {id:'f2',material:'PLA',weight:120,locationId:'riyadh'},
     {id:'f3',material:'PLA',weight:900},
     {id:'f4',material:'PLA',weight:900,locationId:'jeddah',reorderPoint:950},
     {id:'f5',material:'PETG',weight:400}]
    """

    static let SUPPLIES = """
    [{id:'c0',name:'IPA',stock:10,minStock:2,usagePerHour:0.35},
     {id:'c1',name:'Glue',stock:3,minStock:3,usagePerHour:0},
     {id:'c2',name:'Box',stock:2,minStock:1,isPackaging:true},
     {id:'c3',name:'Tape',stock:1,minStock:1,isPackaging:true},
     {id:'c4',name:'M3 bolt',stock:40,minStock:8}]
    """

    static let MACHINES = "[{id:'m1',name:'Alpha',locationId:'riyadh'},{id:'m2',name:'Beta',locationId:'jeddah'}]"

    /// `run(order, settings)` — deduct, then report the shelf and the messages.
    static func run(_ order: String, _ settings: String = "{autoDeduct:true}") -> String {
        """
        (function(){
          var inv = \(SHELF), cons = \(SUPPLIES);
          var o = \(order);
          var a = KhaytOrderDeduction.deductForOrder(o, {settings:\(settings),inventory:inv,consumables:cons,machines:\(MACHINES),today:'2026-09-04'});
          var b = KhaytOrderDeduction.deductPackaging(o, {consumables:cons});
          return [o, inv, cons, a.notices.concat(b.notices), a.effects.concat(b.effects)];
        })()
        """
    }

    static let cases: [String] = [
        // A shortfall that crosses spools, from a branch.
        run("{id:'o1',machineId:'m1',printTime:4,parts:[{filamentId:'f1',printWeight:300,supportWeight:20,qty:2}]}"),
        // The chosen spool is empty — the job still consumed the filament.
        run("{id:'o2',parts:[{filamentId:'f1',printWeight:50,qty:1}]}"),
        // A spool switch already took some of it.
        run("{id:'o3',parts:[{filamentId:'f3',printWeight:400,qty:1,additionalSpools:[{weight:150}]}]}"),
        // Multicolour: each colour out of its own spool, times quantity.
        run("{id:'o4',parts:[{qty:3,colours:[{filamentId:'f2',grams:30},{filamentId:'f5',grams:12.5}]}]}"),
        // An assembly's bought-in components, times how many were built.
        run("{id:'o5',assemblyQty:6,parts:[],components:[{consumableId:'c4',qtyPerUnit:4},{consumableId:'gone',qtyPerUnit:2}]}"),
        // Nothing to deduct, and the flag still goes on.
        run("{id:'o6',parts:[]}"),
        // Auto-deduct off: the shelf and the flag are both left alone.
        run("{id:'o7',parts:[{filamentId:'f3',printWeight:100,qty:1}]}", "{autoDeduct:false}"),
        // A threshold that makes every spool low, and one that makes none.
        run("{id:'o8',parts:[{filamentId:'f3',printWeight:10,qty:1}]}", "{autoDeduct:true,lowStockThreshold:5000}"),
        run("{id:'o9',parts:[{filamentId:'f3',printWeight:10,qty:1}]}", "{autoDeduct:true,lowStockThreshold:0}"),
        // Already deducted: neither half runs.
        run("{id:'o10',materialDeducted:true,packagingDeducted:true,parts:[{filamentId:'f3',printWeight:100,qty:1}]}"),
        // The branch a job belongs to, every way it can be decided.
        "[{locationId:'jeddah',machineId:'m1'},{machineId:'m1'},{machine:'Beta'},{machineId:'gone'},{}].map(function(o){return KhaytOrderDeduction.orderLocationId(o,\(MACHINES));})",
        // The preference order itself.
        "KhaytOrderDeduction.spoolsByLocationPreference(\(SHELF),'riyadh').map(function(s){return s.id;})",
        "KhaytOrderDeduction.spoolsByLocationPreference(\(SHELF),null).map(function(s){return s.id;})",
        // Low stock, at every boundary.
        "[{weight:200},{weight:201},{weight:0},{weight:300,reorderPoint:500},{weight:300,reorderPoint:0}].map(function(s){return [KhaytOrderDeduction.isLowStock(s,{}),KhaytOrderDeduction.isLowStock(s,{lowStockThreshold:250})];})",
        // The grams a part costs — the number reservation and forecast quote.
        "[{printWeight:100,supportWeight:20,qty:3},{printWeight:0.1,qty:7},{}].map(KhaytOrderDeduction.partGramsConsumed)",
        // Floating point, where two engines are likeliest to part company.
        "(function(){var inv=[{id:'f',material:'PLA',weight:0.3}];KhaytOrderDeduction.deductForOrder({id:'x',parts:[{filamentId:'f',printWeight:0.1,qty:1}]},{settings:{autoDeduct:true},inventory:inv,today:'2026-09-04'});return inv[0].weight;})()",
    ]

    @Test("Swift and Node agree about what a job takes off the shelf")
    func parity() async throws {
        let engine = try KhaytEngine()
        for expression in Self.cases {
            let fromNode = try Self.node(expression)
            let fromSwift = try await engine.raw(expression, as: JSONValue.self)
            #expect(fromSwift == fromNode, "diverged for: \(expression)")
        }
    }

    /// The usage cap, at the boundary where an off-by-one lives, through both
    /// runtimes — 200 entries is also where a JSON crossing gets expensive
    /// enough to be worth knowing it still works.
    @Test("a spool's usage history is capped identically in both runtimes")
    func usageCap() async throws {
        let engine = try KhaytEngine()
        let expression = """
        (function(){
          var h=[]; for(var i=0;i<200;i++) h.push({orderId:'old'+i,weightUsed:1,date:'2026-01-01'});
          var inv=[{id:'f',material:'PLA',weight:500,usageHistory:h}];
          KhaytOrderDeduction.deductForOrder({id:'new',project:'P',parts:[{filamentId:'f',printWeight:10,qty:1}]},
            {settings:{autoDeduct:true},inventory:inv,today:'2026-09-04'});
          return [inv[0].usageHistory.length, inv[0].usageHistory[0], inv[0].usageHistory[199].orderId];
        })()
        """
        let fromNode = try Self.node(expression)
        let fromSwift = try await engine.raw(expression, as: JSONValue.self)
        #expect(fromSwift == fromNode)
        #expect(fromSwift == .array([
            .number(200),
            .object(["orderId": .string("new"), "project": .string("P"),
                     "weightUsed": .number(10), "date": .string("2026-09-04")]),
            .string("old198"),
        ]))
    }
}
