import Foundation

/// What a catalogue product is made of — ported to Swift.
///
/// A storefront selling printed parts needs three facts Khayt already holds:
/// how long the thing takes on a machine, what it weighs, and what it is made
/// of. Without them a shop types each one a second time into its storefront's
/// admin, and a hand-typed number that drifts from the shop's own record is
/// worse than no number, because both look authoritative.
///
/// (Named `CatalogueSpecs` rather than `ProductSpecs` because the engine
/// already publishes a `ProductSpecs` struct for the answer.)
public enum CatalogueSpecs {

    public struct Specs: Sendable, Equatable {
        /// Machine hours. NULL rather than zero where a product cannot answer.
        public let printHours: Double?
        public let weightGrams: Double?
        public let material: String
    }

    /// Grams a part draws: print plus support, times quantity.
    ///
    /// This is what the app DEDUCTS from stock when a job completes. A
    /// published weight that disagreed with the shop's own deduction would be
    /// a second truth about the same gram.
    public static func partGrams(_ part: JSONValue?) -> Double {
        guard case .object(let p)? = part else { return 0 }
        return (positive(p["printWeight"]) + positive(p["supportWeight"]))
            * (positive(p["qty"]) == 0 ? 1 : positive(p["qty"]))
    }

    /// Machine hours for a part: PRINT TIME ONLY, times quantity.
    ///
    /// A part also carries `prepTime` and `postTime` — preparation and
    /// finishing labour — and neither belongs here. Finishing is accounted for
    /// on the other side of this wire: `lib/lead-time.js` folds finishing,
    /// dispatch and safety into `handlingDays` and publishes that separately.
    /// A consumer that added prep and post here and then added handlingDays on
    /// top would count finishing twice, and every date it quoted would drift
    /// later — silently, in the direction that loses work.
    public static func partHours(_ part: JSONValue?) -> Double {
        guard case .object(let p)? = part else { return 0 }
        return positive(p["printTime"]) * (positive(p["qty"]) == 0 ? 1 : positive(p["qty"]))
    }

    /// The three facts, or nulls.
    ///
    /// NULL RATHER THAN ZERO where a product cannot answer. A product with no
    /// parts has no print time — it is not a product that prints instantly,
    /// and a consumer deciding whether it can quote a date has to be able to
    /// tell those apart. Zero would read as an answer.
    public static func specs(of product: JSONValue?) -> Specs {
        guard case .object(let p)? = product, case .array(let parts)? = p["parts"],
              !parts.isEmpty
        else { return Specs(printHours: nil, weightGrams: nil, material: "") }

        let hours = parts.reduce(0.0) { $0 + partHours($1) }
        let grams = parts.reduce(0.0) { $0 + partGrams($1) }

        // Distinct, IN THE ORDER THE SHOP LISTED THEM: a multi-part product
        // can mix, and "PETG, TPU" is what somebody packing it needs to read.
        // A `Set` alone would reorder it.
        var seen = Set<String>()
        var materials: [String] = []
        for part in parts {
            guard case .object(let row) = part else { continue }
            let name = JSSemantics.text(row["material"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            materials.append(name)
        }

        return Specs(
            // Four places: a 12-minute part is 0.2 h and must not round to
            // nothing.
            printHours: rounded(hours, 10000),
            weightGrams: rounded(grams, 100),
            material: materials.joined(separator: ", "))
    }

    /// Positive and finite, rounded — or nil.
    ///
    /// ── WHY INFINITY IS NIL AND NOT INFINITY ──────────────────────────────
    ///
    /// A product whose parts add up past `Double`'s range is absurd, and it is
    /// also reachable: two parts at the maximum finite weight sum to infinity.
    /// The JavaScript happily returns `Infinity` — and then **JSON cannot
    /// carry it**, so `JSON.stringify` writes `null` and the app has always
    /// received nothing. Returning a live infinity here would be the first
    /// time this figure reached a screen, where it would print as "inf".
    ///
    /// So nil, which is what the bridge has always delivered. Found by the
    /// parity harness disagreeing about `Double.greatestFiniteMagnitude`,
    /// which is exactly the kind of value nobody writes a test for by hand.
    private static func rounded(_ value: Double, _ places: Double) -> Double? {
        guard value > 0, value.isFinite else { return nil }
        let out = JSSemantics.round(value * places) / places
        return out.isFinite ? out : nil
    }

    /// The module's own `num`: a finite POSITIVE number, or zero.
    private static func positive(_ value: JSONValue?) -> Double {
        let n = JSSemantics.number(value)
        return (n.isFinite && n > 0) ? n : 0
    }
}
