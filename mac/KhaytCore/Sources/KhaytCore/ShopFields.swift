import Foundation

/// The shop's own fields as a document prints them — the seller block of an
/// invoice — read from the book's settings.
///
/// In KhaytCore so the Mac and the iPhone print the same seller from the same
/// rule. It was the Mac's alone (`Shop.shopDocumentFields`), and a phone that
/// drew invoices would otherwise have kept a copy of it.
public enum ShopFields {

    /// Every field an invoice asks the shop for: `biz`, `addr`, `tagline` and
    /// `footer`, each its English spelling when filled in, else its Arabic.
    ///
    /// The document used to be handed the name and the address and nothing
    /// else, and its `shopField` answered the shop's NAME for the other two —
    /// so every invoice printed the name twice at the top and again in the
    /// footer, and the tagline the shop had typed into Settings appeared nowhere.
    public static func document(_ settings: [String: JSONValue]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for base in ["biz", "addr", "tagline", "footer"] {
            out[base] = .string(value(base, settings))
        }
        return out
    }

    /// One field, English first. NOT in the reader's language: for the name in
    /// the shop's language, ask the engine (`KhaytEngine.shopText`).
    public static func value(_ base: String, _ settings: [String: JSONValue]) -> String {
        for key in ["\(base)En", "\(base)Ar"] {
            if case .string(let v)? = settings[key], !v.isEmpty { return v }
        }
        return ""
    }
}
