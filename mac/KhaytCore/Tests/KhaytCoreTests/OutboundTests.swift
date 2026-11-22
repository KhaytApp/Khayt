import Foundation
import Testing
@testable import KhaytCore

/// "Make no internet calls" on the Mac and the phone: the shared rule
/// (`lib/outbound.js`) through the engine, the gate every call site asks
/// (`OutboundGate`), and the Swift purpose list held equal to the rule's.
@Suite struct OutboundTests {

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static func obj(_ v: JSONValue?) -> [String: JSONValue] { if case .object(let o)? = v { return o }; return [:] }

    @Test("the shared vectors, through the engine, exactly as given")
    func vectors() async throws {
        let v = Self.obj(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: Self.root.appending(path: "test/fixtures/outbound-vectors.json"))))
        guard case .array(let cases)? = v["cases"] else { Issue.record("no cases"); return }
        #expect(cases.count >= 92)
        let engine = try KhaytEngine()
        var answered = 0, once = 0
        for value in cases {
            let c = Self.obj(value)
            let why: Comment = { if case .string(let s)? = c["why"] { return Comment(rawValue: s) }; return "?" }()
            let got = Self.obj(try await engine.outboundAllowed(settings: c["settings"] ?? .null, purpose: c["purpose"] ?? .null,
                                                               ctx: c["ctx"] ?? .null))
            let want = Self.obj(c["want"])
            #expect(got["allowed"] == want["allowed"], why)
            #expect(got["reason"] == want["reason"], why)
            // A person's answer (`ctx.answer`): `once` is said only for an
            // allowed switch-sync call, and never without an answer.
            let hasAnswer = Self.obj(c["ctx"])["answer"] != nil
            if hasAnswer { answered += 1 }
            if got["once"] == .bool(true) {
                once += 1
                #expect(hasAnswer && got["allowed"] == .bool(true) && c["purpose"] == .string("switch-sync"), why)
            }
        }
        #expect(answered >= 12, "the answer-token cases are in the shared file")
        #expect(once >= 1 && once < answered, "some answers let the one call through, and the dead ones do not")
        guard case .array(let purposes)? = v["purposes"] else { Issue.record("no purposes"); return }
        #expect(purposes == (try await engine.outboundPurposes()).map(JSONValue.string))
    }

    @Test("the Swift purposes are the rule's, in the rule's order, and the gate's own copy of the rule agrees")
    func purposesAreTheRules() async throws {
        let engine = try KhaytEngine()
        let rule = try await engine.outboundPurposes()
        #expect(OutboundPurpose.allCases.map(\.rawValue) == rule)
        #expect(OutboundGate().rulePurposes() == rule, "the gate loads the same file")
        #expect(rule.contains("storefront") && rule.contains("tunnel") && rule.last == "lan")
    }

    static func offline(keep: [String] = []) -> JSONValue {
        .object(["network": .object(["offline": .bool(true), "keep": .array(keep.map(JSONValue.string))])])
    }

    @Test("until the book is read, everything but the shop's own network waits")
    func unreadWaits() throws {
        let gate = OutboundGate()
        #expect(gate.currentBook == .none, "a process that was told nothing has no book")
        gate.update(book: .unread)
        for purpose in OutboundPurpose.allCases where purpose != .lan {
            #expect(gate.verdict(purpose) == .init(allowed: false, reason: "settings-unknown"), Comment(rawValue: purpose.rawValue))
        }
        // A printer on the shop's network is still polled; one that leads outside is not.
        #expect(gate.verdict(.lan, host: "192.168.1.40").allowed)
        #expect(gate.verdict(.lan, host: "http://192.168.1.40:7125").allowed)
        #expect(gate.verdict(.lan, host: "printer.example.com") == .init(allowed: false, reason: "lan-host-public"))
        #expect(gate.verdict(.lan) == .init(allowed: false, reason: "lan-host-missing"))
    }

    @Test("no book at all is today's behaviour; the shop's switch blocks; a kept purpose goes through")
    func bookStates() throws {
        let gate = OutboundGate()
        gate.update(book: .none)
        #expect(gate.verdict(.cloud) == .init(allowed: true, reason: "ok"))
        #expect(gate.verdict(.lan, host: "printer.example.com").allowed, "online, an address is the shop's business")
        #expect(!gate.isOffline)
        gate.update(book: .settings(Self.offline(keep: ["storage"])))
        #expect(gate.isOffline)
        #expect(gate.verdict(.cloud) == .init(allowed: false, reason: "offline"))
        #expect(gate.verdict(.storage) == .init(allowed: true, reason: "kept"))
        #expect(gate.verdict(.updates).reason == "offline")
        #expect(gate.verdict(.lan, host: "10.0.0.5").allowed && !gate.verdict(.lan, host: "8.8.8.8").allowed)
        // Its own switch still says no for a kept purpose that was never opted in to.
        gate.update(book: .settings(Self.offline(keep: ["crash-reports"])))
        #expect(gate.verdict(.crashReports).reason == "opted-out")
    }

    @Test("this Mac can be stricter than the shop, never looser")
    func localOnlyTakesAway() throws {
        let gate = OutboundGate()
        gate.update(book: .settings(.object([:])))
        gate.update(local: .init(offline: true))
        #expect(gate.verdict(.cloud) == .init(allowed: false, reason: "offline-here"))
        #expect(gate.isOffline)
        // Keeping a purpose in the shop's book does not get past this Mac's own switch.
        gate.update(book: .settings(Self.offline(keep: ["cloud"])))
        #expect(gate.verdict(.cloud).reason == "offline-here")
        // This Mac off, the shop on: the shop's switch holds.
        gate.update(local: .init(offline: false))
        gate.update(book: .settings(Self.offline()))
        #expect(gate.verdict(.cloud).reason == "offline")
        gate.update(book: .settings(.object([:])))
        gate.update(local: .init(installCountOff: true))
        #expect(gate.verdict(.installCount).reason == "opted-out")
        #expect(gate.verdict(.cloud).allowed)
    }

    @Test("a refused call throws one distinct error and is counted on its purpose; an allowed one is not")
    func requireCounts() throws {
        let clock = Clock()
        let gate = OutboundGate(clock: { clock.now })
        gate.update(book: .settings(Self.offline()))
        #expect(throws: OutboundBlocked(purpose: .cloud, reason: "offline")) { try gate.require(.cloud) }
        clock.now = clock.now.addingTimeInterval(60)
        #expect(!gate.allows(.cloud))
        #expect(gate.blocked(.cloud) == .init(count: 2, last: clock.now))
        #expect(gate.blocked(.updates) == nil)
        #expect(throws: OutboundBlocked(purpose: .lan, reason: "lan-host-public", host: "ntfy.example.com")) {
            try gate.require(.lan, url: URL(string: "https://ntfy.example.com/shop")!)
        }
        try gate.require(.lan, url: URL(string: "http://192.168.1.40:7125/printer/info")!)
        #expect(gate.blocked(.lan)?.count == 1)
        // Asking for a screen does not count.
        _ = gate.verdict(.updates)
        _ = gate.rows()
        #expect(gate.blocked(.updates) == nil)
        gate.clearCounts()
        #expect(gate.blockedCounts().isEmpty)
        gate.update(book: .settings(.object([:])))
        try gate.require(.cloud)
        #expect(gate.blocked(.cloud) == nil)
    }

    final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_800_000_000) }

    @Test("the rows are the rule's describe(): one per purpose, in order, with kept and automatic")
    func rows() throws {
        let gate = OutboundGate()
        gate.update(book: .settings(Self.offline(keep: ["storage"])))
        let rows = gate.rows()
        #expect(rows.map(\.purpose) == OutboundPurpose.allCases.map(\.rawValue))
        let storage = try #require(rows.first { $0.purpose == "storage" })
        #expect(storage.kept && storage.allowed && storage.reason == "kept" && storage.automatic)
        let ai = try #require(rows.first { $0.purpose == "ai" })
        #expect(!ai.kept && !ai.allowed && ai.reason == "offline" && !ai.automatic)
        #expect(rows.last?.purpose == "lan" && rows.last?.allowed == true)
    }

    @Test("a switch stored as anything but false is ON: a bad value never fails open")
    func oddValuesFailClosed() throws {
        let gate = OutboundGate()
        for odd in [JSONValue.string("true"), .number(1), .object([:]), .string("false"), .number(0)] {
            gate.update(book: .settings(.object(["network": .object(["offline": odd])])))
            #expect(gate.isOffline, Comment(rawValue: "\(odd)"))
            #expect(!gate.verdict(.cloud).allowed, Comment(rawValue: "\(odd)"))
        }
        gate.update(book: .settings(.object(["network": .object(["offline": .bool(false)])])))
        #expect(!gate.isOffline)
    }

    @Test("asked from many threads at once, the gate answers every one")
    func concurrent() async throws {
        let gate = OutboundGate()
        gate.update(book: .settings(Self.offline()))
        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<200 {
                group.addTask { i % 2 == 0 ? gate.allows(.cloud) : gate.verdict(.lan, host: "192.168.1.\(i % 250)").allowed }
            }
            var refused = 0, lan = 0
            var n = 0
            for await answer in group { if n % 1 == 0 { if answer { lan += 1 } else { refused += 1 } }; n += 1 }
            #expect(refused == 100 && lan == 100)
        }
        #expect(gate.blocked(.cloud)?.count == 100)
    }
}
