import Foundation
import Testing
@testable import KhaytCore

/// The printer this Mac proposes must be the printer Khayt would have proposed.
///
/// `lib/scheduling.js` has been in the Electron kanban since 3.0 and was never
/// in the Mac engine's module list, so the Mac could not schedule at all. Now
/// that it can, the only thing worth asserting is that it gets the SAME answer:
/// a second scheduler that is nearly right is worse than none, because a shop
/// would have two machines' worth of plans that disagree.
///
/// Every case runs the same JSON through Node and through JavaScriptCore and
/// compares the whole proposal — machine, queue position, projected finish and
/// the module's own reason string.
///
/// Equality alone is not enough to prove the bridge is wired: a call that
/// returned an empty proposal would match an empty proposal from Node. So the
/// cases also assert that something was actually placed, and that the hard
/// filters bite.
struct SchedulingParityTests {

    static var repoRoot: URL { BundledLogicIsNotAForkTests.repoRoot }

    static func node(_ expression: String) throws -> JSONValue {
        let script = """
        const S = require('./lib/scheduling.js');
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
            throw KhaytJSError.evaluationFailed("node exited \(process.terminationStatus)")
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// 7 September 2026, 18:42 — the same instant on both sides, because the
    /// module takes `now` as an argument precisely so this is possible.
    static let now = Date(timeIntervalSince1970: 1_788_000_120)

    /// Three printers of a real shop's shape: one takes anything, one is
    /// material-limited, one is offline.
    static let machinesJSON = """
    [{"id":"MACH-u1","name":"Snapmaker U1","compatMaterials":["PLA","PLA+ 2.0","PETG"],
      "nozzleDiameter":0.4,"targetHoursPerDay":16},
     {"id":"MACH-x1c","name":"Bambu X1C","compatMaterials":["PETG","PA-CF"],
      "nozzleDiameter":0.4,"targetHoursPerDay":20},
     {"id":"MACH-off","name":"Prusa CORE One","compatMaterials":[],"isOffline":true}]
    """

    static let ordersJSON = """
    [{"id":"ORD-1","material":"PLA+ 2.0","printTime":6,"status":"pending",
      "dueDate":"2026-09-09","priorityLevel":"urgent"},
     {"id":"ORD-2","material":"PA-CF","printTime":14,"status":"pending",
      "dueDate":"2026-09-12","priorityLevel":"normal"},
     {"id":"ORD-3","material":"PETG","printTime":9,"status":"pending",
      "dueDate":"2026-09-10","priorityLevel":"high"},
     {"id":"ORD-4","material":"Resin","printTime":8,"status":"pending",
      "dueDate":"2026-09-11","priorityLevel":"normal"}]
    """

    static func decoded(_ json: String) throws -> [JSONValue] {
        guard case .array(let rows) = try JSONDecoder()
            .decode(JSONValue.self, from: Data(json.utf8)) else {
            throw KhaytJSError.evaluationFailed("fixture is not an array")
        }
        return rows
    }

    @Test("the Mac proposes exactly what Node proposes")
    func agreesWithNode() async throws {
        let engine = try KhaytEngine()
        let plan = try await engine.proposeSchedule(machines: Self.decoded(Self.machinesJSON),
                                                    orders: Self.decoded(Self.ordersJSON),
                                                    now: Self.now)

        let ms = Int(Self.now.timeIntervalSince1970 * 1000)
        let fromNode = try Self.node(
            "S.proposeSchedule(\(Self.machinesJSON), \(Self.ordersJSON), { now: \(ms) })")

        // Compare the whole shape, field by field, rather than a count.
        guard case .object(let root) = fromNode,
              case .array(let nodeAssign)? = root["assignments"],
              case .array(let nodeUnplaced)? = root["unassignable"] else {
            Issue.record("node returned something that is not a proposal"); return
        }

        #expect(plan.assignments.count == nodeAssign.count)
        for (mine, theirs) in zip(plan.assignments, nodeAssign) {
            guard case .object(let t) = theirs else { continue }
            #expect(JSONValue.string(mine.orderId) == t["orderId"])
            #expect(JSONValue.string(mine.machineId) == t["machineId"])
            if case .number(let p)? = t["position"] { #expect(Int(p) == mine.position) }
            if case .number(let f)? = t["projectedFinishMins"] {
                #expect(abs(f - mine.projectedFinishMins) < 0.0001)
            }
            if case .string(let r)? = t["reason"] { #expect(r == mine.reason) }
        }
        #expect(plan.unassignable.count == nodeUnplaced.count)
        for (mine, theirs) in zip(plan.unassignable, nodeUnplaced) {
            guard case .object(let t) = theirs else { continue }
            #expect(JSONValue.string(mine.orderId) == t["orderId"])
        }
    }

    /// THE PART EQUALITY CANNOT PROVE.
    ///
    /// A bridge that returned `{assignments: [], unassignable: []}` for every
    /// input would pass the comparison above against a Node call that did the
    /// same. These assert the proposal is a real one: work was placed, the
    /// offline machine took none of it, and the material nothing can print was
    /// refused rather than dropped.
    @Test("it actually places work, and the hard filters bite")
    func theProposalIsReal() async throws {
        let engine = try KhaytEngine()
        let plan = try await engine.proposeSchedule(machines: Self.decoded(Self.machinesJSON),
                                                    orders: Self.decoded(Self.ordersJSON),
                                                    now: Self.now)

        #expect(plan.assignments.count == 3, "three of the four are printable")
        #expect(!plan.assignments.contains { $0.machineId == "MACH-off" },
                "an offline printer was given work")
        #expect(plan.assignments.allSatisfy { !($0.reason ?? "").isEmpty },
                "a proposal with no reason cannot be reviewed")

        // PA-CF fits only the X1C; the U1 cannot take it.
        let paCF = plan.assignments.first { $0.orderId == "ORD-2" }
        #expect(paCF?.machineId == "MACH-x1c")

        // Resin fits nothing here, and must be reported rather than silently lost.
        #expect(plan.unassignable.map(\.orderId) == ["ORD-4"])
        let why = plan.unassignable.first?.reason ?? ""
        #expect(why.isEmpty == false, "the resin job was refused without saying why")
    }

    /// `now` is an argument, so the same book an hour later is the same plan.
    @Test("the proposal does not drift with the wall clock")
    func deterministic() async throws {
        let engine = try KhaytEngine()
        let a = try await engine.proposeSchedule(machines: Self.decoded(Self.machinesJSON),
                                                 orders: Self.decoded(Self.ordersJSON), now: Self.now)
        let b = try await engine.proposeSchedule(machines: Self.decoded(Self.machinesJSON),
                                                 orders: Self.decoded(Self.ordersJSON), now: Self.now)
        #expect(a.assignments.map(\.machineId) == b.assignments.map(\.machineId))
        #expect(a.assignments.map(\.position) == b.assignments.map(\.position))
    }
}
