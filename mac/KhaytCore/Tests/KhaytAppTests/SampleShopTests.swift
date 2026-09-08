import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The sample shop is what every screen is designed against, so a branch it
/// cannot reach is a branch nobody ever looks at.
///
/// ── WHAT THIS IS FOR ───────────────────────────────────────────────────────
///
/// The first time the product catalogue was ever photographed it showed twenty
/// rows reading `35%`, twenty reading "Rounded from", and a robot gripper
/// weighing 12,882 g. None of that was a bug in the screen. Every sample
/// product carried the same margin and the same rounding rule, and the
/// quantities had been assigned at random — the product literally named "Shelf
/// brackets, 24" was a batch of 4, while a prosthetic socket trial, which is a
/// one-off by definition, was a batch of 24.
///
/// A column where every row agrees is a column that has never been tested, and
/// it *looks* fine. So does a spool shelf where nothing can compute a rate.
/// These tests do not check any particular figure — they check that the sample
/// shop still SPANS the cases the screens have to draw.
@MainActor
struct SampleShopTests {

    static func book() throws -> [String: JSONValue] {
        let url = Bundle.module.url(forResource: "sample-shop", withExtension: "json")!
        let raw = try JSONDecoder().decode(JSONValue.self, from: try Data(contentsOf: url))
        guard case .object(let o) = raw else { throw Oops.shape }
        return o
    }

    enum Oops: Error { case shape }

    static func rows(_ key: String) throws -> [[String: JSONValue]] {
        guard case .array(let a)? = try book()[key] else { return [] }
        return a.compactMap { if case .object(let o) = $0 { return o } else { return nil } }
    }

    static func number(_ row: [String: JSONValue], _ key: String) -> Double? {
        if case .number(let n)? = row[key] { return n }
        return nil
    }

    // MARK: - The catalogue

    /// The margin column drew `35%` twenty times. A shop prices a commodity
    /// bracket and a bespoke prosthetic differently, and the screen has to show
    /// that it can.
    @Test("the sample products do not all carry the same margin")
    func marginsDiffer() throws {
        let margins = try Self.rows("products").map { Self.number($0, "defaultMargin") }
        let set = Set(margins.compactMap { $0 })
        #expect(set.count >= 5,
                "every sample product priced at the same margin: \(set.sorted())")
        // And a product nobody set a margin on, so the "—" the table draws for an
        // absent margin is a thing somebody has seen.
        #expect(margins.contains(where: { $0 == nil }),
                "no sample product leaves its margin unset, so the '—' never renders")
    }

    /// Three prices in the catalogue explain themselves three different ways —
    /// "Rounded from …", "Calculated", "Your own price". Nineteen of twenty rows
    /// said the same one.
    @Test("the sample products reach all three reasons a price can be what it is")
    func everyPriceReasonIsReachable() async throws {
        let products = try Self.rows("products").map { JSONValue.object($0) }
        let rows = try await KhaytEngine().catalogue(products, language: "en", settings: [:])
        let reasons = Set(rows.map(\.reason))
        for wanted in ["pe.price_is_rounded", "pe.price_is_base", "pe.price_is_override"] {
            #expect(reasons.contains(wanted),
                    "no sample product ever shows '\(wanted)': \(reasons.sorted())")
        }
    }

    /// A product that says how many it is has to BE that many.
    ///
    /// This is the test the loose one below could not be. "Shelf brackets, 24"
    /// was a batch of 4 and "Signage letters, 12" a batch of 1, so the weight
    /// column was quietly answering a different question from the one the name
    /// asked. Nothing about the total hours was implausible enough to notice.
    @Test("a sample product that names a count is a batch of that many")
    func namedCountsMatchTheQuantity() throws {
        for p in try Self.rows("products") {
            guard case .string(let name)? = p["nameEn"],
                  case .array(let parts)? = p["parts"] else { continue }
            // The last run of digits in the name: "Cable chain, 40 links" → 40.
            let counts = name.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            // "Drone arm v4" is a version, not a count. Only a name with a comma
            // before the number is stating how many.
            guard name.contains(","), let said = counts.last else { continue }
            let qty = parts.reduce(0.0) { total, part in
                if case .object(let pt) = part { return total + (Self.number(pt, "qty") ?? 1) }
                return total
            }
            #expect(Int(qty) == said, "\(name) is a batch of \(Int(qty))")
        }
    }

    /// A batch of twenty-four one-hour prints is a day of machine time; a batch
    /// of twenty-four twenty-four-hour prints is most of a month. A floor, not a
    /// proof: it catches a generated absurdity, not a bad estimate.
    @Test("no sample product asks for more machine time than a month has")
    func batchesArePrintable() throws {
        for p in try Self.rows("products") {
            guard case .array(let parts)? = p["parts"] else { continue }
            var hours = 0.0, grams = 0.0
            for case .object(let pt) in parts {
                let q = Self.number(pt, "qty") ?? 1
                hours += (Self.number(pt, "printTime") ?? 0) * q
                grams += ((Self.number(pt, "printWeight") ?? 0)
                          + (Self.number(pt, "supportWeight") ?? 0)) * q
            }
            let name = { if case .string(let s)? = p["nameEn"] { return s } else { return "?" } }()
            #expect(hours <= 24 * 30, "\(name) takes \(Int(hours)) machine hours")
            // 20 kg is four of the biggest spools this shop stocks.
            #expect(grams <= 20_000, "\(name) weighs \(Int(grams)) g")
        }
    }

    // MARK: - The shelf

    /// A spool's rate per gram needs what it weighed NEW, and not one sample
    /// spool carried that — so the spool card fell to "what it cost" on all six,
    /// every fill bar read full, and the rate branch was never once drawn.
    @Test("every sample spool says what it weighed new, and none of them is full")
    func spoolsCanShowARate() throws {
        let spools = try Self.rows("inventory")
        #expect(!spools.isEmpty)
        for s in spools {
            let new = Self.number(s, "spoolWeight")
            #expect(new != nil, "a sample spool has no spoolWeight, so it can show no rate")
            if let new, let left = Self.number(s, "weight") {
                #expect(left <= new, "a spool with more left than it ever held")
            }
        }
        // Six untouched 1 kg spools is not a shop. The fill levels have to differ,
        // or a bar that draws the wrong percentage looks correct.
        let fill = Set(spools.compactMap { s -> Int? in
            guard let new = Self.number(s, "spoolWeight"), new > 0,
                  let left = Self.number(s, "weight") else { return nil }
            return Int((left / new * 100).rounded())
        })
        #expect(fill.count >= 4, "the sample spools all sit at the same fill: \(fill.sorted())")
    }

    /// The tax on a purchase is a real field now, and a book that carries none
    /// of it shows nothing of the work. It must also carry a purchase with NO
    /// tax — an import — because "absent is zero" is the rule that keeps every
    /// existing shop's numbers still.
    @Test("the sample shop has purchases with reclaimable tax, and one without")
    func vatIsBothPresentAndAbsent() throws {
        let spools = try Self.rows("inventory")
        let taxed = spools.filter { (Self.number($0, "vatAmount") ?? 0) > 0 }
        #expect(!taxed.isEmpty, "no sample spool records the tax inside its price")
        #expect(taxed.count < spools.count,
                "every sample spool reclaims tax, so the imported case never renders")
        for s in taxed {
            let vat = Self.number(s, "vatAmount") ?? 0
            let cost = Self.number(s, "cost") ?? 0
            #expect(vat < cost, "a spool whose tax is not less than its price")
        }
    }
}
