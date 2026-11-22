import Foundation

/// The background poll steps aside while a PERSON's command is on its way to
/// a printer (C6, `lib/poll-yield.js`). One instance lives in the runtime, as
/// the rule asks ("one instance per app"); the clock is handed in.
extension KhaytEngine {

    /// A command's token: the generation it was sent in. A reply that comes
    /// after a force-release ends nothing.
    public struct PollYieldToken: Decodable, Sendable, Equatable {
        public let id: String
        public let gen: Int
    }

    private static let instance = "(globalThis.__khaytPollYield || (globalThis.__khaytPollYield = KhaytPollYield.createPollYield()))"

    private func ms(_ now: Date) -> JSONValue { .number((now.timeIntervalSince1970 * 1000).rounded()) }

    /// A command to this printer is sent.
    public func pollYieldBegin(_ id: String, now: Date = Date()) throws -> PollYieldToken? {
        try runtime.call2("(\(Self.instance).begin(ARG0, ARG1) || null)", [.string(id), ms(now)], as: PollYieldToken?.self)
    }

    /// Its reply came, or it failed.
    public func pollYieldEnd(_ id: String, token: PollYieldToken?, now: Date = Date()) throws {
        let t: JSONValue = token.map { .object(["id": .string($0.id), "gen": .number(Double($0.gen))]) } ?? .null
        _ = try runtime.call2("(\(Self.instance).end(ARG0, ARG1, ARG2 || undefined), true)", [.string(id), ms(now), t], as: Bool.self)
    }

    /// Whether the poll should leave this printer alone now, and how many
    /// commands it has been sent: a poll reads `seq` before it asks and drops
    /// what it heard when either says a command went out meanwhile.
    public struct PollYieldState: Decodable, Sendable, Equatable {
        public let yielding: Bool
        public let seq: Int
        public let justSettled: Bool
    }

    public func pollYieldState(_ id: String, now: Date = Date()) throws -> PollYieldState {
        try runtime.call2("""
            (function (id, now) { var y = \(Self.instance);
              return { yielding: y.yielding(id, now), seq: y.seq(id), justSettled: y.justSettled(id, now) }; })(ARG0, ARG1)
            """, [.string(id), ms(now)], as: PollYieldState.self)
    }
}
