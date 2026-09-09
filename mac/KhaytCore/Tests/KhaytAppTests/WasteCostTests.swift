import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// What the sample shop says a failed print cost, against what this app would
/// work it out to be.
///
/// The waste sheet prices an entry itself — `KhaytWasteEntry.costOf`, from the
/// shelf's own per-kilo rate, NET of tax this shop can reclaim — so a sample
/// entry is reproducible by definition. Not one of the six was. All six held
/// the GROSS figure, so the screen totalled 128.18 where this shop's own app
/// would have written 79.53: a 61% overstatement of what its failures cost it,
/// on the screen whose entire purpose is that number.
///
/// PA-CF was wrong twice over — 86.40 for a hundred and eighty grams is 480 a
/// kilo against a shelf that says 240, exactly double, and a figure no version
/// of this rule would produce.
///
/// It mattered because the waste screen invites the arithmetic: it prints the
/// weight, the cost, and a total of both, beside a shelf two screens away that
/// says what a kilo costs.
///
/// THE TRAP THAT HID IT. `costOf` reaches for `global.KhaytSpoolEdit` to take
/// the tax off, and falls back to the gross cost when that global is absent —
/// silently, with no error. Checked from a bare Node script, where `require`
/// sets no global, five of the six looked correct. Every one of them was
/// wrong. An injected module that degrades quietly is worth checking through
/// the app rather than beside it.
///
/// A shop may of course TYPE a different cost; filament bought last year cost
/// what it cost. This is about the demonstration book agreeing with itself.
@MainActor
struct WasteCostTests {

    @Test("every sample waste entry costs what this app would price it at")
    func theSampleAgreesWithItself() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        #expect(!shop.wasteRows.isEmpty, "no waste in the sample book")

        for row in shop.wasteRows {
            guard case .object(let w) = row,
                  case .string(let material)? = w["material"],
                  case .number(let grams)? = w["weight"],
                  case .number(let stored)? = w["cost"] else { continue }
            let worked = try await engine.wasteCost(material: material, grams: grams,
                                                    inventory: shop.inventoryRows,
                                                    reclaimsTax: shop.reclaimsTax)
            guard worked > 0 else { continue }   // a material no longer on the shelf
            #expect(abs(worked - stored) < 0.02,
                    "\(material) \(Int(grams))g is stored at \(stored) and prices at \(worked)")
        }
    }
}
