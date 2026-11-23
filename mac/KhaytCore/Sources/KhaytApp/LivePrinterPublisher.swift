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
    private var lastSignature: String?
    private var notBefore: Date?
    private var inFlight = false
    /// A 403 (a viewer, or a token the shop revoked): stop for this session
    /// rather than asking again every sweep.
    private var refused = false

    var fetch: (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await CloudReader.session.data(for: request)
    }

    func forget() { lastSent = nil; lastSignature = nil; notBefore = nil; refused = false }

    /// Called after every printer sweep.
    ///
    /// ── ONLY A COMPUTER THAT HEARS THE PRINTERS SPEAKS FOR THE SHOP ───────
    ///
    /// The cloud keeps ONE snapshot per shop and every unlocked computer of
    /// the shop may publish. The owner's laptop at home cannot reach the
    /// printers; publishing its rows replaced the shop computer's real
    /// picture with "not heard" every 45 seconds, and the phone flipped
    /// between the two. So this Mac publishes only while at least one printer
    /// answered it in the last three minutes (`hasFreshPoll`), and is silent
    /// otherwise: not even a heartbeat. The rule, and what counts as a change
    /// and when one is due, are `lib/live-snapshot.js`, the desktop's own.
    func publishIfDue(rows: [JSONValue], engine: KhaytEngine?, connection: CloudReader.Connection?, dek: Data?,
                      canWrite: Bool, now: Date = Date(), token: () async -> String?) async {
        guard !refused, !inFlight, canWrite, let engine, let connection, let dek, !rows.isEmpty else { return }
        // A rule that cannot be asked publishes nothing: closed.
        guard (try? await engine.liveHasFreshPoll(rows: rows, now: now)) == true,
              let signature = try? await engine.liveSignature(rows: rows),
              (try? await engine.liveDue(changed: signature != lastSignature, now: now,
                                         lastSent: lastSent, notBefore: notBefore)) == true else { return }
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        let at = StoreWriter.iso(now)
        guard let token = await token(), !token.isEmpty,
              let plaintexts = try? await engine.liveSnapshots(rows: rows, at: at),
              let body = try? LivePrinters.body(plaintexts: plaintexts, at: at, dek: dek),
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
            // Honoured, up to the rule's limit: a wrong answer must not
            // silence this Mac for hours.
            let limit = (try? await engine.liveMaxRetryAfter()) ?? 300
            // Not a number at all ("nan") would make a date nothing can be
            // compared with, and silence this Mac until the app restarts.
            let wait = retry.isFinite ? min(max(retry, 0), limit) : LivePrinters.minInterval
            notBefore = now.addingTimeInterval(wait)
        case 403, 401:
            refused = true
        default:
            // Anything else — a deploy, a 5xx — is tried again at the next due
            // moment, never in a loop of its own.
            notBefore = now.addingTimeInterval(LivePrinters.heartbeat)
        }
    }
}
