import Foundation

/// A saved message, with this job's facts put into it — ported to Swift.
///
/// A shop writes its templates once and sends them from whichever app it has
/// open. If the two apps knew different placeholder names, a template written
/// in one would go out of the other with `{{due}}` printed literally, to a
/// customer. So WHICH placeholders exist, and what stands in for a blank, is
/// one rule — this one, checked against `lib/wa-template.js`.
///
/// What a price LOOKS like is not shared: that is a currency, a locale and a
/// digit system, and each app already has an answer the rest of its screen
/// agrees with. This takes text and puts it in place.
public enum WaTemplate {

    /// Every placeholder a template may use, in the order the editor lists them.
    /// `shop`, `tracking` and `carrier` came with the WhatsApp milestone
    /// updates, at the end so the first six keep their places.
    public static let placeholders = ["client", "id", "price", "currency", "due", "status",
                                      "shop", "tracking", "carrier"]

    /// What is printed when a value is missing.
    ///
    /// Not the same mark for both. A nameless customer gets `...` because the
    /// sentence is addressed to somebody and has to keep its shape — "Hi ...,
    /// your order is ready" reads as a template somebody forgot to fill, which
    /// is what it is and what the shop should notice before sending. A missing
    /// date gets an em dash, the mark this app uses everywhere for a figure it
    /// does not have.
    public static let blanks = ["client": "...", "due": "—"]

    /// The template with the values in it.
    ///
    /// ── ONE PASS ──────────────────────────────────────────────────────────
    ///
    /// Six replacements in a row would run over their own output: a value
    /// inserted by the first is searched by the second, so a customer named
    /// `{{price}}` would have a price printed as their name. The original was
    /// written that way and this is not.
    public static func fill(_ body: String?, values: [String: String]) -> String {
        let source = body ?? ""
        var out = ""
        out.reserveCapacity(source.count)
        var i = source.startIndex
        while i < source.endIndex {
            guard source[i] == "{",
                  let after = source.index(i, offsetBy: 2, limitedBy: source.endIndex),
                  source[source.index(after: i)] == "{",
                  let close = source.range(of: "}}", range: after..<source.endIndex)
            else {
                out.append(source[i]); i = source.index(after: i); continue
            }
            let key = String(source[after..<close.lowerBound])
            guard placeholders.contains(key) else {
                out.append(source[i]); i = source.index(after: i); continue
            }
            let given = values[key] ?? ""
            out += given.isEmpty ? (blanks[key] ?? "") : given
            i = close.upperBound
        }
        return out
    }

    /// Whether a template mentions a placeholder — so a caller can skip
    /// resolving a figure nothing is going to print.
    public static func uses(_ body: String?, _ key: String) -> Bool {
        (body ?? "").contains("{{\(key)}}")
    }
}

/// One of the shop's saved messages.
public struct MessageTemplate: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let body: String
    /// The job milestone this template speaks for — `received`, `ready`,
    /// `shipped`, `delivered` — or empty for a message sent any time. A
    /// template with a milestone REPLACES Khayt's default words for that
    /// WhatsApp update (`lib/whatsapp-message.js:templateFor`).
    public let milestone: String
    /// `ar` or `en`, or empty for every customer whatever their language.
    public let lang: String

    public init(id: String, name: String, body: String, milestone: String = "", lang: String = "") {
        self.id = id; self.name = name; self.body = body
        self.milestone = milestone; self.lang = lang
    }

    /// The row as the book stores it — what `lib/whatsapp-message.js` reads.
    /// The two new fields only when set, so a template that has neither looks
    /// exactly like one the other app wrote.
    public var row: JSONValue {
        var out: [String: JSONValue] = ["id": .string(id), "name": .string(name), "body": .string(body)]
        if !milestone.isEmpty { out["milestone"] = .string(milestone) }
        if !lang.isEmpty { out["lang"] = .string(lang) }
        return .object(out)
    }

    /// The store key, which is the other app's.
    public static let collection = "waTemplates"

    /// The templates in a book, in the order they are stored.
    ///
    /// A row with no body is dropped: it can only produce an empty message,
    /// and a template that sends nothing is worse on the list than off it.
    public static func from(_ rows: [JSONValue]) -> [MessageTemplate] {
        rows.compactMap { row in
            guard case .object(let r) = row,
                  case .string(let id)? = r["id"], !id.isEmpty,
                  case .string(let body)? = r["body"], !body.isEmpty else { return nil }
            var name = ""
            if case .string(let n)? = r["name"] { name = n }
            var milestone = ""
            if case .string(let m)? = r["milestone"] { milestone = m }
            var lang = ""
            if case .string(let l)? = r["lang"] { lang = l }
            return MessageTemplate(id: id, name: name.isEmpty ? id : name, body: body,
                                   milestone: milestone, lang: lang)
        }
    }
}
