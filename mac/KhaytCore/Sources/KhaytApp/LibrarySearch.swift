import Foundation
import KhaytCore

/// What the library's search box asks for: free text, and `field:value`
/// tokens that each narrow on one property.
///
/// `tag:dragon group:"Saudi Kings" material:PLA` reads as three filters and no
/// free text. A value with a space in it is quoted — straight quotes, curly
/// ones (which a Mac types on its own) or «guillemets». The field names have
/// Arabic spellings too (`وسم:تنين`), because a shop typing in Arabic should
/// not have to switch keyboards for four letters of English.
///
/// ── ONE STRING, NOT A SECOND STATE ───────────────────────────────────────
///
/// The tokens live in `Shop.search` itself and are parsed from it, so the
/// field, the chips above the grid and ⌘K's history can never disagree about
/// what is being searched. Removing a chip removes its text from the box.
///
/// Every value is matched FOLDED (`SearchText`), as the free text always was:
/// case, width, Latin accents, harakat, alef forms and Arabic-Indic digits do
/// not decide what is found. A value matches when the model's property
/// CONTAINS it, so a token half-typed already narrows.
struct LibrarySearch: Equatable, Sendable {

    enum Field: String, CaseIterable, Sendable {
        case tag, group, category, material, creator, printer

        /// What the chip calls it.
        var wordKey: String { "mac.lib_token_" + rawValue }

        /// The names a field is typed as, folded. English first; each Arabic
        /// one is the word the app's own menus use for that axis.
        static let spellings: [String: Field] = {
            let names: [(String, Field)] = [
                ("tag", .tag), ("tags", .tag), ("وسم", .tag), ("الوسم", .tag),
                ("group", .group), ("مجموعة", .group), ("المجموعة", .group),
                ("category", .category), ("فئة", .category), ("تصنيف", .category), ("التصنيف", .category),
                ("material", .material), ("خامة", .material), ("مادة", .material), ("الخامة", .material),
                ("creator", .creator), ("by", .creator), ("مصمم", .creator), ("المصمم", .creator),
                ("printer", .printer), ("طابعة", .printer), ("الطابعة", .printer),
            ]
            return Dictionary(names.map { (SearchText.fold($0.0), $0.1) }, uniquingKeysWith: { a, _ in a })
        }()

        static func named(_ typed: String) -> Field? { spellings[SearchText.fold(typed)] }
    }

    struct Token: Equatable, Sendable {
        let field: Field
        /// As typed, unquoted — what the chip shows.
        let value: String
        /// `value`, folded — what is matched.
        let folded: String
        /// The token's exact text in the search, quotes and all.
        let source: String
        /// Where it sits in the search, in Characters — what removing its chip
        /// takes out. Two chips with the same text are two places.
        let range: Range<Int>
    }

    /// The free text, folded, as one phrase (the search always matched the
    /// whole phrase: "model 12" is not "model" and "12" anywhere).
    var text: String
    var tokens: [Token]

    var isEmpty: Bool { text.isEmpty && tokens.isEmpty }

    /// Closing quote for each opening one.
    private static let quotes: [Character: Character] = [
        "\"": "\"", "\u{201C}": "\u{201D}", "\u{201D}": "\u{201D}", "\u{00AB}": "\u{00BB}", "\u{00BB}": "\u{00AB}",
    ]
    /// A colon, ASCII or full-width.
    private static func isColon(_ c: Character) -> Bool { c == ":" || c == "\u{FF1A}" }

    static func parse(_ raw: String) -> LibrarySearch {
        let chars = Array(raw)
        var i = 0
        var free: [String] = []
        var tokens: [Token] = []
        while i < chars.count {
            if chars[i].isWhitespace { i += 1; continue }
            let start = i
            var j = i
            while j < chars.count, !chars[j].isWhitespace, !isColon(chars[j]) { j += 1 }
            if j < chars.count, j > i, isColon(chars[j]), let field = Field.named(String(chars[i..<j])) {
                var k = j + 1
                let value: String
                if k < chars.count, let close = quotes[chars[k]] {
                    k += 1
                    let from = k
                    while k < chars.count, chars[k] != close { k += 1 }
                    value = String(chars[from..<k])
                    if k < chars.count { k += 1 }
                } else {
                    let from = k
                    while k < chars.count, !chars[k].isWhitespace { k += 1 }
                    value = String(chars[from..<k])
                }
                // `tag:` with nothing after it yet asks for nothing — and is
                // not free text either, or typing the colon would search for
                // the word "tag".
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    tokens.append(Token(field: field, value: trimmed, folded: SearchText.fold(trimmed),
                                        source: String(chars[start..<k]), range: start..<k))
                }
                i = k
                continue
            }
            while j < chars.count, !chars[j].isWhitespace { j += 1 }
            free.append(String(chars[start..<j]))
            i = j
        }
        return LibrarySearch(text: SearchText.fold(free.joined(separator: " ")), tokens: tokens)
    }

    /// Can the answer to this query be found among the answer to `older`?
    ///
    /// True when every condition `older` set is still here at least as tight:
    /// its phrase inside this one's, and its tokens, in order, each holding
    /// the value it held. `LibraryMemo` narrows the last list instead of
    /// searching the book again only then. Typing the colon of `tag:` turns
    /// the free word "tag" into a token, which is NOT narrower, and starts over.
    func narrows(from older: LibrarySearch) -> Bool {
        guard older.text.isEmpty || text.contains(older.text) else { return false }
        guard older.tokens.count <= tokens.count else { return false }
        for (was, now) in zip(older.tokens, tokens) {
            guard was.field == now.field, now.folded.contains(was.folded) else { return false }
        }
        return true
    }

    /// The search with one token's text taken out — at the place it was
    /// parsed from, not the first place the same text appears — and the
    /// rest of what was typed exactly as it was, spaces in quotes included.
    static func removing(_ token: Token, from raw: String) -> String {
        let chars = Array(raw)
        guard token.range.upperBound <= chars.count,
              String(chars[token.range]) == token.source else { return raw }
        let before = String(chars[..<token.range.lowerBound])
        let after = String(chars[token.range.upperBound...])
        let left = before.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        let right = after.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
        return left.isEmpty || right.isEmpty ? left + right : left + " " + right
    }
}
