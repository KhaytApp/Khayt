import Foundation
import KhaytCore

/// Settings › Online › "Quote form for your store": the cloud's embeddable
/// quote form (khayt-cloud #144, docs/api-contract.md "Quote form").
///
/// `GET /v1/shops/{id}/embed` (any role) and `PUT` (owner or manager), both
/// built on `CloudReader.request` — the one place that sets
/// `x-delta-capable`; see the note in `CloudIntake`.
///
/// ── DARK UNTIL IT IS NOT ──────────────────────────────────────────────────
///
/// The cloud keeps the form switched off (QUOTE_EMBED_ENABLED) until the
/// privacy policy covers it. While it is, every embed route answers 404
/// `reason:"no-route"` — that, and only that, is "not available yet". A 200
/// with `enabled:false` is a shop that simply has the form off.
enum QuoteFormEmbed {

    /// What both routes answer. Every field but `enabled` and `origins` is
    /// optional on the way in: a missing one is shown as unknown, never as a
    /// false the cloud did not say.
    struct State: Decodable, Equatable, Sendable {
        var enabled: Bool
        var origins: [String]
        var updatedAt: String?
        var priceAvailable: Bool?
        var keepsFiles: Bool?
        var files: Files?
        var month: Month?
        var links: Links?

        struct Files: Decodable, Equatable, Sendable {
            var count: Int?
            var bytes: Int?
            var maxCount: Int?
            var maxBytes: Int?
            var maxFileBytes: Int?
        }
        struct Month: Decodable, Equatable, Sendable {
            var month: String?
            var quotes: Int?
            var requests: Int?
        }
        struct Links: Decodable, Equatable, Sendable {
            var page: String?
            var frame: String?
            var script: String?
        }

        init(enabled: Bool = false, origins: [String] = [], updatedAt: String? = nil,
             priceAvailable: Bool? = nil, keepsFiles: Bool? = nil, files: Files? = nil,
             month: Month? = nil, links: Links? = nil) {
            self.enabled = enabled; self.origins = origins; self.updatedAt = updatedAt
            self.priceAvailable = priceAvailable; self.keepsFiles = keepsFiles
            self.files = files; self.month = month; self.links = links
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
            origins = ((try? c.decodeIfPresent([String].self, forKey: .origins)) ?? nil) ?? []
            updatedAt = try? c.decodeIfPresent(String.self, forKey: .updatedAt)
            priceAvailable = try? c.decodeIfPresent(Bool.self, forKey: .priceAvailable)
            keepsFiles = try? c.decodeIfPresent(Bool.self, forKey: .keepsFiles)
            files = try? c.decodeIfPresent(Files.self, forKey: .files)
            month = try? c.decodeIfPresent(Month.self, forKey: .month)
            // Shown and copied into a shop's website as given, so only https.
            if var l = try? c.decodeIfPresent(Links.self, forKey: .links) {
                func safe(_ s: String?) -> String? {
                    guard let s, let u = URL(string: s), u.scheme == "https", u.host != nil else { return nil }
                    return s
                }
                l.page = safe(l.page); l.frame = safe(l.frame); l.script = safe(l.script)
                links = l
            } else { links = nil }
        }
        private enum Key: String, CodingKey {
            case enabled, origins, updatedAt, priceAvailable, keepsFiles, files, month, links
        }
    }

    enum Failure: Error, Equatable, LocalizedError {
        /// 404 `no-route`: the cloud has the quote form switched off.
        case notAvailable
        /// 403: this sign-in is not the owner or a manager.
        case notAllowed
        /// 401.
        case unauthorised
        /// 400 `bad-embed`: the cloud refused this origin.
        case badOrigin(String)
        /// Refused here before sending: more than `maxOrigins`.
        case tooMany
        case malformed
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .notAvailable: "The quote form is not available on Khayt Cloud yet."
            case .notAllowed: "Only the owner or a manager can change the quote form."
            case .unauthorised: "Khayt Cloud did not accept this sign-in."
            case .badOrigin(let value): "Not an allowed web address: \(value)"
            case .tooMany: "At most \(QuoteFormEmbed.maxOrigins) web addresses."
            case .malformed: "Khayt Cloud answered with something this app could not read."
            case .http(let code, let body): "Khayt Cloud answered \(code)" + (body.isEmpty ? "" : ": \(body)")
            }
        }
    }

    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)

    static let maxOrigins = 10

    // MARK: - The two routes

    @MainActor static func read(_ connection: CloudReader.Connection, token: String,
                     fetch: Fetch) async throws -> State {
        let request = try CloudReader.request(connection, token: token, method: "GET", tail: "/embed")
        return try answer(try await fetch(request))
    }

    /// Checked here first, by the same rule the cloud holds, so a typo is
    /// caught before the round trip; the cloud's own `bad-embed` is still
    /// reported if it refuses anyway.
    @MainActor static func save(enabled: Bool, origins raw: [String], _ connection: CloudReader.Connection,
                     token: String, fetch: Fetch) async throws -> State {
        let origins = tidy(raw)
        if let problem = problem(origins) { throw problem }
        var request = try CloudReader.request(connection, token: token, method: "PUT", tail: "/embed")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["enabled": enabled, "origins": origins])
        return try answer(try await fetch(request))
    }

    private static func answer(_ pair: (Data, URLResponse)) throws -> State {
        let (data, response) = pair
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        switch status {
        case 200:
            guard let state = try? JSONDecoder().decode(State.self, from: data) else { throw Failure.malformed }
            return state
        case 400 where (body?["reason"] as? String) == "bad-embed":
            throw Failure.badOrigin((body?["value"] as? String) ?? "")
        case 401: throw Failure.unauthorised
        case 403: throw Failure.notAllowed
        case 404 where (body?["reason"] as? String) == "no-route": throw Failure.notAvailable
        default:
            throw Failure.http(status, (body?["error"] as? String) ?? "")
        }
    }

    // MARK: - The origin rule

    /// Blank lines out, whitespace trimmed.
    static func tidy(_ origins: [String]) -> [String] {
        origins.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// The first thing wrong with a list, or nil.
    static func problem(_ origins: [String]) -> Failure? {
        if origins.count > maxOrigins { return .tooMany }
        if let bad = origins.first(where: { !isOrigin($0) }) { return .badOrigin(bad) }
        return nil
    }

    /// Exactly `https://host[:port]`: no path (not even a trailing slash), no
    /// query, no wildcard, no user, and nothing but https.
    static func isOrigin(_ text: String) -> Bool {
        let label = "[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
        let pattern = "^https://\(label)(?:\\.\(label))*(?::([0-9]{1,5}))?$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return false }
        let portRange = match.range(at: 1)
        if portRange.location != NSNotFound, let r = Range(portRange, in: text) {
            guard let port = Int(text[r]), (1...65_535).contains(port) else { return false }
        }
        return text.count <= 253 + 8 + 6
    }

    // MARK: - The snippets

    /// `links.page` with the language and theme a shop picked, as query
    /// items. Never built from a base URL of our own: the cloud says where.
    static func page(_ link: String, lang: String, theme: String) -> String {
        guard var parts = URLComponents(string: link) else { return link }
        var items = (parts.queryItems ?? []).filter { $0.name != "lang" && $0.name != "theme" }
        items.append(URLQueryItem(name: "lang", value: lang))
        items.append(URLQueryItem(name: "theme", value: theme))
        parts.queryItems = items
        return parts.string ?? link
    }

    /// `links.frame` comes with no query; the frame reads `lang` and `theme`
    /// exactly as the page does, so the shop's picks go on it the same way.
    static func frame(_ link: String, title: String, lang: String, theme: String) -> String {
        "<iframe src=\"\(attribute(page(link, lang: lang, theme: theme)))\" title=\"\(attribute(title))\" "
            + "style=\"width:100%;min-height:640px;border:0\" loading=\"lazy\"></iframe>"
    }

    static func script(_ link: String, shopId: String, lang: String, theme: String) -> String {
        "<script src=\"\(attribute(link))\" data-shop=\"\(attribute(shopId))\" "
            + "data-lang=\"\(attribute(lang))\" data-theme=\"\(attribute(theme))\" async></script>"
    }

    private static func attribute(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - The shop's side

@MainActor
extension Shop {

    /// A seam, so a test can answer for the cloud.
    nonisolated(unsafe) static var embedFetch: QuoteFormEmbed.Fetch = { r in try await CloudReader.session.data(for: r) }

    /// What the pane draws.
    enum QuoteFormPane: Equatable {
        /// Not connected to Khayt Cloud: nothing was asked.
        case needsCloud
        /// The cloud has the form switched off (404 `no-route`).
        case notAvailable
        case shown(QuoteFormEmbed.State)
        /// Could not be read, in the shop's words.
        case problem(String)
    }

    /// The owner or a manager: who the cloud lets change the form.
    var cloudCanManageEmbed: Bool { pretendsOwner || cloudCanManageTeam }

    func readQuoteFormEmbed() async -> QuoteFormPane {
        guard let (connection, token) = await vaultSession() else { return .needsCloud }
        do {
            return .shown(try await QuoteFormEmbed.read(connection, token: token, fetch: Self.embedFetch))
        } catch QuoteFormEmbed.Failure.notAvailable {
            return .notAvailable
        } catch {
            return .problem(embedProblem(error))
        }
    }

    /// Save, or the reason not. The pane keeps what it shows on a refusal.
    func saveQuoteFormEmbed(enabled: Bool, origins: [String]) async -> Result<QuoteFormEmbed.State, QuoteFormSaveFailure> {
        guard cloudCanManageEmbed else { return .failure(.init(sentence: words.callIt("mac.qfe_managers_only"))) }
        guard let (connection, token) = await vaultSession() else {
            return .failure(.init(sentence: words.callIt("mac.qfe_needs_cloud")))
        }
        do {
            return .success(try await QuoteFormEmbed.save(enabled: enabled, origins: origins, connection,
                                                          token: token, fetch: Self.embedFetch))
        } catch QuoteFormEmbed.Failure.notAvailable {
            return .failure(.init(sentence: words.callIt("mac.qfe_not_available"), notAvailable: true))
        } catch {
            return .failure(.init(sentence: embedProblem(error)))
        }
    }

    struct QuoteFormSaveFailure: Error, Equatable {
        let sentence: String
        var notAvailable = false
    }

    func embedProblem(_ error: Error) -> String {
        guard let failure = error as? QuoteFormEmbed.Failure else {
            return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
        switch failure {
        case .notAvailable: return words.callIt("mac.qfe_not_available")
        case .notAllowed: return words.callIt("mac.qfe_managers_only")
        case .unauthorised: return words.callIt("mac.qfe_err_unauthorised")
        case .badOrigin(let value): return words.callIt("mac.qfe_err_origin", ["value": .string(value)])
        case .tooMany: return words.callIt("mac.qfe_err_too_many", ["n": .number(Double(QuoteFormEmbed.maxOrigins))])
        case .malformed: return words.callIt("mac.qfe_err_malformed")
        case .http(let code, _): return words.callIt("mac.cloud_err_http", ["code": .string(String(code))])
        }
    }
}
