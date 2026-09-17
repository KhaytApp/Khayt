import Foundation

/// Which papers travel with an order — ported to Swift.
///
/// Documents are filed against the PRODUCT, not the part: a safety sheet
/// belongs to the thing being made, and filing it against one order's line
/// item would mean re-attaching it for every order of the same product.
///
/// Two audiences, two lists. The work order is read by whoever makes it, so it
/// lists everything; the delivery note goes to the customer, so it lists only
/// what the shop marked to ship — a machine setup sheet is not something to
/// put in the box.
///
/// ── THE ONE DECISION WORTH PORTING CAREFULLY ──────────────────────────────
///
/// **Absent means yes.** A document attached before the `packWithOrder` flag
/// existed carries no flag, and it was attached in order to travel. Only a
/// literal `false` keeps a document behind. Defaulting the other way would
/// silently stop shipping safety sheets that shops have been shipping for
/// months, with nothing on screen to say so — which is why the parity test
/// puts every awkward value in that field rather than just `true` and `false`.
///
/// (Named `OrderDocs` rather than `ProductDocs` because the app already has a
/// `ProductDocs` — that one is where the files live on disk; this is what they
/// mean.)
public enum OrderDocs {

    /// One paper attached to a product.
    public struct Doc: Sendable, Equatable {
        /// The name on disk, which is a timestamp.
        public let filename: String
        /// What the shop called it.
        public let name: String
        /// Whether it goes in the customer's box.
        public let packWithOrder: Bool
    }

    /// Every document attached to the product this order is for.
    public static func forOrder(_ order: JSONValue?, products: [JSONValue]) -> [Doc] {
        guard case .object(let o)? = order, JSSemantics.truthy(o["productId"]) else { return [] }
        let wanted = o["productId"]
        // `p.id === id` is a STRICT comparison, so a product whose id is the
        // number 7 does not answer for an order asking about "7".
        let product = products.first { row in
            if case .object(let p) = row { return strictlyEqual(p["id"], wanted) }
            return false
        }
        guard case .object(let p)? = product, case .array(let docs)? = p["docs"] else { return [] }
        return docs.compactMap { row -> Doc? in
            guard case .object(let d) = row else { return nil }
            // Kept if it names a file EITHER way round; a row with neither is
            // a row that names no file.
            guard JSSemantics.truthy(d["originalName"]) || JSSemantics.truthy(d["filename"])
            else { return nil }
            let filename = JSSemantics.truthy(d["filename"]) ? JSSemantics.text(d["filename"]) : ""
            let name = JSSemantics.truthy(d["originalName"])
                ? JSSemantics.text(d["originalName"])
                : (JSSemantics.truthy(d["filename"]) ? JSSemantics.text(d["filename"]) : "")
            return Doc(filename: filename, name: name,
                       packWithOrder: d["packWithOrder"] != .bool(false))
        }
    }

    /// The subset the customer receives with the goods.
    public static func packableForOrder(_ order: JSONValue?, products: [JSONValue]) -> [Doc] {
        forOrder(order, products: products).filter(\.packWithOrder)
    }

    /// `===` between two JSON values, for the two types an id is ever stored as.
    ///
    /// Different types are never equal in JavaScript however similar they look,
    /// and that is the behaviour worth keeping: an id matched loosely is how
    /// one order ends up carrying another product's paperwork.
    private static func strictlyEqual(_ a: JSONValue?, _ b: JSONValue?) -> Bool {
        switch (a, b) {
        case (.string(let x), .string(let y)): return x == y
        case (.number(let x), .number(let y)): return x == y && !x.isNaN
        case (.bool(let x), .bool(let y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }
}
