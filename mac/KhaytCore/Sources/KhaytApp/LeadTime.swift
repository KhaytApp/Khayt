import Foundation
import KhaytCore

/// Publishing when this shop could have a new order printed, finished and posted.
///
/// ── WHY THIS FILE EXISTS AT ALL ────────────────────────────────────────────
///
/// This was the one thing only the Electron **main process** did. Every six
/// hours `publishLeadTime()` in `main.js` built a snapshot from the shop's queue
/// and PUT it to `/v1/shops/{id}/lead-time`, and a storefront quotes its
/// delivery dates from that — refusing to quote at all once the snapshot is
/// older than `staleAfterHours`, which is the whole point of the field.
///
/// So a Mac where somebody had shut Electron down took the shop's published
/// delivery dates offline with it, silently, some hours later. Nothing on any
/// screen in either app said so. For a Mac that is meant to replace Electron
/// outright, that is not a missing feature — it is a feature that breaks when
/// you succeed at the goal.
///
/// ── THE SNAPSHOT IS NOT ENCRYPTED, AND THAT IS DELIBERATE ─────────────────
///
/// Every other body this app sends the cloud is sealed with the shop's DEK.
/// This one is plain JSON, because it is read by a storefront that holds no
/// credential of the shop's. `lib/lead-time.js` is built around that: the
/// snapshot carries `availableFrom` and a handling allowance and NOT the queue,
/// because hours of booked work published hourly is a competitor's view of how
/// busy a shop is. The discretion lives in the module, so both apps get it.
@MainActor
enum LeadTimePublisher {

    enum Failure: Error, CustomStringConvertible, Equatable {
        case unauthorised
        /// A 403: this sign-in may read the shop and not change it.
        case readOnly
        case http(Int, String)

        var description: String {
            switch self {
            case .unauthorised:
                return "Khayt Cloud did not accept this shop's token for the delivery promise."
            case .readOnly:
                return "This sign-in can read this shop but not publish its delivery promise."
            case .http(let code, let body):
                return "Khayt Cloud answered \(code) to the delivery promise"
                     + (body.isEmpty ? "" : ": \(body)")
            }
        }
    }

    /// `{ leadTime: … }` — and `null` is a real value here, not an omission.
    /// It is how a shop that has turned publishing off WITHDRAWS the date it
    /// last published, rather than leaving a frozen promise on a public URL.
    private struct Body: Encodable {
        let leadTime: JSONValue
    }

    /// Send one snapshot, or withdraw with nil.
    ///
    /// `fetch` is a seam for the same reason it is one in `CloudReader` and
    /// `CloudWriter`: the whole path is exercised in the tests and none of them
    /// has a shop's credentials.
    static func publish(_ connection: CloudReader.Connection, token: String,
                        snapshot: JSONValue?,
                        fetch: (URLRequest) async throws -> (Data, URLResponse)) async throws {
        var request = try CloudReader.request(connection, token: token,
                                              method: "PUT", tail: "/lead-time")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(leadTime: snapshot ?? .null))

        let (data, response) = try await fetch(request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return
        case 401: throw Failure.unauthorised
        // A viewer's account, not a reset token. Saying the wrong one sends a
        // shop to fix something that is not broken — and this ran on a timer,
        // so it said it over and over.
        case 403: throw Failure.readOnly
        case let code:
            throw Failure.http(code, CloudWriter.said(data))
        }
    }

    /// The shop's LOCAL day, `YYYY-MM-DD`.
    ///
    /// `lib/lead-time.js` anchors everything to `T00:00:00Z` and never asks a
    /// clock, so the timezone decision is made once — here — rather than smeared
    /// through the arithmetic. A UTC-derived day from a +03:00 shop at 01:00
    /// promises yesterday, and the module's own comment says so.
    static func localDay(_ now: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }
}
