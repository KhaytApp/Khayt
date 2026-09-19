import Foundation
import KhaytCore

/// Somebody the shop buys from.
///
/// ── WHY THIS APP NEEDED ONE AT ALL ────────────────────────────────────────
///
/// A supplier is not a contact card. It is where the price a reorder is drafted
/// at comes from: `lib/reorder.js` asks the suppliers list what a kilo of a
/// material costs before it falls back to dividing a spool's own cost by its
/// weight. This app could READ that list — every order it drafts is priced
/// through it — and could not write a line of it, so a shop that had been
/// quoted a better rate had to open the other window to say so, and every order
/// drafted here went on using the old figure.
///
/// Thin, like `PurchaseOrder`: what a row and a form need, and nothing that
/// decides anything. `purchases` is carried as a count and a total rather than
/// as records, because what a supplier costs the shop is a figure to show, and
/// the records themselves are the other app's purchase log.
struct Supplier: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    /// One of `Supplier.categories`. A book may carry something else — the
    /// other app has never validated it — so an unknown one reads as `other`
    /// for the picker and is written back as it was found.
    var category: String
    var phone: String
    /// Days between ordering and arriving, as the shop has found it. Nil when
    /// the shop has never said.
    var leadDays: Int?
    var website: String
    var notes: String
    /// What this supplier quotes, per kilogram, per material.
    var priceList: [Quote]

    /// How many purchases have been logged against it, and what they came to.
    let purchaseCount: Int
    let totalSpent: Double

    /// A quoted rate: a material, and what a kilo of it costs.
    struct Quote: Identifiable, Hashable, Sendable {
        /// Made here and kept for the form's sake — a quote has no id in the
        /// book, and two rows for the same material must still be two rows
        /// while somebody is typing.
        let id = UUID()
        var material: String
        var pricePerKg: Double

        static func == (a: Quote, b: Quote) -> Bool {
            a.material == b.material && a.pricePerKg == b.pricePerKg && a.id == b.id
        }
    }

    /// The categories the other app offers, in its order. `other` is the
    /// default there and is the default here.
    static let categories = ["filament", "hardware", "tools", "packaging", "services", "other"]

    /// A new one, before it has been saved.
    static func blank() -> Supplier {
        Supplier(id: "", name: "", category: "other", phone: "", leadDays: nil,
                 website: "", notes: "", priceList: [],
                 purchaseCount: 0, totalSpent: 0)
    }

    @MainActor
    init?(row: JSONValue) {
        guard case .object(let o) = row,
              case .string(let id)? = o["id"], !id.isEmpty else { return nil }
        self.id = id
        self.name = Shop.plainString(o["name"]) ?? id
        self.category = Shop.plainString(o["category"]) ?? "other"
        self.phone = Shop.plainString(o["phone"]) ?? ""
        // A lead time of zero is the shop saying nothing, which is how the
        // other app writes it: `leadDays: num(...) || null`.
        let lead = Shop.plainNumber(o["leadDays"]) ?? 0
        self.leadDays = lead > 0 ? Int(lead.rounded()) : nil
        self.website = Shop.plainString(o["website"]) ?? ""
        self.notes = Shop.plainString(o["notes"]) ?? ""
        if case .array(let quoted)? = o["priceList"] {
            self.priceList = quoted.compactMap { q in
                guard case .object(let row) = q else { return nil }
                let material = Shop.plainString(row["material"]) ?? ""
                let price = Shop.plainNumber(row["pricePerKg"]) ?? 0
                guard !material.isEmpty, price > 0 else { return nil }
                return Quote(material: material, pricePerKg: price)
            }
        } else {
            self.priceList = []
        }
        if case .array(let bought)? = o["purchases"] {
            self.purchaseCount = bought.count
            self.totalSpent = bought.reduce(0) { sum, p in
                guard case .object(let row) = p else { return sum }
                return sum + (Shop.plainNumber(row["amount"]) ?? 0)
            }
        } else {
            self.purchaseCount = 0
            self.totalSpent = 0
        }
    }

    private init(id: String, name: String, category: String, phone: String,
                 leadDays: Int?, website: String, notes: String, priceList: [Quote],
                 purchaseCount: Int, totalSpent: Double) {
        self.id = id
        self.name = name
        self.category = category
        self.phone = phone
        self.leadDays = leadDays
        self.website = website
        self.notes = notes
        self.priceList = priceList
        self.purchaseCount = purchaseCount
        self.totalSpent = totalSpent
    }

    /// What a save should put into the book, WITHOUT the fields this app does
    /// not own.
    ///
    /// ── THE RE-ENCODING TRAP, AGAIN ───────────────────────────────────────
    ///
    /// A Mac product save once dropped the part-cost fields off a product and
    /// re-priced it, because it wrote back only what its own form knew about.
    /// A supplier row carries `purchases` — the log the other app writes — and
    /// may carry fields neither app has named yet. So this returns only what
    /// the form CHANGED, and the write merges it onto the row already there.
    var edits: [String: JSONValue] {
        var out: [String: JSONValue] = [
            "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)),
            "category": .string(category),
            "phone": .string(phone.trimmingCharacters(in: .whitespaces)),
            "website": .string(website.trimmingCharacters(in: .whitespaces)),
            "notes": .string(notes.trimmingCharacters(in: .whitespacesAndNewlines)),
            "priceList": .array(priceList.compactMap { q in
                let material = q.material.trimmingCharacters(in: .whitespaces)
                guard !material.isEmpty, q.pricePerKg > 0 else { return nil }
                return JSONValue.object(["material": .string(material),
                                         "pricePerKg": .number(q.pricePerKg)])
            }),
        ]
        // Null, not absent, and not zero: the other app writes `|| null` and a
        // stored 0 would read back as "no lead time" anyway. Writing null says
        // the shop cleared it.
        out["leadDays"] = leadDays.map { JSONValue.number(Double($0)) } ?? .null
        return out
    }
}
