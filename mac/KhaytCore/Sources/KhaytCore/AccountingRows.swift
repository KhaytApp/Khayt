import Foundation

/// Orders → the row shape the accountant's CSV is laid out from.
///
/// ── WHY THIS IS ITS OWN RULE ──────────────────────────────────────────────
///
/// The exporter is a FORMATTER: give it rows with a rate and a tax mode on them
/// and it lays out columns. Everything that decides what those rows say lived in
/// the other app's renderer — which orders count, that a quote is not an
/// invoice, that an order with no price is not one either, what the shop's VAT
/// rate and pricing mode are, and which customer a `clientId` belongs to.
///
/// So an app calling the formatter directly gets a file that looks right and is
/// wrong in four ways at once. Measured, on a real order of 1,150 at 15%
/// inclusive:
///
///     VAT        0.00   instead of 150.00
///     Subtotal   1150   instead of 1000
///     Customer   empty
///     and a quote exported as though it were an invoice
///
/// That is a file a shop hands an accountant, and two apps disagreeing about a
/// VAT figure is a disagreement an auditor finds.
public enum AccountingRows {

    /// The shop's VAT rate and whether its prices include it.
    public struct Tax: Sendable, Equatable {
        public let rate: Double
        public let mode: String
        public init(rate: Double, mode: String) {
            self.rate = rate
            self.mode = mode
        }
    }

    /// The same sum the original does over a tax profile's rates.
    ///
    /// The PROFILE is still `lib/tax.js`'s — eight bundled modules read it, so
    /// it has not moved — and this only adds its rates up. `+r.percent || 0`,
    /// so a rate written as text still counts and a missing one counts as zero.
    public static func tax(profile: JSONValue?) -> Tax {
        // Anything that is not a profile answers what a shop with no tax module
        // at all gets. The original throws on a `null` profile — it reads
        // `.rates` straight off it — and takes the whole export with it.
        guard case .object(let p)? = profile else { return Tax(rate: 0, mode: "inclusive") }
        var rate = 0.0
        if case .array(let rates)? = p["rates"] {
            for row in rates {
                guard case .object(let r) = row else { continue }
                let percent = JSSemantics.number(r["percent"])
                rate += (percent.isNaN || percent == 0) ? 0 : percent
            }
        }
        return Tax(rate: rate, mode: JSSemantics.text(p["mode"]))
    }

    /// The whole print log in; the rows that come back are the ones that are
    /// invoices.
    ///
    /// A QUOTE IS NOT AN INVOICE and an order with no price is not one either.
    /// Both exclusions are here rather than at the call site because both are
    /// facts about accounting, not about a screen.
    ///
    /// `toBase` is the one part that needs a host — how an order's currency
    /// converts to the shop's base. Passing none gives EMPTY base columns
    /// rather than a base figure that is silently the foreign one: an empty
    /// column is a column an accountant asks about, and a wrong one is not.
    public static func invoiceRows(orders: [JSONValue], settings: [String: JSONValue],
                                   clients: [JSONValue], tax: Tax,
                                   currencyOf: ((JSONValue) -> String)? = nil,
                                   toBase: ((Double, String) -> Double)? = nil,
                                   localName: ((JSONValue) -> String)? = nil) -> [JSONValue] {
        let baseCurrency = JSSemantics.truthy(settings["currency"])
            ? JSSemantics.text(settings["currency"]) : "SAR"

        var out: [JSONValue] = []
        for order in orders {
            guard JSSemantics.truthy(order), case .object(let o) = order else { continue }
            if case .string("quote")? = o["status"] { continue }
            let price = JSSemantics.number(o["price"])
            guard price > 0 else { continue }   // `!(+o.price > 0)` — NaN too

            let currency = currencyOf?(order)
                ?? (JSSemantics.truthy(o["currency"]) ? JSSemantics.text(o["currency"])
                                                      : baseCurrency)
            // `c.id === o.clientId` is STRICT, so a client id written as a
            // number does not match one written as text. That is the other
            // app's answer and a shop's book is consistent within itself.
            var client: JSONValue?
            if let wanted = o["clientId"], JSSemantics.truthy(wanted) {
                client = clients.first { row in
                    guard JSSemantics.truthy(row), case .object(let c) = row else { return false }
                    return c["id"] == wanted
                }
            }
            var name = ""
            if let client { name = localName?(client) ?? {
                guard case .object(let c) = client else { return "" }
                return JSSemantics.truthy(c["name"]) ? JSSemantics.text(c["name"]) : ""
            }() }
            if name.isEmpty {
                name = JSSemantics.truthy(o["clientName"]) ? JSSemantics.text(o["clientName"])
                     : JSSemantics.truthy(o["client"]) ? JSSemantics.text(o["client"]) : ""
            }

            var row: [String: JSONValue] = [
                "date": JSSemantics.truthy(o["date"]) ? (o["date"] ?? .string("")) : .string(""),
                "clientName": .string(name),
                "price": .number(price.isNaN ? 0 : price),
                "currency": .string(currency),
                "vatRate": .number(tax.rate),
                "taxMode": .string(tax.mode),
                "baseCurrency": .string(toBase == nil ? "" : baseCurrency),
            ]
            // `id` and `status` are copied ACROSS rather than defaulted: the
            // original writes `o.id` whatever it is, and a field that is not
            // there at all disappears from the row when it is written out
            // rather than arriving as a null.
            if let id = o["id"] { row["id"] = id }
            if let status = o["status"] { row["status"] = status }
            // `undefined` disappears from the row entirely when there is no
            // converter, rather than arriving as a null the exporter would
            // print as a figure of nothing.
            if let toBase { row["baseAmount"] = .number(toBase(price.isNaN ? 0 : price, currency)) }
            out.append(.object(row))
        }
        return out
    }
}
