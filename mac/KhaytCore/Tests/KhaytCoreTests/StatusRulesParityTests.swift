import Foundation
import Testing
@testable import KhaytCore

/// Swift and Node must agree about what happens to a job.
///
/// The rules for moving an order between stages were lifted out of
/// `renderer/order-flows.js` into `lib/order-status.js` so this app could move
/// a job by the same rules the Electron app moves it by, rather than
/// reimplementing the most consequential write in Khayt a second way.
///
/// "Same code" is a claim, not a guarantee — the bundle can go stale, and
/// JavaScriptCore is not V8. `BundledLogicIsNotAForkTests` proves the bytes
/// match; this proves the ANSWERS match, and that the module even loads here.
///
/// It also covers `apply()`, which the app does not call yet. Waiting until the
/// board can drag a card would mean discovering a JavaScriptCore divergence in
/// the middle of writing the screen, and the effects list is exactly the sort
/// of shape a JSON crossing quietly reorders.
struct StatusRulesParityTests {

    static var repoRoot: URL { BundledLogicIsNotAForkTests.repoRoot }

    /// Run an expression under Node with the same modules loaded.
    ///
    /// `assembly.js` comes first: `order-status` consults it through a `typeof`
    /// guard, so loading it second would have Node gate assemblies while
    /// JavaScriptCore silently did not — and the test would pass by comparing
    /// two different questions.
    static func node(_ expression: String) throws -> JSONValue {
        let script = """
        require('./lib/assembly.js'); require('./lib/order-status.js');
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

    /// A shop's log, small enough to reason about and varied enough to matter.
    static let LOG = """
    [{id:'a',status:'printing'},{id:'b',status:'printing'},{id:'c',status:'pending',clientId:'c1'},
     {id:'d',status:'on_hold',dueDate:'2026-09-20',heldAt:'2026-08-26T09:15:00.000Z',holdReason:'no filament'},
     {id:'e',status:'qc',components:[{id:'k1'}],parts:[{name:'body',partStatus:'qc_pass'},{name:'lid',partStatus:'printed'}]},
     {id:'f',status:'completed',completedAt:'2026-09-01T00:00:00.000Z',materialDeducted:true,printingStartedAt:'2026-08-30T00:00:00.000Z'}]
    """

    /// A frozen clock, so two runtimes can be asked the same question.
    static let NOW = "1757063700000"

    static let cases: [String] = [
        // The gate, over every job and every column that could refuse it.
        "\(LOG).map(function(o){return KhaytOrderStatus.gate(o,'printing',{orders:\(LOG),settings:{}});})",
        "\(LOG).map(function(o){return KhaytOrderStatus.gate(o,'printing',{orders:\(LOG),settings:{productionPaused:true}});})",
        "\(LOG).map(function(o){return KhaytOrderStatus.gate(o,'printing',{orders:\(LOG),settings:{wipLimits:{printing:2}}});})",
        "\(LOG).map(function(o){return KhaytOrderStatus.gate(o,'printing',{orders:\(LOG),settings:{wipLimits:{printing:2},wipEnforceHardLimit:true}});})",
        "\(LOG).map(function(o){return KhaytOrderStatus.gate(o,'completed',{orders:\(LOG),settings:{wipLimits:{completed:1},wipEnforceHardLimit:true}});})",
        // The move itself: the order as it ends up, and the effects asked for.
        "['pending','printing','post','qc','on_hold','completed','delivered'].map(function(s){var o=JSON.parse(JSON.stringify(\(LOG)))[3];var r=KhaytOrderStatus.apply(o,s,{now:\(NOW)});return [o,r.notices,r.effects];})",
        "['pending','printing','completed'].map(function(s){var o=JSON.parse(JSON.stringify(\(LOG)))[5];var r=KhaytOrderStatus.apply(o,s,{now:\(NOW)});return [o,r.notices,r.effects];})",
        // A resin job entering post, decided from the spool.
        "(function(){var o={id:'r',status:'printing',filamentId:'f2'};var r=KhaytOrderStatus.apply(o,'post',{now:\(NOW),inventory:[{id:'f2',materialType:'resin'}]});return [o,r.effects];})()",
        // The cap, at the boundary where an off-by-one lives.
        "(function(){var h=[];for(var i=0;i<200;i++)h.push({status:'pending',at:'t'+i});var o={id:'h',status:'pending',statusHistory:h};KhaytOrderStatus.apply(o,'printing',{now:\(NOW)});return [o.statusHistory.length,o.statusHistory[0].at,o.statusHistory[199].status];})()",
        // Dates cross the JSON boundary as strings and are built from them —
        // the likeliest place two engines part company on a due date.
        "[1,9,45,400].map(function(d){var o={id:'x',status:'on_hold',dueDate:'2026-09-20',heldAt:new Date(\(NOW)-d*86400000).toISOString()};var r=KhaytOrderStatus.apply(o,'printing',{now:\(NOW)});return [o.dueDate,r.notices];})",
        // The money a completion fixes for ever.
        "(function(){var o={id:'m',status:'qc',parts:[{baseCost:10.005},{baseCost:5.5}]};KhaytOrderStatus.apply(o,'completed',{now:\(NOW)});return o.costBasis;})()",
        // The WIP arithmetic on its own.
        "['quote','pending','printing','post','qc','completed','delivered'].map(function(s){return KhaytOrderStatus.wouldExceedWipLimit(\(LOG),'c',s,{printing:2,pending:1,completed:1,delivered:1,quote:1});})",
        // The token format both apps mint.
        "KhaytOrderStatus.makeSurveyToken([0,15,255,1])",
        // The hold and the inspection: the two records a move carries with it.
        "(function(){var o={id:'h',status:'printing',dueDate:'2026-09-20'};var r=KhaytOrderStatus.apply(o,'on_hold',{now:\(NOW),holdReason:'no filament'});return [o,r.notices];})()",
        "(function(){var o={id:'h',status:'printing',heldAt:'2026-08-01T00:00:00.000Z'};KhaytOrderStatus.apply(o,'on_hold',{now:\(NOW)});return o.heldAt;})()",
        "(function(){var o={id:'q',status:'qc',inspector:'OLD'};KhaytOrderStatus.apply(o,'completed',{now:\(NOW),qc:{outcome:'pass',notes:'clean',inspector:'OP1'}});return o;})()",
        "(function(){var o={id:'q',status:'qc',inspector:'OLD'};KhaytOrderStatus.apply(o,'completed',{now:\(NOW),qc:{outcome:'pass'}});return [o.inspector,o.qcNotes];})()",
        "(function(){var o={id:'q',status:'qc'};KhaytOrderStatus.apply(o,'completed',{now:\(NOW),qc:{outcome:'fail'}});return o.qcStatus===undefined;})()",
    ]

    @Test("Swift and Node agree about what happens to a job")
    func parity() async throws {
        let engine = try KhaytEngine()
        for expression in Self.cases {
            let fromNode = try Self.node(expression)
            let fromSwift = try await engine.raw(expression, as: JSONValue.self)
            #expect(fromSwift == fromNode, "diverged for: \(expression)")
        }
    }

    @Test("the gate comes back as a type a screen can act on")
    func gateDecodes() async throws {
        let engine = try KhaytEngine()
        let orders: [JSONValue] = [
            .object(["id": .string("a"), "status": .string("printing")]),
            .object(["id": .string("b"), "status": .string("printing")]),
        ]
        let job: JSONValue = .object(["id": .string("c"), "status": .string("pending")])

        let free = try await engine.statusGate(order: job, to: "printing", orders: orders, settings: [:])
        #expect(free.ok)
        #expect(free.block == nil)
        #expect(free.warn == nil)
        #expect(!free.needsActuals)

        let squeeze = try await engine.statusGate(
            order: job, to: "printing", orders: orders,
            settings: ["wipLimits": .object(["printing": .number(2)])])
        #expect(squeeze.ok, "a soft limit warns and lets the work through")
        #expect(squeeze.warn?.code == "wip_reached")
        #expect(squeeze.warn?.params["n"] == .number(2))

        let refused = try await engine.statusGate(
            order: job, to: "printing", orders: orders,
            settings: ["wipLimits": .object(["printing": .number(2)]),
                       "wipEnforceHardLimit": .bool(true)])
        #expect(!refused.ok)
        #expect(refused.block?.code == "wip_blocked")
        #expect(refused.block?.params["col"] == .string("printing"))

        let paused = try await engine.statusGate(
            order: job, to: "printing", orders: orders,
            settings: ["productionPaused": .bool(true)])
        #expect(!paused.ok)
        #expect(paused.block?.code == "production_paused")

        let finishing = try await engine.statusGate(order: job, to: "completed", orders: orders, settings: [:])
        #expect(finishing.ok)
        #expect(finishing.needsActuals, "completing is when the shop learns what the job cost")
    }

    /// The gate is only as good as the module it consults. If `assembly.js`
    /// ever falls out of the bundle, `order-status` does not crash — it stops
    /// gating, and this app would complete an assembly the Electron app
    /// refuses. That is the failure this test exists for.
    @Test("an unfinished assembly is refused here too")
    func assemblyGateIsWired() async throws {
        let engine = try KhaytEngine()
        let job: JSONValue = .object([
            "id": .string("e"), "status": .string("qc"),
            "components": .array([.object(["id": .string("k1")])]),
            "parts": .array([
                .object(["name": .string("body"), "partStatus": .string("qc_pass")]),
                .object(["name": .string("lid"), "partStatus": .string("printed")]),
            ]),
        ])
        let gate = try await engine.statusGate(order: job, to: "completed", orders: [job], settings: [:])
        #expect(!gate.ok)
        #expect(gate.block?.code == "assembly_parts")
        #expect(gate.block?.params["parts"] == .string("lid"), "say which part is holding it up")
    }
}
