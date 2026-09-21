import Foundation
import KhaytCore

/// Telling a customer, by email, that their job moved.
///
/// The words are `lib/order-email.js` and are not this file's business. What is
/// here is the door each provider opens: SendGrid and Mailgun are one HTTPS
/// POST apiece, with different shapes and different ways of saying no.
///
/// ── AND THE THIRD, WHICH IS A PROTOCOL ────────────────────────────────────
///
/// `custom` is the shop's own SMTP relay: a socket, a greeting, STARTTLS, AUTH,
/// a dialogue. This file refused it by name for as long as it existed, and the
/// comment here used to explain why — writing a second implementation of a
/// protocol is how two apps come to disagree about whether a customer was told.
///
/// That was a reason to SHARE the parts that can disagree, not a reason to
/// leave a shop unable to send. The rules with an opinion in them now live in
/// `lib/smtp-format.js`, which both apps read; `SmtpClient` is the socket, and
/// sockets have no opinions. See that file for the STARTTLS upgrade, which is
/// the only genuinely hard part.
///
/// ── WHICH HOSTS ARE GUARDED, AND WHICH NEED NOT BE ────────────────────────
///
/// SendGrid's and Mailgun's are constants in this file; the only thing a shop
/// supplies is a key, so there is nothing for an SSRF guard to guard. The SMTP
/// relay is the opposite — a hostname typed into a settings field — and it gets
/// the same two layers `WebhookClient` applies: the name, and every address it
/// resolves to. That guard lives in `SmtpClient.send`, next to the connection
/// it protects.
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
                     smtpPassword: String = "",
                     engine: KhaytEngine? = nil,
                     session: URLSession = .shared) async throws {
        let from = str(config["fromEmail"]) ?? "noreply@khaytapp.com"
        let fromName = str(config["fromName"]) ?? "Khayt"

        // SMTP FIRST, because it is the one provider with no API key: a relay
        // is a host, a user and a password. Checking the key before the switch
        // would refuse every SMTP shop for the wrong reason.
        if mail.provider == "custom" {
            guard let engine else { throw Failure.unsupported(mail.provider) }
            let user = str(config["smtpUser"]) ?? ""
            try await SmtpClient.send(mail, relay: SmtpClient.Relay(
                host: str(config["smtpHost"]) ?? "",
                port: smtpPort(config["smtpPort"]),
                user: user,
                password: smtpPassword,
                secure: bool(config["smtpSecure"]),
                // A relay almost always insists the envelope sender be the
                // account that authenticated, so the user is the fallback
                // rather than Khayt's address — which is what `main.js` does.
                from: str(config["fromEmail"]) ?? (user.isEmpty ? from : user),
                fromName: fromName), engine: engine)
            return
        }

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
            // `mailto`, or something added to the other app and not to this
            // one. Refused by name rather than dropped.
            throw Failure.unsupported(mail.provider)
        }
    }

    /// The port, however the book happens to hold it.
    ///
    /// `renderer/settings.js` writes it from a `type="number"` input, which
    /// gives a number — but a book that has been through an export, an import
    /// or a hand edit can hold the string, and `main.js` reads `smtpPort || 587`
    /// either way. A `0` is the field left empty, not a port.
    static func smtpPort(_ value: JSONValue?) -> UInt16 {
        var raw = 0
        if case .number(let n)? = value { raw = Int(n) }
        if case .string(let s)? = value, let n = Int(s) { raw = n }
        guard (1...65535).contains(raw) else { return 587 }
        return UInt16(raw)
    }

    private static func bool(_ value: JSONValue?) -> Bool {
        if case .bool(let b)? = value { return b }
        return false
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
