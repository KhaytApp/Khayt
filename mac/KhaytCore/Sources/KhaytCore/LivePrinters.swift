import Foundation

/// The printers' live status, as this Mac publishes it to Khayt Cloud for the
/// phone and the PWA to read away from the shop — khayt-cloud
/// `docs/api-contract.md`, "Live channel & live printers" (Sep 2026).
///
/// The envelope is sealed here; the snapshot's rules are the shared lib's
/// (`lib/live-snapshot.js`), and the socket is the caller's.
public enum LivePrinters {
    /// The serialised envelope must stay under this (the server's 413 line).
    public static let maxCiphertext = 65_536
    /// The server refuses a second snapshot inside 2 s (429).
    public static let minInterval: TimeInterval = 2
    /// With nothing changed, a heartbeat this often keeps `receivedAt` fresh,
    /// so a viewer can tell "idle" from "the Mac is off" (contract: 30–60 s).
    public static let heartbeat: TimeInterval = 45

    /// The request body, `{ ciphertext, at }`, sealed under the shop's DEK.
    /// `plaintexts` are the shared rule's, in the order to try
    /// (`KhaytEngine.liveSnapshots`: whole, then without `filename` and
    /// `error`); nil comes back only when not even the last one fits.
    ///
    /// What a row holds, what counts as a change, when to send and whether
    /// to send at all are `lib/live-snapshot.js`, through the engine. Only
    /// the sealing is here, because the key never goes into JavaScript.
    public static func body(plaintexts: [[String: JSONValue]], at: String, dek: Data) throws -> Data? {
        for plain in plaintexts {
            let blob = try SyncCrypto.seal(plain, dek: dek)
            let cipher = try JSONEncoder().encode(blob)
            guard cipher.count <= maxCiphertext else { continue }
            let envelope: [String: Any] = [
                "ciphertext": try JSONSerialization.jsonObject(with: cipher), "at": at,
            ]
            return try JSONSerialization.data(withJSONObject: envelope)
        }
        return nil
    }
}
