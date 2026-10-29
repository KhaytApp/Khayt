import Foundation
import KhaytCore

/// The orders a storefront has already sent, which this app could not see.
///
/// ── THE HALF THAT WAS MISSING ─────────────────────────────────────────────
///
/// The Integrations screen hands a shop the address to paste into Shopify,
/// Salla, Zid, WooCommerce, Etsy, Medusa and the rest — `Copy import link`,
/// right there, and it works. Every order those storefronts send arrives at
/// khayt-cloud, is mapped by `mapPlatformOrder`, is de-duplicated on the
/// platform's own reference and is filed in the shop's intake queue.
///
/// And then this app never asked for it. The Mac could tell a storefront where
/// to send its orders and could not show the shop one that had arrived. The
/// desktop reads the same queue from its Order requests screen; nothing here
/// did, which is a renderer-only feature and therefore a gap.
///
/// ── WHY IT IS BUILT ON `CloudReader` ──────────────────────────────────────
///
/// Not for tidiness. `CloudReader.request` is the one place that sets
/// `x-delta-capable`, and khayt-cloud records the delta capability of every
/// credential it hears from on **every** route — a request that omitted the
/// header would close delta sync for the whole shop, on all its devices, from
/// a screen that has nothing to do with syncing. The long note is over there.
///
/// Pure of the network: `fetch` is a seam, as `CloudReader.pull`'s is, so the
/// whole path can be exercised without a shop's credentials.
@MainActor
enum CloudIntake {

    /// One order, as the queue holds it.
    ///
    /// `payload` is kept whole rather than decoded into fields, because the
    /// rule that reads it is `lib/shelf-sale.js` and it runs in JavaScript.
    /// Decoding here would mean two readers of one wire format.
    struct Item: Identifiable, Sendable {
        let id: String
        let payload: JSONValue
        let createdAt: Date?

        /// What to call this order on screen.
        var title: String {
            text("title") ?? text("description")?
                .split(separator: "\n").first.map(String.init) ?? id
        }
        var customer: String { text("name") ?? "" }
        var contact: String { text("contact") ?? "" }
        var source: String { text("source") ?? "" }
        var reference: String { text("ref") ?? "" }
        /// A request from the shop's embedded quote form (khayt-cloud #144).
        var isQuoteForm: Bool { source == "quote-form" }
        /// The model the visitor uploaded with it, when the payload names one.
        var file: QuoteFormFile.Meta? { QuoteFormFile.Meta(payload) }

        func text(_ key: String) -> String? {
            guard case .object(let fields) = payload,
                  case .string(let value)? = fields[key],
                  !value.isEmpty else { return nil }
            return value
        }
    }

    enum Failure: Error, LocalizedError {
        case notConnected
        case refused(Int, String)
        case malformed
        /// 404 `reason:"no-route"`: the cloud has this route switched off
        /// (the quote form is dark until the shop's privacy policy covers it).
        case notOffered
        /// The download was bigger than the request said its file is.
        case tooLarge(Int)
        /// 409 `reason:"file-not-downloaded"`: the cloud still keeps this
        /// request's file and the DELETE did not say it was downloaded.
        case fileNotDownloaded

        var errorDescription: String? {
            switch self {
            case .notConnected: return "This book is not connected to Khayt Cloud."
            case .malformed: return "The cloud answered with something this app could not read."
            case .notOffered: return "Khayt Cloud does not offer this yet."
            case .tooLarge(let most): return "The file was larger than the \(most) bytes it should be."
            case .fileNotDownloaded: return "Update Khayt to import this request with its file."
            case .refused(let code, let why):
                return why.isEmpty ? "The cloud refused the request (HTTP \(code))" : why
            }
        }
    }

    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)

    /// Everything waiting, oldest first — the order a shop would work through.
    static func list(_ connection: CloudReader.Connection, token: String,
                     fetch: Fetch) async throws -> [Item] {
        let request = try CloudReader.request(connection, token: token,
                                              method: "GET", tail: "/intake")
        let (data, response) = try await fetch(request)
        try check(response, data)
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = body["items"] as? [[String: Any]] else { throw Failure.malformed }
        return rows.compactMap(item(from:)).sorted {
            ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
        }
    }

    /// Take one out of the queue.
    ///
    /// Called AFTER the order has been written into this shop's book, never
    /// before: a delete that went first would lose the order outright if the
    /// write then failed, and the queue is the only copy this app has.
    static func drain(_ connection: CloudReader.Connection, token: String, id: String,
                      fetch: Fetch) async throws {
        var request = try CloudReader.request(connection, token: token, method: "DELETE",
                                              tail: "/intake/" + id.uriComponent)
        // A claim, so it is made here and nowhere else: this app downloads and
        // checks a request's file before it ever drains it (`recordQuoteForm`),
        // and khayt-cloud refuses to delete a kept file for a client that does
        // not say so — an older build would throw the visitor's model away.
        request.setValue("1", forHTTPHeaderField: "X-Intake-File-Capable")
        let (data, response) = try await fetch(request)
        if (response as? HTTPURLResponse)?.statusCode == 409,
           let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           body["reason"] as? String == "file-not-downloaded" {
            throw Failure.fileNotDownloaded
        }
        try check(response, data)
    }

    /// What the file route answered.
    enum FileAnswer: Sendable {
        /// The bytes, and the `X-Content-SHA256` the cloud sent with them.
        case file(Data, sha256: String?)
        /// 404 `reason:"no-file"`: the cloud kept it for its time and has
        /// deleted it. The request itself is still worth importing.
        case expired
    }

    /// The model a quote-form request carries (`GET …/intake/{id}/file`).
    ///
    /// Read BEFORE the request is written into the book and long before it is
    /// drained: `DELETE /intake/{id}` deletes the file on the cloud too, so a
    /// drain that went first would throw the customer's model away.
    ///
    /// A 404 is two different things and they must not be confused:
    /// `no-file` is a file that has expired (import without it, then drain);
    /// `no-route` is the whole feature switched off (keep everything queued).
    ///
    /// `maxBytes` is the size the request declared. A body (or a
    /// `Content-Length`) over it is refused before anything is hashed: the
    /// cloud caps a file at `files.maxFileBytes` (32 MB unless its server env
    /// says otherwise), so an answer past what was declared is not the file.
    static func file(_ connection: CloudReader.Connection, token: String, id: String,
                     maxBytes: Int, fetch: Fetch) async throws -> FileAnswer {
        var request = try CloudReader.request(connection, token: token, method: "GET",
                                              tail: "/intake/" + id.uriComponent + "/file")
        // A model is not a JSON answer: give it longer than the 30 seconds
        // every other call gets.
        request.timeoutInterval = 300
        let (data, response) = try await fetch(request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 200 {
            let declared = response.expectedContentLength
            if declared > Int64(maxBytes) || data.count > maxBytes { throw Failure.tooLarge(maxBytes) }
            return .file(data, sha256: http?.value(forHTTPHeaderField: "X-Content-SHA256"))
        }
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if status == 404 {
            switch body?["reason"] as? String {
            case "no-file": return .expired
            case "no-route": throw Failure.notOffered
            default: break
            }
        }
        throw Failure.refused(status, (body?["error"] as? String) ?? "")
    }

    // MARK: - Reading the answer

    private static func check(_ response: URLResponse, _ data: Data) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw Failure.refused(status, (body?["error"] as? String) ?? "")
        }
    }

    /// A row with no id is dropped rather than shown.
    ///
    /// The id is how the row is deleted afterwards, so a row without one could
    /// be imported and then reappear on the next look — the shop importing the
    /// same order every time it opened the screen. khayt-cloud's import route
    /// answered `"id":"0"` for every storefront order for most of its life, and
    /// a listing built on the same mistake is not worth guessing around.
    private static func item(from row: [String: Any]) -> Item? {
        let id = (row["id"] as? String) ?? (row["id"] as? Int).map(String.init) ?? ""
        guard !id.isEmpty, id != "0" else { return nil }
        let payload = JSONValue.from(row["payload"] ?? NSNull())
        guard case .object = payload else { return nil }
        return Item(id: id, payload: payload,
                    createdAt: (row["createdAt"] as? String).flatMap(iso))
    }

    /// When the order arrived.
    ///
    /// `created_at` is a MySQL `DATETIME` and comes back as `2026-09-22
    /// 14:02:11` — no `T`, no zone — so reading it with an ISO8601 parser
    /// alone returns nil for every row the service has ever held. It is UTC:
    /// khayt-cloud sets the session to UTC and every other timestamp it hands
    /// out is.
    ///
    /// The ISO readers stay as well, because a row written by the Node backend
    /// (`src/server.js`, the other implementation) is ISO — see the repo's own
    /// note that khayt-cloud has two backends.
    private static func iso(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let sql = DateFormatter()
        sql.locale = Locale(identifier: "en_US_POSIX")
        sql.calendar = Calendar(identifier: .gregorian)
        sql.timeZone = TimeZone(identifier: "UTC")
        sql.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return sql.date(from: text)
    }
}
