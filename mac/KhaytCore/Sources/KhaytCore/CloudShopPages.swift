import Foundation

/// What Khayt Cloud knows about a shop's public pages: its reviews, its
/// storefront's visitors, and the name in its web address.
///
/// The same five calls the desktop makes through `lib/cloud-client.js`
/// (`getReviewSummary`, `listReviews`, `deleteReview`, `storefrontStats`,
/// `getShopSlug`/`setShopSlug`), on the Mac's own request builder — so every
/// one carries the delta header and refuses http (`CloudReader.request`).
///
///   - `GET  /v1/shops/{id}/reviews` → `{count, avg, recent}`, the public
///     summary the storefront prints.
///   - `GET  /v1/shops/{id}/reviews/all?limit=` → `{reviews: [...]}`, every
///     review with its id. Owner-only.
///   - `DELETE /v1/shops/{id}/reviews/{reviewId}`. Owner-only.
///   - `GET  /v1/shops/{id}/sfstats` → `{views, carts, orders, items}`.
///   - `GET | PUT /v1/shops/{id}/slug` → `{slug, graceDays}`; the server owns
///     the rules (reserved words, names already taken), so its `error` is the
///     sentence worth showing.
///
/// What the answers MEAN for the screen — the funnel's conversion, the top
/// products, a review's whole stars — is `lib/storefront-insights.js`, read
/// through the engine, so both apps draw the same figures.
public enum CloudShopPages {

    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public let status: Int
        public let reason: String
        public let error: String
        public var description: String { "Khayt Cloud refused (\(status))" + (error.isEmpty ? "" : ": \(error)") }
    }

    /// The public summary the storefront prints.
    public struct Summary: Sendable, Equatable {
        public let count: Int
        public let average: Double
    }

    /// The summary, or nil when the cloud has none to give (the desktop's
    /// "best effort": a failed summary is no summary, never an error on screen).
    public static func reviewSummary(_ connection: CloudReader.Connection, token: String,
                                     fetch: S3.Fetch) async -> Summary? {
        guard let data = try? await send(connection, token, "GET", "/reviews", fetch: fetch),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let count = (o["count"] as? NSNumber)?.intValue ?? 0
        let avg = (o["avg"] as? NSNumber)?.doubleValue ?? Double(o["avg"] as? String ?? "") ?? 0
        return Summary(count: count, average: avg)
    }

    /// Every review, with ids, as the cloud sent it (`reviews`), for
    /// `KhaytEngine.reviewRows` to read.
    public static func reviews(_ connection: CloudReader.Connection, token: String, limit: Int = 50,
                               fetch: S3.Fetch) async throws -> JSONValue {
        let data = try await send(connection, token, "GET", "/reviews/all?limit=\(max(1, limit))", fetch: fetch)
        if case .object(let o) = try JSONValue.decode(JSONValue.self, from: data), let list = o["reviews"] {
            return list
        }
        return .array([])
    }

    public static func deleteReview(_ id: String, _ connection: CloudReader.Connection, token: String,
                                    fetch: S3.Fetch) async throws {
        _ = try await send(connection, token, "DELETE", "/reviews/" + id.uriComponent, fetch: fetch)
    }

    /// The storefront funnel as the cloud sent it, for
    /// `KhaytEngine.storefrontInsights`.
    public static func storefrontStats(_ connection: CloudReader.Connection, token: String,
                                       fetch: S3.Fetch) async throws -> JSONValue {
        let data = try await send(connection, token, "GET", "/sfstats", fetch: fetch)
        return (try? JSONValue.decode(JSONValue.self, from: data)) ?? .object([:])
    }

    /// The shop's own name for its public pages.
    public struct Slug: Sendable, Equatable {
        public let slug: String?
        /// How long the previous name keeps working after a change.
        public let graceDays: Int
    }

    public static func slug(_ connection: CloudReader.Connection, token: String,
                            fetch: S3.Fetch) async throws -> Slug {
        let data = try await send(connection, token, "GET", "/slug", fetch: fetch)
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let name = (o["slug"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Slug(slug: name, graceDays: (o["graceDays"] as? NSNumber)?.intValue ?? 90)
    }

    /// Claim or change it. Lower-cased and trimmed first, as the desktop does;
    /// everything else is the server's to judge.
    public static func setSlug(_ name: String, _ connection: CloudReader.Connection, token: String,
                               fetch: S3.Fetch) async throws -> String? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let body = try JSONSerialization.data(withJSONObject: ["slug": clean])
        let data = try await send(connection, token, "PUT", "/slug", body: body, fetch: fetch)
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return o["slug"] as? String
    }

    // MARK: - Plumbing

    static func send(_ connection: CloudReader.Connection, _ token: String, _ method: String, _ tail: String,
                     body: Data? = nil, fetch: S3.Fetch) async throws -> Data {
        var request = try CloudReader.request(connection, token: token, method: method, tail: tail)
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await fetch(request)
        let code = S3.status(response)
        guard (200..<300).contains(code) else {
            let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw Refusal(status: code, reason: (o?["reason"] as? String) ?? "",
                          error: (o?["error"] as? String) ?? "")
        }
        return data
    }
}
