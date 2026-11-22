import Foundation
import KhaytCore

/// Publishing the shop's pricing inputs, so its storefront can quote an
/// uploaded model with Khayt's own calculator.
///
/// The storefront (athartuwaiq3d.com) runs `lib/public-quote.js` itself, server
/// side, and asked for the shop's inputs rather than a second calculator. This
/// sends them beside the delivery promise, on the same timer: the sheet
/// `lib/quote-sheet.js` builds, or null to WITHDRAW it when the shop switches
/// public pricing off.
///
/// ── UNLIKE THE DELIVERY PROMISE, THIS IS NOT PUBLIC ──────────────────────
///
/// A delivery date is fine on a public URL. A cost base and a margin are not,
/// so Khayt Cloud serves the sheet only to a holder of the shop's token. It is
/// sent in plain JSON like the promise — the storefront must read it without
/// the shop's data key — and it carries nothing but what a price is made of.
@MainActor
enum QuoteSheetPublisher {
    enum Failure: Error, CustomStringConvertible, Equatable {
        case unauthorised
        case readOnly
        /// Khayt Cloud does not have the endpoint yet. Expected until it ships;
        /// said quietly, not raised.
        case notOffered
        case http(Int, String)
        var description: String {
            switch self {
            case .unauthorised: "Khayt Cloud did not accept this shop's token for the quote sheet."
            case .readOnly: "This sign-in can read this shop but not publish its quote sheet."
            case .notOffered: "Khayt Cloud does not take a quote sheet yet."
            case .http(let code, let body): "Khayt Cloud answered \(code) to the quote sheet" + (body.isEmpty ? "" : ": \(body)")
            }
        }
    }

    private struct Body: Encodable { let quoteSheet: JSONValue }

    /// Send one sheet, or withdraw with nil.
    static func publish(_ connection: CloudReader.Connection, token: String, sheet: JSONValue?,
                        fetch: (URLRequest) async throws -> (Data, URLResponse)) async throws {
        var request = try CloudReader.request(connection, token: token, method: "PUT", tail: "/quote-sheet")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(quoteSheet: sheet ?? .null))
        let (data, response) = try await fetch(request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200, 204: return
        case 401: throw Failure.unauthorised
        case 403: throw Failure.readOnly
        case 404: throw Failure.notOffered
        case let code: throw Failure.http(code, String(decoding: data.prefix(200), as: UTF8.self))
        }
    }

    /// A week: the storefront stops quoting from a sheet older than this, so a
    /// Mac switched off for a holiday stops publishing prices it cannot stand
    /// behind. Republished every six hours, well inside it.
    static let staleAfterHours: Double = 168
}
