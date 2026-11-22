import Foundation
import KhaytCore

/// The other shelf: glue, IPA, mailing bags, brass nozzles, gloves.
///
/// Khayt has always been able to say what is about to run out that is not
/// filament — `lib/consumable-reorder.js`, drawn by `ConsumablesCard` — and
/// this app could never put anything ON that shelf. The record was written
/// only by `renderer/inventory.js`'s modal, so a shop using the Mac had an
/// empty shelf and a card that could only ever say nothing.
///
/// The fields are `lib/consumable-edit.js`'s, and that rule is the one place
/// they are normalised. Decoding them here is for DRAWING; every write goes
/// back through the rule so this app and the other cannot drift apart on what
/// a blank category means or whether a count may go negative.
struct Consumable: Identifiable, Decodable, Hashable, Sendable {
    let id: String
    let name: String?
    /// On hand, in `unit`. Absent is nothing counted, which the reorder rule
    /// reads as low — deliberately, and it is why a new one starts low.
    let stock: Double?
    /// What it is counted in: "roll", "each", "L". FREE TEXT, unlike a spool's.
    /// Nothing converts with it — `consumable-reorder.js` trims it and prints
    /// it beside the item's own number. See the rule for why.
    let unit: String?
    let cost: Double?
    /// Warn at or below this many. 0 or absent is no threshold the shop set;
    /// empty still counts as low whatever this says.
    let minStock: Double?
    /// Units consumed per printing hour. 0 is hourly deduction switched OFF,
    /// which is not the same claim as never configured — so the rule stores it.
    let usagePerHour: Double?
    /// The shop's own shelf name. Absent is Uncategorised, which
    /// `lib/consumable-categories.js` treats as a category in its own right.
    let category: String?
    /// One per completed order, by the packaging deduction path.
    let isPackaging: Bool?

    /// What to call it on screen. An unnamed consumable cannot exist — the rule
    /// refuses one — but a record written before the rule might be, and a blank
    /// row reads as a fault rather than as a missing name.
    @MainActor func title(_ words: Words) -> String {
        let said = (name ?? "").trimmingCharacters(in: .whitespaces)
        return said.isEmpty ? words.callIt("mac.unnamed") : said
    }

    var onHand: Double { stock ?? 0 }
    var threshold: Double { minStock ?? 0 }

    /// Low by the SHARED rule's definition, restated: below a threshold the
    /// shop set, or empty regardless.
    ///
    /// Restated rather than asked, because this is drawn per row while the
    /// engine is an actor and a view cannot await it mid-draw. It is pinned
    /// against the rule by `ConsumableShelfTests`, which is what stops the two
    /// answers drifting the way the renderer's badge and its toast once did.
    var isLow: Bool {
        if onHand <= 0 { return true }
        return threshold > 0 && onHand <= threshold
    }
}
