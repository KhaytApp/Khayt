import Foundation

/// The live snapshot's rules (`lib/live-snapshot.js`), asked rather than
/// written again: this Mac and the Windows/Linux app publish to ONE slot per
/// shop, so what they send and when must be one rule. Swift had its own copy
/// of `signature`, `due` and `cloudRow` until Nov 2026.
extension KhaytEngine {

    /// The plaintexts to try, in order: `{ v: 1, at, printers }` whole, then
    /// with `filename` and `error` dropped (the contract's order for an
    /// envelope over the size line). Rows are the cloud's: `lastUpdated` and
    /// `lastOkAt` in epoch milliseconds.
    public func liveSnapshots(rows: [JSONValue], at: String) throws -> [[String: JSONValue]] {
        try runtime.call2("""
            (function (rows, at) {
              var L = globalThis.KhaytLiveSnapshot;
              return [L.snapshot(rows, at), L.snapshot(rows.map(L.slim), at)];
            })(ARG0, ARG1)
            """, [.array(rows), .string(at)], as: [[String: JSONValue]].self)
    }

    /// What is compared to decide "changed": the rows without the two stamps
    /// that move on every poll.
    public func liveSignature(rows: [JSONValue]) throws -> String {
        try runtime.call2("globalThis.KhaytLiveSnapshot.signature(ARG0)", [.array(rows)], as: String.self)
    }

    /// Send now? On a change after 2 s, else every heartbeat, never before `notBefore`.
    public func liveDue(changed: Bool, now: Date, lastSent: Date?, notBefore: Date?) throws -> Bool {
        func ms(_ d: Date?) -> JSONValue { d.map { .number(($0.timeIntervalSince1970 * 1000).rounded()) } ?? .null }
        return try runtime.call2("globalThis.KhaytLiveSnapshot.due({ changed: ARG0, now: ARG1, lastSent: ARG2, notBefore: ARG3 })",
                                 [.bool(changed), ms(now), ms(lastSent), ms(notBefore)], as: Bool.self)
    }

    /// Has this computer heard from at least one printer in the last three
    /// minutes? Only then may it publish: the cloud keeps one snapshot per
    /// shop, and a Mac that cannot reach the printers would replace the shop
    /// computer's real picture with "not heard".
    public func liveHasFreshPoll(rows: [JSONValue], now: Date) throws -> Bool {
        try runtime.call2("globalThis.KhaytLiveSnapshot.hasFreshPoll(ARG0, ARG1)",
                          [.array(rows), .number((now.timeIntervalSince1970 * 1000).rounded())], as: Bool.self)
    }

    /// The longest a 429's retry-after is honoured, in seconds.
    public func liveMaxRetryAfter() throws -> Double {
        try runtime.call2("globalThis.KhaytLiveSnapshot.MAX_RETRY_AFTER_MS / 1000", [], as: Double.self)
    }
}
