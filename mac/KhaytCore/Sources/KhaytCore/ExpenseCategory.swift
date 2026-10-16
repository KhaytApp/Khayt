import Foundation

/// What an expense's stored category MEANS — `lib/expense-book.js`
/// `normaliseCategory` / `categoryOf`, mirrored.
///
/// The iPhone's expense sheet saved `power`, `rent`, `resin` and `parts` until
/// it was fixed, and none of them is a category the book knows. Every reader
/// grouped such a row under its own unknown key: it counted in the total and
/// matched no picker, budget or chart bucket. They are read as what they meant
/// rather than rewritten, so a row on disk keeps what it was saved with.
///
/// `resin` is `other`, NOT filament: filament is stock, left out of the P&L's
/// operating expenses, and resin is not tracked as stock anywhere.
///
/// The map is written out here rather than asked of the engine because the
/// readers are synchronous (`Expense`'s decoder, the category-chart port) and
/// the engine is an actor. `ExpenseCategoryParityTests` holds both the map and
/// the list to the JavaScript's, so the two cannot drift.
public enum ExpenseCategory {

    /// Khayt's own categories, in its own order — `CATEGORIES`.
    public static let known = ["filament", "electricity", "maintenance", "tools", "equipment", "shipping", "other"]

    /// Categories a book holds that the list never had — `CATEGORY_ALIASES`.
    public static let aliases: [String: String] = [
        "power": "electricity",
        "parts": "maintenance",
        "rent": "other",
        "resin": "other",
    ]

    /// One of `known` when the value is one (any case, surrounding spaces
    /// ignored) or an alias of one; anything else exactly as it was.
    public static func normalise(_ raw: String) -> String {
        // JavaScript's `trim()` and `toLowerCase()`: whitespace and line breaks.
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if known.contains(key) { return key }
        if let meant = aliases[key] { return meant }
        return raw
    }

    /// The same for a raw JSON value: only a string is normalised, anything
    /// else (absent, a number) is handed back untouched, as the JavaScript
    /// does.
    public static func normalise(_ raw: JSONValue?) -> JSONValue? {
        guard case .string(let s)? = raw else { return raw }
        return .string(normalise(s))
    }
}
