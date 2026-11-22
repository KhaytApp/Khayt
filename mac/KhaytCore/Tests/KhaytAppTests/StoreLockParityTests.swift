import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Swift and `lib/store-lock.js` must agree about who owns a shop's book.
///
/// This is a protocol between two applications, so "both implementations read
/// the same rules the same way" is the whole property. A disagreement does not
/// show up as an error — it shows up as two writers on one file, which is the
/// failure the lock exists to prevent.
struct StoreLockParityTests {

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func node(_ expression: String) throws -> JSONValue {
        let script = """
        const L = require('./lib/store-lock.js');
        process.stdout.write(JSON.stringify(\(expression)));
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", script]
        process.currentDirectoryURL = repoRoot
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let problem = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.node(String(data: problem, encoding: .utf8) ?? "node failed")
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    enum Failure: Error { case node(String) }

    /// now = 1_000_000. Every case is written as the JS object literal so both
    /// sides are handed the identical record, rather than one built twice.
    struct Case {
        let name: String
        let record: String          // JS literal, or "null"
        let pid: Int
        let host: String
        let alive: String           // "true" | "false" | "null"
    }

    static let now: Double = 1_000_000

    static let cases: [Case] = [
        .init(name: "no lock at all", record: "null", pid: 7, host: "mac", alive: "null"),
        .init(name: "a file that is not a lock record",
              record: "{v:1}", pid: 7, host: "mac", alive: "null"),
        .init(name: "a pid of zero is not a holder",
              record: "{pid:0,host:'mac',heartbeat:1000000}", pid: 7, host: "mac", alive: "null"),
        .init(name: "our own record",
              record: "{app:'Khayt',pid:7,host:'mac',heartbeat:1000000}", pid: 7, host: "mac", alive: "null"),
        .init(name: "same pid, different machine, is a different process",
              record: "{app:'Khayt',pid:7,host:'other',heartbeat:1000000}", pid: 7, host: "mac", alive: "true"),
        .init(name: "a living holder keeps it however old the heartbeat",
              record: "{app:'Khayt',pid:9,host:'mac',heartbeat:0}", pid: 7, host: "mac", alive: "true"),
        .init(name: "a dead holder releases it however fresh the heartbeat",
              record: "{app:'Khayt',pid:9,host:'mac',heartbeat:1000000}", pid: 7, host: "mac", alive: "false"),
        .init(name: "another machine, fresh, is held",
              record: "{app:'Khayt',pid:9,host:'nas',heartbeat:999000}", pid: 7, host: "mac", alive: "null"),
        .init(name: "another machine, stale, is free",
              record: "{app:'Khayt',pid:9,host:'nas',heartbeat:100}", pid: 7, host: "mac", alive: "null"),
        .init(name: "a heartbeat from the future is not stale",
              record: "{app:'Khayt',pid:9,host:'nas',heartbeat:1060000}", pid: 7, host: "mac", alive: "null"),
        .init(name: "unknowable on this machine, fresh",
              record: "{app:'Khayt',pid:9,host:'mac',heartbeat:999000}", pid: 7, host: "mac", alive: "null"),
        .init(name: "unknowable on this machine, stale",
              record: "{app:'Khayt',pid:9,host:'mac',heartbeat:100}", pid: 7, host: "mac", alive: "null"),
        .init(name: "a record with no host at all",
              record: "{app:'Khayt',pid:9,heartbeat:1000000}", pid: 7, host: "mac", alive: "false"),
        // The divergence that started this: two runtimes, one machine, two
        // spellings. Both sides must fold before comparing.
        .init(name: "same machine, different case",
              record: "{app:'Khayt',pid:9,host:'Turkis-MacBook-Air.local',heartbeat:0}",
              pid: 7, host: "turkis-macbook-air.local", alive: "true"),
        .init(name: "our own record, different case",
              record: "{app:'Khayt',pid:7,host:'Turkis-MacBook-Air.local',heartbeat:0}",
              pid: 7, host: "TURKIS-macbook-air.LOCAL", alive: "null"),
        .init(name: "exactly on the staleness boundary",
              record: "{app:'Khayt',pid:9,host:'nas',heartbeat:910000}", pid: 7, host: "mac", alive: "null"),
    ]

    static func swiftRecord(_ literal: String) throws -> StoreLock.Record? {
        guard literal != "null" else { return nil }
        // Read the literal through Node so the Swift side is handed exactly what
        // the JS side parsed, rather than a second hand-written copy of it.
        let json = try node("(\(literal))")
        let data = try JSONEncoder().encode(json)
        return try JSONDecoder().decode(StoreLock.Record.self, from: data)
    }

    @Test("Swift and lib/store-lock.js reach the same verdict")
    func verdictsMatch() throws {
        for c in Self.cases {
            let expr = "L.decide(\(c.record), {pid:\(c.pid), host:'\(c.host)', now:\(Int(Self.now)), alive:\(c.alive)})"
            let fromNode = try Self.node("({action: \(expr).action, reason: \(expr).reason})")

            let alive: Bool? = c.alive == "true" ? true : (c.alive == "false" ? false : nil)
            let mine = StoreLock.decide(try Self.swiftRecord(c.record),
                                        pid: c.pid, host: c.host, now: Self.now, alive: alive)
            let fromSwift = JSONValue.object([
                "action": .string(mine.action.rawValue),
                "reason": .string(mine.reason),
            ])
            #expect(fromSwift == fromNode, """
                \(c.name)
                  record: \(c.record)  self: pid \(c.pid) on \(c.host), alive=\(c.alive)
                  Node:  \(fromNode)
                  Swift: \(fromSwift)
                """)
        }
    }

    @Test("both sides agree on how long is too long")
    func staleWindowMatches() throws {
        let fromNode = try Self.node("L.STALE_AFTER_MS")
        #expect(fromNode == .number(StoreLock.staleAfterMs))
    }

    @Test("both sides look for the same file")
    func filenameMatches() throws {
        let fromNode = try Self.node("L.LOCK_FILENAME")
        #expect(fromNode == .string(StoreLock.filename))
    }
}
