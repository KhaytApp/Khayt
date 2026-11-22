import Foundation
import Testing
@testable import KhaytCore

/// The date this shop publishes for a storefront to quote must be the date
/// Khayt would have published from the same book.
///
/// A wrong argument name here does not fail. `buildSnapshot` reads an options
/// object, so `printLog:` misspelled is an empty queue — and an empty queue
/// produces a *shorter*, entirely plausible promise that no screen contradicts.
/// The shop finds out when a customer does.
///
/// So every case below is compared against Node running the same two modules on
/// the same JSON, and the ones that matter are also checked to DIFFER from the
/// empty-queue answer. Equality alone would pass for a bridge wired to nothing.
struct LeadTimeParityTests {

    static var repoRoot: URL { BundledLogicIsNotAForkTests.repoRoot }

    static func node(_ expression: String) throws -> JSONValue {
        let script = """
        require('./lib/attention.js'); require('./lib/lead-time.js');
        const P = require('./lib/lead-time-publish.js');
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

    // MARK: - One book, in both languages

    static let today = "2026-09-05"
    static let nowIso = "2026-09-05T09:00:00Z"

    /// `leadTime` as this shop actually has it, publishing turned on.
    static let settings: [String: JSONValue] = [
        "leadTime": .object([
            "publishToCloud": .bool(true), "dailyHours": .number(8),
            "workingDaysPerWeek": .number(5), "finishingDays": .number(1),
            "dispatchDays": .number(1), "safetyDays": .number(1),
        ]),
    ]

    /// Two machines and a queue heavy enough that dropping it changes the date.
    static let machines: [JSONValue] = [
        .object(["id": .string("m1"), "name": .string("U1")]),
        .object(["id": .string("m2"), "name": .string("Second")]),
    ]

    static let printLog: [JSONValue] = [
        .object(["id": .string("o1"), "status": .string("queued"),
                 "printTime": .number(30), "machineId": .string("m1")]),
        .object(["id": .string("o2"), "status": .string("printing"),
                 "printTime": .number(20), "machineId": .string("m1")]),
        // Unassigned work still has to land somewhere.
        .object(["id": .string("o3"), "status": .string("pending"), "printTime": .number(12)]),
        // Settled work is not work.
        .object(["id": .string("o4"), "status": .string("delivered"),
                 "printTime": .number(99), "machineId": .string("m2")]),
    ]

    /// `m2` is mid-print with four hours to go, from a job no order knows about.
    static let statusCache: [String: JSONValue] = [
        "m2": .object(["state": .string("printing"), "progress": .number(40),
                       "filename": .string("helmet.gcode"),
                       "timeRemaining": .number(4 * 3600),
                       "lastUpdated": .number(1_788_642_000_000)]),
    ]

    static func jsLiteral(_ value: JSONValue) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    static func nodeSnapshot(settings: [String: JSONValue] = settings,
                             printLog: [JSONValue] = printLog,
                             machines: [JSONValue] = machines,
                             statusCache: [String: JSONValue] = statusCache) throws -> JSONValue {
        try node("P.buildSnapshot({settings: \(jsLiteral(.object(settings)))"
               + ", printLog: \(jsLiteral(.array(printLog)))"
               + ", machines: \(jsLiteral(.array(machines)))"
               + ", statusCache: \(jsLiteral(.object(statusCache)))"
               + ", today: '\(today)', nowIso: '\(nowIso)'})")
    }

    // MARK: - The tests

    @Test("the Mac publishes the snapshot Node builds from the same book")
    func matchesNode() async throws {
        let engine = try KhaytEngine()
        let mine = try await engine.leadTimeSnapshot(settings: Self.settings, printLog: Self.printLog,
                                               machines: Self.machines, today: Self.today,
                                               nowIso: Self.nowIso, statusCache: Self.statusCache)
        #expect(mine == (try Self.nodeSnapshot()))
        #expect(mine != nil)
    }

    /// The one that catches a bridge wired to nothing.
    ///
    /// If `printLog` never reaches the module, this app publishes the promise of
    /// a shop with an empty queue — which is a real date, in the right shape,
    /// and shorter than the truth.
    @Test("the queue reaches the module — an empty book promises something else")
    func theQueueIsActuallyRead() async throws {
        let engine = try KhaytEngine()
        let full = try await engine.leadTimeSnapshot(settings: Self.settings, printLog: Self.printLog,
                                               machines: Self.machines, today: Self.today,
                                               nowIso: Self.nowIso, statusCache: Self.statusCache)
        let empty = try await engine.leadTimeSnapshot(settings: Self.settings, printLog: [],
                                                machines: Self.machines, today: Self.today,
                                                nowIso: Self.nowIso, statusCache: [:])
        #expect(full != empty)
        #expect(empty == (try Self.nodeSnapshot(printLog: [], statusCache: [:])))
    }

    /// A machine printing something the order book never heard of.
    ///
    /// This is the field `PrinterWatch.statusCache` did not carry. Without
    /// `timeRemaining` the lane is dropped as "busy, duration unknown"; with it
    /// the hours count. Both are legitimate answers and they are different ones,
    /// which is exactly why the cache must pass the number through.
    @Test("what the printers are doing changes the promise")
    func inFlightWorkCounts() async throws {
        let engine = try KhaytEngine()
        let withCache = try await engine.leadTimeSnapshot(settings: Self.settings, printLog: Self.printLog,
                                                    machines: Self.machines, today: Self.today,
                                                    nowIso: Self.nowIso, statusCache: Self.statusCache)
        let blind = try await engine.leadTimeSnapshot(settings: Self.settings, printLog: Self.printLog,
                                                machines: Self.machines, today: Self.today,
                                                nowIso: Self.nowIso, statusCache: [:])
        #expect(withCache != blind)
        #expect(blind == (try Self.nodeSnapshot(statusCache: [:])))

        // And with the state but no estimate, the lane goes out of the shop's
        // capacity rather than counting as free.
        let unknown: [String: JSONValue] = [
            "m2": .object(["state": .string("printing"), "progress": .number(1),
                           "filename": .string("helmet.gcode"),
                           "lastUpdated": .number(1_788_642_000_000)]),
        ]
        let occupied = try await engine.leadTimeSnapshot(settings: Self.settings, printLog: Self.printLog,
                                                   machines: Self.machines, today: Self.today,
                                                   nowIso: Self.nowIso, statusCache: unknown)
        #expect(occupied == (try Self.nodeSnapshot(statusCache: unknown)))
    }

    @Test("a shop that has not asked for this publishes nothing")
    func offMeansNil() async throws {
        let engine = try KhaytEngine()
        let off: [String: JSONValue] = ["leadTime": .object(["publishToCloud": .bool(false)])]
        #expect(try await engine.leadTimeSnapshot(settings: off, printLog: Self.printLog,
                                            machines: Self.machines, today: Self.today,
                                            nowIso: Self.nowIso) == nil)
        // …and a book with no leadTime block at all, which is most shops.
        #expect(try await engine.leadTimeSnapshot(settings: [:], printLog: Self.printLog,
                                            machines: Self.machines, today: Self.today,
                                            nowIso: Self.nowIso) == nil)
    }
}
