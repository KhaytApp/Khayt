import Foundation
import KhaytCore

/// Publishes this Mac's printers to Khayt Cloud, so the phone and the PWA can
/// follow a print away from the shop. Requested by the phone's session (Sep
/// 2026); the contract is khayt-cloud's (`PUT /live/printers`, see
/// `LivePrinters`). Only while the cloud is signed in AND unlocked on this Mac,
/// and only for a role that may write: a viewer's snapshot is a 403.
@MainActor
final class LivePrinterPublisher {
    private var lastSent: Date?
    private var lastSignature: [JSONValue]?
    private var notBefore: Date?
    private var inFlight = false
    /// A 403 (a viewer, or a token the shop revoked): stop for this session
    /// rather than asking again every sweep.
    private var refused = false

    var fetch: (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await URLSession.shared.data(for: request)
    }

    func forget() { lastSent = nil; lastSignature = nil; notBefore = nil; refused = false }

    /// Called after every printer sweep.
    func publishIfDue(rows: [JSONValue], connection: CloudReader.Connection?, dek: Data?,
                      canWrite: Bool, token: () async -> String?) async {
        guard !refused, !inFlight, canWrite, let connection, let dek, !rows.isEmpty else { return }
        let now = Date()
        let signature = LivePrinters.signature(rows)
        guard LivePrinters.due(changed: signature != lastSignature, now: now,
                               lastSent: lastSent, notBefore: notBefore) else { return }
        inFlight = true
        defer { inFlight = false }
        guard let token = await token(), !token.isEmpty,
              let body = try? LivePrinters.body(rows: rows, at: StoreWriter.iso(now), dek: dek),
              var request = try? CloudReader.request(connection, token: token, method: "PUT",
                                                     tail: "/live/printers") else { return }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 15
        guard let (data, response) = try? await fetch(request),
              let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300:
            lastSent = now
            lastSignature = signature
        case 429:
            let retry = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "")
                ?? ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["retryAfter"] as? Double
                ?? LivePrinters.minInterval
            notBefore = now.addingTimeInterval(retry)
        case 403, 401:
            refused = true
        default:
            // Anything else — a deploy, a 5xx — is tried again at the next due
            // moment, never in a loop of its own.
            notBefore = now.addingTimeInterval(LivePrinters.heartbeat)
        }
    }
}
