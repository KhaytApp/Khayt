import Foundation

/// What a customer has agreed to pay for a thing — ported to Swift.
///
/// A customer's record can carry a price list — "brackets: 12.50", "any
/// keychain: 8" — and when that customer is chosen for a job, each part whose
/// NAME CONTAINS one of those products takes the agreed figure.
///
/// ── WHERE THE FIGURE LANDS, AND WHY IT MATTERS ────────────────────────────
///
/// On the part as `agreedPrice`, per unit, and nowhere else. The part's cost
/// stays what it cost, and the pricing rule charges the agreed figure for that
/// part INSTEAD of cost plus margin.
///
/// Until September 2026 the other app wrote the agreed figure into the COST,
/// so the job's margin went on top of it: a part agreed at 50 on a 30% job
/// billed 65, and the profit report then showed the part sold at cost. Both
/// were wrong, and the shop had to notice the total. An agreed price is a
/// PRICE, not a cost.
public enum PriceAgreements {

    /// The agreement covering a part with this name, or nil.
    ///
    /// ── THE FIRST MATCH WINS, EVEN WHEN IT HAS NO PRICE ───────────────────
    ///
    /// `find` takes the FIRST entry whose product the name contains, and only
    /// then asks whether that entry has a price. So a shop that wrote a
    /// product down with no price has said "this one is not agreed", and a
    /// later entry must not quietly stand in for it.
    ///
    /// Reading it as "the first entry with a price" would silently price a
    /// part the shop deliberately left open — which is the kind of difference
    /// nobody notices until an invoice is wrong.
    public static func find(in priceList: [JSONValue], name: JSONValue?) -> JSONValue? {
        let wanted = JSSemantics.truthy(name) ? JSSemantics.text(name).lowercased() : ""
        guard !wanted.isEmpty else { return nil }
        let entry = priceList.first { row in
            guard JSSemantics.truthy(row), case .object(let p) = row,
                  JSSemantics.truthy(p["product"]) else { return false }
            let product = JSSemantics.text(p["product"]).lowercased()
            // ── EVERY STRING CONTAINS THE EMPTY STRING ────────────────────
            //
            // `wanted.includes("")` is TRUE in JavaScript, and Swift's
            // `contains("")` is not — so an agreement whose product is
            // something truthy that STRINGIFIES to nothing, like `[]`, matches
            // every part and prices the whole cart at its figure. It is first
            // in the list, so it wins outright.
            //
            // That is a real trap in a real book: the products come from a
            // customer record somebody typed. Reproduced rather than tidied,
            // because tidying it would mean the two apps bill differently for
            // the same cart.
            if product.isEmpty { return true }
            return wanted.contains(product)
        }
        guard case .object(let found)? = entry,
              JSSemantics.number(found["price"]) > 0 else { return nil }
        return entry
    }

    /// The agreed price for a part with this name, or nil.
    public static func price(in priceList: [JSONValue], name: JSONValue?) -> Double? {
        guard case .object(let entry)? = find(in: priceList, name: name) else { return nil }
        return JSSemantics.number(entry["price"])
    }

    /// Apply a customer's agreements to a cart.
    ///
    /// A part with no agreement is left as it was EXCEPT that `agreedPrice` is
    /// removed — including one a previous customer left on it, because the
    /// cart now belongs to this customer. Returns the parts and how many took
    /// an agreement, so a host can say "price agreement applied" only when one
    /// was.
    public static func apply(to parts: [JSONValue],
                             priceList: [JSONValue]) -> (parts: [JSONValue], applied: Int) {
        var applied = 0
        let out = parts.map { row -> JSONValue in
            guard JSSemantics.truthy(row), case .object(var part) = row else { return row }
            guard let agreed = price(in: priceList, name: part["name"]) else {
                part["agreedPrice"] = nil        // `delete part.agreedPrice`
                return .object(part)
            }
            part["agreedPrice"] = .number(agreed)
            applied += 1
            return .object(part)
        }
        return (out, applied)
    }
}
