import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Which `cmd-printer` events a Mac runs: opened with the shop key, fresh,
/// a known verb, and once per command id, so a replayed event never stops a
/// second print.
@MainActor
struct CloudPrinterCommandsTests {
    static let dek = Data(repeating: 7, count: 32)
    static let now = Date(timeIntervalSince1970: 1_793_000_000)

    static func stamp(_ secondsAgo: TimeInterval) -> String {
        ShopEventPublisher.stamp(now.addingTimeInterval(-secondsAgo))
    }

    static func event(_ id: String, verb: String = "pause", machine: String = "M1",
                      ago: TimeInterval = 10, saidAgo: TimeInterval? = nil, kind: String = "cmd-printer",
                      key: Data = dek) throws -> CloudPrinterCommands.Event {
        let payload: [String: JSONValue] = ["id": .string(id), "machineId": .string(machine),
                                            "verb": .string(verb), "at": .string(stamp(saidAgo ?? ago))]
        let blob = try SyncCrypto.seal(payload, dek: key)
        return .init(id: "ev-" + id, kind: kind, at: stamp(ago), ciphertext: blob)
    }

    @Test("a fresh command runs, with stop meaning cancel")
    func fresh() throws {
        let run = CloudPrinterCommands.commands(
            [try Self.event("c1"), try Self.event("c2", verb: "stop", machine: "M2"), try Self.event("c3", verb: "resume")],
            dek: Self.dek, now: Self.now, handled: [])
        #expect(run == [.init(id: "c1", machineId: "M1", verb: .pause),
                        .init(id: "c2", machineId: "M2", verb: .cancel),
                        .init(id: "c3", machineId: "M1", verb: .resume)])
    }

    @Test("stale, from the future, or stamped stale by the phone: not run")
    func staleness() throws {
        let events = [try Self.event("old", ago: 121),
                      try Self.event("ahead", ago: -31),
                      try Self.event("phone-old", ago: 5, saidAgo: 600),
                      try Self.event("edge", ago: 119)]
        let run = CloudPrinterCommands.commands(events, dek: Self.dek, now: Self.now, handled: [])
        #expect(run.map(\.id) == ["edge"])
    }

    @Test("once per id: already handled, or twice in one page, runs once")
    func dedupe() throws {
        let twice = [try Self.event("c1"), try Self.event("c1", verb: "stop")]
        #expect(CloudPrinterCommands.commands(twice, dek: Self.dek, now: Self.now, handled: []).map(\.id) == ["c1"])
        #expect(CloudPrinterCommands.commands([try Self.event("c1")], dek: Self.dek, now: Self.now,
                                              handled: ["c1"]).isEmpty)
    }

    @Test("another key, another kind, or an unknown verb: nothing")
    func refusals() throws {
        let events = [try Self.event("k", key: Data(repeating: 9, count: 32)),
                      try Self.event("r", kind: "cmd-result"),
                      try Self.event("p", kind: "print-finished"),
                      try Self.event("x", verb: "explode"),
                      CloudPrinterCommands.Event(id: "e", kind: "cmd-printer", at: Self.stamp(5), ciphertext: nil)]
        #expect(CloudPrinterCommands.commands(events, dek: Self.dek, now: Self.now, handled: []).isEmpty)
    }

    @Test("the ids already handled outlive a restart")
    @MainActor func handledSurvivesRestart() throws {
        let suite = "khayt.test.cloudcmd.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["c1": Self.now.timeIntervalSince1970], forKey: CloudPrinterCommands.handledKey)
        let restarted = CloudPrinterCommands(defaults: defaults)
        #expect(Set(restarted.handled.keys) == ["c1"])
        #expect(CloudPrinterCommands.commands([try Self.event("c1", verb: "stop")], dek: Self.dek, now: Self.now,
                                              handled: Set(restarted.handled.keys)).isEmpty)
    }
}
