import Foundation

/// The rules of an SMTP conversation, with no socket anywhere near them.
///
/// ── WHY SWIFT AND NOT THE SHARED MODULE ───────────────────────────────────
///
/// `lib/smtp-format.js` is the same rules, and the Electron app requires it.
/// This app cannot: the send happens inside a `NWProtocolFramer`, on
/// Network.framework's own queue, where nothing may `await` — and every call
/// into the JavaScript engine is an `await`, because `KhaytEngine` is an actor.
/// A framer that suspends does not suspend the connection; it deadlocks it.
///
/// So these are written twice, and `SmtpParityTests` in `KhaytCoreTests` loads
/// the real `lib/smtp-format.js` off disk and asserts the two agree, case by
/// case — the same pin the other twenty-four shared modules carry. The
/// JavaScript is the fixture. If you change a rule here, change it there.
///
/// ── WHAT EACH OF THESE IS FOR ─────────────────────────────────────────────
///
/// None of them is cosmetic:
///
/// - `sanitizeHeader` is the difference between a Subject and an injected
///   second header. A customer's name arrives here through `{{name}}`, and a
///   name is data — it holds whatever somebody once pasted into it.
/// - `dotStuff` is the difference between a whole email and one silently cut
///   at the first line a shop began with a full stop.
/// - `replyIsComplete` is the difference between reading a server's whole
///   greeting and reading its first line. Get it wrong and this app decides a
///   server cannot encrypt, which is not a hang — it is a refusal to send.
/// - `offersStartTls` is the only thing standing between the shop's password
///   and a plaintext socket.
public enum Smtp {

    /// The name this app gives in EHLO. Both apps must say the same thing.
    public static let ehloName = "khayt.local"

    // MARK: - Headers

    /// Strip CR/LF and other control characters.
    ///
    /// The class is `lib/smtp-format.js`'s exactly: U+0000–U+001F and U+007F,
    /// each *run* collapsing to one space, then trimmed. Collapsing runs
    /// rather than characters matters — a pasted `\r\n` is two characters and
    /// must not become two spaces, because the parity test compares strings.
    public static func sanitizeHeader(_ value: String) -> String {
        var out = ""
        var inRun = false
        for scalar in value.unicodeScalars {
            if scalar.value <= 0x1F || scalar.value == 0x7F {
                if !inRun { out.append(" "); inRun = true }
            } else {
                out.unicodeScalars.append(scalar); inRun = false
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Normalise line endings to CRLF and escape a leading dot on every line.
    ///
    /// RFC 5321: a line consisting of a single dot ends DATA, so a body line
    /// that begins with one has to be sent as two. The order matters — the
    /// dots are escaped *after* the endings are normalised, or a lone CR keeps
    /// the following line from being recognised as a line at all.
    public static func dotStuff(_ data: String) -> String {
        var normalised = data.replacingOccurrences(of: "\r\n", with: "\n")
        normalised = normalised.replacingOccurrences(of: "\r", with: "\n")
        let lines = normalised.components(separatedBy: "\n")
        return lines.map { $0.hasPrefix(".") ? "." + $0 : $0 }
            .joined(separator: "\r\n")
    }

    // MARK: - Reading the server

    /// One complete reply.
    public struct Reply: Equatable, Sendable {
        /// The three-digit code on the reply's LAST line.
        public let code: Int
        /// Everything the server said, trimmed. Carried whole because a 5xx
        /// line is what the shop is shown, and "550 5.7.1 relay denied" tells
        /// a shop what to fix where "refused" does not.
        public let text: String
        /// 4xx is a try-again and 5xx a refusal; both end the send.
        public var ok: Bool { code < 400 }

        /// The last line, which is the one that carries the reason.
        public var reason: String {
            text.components(separatedBy: "\r\n").last ?? text
        }
    }

    /// Has a whole reply arrived yet?
    ///
    /// `nil` means read again — NOT an error. A multi-line reply is `250-` on
    /// every line but the last, which is `250 `; the space is the terminator,
    /// not the newline.
    public static func replyIsComplete(_ buffer: String) -> Reply? {
        let lines = buffer.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard let last = lines.last else { return nil }
        // `/^\d{3} /` — and `\d` in JavaScript is ASCII, so this is too. A
        // check that accepted any Unicode digit would call ٢٥٠ a reply here
        // and fail to turn it into a number two lines down.
        let head = Array(last.unicodeScalars.prefix(4))
        guard head.count == 4, head[3] == " ",
              head[0...2].allSatisfy({ ("0"..."9").contains($0) })
        else { return nil }
        let code = head[0...2].reduce(0) { $0 * 10 + Int($1.value - 48) }
        return Reply(code: code, text: buffer.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Did the server offer to encrypt?
    ///
    /// ANCHORED TO A LINE. The obvious spelling — does the text contain
    /// "STARTTLS" — reads the same and is not: a server whose greeting banner
    /// or hostname carries the word would talk this app into sending a
    /// password in the clear, and a banner is chosen by whoever answers the
    /// socket. `lib/smtp-format.js` is anchored for the same reason.
    public static func offersStartTls(_ ehlo: String) -> Bool {
        // Split on any newline, not on CRLF: the module's `m` flag breaks on a
        // bare LF too, and a rule that disagreed there would be a rule this
        // app applied to input the other one had already accepted.
        for line in ehlo.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count > 4 else { continue }
            let prefix = trimmed.prefix(4)
            guard prefix == "250 " || prefix == "250-" else { continue }
            if trimmed.dropFirst(4).uppercased() == "STARTTLS" { return true }
        }
        return false
    }

    // MARK: - Writing the message

    /// The whole DATA payload, terminating dot included.
    ///
    /// The terminator comes back as part of this rather than being left to the
    /// transport: it is the one thing in the protocol whose absence is not an
    /// error but a hang, and a transport that forgets it waits for a reply the
    /// server will never send.
    public static func buildMessage(from: String, fromName: String, to: String,
                                    subject: String, html: String) -> String {
        let safeFrom = sanitizeHeader(from)
        let safeTo = sanitizeHeader(to)
        let safeFromName = sanitizeHeader(fromName)
        let safeSubject = sanitizeHeader(subject)
        let fromLine = safeFromName.isEmpty ? safeFrom : "\(safeFromName) <\(safeFrom)>"
        let headers = [
            "From: \(fromLine)",
            "To: \(safeTo)",
            "Subject: \(safeSubject)",
            "MIME-Version: 1.0",
            "Content-Type: text/html; charset=UTF-8",
            "",
        ].joined(separator: "\r\n")
        return dotStuff("\(headers)\r\n\(html)") + "\r\n."
    }

    /// `AUTH LOGIN`'s two payloads, in the order the server asks for them.
    ///
    /// Base64 and nothing else — not encryption. This is why the STARTTLS
    /// check above is not optional: the password goes down the socket in a
    /// form anyone watching can read back.
    public static func authLoginPayloads(user: String, pass: String) -> [String] {
        [Data(user.utf8).base64EncodedString(), Data(pass.utf8).base64EncodedString()]
    }
}
