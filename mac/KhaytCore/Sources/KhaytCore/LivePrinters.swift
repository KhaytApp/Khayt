import Foundation

/// The printers' live status, as this Mac publishes it to Khayt Cloud for the
/// phone and the PWA to read away from the shop — khayt-cloud
/// `docs/api-contract.md`, "Live channel & live printers" (Sep 2026).
///
/// Pure: the snapshot, the envelope and WHEN to send are decided here; the
/// socket is the caller's.
public enum LivePrinters {
    /// The serialised envelope must stay under this (the server's 413 line).
    public static let maxCiphertext = 65_536
    /// The server refuses a second snapshot inside 2 s (429).
    public static let minInterval: TimeInterval = 2
    /// With nothing changed, a heartbeat this often keeps `receivedAt` fresh,
    /// so a viewer can tell "idle" from "the Mac is off" (contract: 30–60 s).
    public static let heartbeat: TimeInterval = 45

    /// The plaintext: `{ v: 1, at, printers }`. Each row is the LAN API's
    /// `/api/machines/live` row, with `lastUpdated` as epoch MILLISECONDS —
    /// the cloud contract's unit, not the LAN API's ISO string.
    public static func snapshot(rows: [JSONValue], at: String) -> [String: JSONValue] {
        ["v": .number(1), "at": .string(at), "printers": .array(rows.map(cloudRow))]
    }

    static func cloudRow(_ row: JSONValue) -> JSONValue {
        guard case .object(var o) = row else { return row }
        if case .string(let iso)? = o["lastUpdated"] {
            o["lastUpdated"] = epochMs(iso).map { .number($0) } ?? .null
        }
        return .object(o)
    }

    static func epochMs(_ iso: String) -> Double? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return (d.timeIntervalSince1970 * 1000).rounded() }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso).map { ($0.timeIntervalSince1970 * 1000).rounded() }
    }

    /// The request body, `{ ciphertext, at }`, sealed under the shop's DEK. Over
    /// the size line, `filename` and `error` go first — the contract's order —
    /// and nil comes back only when even that does not fit.
    public static func body(rows: [JSONValue], at: String, dek: Data) throws -> Data? {
        for trimmed in [false, true] {
            let used = trimmed ? rows.map(slim) : rows
            let blob = try SyncCrypto.seal(snapshot(rows: used, at: at), dek: dek)
            let cipher = try JSONEncoder().encode(blob)
            guard cipher.count <= maxCiphertext else { continue }
            let envelope: [String: Any] = [
                "ciphertext": try JSONSerialization.jsonObject(with: cipher), "at": at,
            ]
            return try JSONSerialization.data(withJSONObject: envelope)
        }
        return nil
    }

    static func slim(_ row: JSONValue) -> JSONValue {
        guard case .object(var o) = row else { return row }
        o["filename"] = .null
        o["error"] = .null
        return .object(o)
    }

    /// What is compared to decide "changed": everything but `lastUpdated`,
    /// which moves on every poll and would otherwise mean a snapshot every
    /// two seconds while nothing a person could see had changed.
    public static func signature(_ rows: [JSONValue]) -> [JSONValue] {
        rows.map { row in
            guard case .object(var o) = row else { return row }
            o.removeValue(forKey: "lastUpdated")
            return .object(o)
        }
    }

    /// Send now? On a change once 2 s have passed since the last accepted
    /// snapshot; with no change, every `heartbeat`; never before `notBefore`
    /// (a 429's Retry-After).
    public static func due(changed: Bool, now: Date, lastSent: Date?, notBefore: Date?) -> Bool {
        if let notBefore, now < notBefore { return false }
        guard let lastSent else { return true }
        let gap = now.timeIntervalSince(lastSent)
        return changed ? gap >= minInterval : gap >= heartbeat
    }
}
