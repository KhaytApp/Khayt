import Foundation

/// What a shop's Telegram bot says when a job moves.
///
/// The message was built inline in the other app's renderer, so the Mac —
/// which refuses any move that would reach outside the shop precisely because
/// it could not send one — had no way to say the same thing. A shop whose only
/// integration is a Telegram bot could not finish a job on the Mac at all.
///
/// The transport is NOT here. Sending is a platform's job — Electron has its
/// main process, the Mac has `URLSession` — and both send exactly this.
/// Named for the bot rather than for the module because `TelegramMessage` is
/// already the shape this hands back — the type a call site holds and sends.
public enum TelegramBot {

    /// Telegram's own limit. A longer message is refused, not truncated by them.
    public static let maxMessage = 4096

    /// Strip control characters and truncate.
    ///
    /// A project name is customer-supplied text going into a message someone
    /// reads on a phone: newlines and tabs let it forge a second line that
    /// looks like it came from the shop.
    ///
    /// `slice(0, 200)` counts UTF-16 code units, so this does too — 200 emoji
    /// is a longer string than 200 letters and the cut has to fall in the same
    /// place on both sides.
    public static func safe(_ value: JSONValue?) -> String {
        // OVER SCALARS, NOT CHARACTERS: "\r\n" is ONE Character in Swift, so a
        // walk over Characters matches neither "\r" nor "\n" and a Windows
        // line ending goes straight through — which is the exact thing this
        // function exists to stop. The parity harness caught it.
        var cleaned = String.UnicodeScalarView()
        for scalar in JSSemantics.text(value).unicodeScalars {
            cleaned.append(scalar == "\r" || scalar == "\n" || scalar == "\t" ? " " : scalar)
        }
        return String(decoding: Array(String(cleaned).utf16.prefix(200)), as: UTF16.self)
    }

    public static func safe(_ text: String) -> String { safe(JSONValue.string(text)) }

    /// The message for a status change, or nil when the shop has not asked for
    /// one — no bot configured, or this move is not one it wants told about.
    ///
    /// `money` is passed in because how a shop writes money is the app's
    /// business and not this module's. The default is `String(n)`, which is
    /// what the original falls back to.
    public static func forStatus(_ order: JSONValue?, newStatus: String,
                                 settings: [String: JSONValue],
                                 money: (JSONValue?) -> String = jsString)
        -> TelegramMessage? {
        guard case .object(let tg)? = settings["telegram"],
              JSSemantics.truthy(tg["botToken"]), JSSemantics.truthy(tg["chatId"])
        else { return nil }
        var o: [String: JSONValue] = [:]
        if case .object(let fields)? = order { o = fields }

        // `o.project || o.id` — a job with an empty project name falls back to
        // its id rather than announcing a blank.
        let what = JSSemantics.truthy(o["project"]) ? o["project"] : o["id"]

        var message = ""
        if newStatus == "completed" && JSSemantics.truthy(tg["notifyOnComplete"]) {
            message = "✅ Order completed: \(safe(what)) (\(money(o["price"])))"
        } else if newStatus == "on_hold" && JSSemantics.truthy(tg["notifyOnHold"]) {
            let why = JSSemantics.truthy(o["holdReason"]) ? " — " + safe(o["holdReason"]) : ""
            message = "⏸ Order on hold: \(safe(what))\(why)"
        }
        guard !message.isEmpty else { return nil }
        // The token and the chat id are read as TEXT. The original hands back
        // whatever the settings hold; a book with a number there decoded as
        // nothing across the old bridge and threw, so nobody can have been
        // relying on the difference.
        return TelegramMessage(botToken: JSSemantics.text(tg["botToken"]),
                       chatId: JSSemantics.text(tg["chatId"]),
                       message: message)
    }

    /// Whether a bot token is one Telegram could possibly accept.
    ///
    /// The same shape the Electron main process checks before it sends. A token
    /// that cannot be valid is a mistyped setting, and finding that out here
    /// rather than from a 401 is the difference between a message a shop can
    /// act on and a silence.
    public static func isBotToken(_ token: String) -> Bool {
        token.range(of: "^[0-9]+:[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    /// A chat id, as Telegram will accept one — or nil when it is not one.
    ///
    /// Telegram's `chat_id` is either a numeric id (negative for a group or
    /// channel) or a public `@username`. Khayt used to run every value through
    /// `[^0-9@-]`, which keeps the @ and THROWS THE NAME AWAY: a shop that
    /// typed `@khaytshop` was sending to `@`, getting a 400 back, and being
    /// told nothing. That had been true for as long as the feature existed.
    ///
    /// So: recognise the two shapes Telegram documents, trim, and refuse
    /// anything else rather than mangle it into something that cannot work.
    public static func chatId(_ value: String) -> String? {
        // `.trim()` also strips the byte-order mark, which Swift's whitespace
        // set does not — a value pasted from a spreadsheet can carry one.
        let raw = value.trimmingCharacters(in: jsWhitespace)
        guard !raw.isEmpty else { return nil }
        if raw.range(of: "^-?[0-9]+$", options: .regularExpression) != nil { return raw }
        let name = raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
        // A username is 5–32 characters of letters, digits and underscores,
        // which is Telegram's own rule, and must not be all digits.
        guard name.range(of: "^[A-Za-z0-9_]{5,32}$", options: .regularExpression) != nil,
              name.range(of: "[A-Za-z_]", options: .regularExpression) != nil else { return nil }
        return "@" + name
    }

    /// Whether a shop's chat id is one Telegram could deliver to.
    public static func isChatId(_ value: String) -> Bool { chatId(value) != nil }

    /// `String(n)` — which prints a missing value as "undefined" and a null as
    /// "null", where the join-style coercion prints both as empty. This is the
    /// module's own fallback for a caller that passes no formatter; every
    /// caller in this app passes one.
    public static func jsString(_ value: JSONValue?) -> String {
        guard let value else { return "undefined" }
        if case .null = value { return "null" }
        return JSSemantics.text(value)
    }

    /// What `String.prototype.trim` strips: Unicode whitespace, the line
    /// terminators, and U+FEFF.
    static let jsWhitespace: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: "\u{FEFF}")
        return set
    }()
}
