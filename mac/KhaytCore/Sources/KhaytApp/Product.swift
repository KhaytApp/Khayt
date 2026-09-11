import Foundation
import KhaytCore

/// A product as the shop wrote it down — the editable record behind a
/// catalogue row.
///
/// `KhaytEngine.CatalogueRow` is what the catalogue DRAWS: one name in one
/// language, a price with its provenance, specs summed from the parts. It is
/// computed, and none of it can be typed back into. This is the other half: the
/// record itself, in the shape `products` actually holds.
///
/// ── THE NAME IS NOT A FIELD, IT IS ONE FIELD PER LANGUAGE ─────────────────
///
/// `lib/content-languages.js` decides the key: `nameEn`, `nameAr`, and
/// `name_de` for everything else. A shop chooses which languages its catalogue
/// carries, so the set of keys is the shop's, not this app's.
///
/// The Electron editor has a comment on exactly this, written the day it cost
/// somebody their data: its form wrote a field only if the draft already
/// carried that key, and the draft was seeded with `nameEn`/`nameAr` only — so
/// a shop writing German typed a product name, saved, and lost it in silence.
/// Storing the languages as a dictionary keyed by code is how that shape of bug
/// cannot happen here: there is no whitelist to fall outside of.
///
/// ── AND EVERYTHING ELSE ON THE RECORD IS THE SHOP'S ───────────────────────
///
/// A product carries price tiers, parts, components, a photo, documents and a
/// storefront link. This app offers none of those, so `rest` holds them and
/// hands them back untouched. A screen showing six fields must not delete the
/// other twenty — the same rule `saveCustomer` follows, and for the same reason.
struct Product: Identifiable, Sendable {

    /// One language the catalogue can carry, and the two record keys it owns.
    ///
    /// A struct rather than a tuple: the same four fields were written in two
    /// different orders within an hour of each other, which is the whole
    /// argument against tuples with more than two parts.
    struct LanguageKey: Identifiable, Hashable, Sendable {
        let language: String
        /// The language's own name — "Deutsch", not "German".
        let title: String
        let name: String
        let description: String
        var id: String { language }
    }

    var id: String
    /// Language code → name. Absent or blank is "not written in that language".
    var names: [String: String]
    var descriptions: [String: String]
    /// Per cent. Nil means the shop has not set one and the shared price rule
    /// falls back to the shop's default — which is not the same as zero.
    var margin: Double?
    var group: String
    var category: String
    var createdAt: String
    /// Every other field on the record, carried through a save untouched.
    var rest: [String: JSONValue]

    /// A name in any language the shop has, for a title that must say something.
    func anyName() -> String {
        for code in ["en", "ar"] {
            if let name = names[code]?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                return name
            }
        }
        return names.values
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    /// A product with no name in any language cannot be told from another.
    var hasAName: Bool { !anyName().isEmpty }

    // MARK: - Reading and writing the record

    /// Read one, given the language keys the shop is using.
    ///
    /// `languages` comes from the engine rather than being assumed, and the
    /// record is scanned for EVERY supported key rather than only those — a
    /// product written when the shop carried French still holds `name_fr`, and
    /// dropping it on save because French is switched off today would delete
    /// the shop's own text.
    static func from(_ record: [String: JSONValue], keys: [LanguageKey]) -> Product {
        var names: [String: String] = [:]
        var descriptions: [String: String] = [:]
        var rest = record
        for key in keys {
            if case .string(let value)? = record[key.name] { names[key.language] = value }
            if case .string(let value)? = record[key.description] { descriptions[key.language] = value }
            rest.removeValue(forKey: key.name)
            rest.removeValue(forKey: key.description)
        }
        for own in ["id", "defaultMargin", "group", "category", "createdAt"] {
            rest.removeValue(forKey: own)
        }
        var margin: Double?
        if case .number(let value)? = record["defaultMargin"] { margin = value }
        return Product(
            id: Self.text(record["id"]),
            names: names, descriptions: descriptions, margin: margin,
            group: Self.text(record["group"]), category: Self.text(record["category"]),
            createdAt: Self.text(record["createdAt"]),
            rest: rest)
    }

    /// Back to a record. Blank languages are REMOVED rather than written empty,
    /// so a shop that clears a translation does not leave `""` behind for the
    /// storefront to render as a product with no name.
    func record(keys: [LanguageKey]) -> [String: JSONValue] {
        var out = rest
        out["id"] = .string(id)
        out["createdAt"] = .string(createdAt)
        out["group"] = .string(group)
        out["category"] = .string(category)
        if let margin { out["defaultMargin"] = .number(margin) } else { out.removeValue(forKey: "defaultMargin") }
        for key in keys {
            let name = (names[key.language] ?? "").trimmingCharacters(in: .whitespaces)
            let description = (descriptions[key.language] ?? "").trimmingCharacters(in: .whitespaces)
            if name.isEmpty { out.removeValue(forKey: key.name) } else { out[key.name] = .string(name) }
            if description.isEmpty { out.removeValue(forKey: key.description) } else { out[key.description] = .string(description) }
        }
        return out
    }

    private static func text(_ value: JSONValue?) -> String {
        if case .string(let s)? = value { return s }
        return ""
    }
}
