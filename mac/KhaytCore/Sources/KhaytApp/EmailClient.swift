import Foundation
import KhaytCore

/// Telling a customer, by email, that their job moved.
///
/// The words are `lib/order-email.js` and are not this file's business. What is
/// here is the door each provider opens: SendGrid and Mailgun are one HTTPS
/// POST apiece, with different shapes and different ways of saying no.
///
/// ── WHY THERE IS NO SMTP HERE ─────────────────────────────────────────────
///
/// The other app's third provider, `custom`, is SMTP: a socket, EHLO, STARTTLS,
/// AUTH, a dialogue with a server the shop names. That is not a missing `if` —
/// it is a protocol, and writing a second implementation of it is how two apps
/// come to disagree about whether a customer was told. So a shop on SMTP still
/// has its move REFUSED here, by name, and `NeedsTheOtherAppTests` carries the
/// gap with that sentence attached.
///
/// ── AND WHY THE HOSTS ARE NOT GUARDED LIKE A WEBHOOK'S ────────────────────
///
/// `WebhookClient` resolves the host and refuses private addresses because the
/// URL is typed by the shop. These two are not: they are constants in this
/// file, and the only thing a shop supplies is a key. There is nothing for an
/// SSRF guard to guard.
@MainActor
enum EmailClient {

    /// Ten seconds, as Telegram's and the webhooks'. A shop finishing a job
    /// should not wait on a mail API that is not answering.
    static let timeout: TimeInterval = 10

    enum Failure: Error, LocalizedError {
        case unsupported(String)
        case missingKey(String)
        case badDomain
        case unreachable(String)
        case refused(Int, String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let p): return "This app cannot send mail through \(p)"
            case .missingKey(let p): return "No API key saved for \(p)"
            case .badDomain: return "Mailgun needs a valid sending domain"
            case .unreachable(let why): return why
            case .refused(let code, let why):
                return why.isEmpty ? "Mail provider refused (HTTP \(code))" : why
            }
        }
    }

    /// Send one email and wait for the provider to say it took it.
    ///
    /// AWAITED, not fired and forgotten — for the reason `Telegram.send` is:
    /// the move was refused in the first place because a piece of it could not
    /// be done, and a send nobody looks at puts the app back there.
    ///
    /// `config` is `settings.emailConfig` with its secrets already opened;
    /// this reads `fromEmail`, `fromName` and `domain` from it, exactly as
    /// `hub:send-email` does.
    static func send(_ mail: OrderEmail, apiKey: String,
                     config: [String: JSONValue],
                     session: URLSession = .shared) async throws {
        let from = str(config["fromEmail"]) ?? "noreply@khaytapp.com"
        let fromName = str(config["fromName"]) ?? "Khayt"
        guard !apiKey.isEmpty else { throw Failure.missingKey(mail.provider) }

        switch mail.provider {
        case "sendgrid":
            try await post(
                url: URL(string: "https://api.sendgrid.com/v3/mail/send")!,
                headers: ["Authorization": "Bearer \(apiKey)",
                          "Content-Type": "application/json"],
                body: try JSONSerialization.data(withJSONObject: [
                    "personalizations": [["to": [["email": mail.to]]]],
                    "from": ["email": from, "name": fromName],
                    "subject": mail.subject,
                    "content": [["type": "text/html", "value": mail.html]],
                ]),
                session: session)

        case "mailgun":
            // The same sanitising the Electron handler does before building a
            // path out of it: a domain is a path component here, and one with
            // a slash in it addresses somebody else's mailbox.
            guard let domain = mailgunDomain(str(config["domain"]) ?? "") else {
                throw Failure.badDomain
            }
            // Basic auth, `api` as the username, exactly as `hub:send-email`.
            let credentials = Data("api:\(apiKey)".utf8).base64EncodedString()
            var form = URLComponents()
            form.queryItems = [
                URLQueryItem(name: "from", value: "\(fromName) <mailgun@\(domain)>"),
                URLQueryItem(name: "to", value: mail.to),
                URLQueryItem(name: "subject", value: mail.subject),
                URLQueryItem(name: "html", value: mail.html),
            ]
            try await post(
                url: URL(string: "https://api.mailgun.net/v3/\(domain)/messages")!,
                headers: ["Authorization": "Basic \(credentials)",
                          "Content-Type": "application/x-www-form-urlencoded"],
                body: Data((form.percentEncodedQuery ?? "").utf8),
                session: session)

        default:
            // `custom` (SMTP), `mailto`, or something added to the other app
            // and not to this one. Refused by name rather than dropped.
            throw Failure.unsupported(mail.provider)
        }
    }

    // MARK: - Private

    private static func post(url: URL, headers: [String: String], body: Data,
                             session: URLSession) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure.refused(status, providerReason(data))
        }
    }

    /// What the provider said, when it said anything worth repeating.
    ///
    /// An expired key and a malformed address both arrive as a 4xx, and the
    /// difference is in the body. A shop can fix one of them.
    private static func providerReason(_ data: Data) -> String {
        guard let any = try? JSONSerialization.jsonObject(with: data) else { return "" }
        if let body = any as? [String: Any] {
            // Mailgun: `{"message": "..."}`. SendGrid: `{"errors":[{"message":…}]}`.
            if let m = body["message"] as? String { return m }
            if let errors = body["errors"] as? [[String: Any]],
               let first = errors.first?["message"] as? String { return first }
        }
        return ""
    }

    /// `sanitizeMailgunDomain` from `lib/host-guard.js`, in Swift.
    ///
    /// A hostname and nothing else: no scheme, no path, no credentials. The
    /// Electron handler refuses rather than repairs, and so does this.
    ///
    /// THE PATTERN IS COPIED, NOT WRITTEN. The first draft here was
    /// `^[a-z0-9.-]+\.[a-z]{2,}$`, which reads the same and is not: it accepts
    /// a label starting with a hyphen and rejects a numeric TLD the other app
    /// accepts. Two apps disagreeing about which sending domain is valid is a
    /// shop whose mail works on one machine. `mailgunDomainPatternMatchesLib`
    /// in test/order-email.test.js compares this literal against the module's.
    static let mailgunDomainPattern =
        "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"

    static func mailgunDomain(_ raw: String) -> String? {
        let d = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // 253 is the module's, and it is the length a DNS name can actually be.
        guard !d.isEmpty, d.count <= 253 else { return nil }
        let ok = d.range(of: mailgunDomainPattern, options: .regularExpression) != nil
        return ok ? d : nil
    }

    private static func str(_ value: JSONValue?) -> String? {
        if case .string(let s)? = value, !s.isEmpty { return s }
        return nil
    }
}
