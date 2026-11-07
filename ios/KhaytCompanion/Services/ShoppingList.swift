import Foundation
import KhaytCore

/**
 * Values read the way JavaScript reads them, for the ports that must answer
 * exactly as the shared rules do (`ReorderRules`, `EnergyRules`).
 *
 * `toNumber` is `+v` / `Number(v)`: a missing value is NaN, `null` and `""`
 * are 0, a numeric string is its number. `text` is `String(v)`. `truthy` is
 * JavaScript's truthiness. The ported rules are written in these terms so a
 * stored string or null lands where the JavaScript puts it.
 */
enum JSRead {
    static func toNumber(_ v: JSONValue?) -> Double {
        switch v {
        case nil: return .nan
        case .null?: return 0
        case .bool(let b)?: return b ? 1 : 0
        case .number(let n)?: return n
        case .string(let s)?: return number(in: s)
        case .array(let a)?:
            if a.isEmpty { return 0 }
            if a.count == 1 { return number(in: text(a[0])) }
            return .nan
        case .object?: return .nan
        }
    }

    /// JavaScript's StringToNumber, for the shapes a book can hold: blank is
    /// 0, a decimal (with an exponent, a sign, a leading or trailing point)
    /// or `Infinity` is its number, `0x`/`0o`/`0b` an integer, else NaN.
    static func number(in s: String) -> Double {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return 0 }
        switch t {
        case "Infinity", "+Infinity": return .infinity
        case "-Infinity": return -.infinity
        default: break
        }
        let lower = t.lowercased()
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where lower.hasPrefix(prefix) {
            let digits = lower.dropFirst(2)
            guard !digits.isEmpty, let n = UInt64(digits, radix: radix) else { return .nan }
            return Double(n)
        }
        // Only digits, a sign, a point and an exponent: Swift's parser also
        // takes "nan", "inf" and hex floats, which JavaScript does not.
        let allowed = Set("0123456789+-.eE")
        guard t.allSatisfy({ allowed.contains($0) }), let d = Double(t) else { return .nan }
        return d
    }

    /// `String(v)`. `undefined` is spelled as JavaScript spells it.
    static func text(_ v: JSONValue?) -> String {
        switch v {
        case nil: return "undefined"
        case .null?: return "null"
        case .bool(let b)?: return b ? "true" : "false"
        case .number(let n)?: return numberText(n)
        case .string(let s)?: return s
        case .array(let a)?:
            return a.map { el -> String in
                if case .null = el { return "" }
                return text(el)
            }.joined(separator: ",")
        case .object?: return "[object Object]"
        }
    }

    static func numberText(_ n: Double) -> String {
        if n.isNaN { return "NaN" }
        if n.isInfinite { return n > 0 ? "Infinity" : "-Infinity" }
        if n == n.rounded(), abs(n) < 1e21 { return String(Int64(n)) }
        return String(n)
    }

    static func truthy(_ v: JSONValue?) -> Bool {
        switch v {
        case nil, .null?: return false
        case .bool(let b)?: return b
        case .number(let n)?: return n != 0 && !n.isNaN
        case .string(let s)?: return !s.isEmpty
        case .array?, .object?: return true
        }
    }

    /// `a === b` for the values a book holds: primitives by value, an array
    /// or an object never (two parsed records are never the same object).
    static func strictlyEqual(_ a: JSONValue?, _ b: JSONValue?) -> Bool {
        switch (a, b) {
        case (nil, nil), (.null?, .null?): return true
        case (.bool(let x)?, .bool(let y)?): return x == y
        case (.number(let x)?, .number(let y)?): return x == y
        case (.string(let x)?, .string(let y)?): return x == y
        default: return false
        }
    }

    /// `Math.round`: halves go up, toward +∞ — and without the `x + 0.5`
    /// error that rounds 0.49999999999999994 to 1.
    static func round(_ x: Double) -> Double {
        guard x.isFinite else { return x }
        let down = x.rounded(.down)
        return x - down >= 0.5 ? down + 1 : down
    }

    /// A collection of the book, or none.
    static func rows(_ store: [String: JSONValue], _ collection: String) -> [JSONValue] {
        if case .array(let r)? = store[collection] { return r }
        return []
    }
}

/**
 * The shopping list on the phone: `lib/reorder.js` `shoppingList` and
 * `shoppingListText`, with the low-stock rule they are handed on the Mac
 * (`KhaytOrderDeduction.isLowStock`, which asks `lib/inventory-units.js`
 * `lowThreshold`), in Swift.
 *
 * ── WHY A PORT ───────────────────────────────────────────────────────────
 *
 * The same reason as `CareRules`: the list is drawn from the book on the
 * phone, synchronously, and it is a handful of pure rules. What keeps it
 * honest is `ShoppingListParityTests`, which runs the REAL `lib/reorder.js`,
 * `lib/order-deduction.js` and `lib/inventory-units.js` in JavaScriptCore
 * against this file — the Mac's own call (`KhaytEngine.shoppingList`), word
 * for word. Change the JavaScript and that test says so.
 *
 * Values are read as the JavaScript reads them (`JSRead`): `+item.weight`,
 * `item.reorderQty || 1000`, a supplier's `pricePerKg` as a string.
 *
 * ── WHAT IT IS NOT ───────────────────────────────────────────────────────
 *
 * A planning aid. Nothing here orders anything, and it shows no money: what
 * is on the shelf and how much to buy, in grams, by who sells it.
 */
enum ReorderRules {

    // MARK: - lib/inventory-units.js

    /// `num`: absent, `null` and `""` are null — not zero.
    static func unitNum(_ v: JSONValue?) -> Double? {
        switch v {
        case nil, .null?: return nil
        case .string(let s)? where s.isEmpty: return nil
        default:
            let n = JSRead.toNumber(v)
            return n.isFinite ? n : nil
        }
    }

    /// `unitOf`: grams unless the item says ml or sheet.
    static func unitOf(_ item: [String: JSONValue]) -> String {
        let said = JSRead.truthy(item["unit"]) ? JSRead.text(item["unit"]) : ""
        let u = said.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["g", "ml", "sheet"].contains(u) ? u : "g"
    }

    /// Each unit's own low mark (`SPEC[unit].low`).
    static let unitLow: [String: Double] = ["g": 200, "ml": 150, "sheet": 2]

    /// `lowThreshold`: the item's reorder point, then the shop's threshold
    /// (grams only), then the unit's default.
    static func lowThreshold(_ item: [String: JSONValue], settings: [String: JSONValue]) -> Double {
        if let own = unitNum(item["reorderPoint"]) { return own }
        let unit = unitOf(item)
        if unit == "g", let shopWide = unitNum(settings["lowStockThreshold"]) { return shopWide }
        return unitLow[unit] ?? 200
    }

    /// `KhaytOrderDeduction.isLowStock`, with the units module loaded (as it
    /// is in every app): at or under the threshold.
    static func isLowStock(_ item: [String: JSONValue], settings: [String: JSONValue]) -> Bool {
        let w = JSRead.toNumber(item["weight"])
        let have = (w.isNaN || w == 0) ? 0 : w
        return have <= lowThreshold(item, settings: settings)
    }

    // MARK: - lib/reorder.js, the supplier

    /// `famToken`: the first run of a letter then letters, digits or `+`.
    static func famToken(_ s: String) -> String {
        let upper = s.uppercased()
        guard let r = upper.range(of: "[A-Z][A-Z0-9+]*", options: .regularExpression) else { return "" }
        return String(upper[r])
    }

    private static let separators = try! NSRegularExpression(pattern: #"[\s_-]+"#)

    /// `foldMaterial`: case ignored; `-`, `_` and runs of spaces one space.
    static func foldMaterial(_ s: String) -> String {
        let lower = s.lowercased()
        let folded = separators.stringByReplacingMatches(
            in: lower, range: NSRange(lower.startIndex..., in: lower), withTemplate: " ")
        return folded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func containsWords(_ a: String, _ b: String) -> Bool {
        (" " + a + " ").contains(" " + b + " ")
    }

    struct Quote: Equatable {
        let supplierId: JSONValue?
        let supplierName: String
        let pricePerKg: Double
    }

    /// What a supplier's `priceList` can be walked as. A truthy value that is
    /// not a list or a string makes `for…of` throw in the JavaScript.
    private enum Walk { case rows([JSONValue]), nothing, throwsTypeError }

    private static func walk(_ v: JSONValue?) -> Walk {
        guard JSRead.truthy(v) else { return .nothing }
        switch v {
        case .array(let a)?: return .rows(a)
        // A string walks as its characters, none of which carries a price.
        case .string?: return .nothing
        default: return .throwsTypeError
        }
    }

    struct Thrown: Error {}

    /// `supplierPriceFor`: the closest price-list entry across every
    /// supplier — the same name, then whole words (sharing the most), then
    /// the family token, then any containment; price breaks a tie only within
    /// the closest rank. Throws where the JavaScript does (a `priceList` that
    /// is neither a list nor a string).
    static func supplierPriceFor(_ suppliers: [JSONValue], material: JSONValue?) throws -> Quote? {
        let name = (material == nil || material == .null) ? "" : JSRead.text(material)
        let fam = famToken(name)
        let ml = foldMaterial(name)
        var best: Quote?
        var bestRank = 0
        var bestShared = 0
        for s in suppliers {
            guard case .object(let seller) = s else { continue }
            let entries: [JSONValue]
            switch walk(seller["priceList"]) {
            case .rows(let r): entries = r
            case .nothing: continue
            case .throwsTypeError: throw Thrown()
            }
            for e in entries {
                var pk: Double = 0
                var entryMaterial: JSONValue?
                if JSRead.truthy(e) {
                    if case .object(let entry) = e {
                        pk = JSRead.toNumber(entry["pricePerKg"])
                        entryMaterial = entry["material"]
                    } else {
                        pk = .nan
                    }
                }
                if pk.isNaN { pk = 0 }
                guard pk > 0 else { continue }
                let emText = JSRead.truthy(e) && entryMaterial != nil && entryMaterial != .null
                    ? JSRead.text(entryMaterial) : ""
                let em = foldMaterial(emText)
                guard !em.isEmpty else { continue }
                var rank = 0
                if !ml.isEmpty && em == ml { rank = 4 }
                else if !ml.isEmpty && (containsWords(ml, em) || containsWords(em, ml)) { rank = 3 }
                else if !fam.isEmpty && famToken(em) == fam { rank = 2 }
                else if !ml.isEmpty && (ml.contains(em) || em.contains(ml)) { rank = 1 }
                if rank == 0 || rank < bestRank { continue }
                let shared = rank == 3 ? min(em.utf16.count, ml.utf16.count) : 0
                if rank == bestRank, let b = best {
                    if shared != bestShared {
                        if shared < bestShared { continue }
                    } else if pk >= b.pricePerKg { continue }
                }
                best = Quote(supplierId: seller["id"],
                             supplierName: JSRead.truthy(seller["name"]) ? JSRead.text(seller["name"]) : "",
                             pricePerKg: pk)
                bestRank = rank
                bestShared = shared
            }
        }
        return best
    }

    // MARK: - lib/reorder.js, the list

    struct Item: Equatable, Identifiable {
        /// The spool's id (`""` when it has none) — not unique on a hand-edited
        /// book, so the screens key rows by position.
        let id: String
        let name: String
        let have: Double
        let buy: Double
        let color: String
    }

    struct Group: Equatable, Identifiable {
        let supplier: String
        let items: [Item]
        var id: String { supplier }
    }

    /// `shoppingList(inventory, suppliers, { isLow: isLowStock(·, settings),
    /// noSupplier })` — every item at or under its reorder point, grouped by
    /// the supplier that prices its material, else its own `supplierId`'s,
    /// else `noSupplier`. Groups in the order `sort()` gives their names
    /// (UTF-16 code units), items in shelf order.
    static func shoppingList(inventory: [JSONValue], suppliers: [JSONValue], settings: [String: JSONValue],
                             noSupplier: String) -> [Group] {
        let fallback = noSupplier.isEmpty ? "No supplier set" : noSupplier
        var order: [String] = []
        var groups: [String: [Item]] = [:]
        for row in inventory {
            // A truthy row that is not a record reads as one with no fields,
            // as `item.weight` on a string does in the JavaScript.
            guard JSRead.truthy(row) else { continue }
            var item: [String: JSONValue] = [:]
            if case .object(let o) = row { item = o }
            guard isLowStock(item, settings: settings) else { continue }
            var supName = ""
            if let quote = try? supplierPriceFor(suppliers, material: item["material"]) {
                supName = quote.supplierName
            }
            if supName.isEmpty, JSRead.truthy(item["supplierId"]) {
                let seller = suppliers.first { s in
                    guard case .object(let o) = s else { return false }
                    return JSRead.strictlyEqual(o["id"], item["supplierId"])
                }
                if case .object(let o)? = seller, JSRead.truthy(o["name"]) { supName = JSRead.text(o["name"]) }
            }
            if supName.isEmpty { supName = fallback }
            let weight = JSRead.toNumber(item["weight"])
            var qty = JSRead.toNumber(item["reorderQty"])
            if qty.isNaN || qty == 0 { qty = 1000 }
            if groups[supName] == nil { order.append(supName) }
            groups[supName, default: []].append(Item(
                id: item["id"] == nil || item["id"] == .null ? "" : JSRead.text(item["id"]),
                name: JSRead.truthy(item["material"]) ? JSRead.text(item["material"]) : "Filament",
                have: JSRead.round(weight.isNaN ? 0 : weight),
                buy: JSRead.round(qty),
                color: JSRead.truthy(item["color"]) ? JSRead.text(item["color"]) : "#888"))
        }
        return order
            .sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            .map { Group(supplier: $0, items: groups[$0] ?? []) }
    }

    /// `shoppingListText`: a title line, a blank, then each supplier and its
    /// items as "  • Name   120 g → 1000 g", a blank after each.
    ///
    /// The unit stays the JavaScript's literal "g", in every language: this is
    /// the text the Mac and the desktop copy, and the parity test holds it to
    /// theirs. The page itself writes grams with `L10n.grams`.
    static func shoppingListText(_ groups: [Group], title: String) -> String {
        let unit = "g"
        var lines = [title, ""]
        for g in groups {
            lines.append(g.supplier)
            for r in g.items {
                let have = JSRead.numberText(r.have), buy = JSRead.numberText(r.buy)
                lines.append("  \u{2022} \(r.name)   \(have) \(unit) \u{2192} \(buy) \(unit)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - The list as this phone holds it

/// The shopping list out of the phone's book. Inventory and suppliers travel
/// whole (`BookScope`), so the list is the shop's, not a window of it.
struct ShopShoppingList {
    var groups: [ReorderRules.Group] = []
    /// The title the text is shared under: "Shopping list — <shop>".
    var title: String = ""

    var isEmpty: Bool { groups.allSatisfy { $0.items.isEmpty } }
    var text: String { ReorderRules.shoppingListText(groups, title: title) }

    init() {}

    init(store: [String: JSONValue], shopName: String) {
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = store["settings"] { settings = s }
        let name = shopName.trimmingCharacters(in: .whitespacesAndNewlines)
        title = L10n.tr("shop.title") + " \u{2014} " + (name.isEmpty ? "Khayt" : name)
        groups = ReorderRules.shoppingList(inventory: JSRead.rows(store, "inventory"),
                                           suppliers: JSRead.rows(store, "suppliers"),
                                           settings: settings, noSupplier: L10n.tr("shop.no_supplier"))
    }
}
