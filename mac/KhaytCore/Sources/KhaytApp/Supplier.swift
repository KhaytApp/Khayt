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

    /// What has been bought from it, newest first — the log the other app
    /// keeps and this one can now add to.
    let purchases: [Purchase]

    /// How many purchases have been logged against it, and what they came to.
    var purchaseCount: Int { purchases.count }
    var totalSpent: Double {
        (purchases.reduce(0) { $0 + $1.amount } * 100).rounded() / 100
    }

    /// One thing bought, as the book records it.
    ///
    /// The unit is carried and never assumed: `lib/supplier-prices.js` compares
    /// prices only within a unit family, because a spool of PLA bought for 75
    /// and a kilogram of PLA bought for 22 are not the same purchase getting
    /// cheaper.
    struct Purchase: Identifiable, Hashable, Sendable {
        let id: String
        let date: String
        let amount: Double
        let item: String
        let notes: String
        let quantity: Double
        let unit: String
        let materialType: String
        /// Nil where the shop did not say. NOT the amount divided by the
        /// quantity: that division is the rule's to make, and writing a figure
        /// the shop did not give turns a guess into a fact in its own book.
        let unitPrice: Double?

        /// The second line of a row: what it was, in what unit, and the note.
        var said: String? {
            var parts: [String] = []
            if !materialType.isEmpty { parts.append(materialType) }
            if quantity > 0, !unit.isEmpty {
                let n = quantity == quantity.rounded()
                    ? String(Int(quantity)) : String(format: "%.2f", quantity)
                parts.append("\(n) \(unit)")
            }
            if !notes.isEmpty { parts.append(notes) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        @MainActor
        init?(row: JSONValue) {
            guard case .object(let o) = row else { return nil }
            // A log written before purchases carried ids still reads: the id is
            // only needed to tell two rows apart on screen.
            self.id = Shop.plainString(o["id"]) ?? UUID().uuidString
            self.date = Shop.plainString(o["date"]) ?? ""
            self.amount = Shop.plainNumber(o["amount"]) ?? 0
            self.item = Shop.plainString(o["item"]) ?? ""
            self.notes = Shop.plainString(o["notes"]) ?? ""
            self.quantity = Shop.plainNumber(o["quantity"]) ?? 1
            self.unit = Shop.plainString(o["unit"]) ?? ""
            self.materialType = Shop.plainString(o["materialType"]) ?? ""
            let priced = Shop.plainNumber(o["unitPrice"]) ?? 0
            self.unitPrice = priced > 0 ? priced : nil
        }
    }

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
                 website: "", notes: "", priceList: [], purchases: [])
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
            self.purchases = bought.compactMap(Purchase.init(row:))
        } else {
            self.purchases = []
        }
    }

    private init(id: String, name: String, category: String, phone: String,
                 leadDays: Int?, website: String, notes: String, priceList: [Quote],
                 purchases: [Purchase]) {
        self.id = id
        self.name = name
        self.category = category
        self.phone = phone
        self.leadDays = leadDays
        self.website = website
        self.notes = notes
        self.priceList = priceList
        self.purchases = purchases
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
