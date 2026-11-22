import Foundation

/// Which shape the shelf draws for an inventory item.
///
/// ── WHY THIS IS A TYPE AND NOT A `SWITCH` IN THE VIEW ─────────────────────
///
/// The shelf drew a spool for everything. Not by decision — by the field simply
/// not being asked for, the same shape of bug as the machine card that gave a
/// laser cutter a nozzle diameter. `lib/inventory-units.js` has known since it
/// was written that an item is measured by `mass`, `volume` or `count`, and the
/// picture at the top of the card was the last place still assuming filament.
///
/// Kept out of the view so the mapping can be TESTED, and tested against the
/// module rather than against a list copied out of it: `ItemFaceTests` reads
/// every unit `inventory-units.js` offers, asks this for a face, and fails if
/// any of them falls through. A fourth unit — a reel of vinyl, a bar of wax —
/// then cannot be added without somebody deciding what it looks like, which is
/// exactly the decision that was skipped last time.
enum ItemFace {
    /// Filament, wound on a reel. `mass`.
    case spool
    /// A liquid in a bottle — resin, IPA. `volume`.
    case bottle
    /// Sheet goods, stacked. `count`.
    case sheets

    /// The face for one of `inventory-units.js`'s measures.
    ///
    /// ── NIL IS A SPOOL, AND AN UNKNOWN MEASURE IS NOT ─────────────────────
    ///
    /// Nil means the book has not loaded yet, or the item predates units
    /// entirely — and every item in every book written before `unit` existed is
    /// filament in grams, which is the same reasoning `inventory-units.js`
    /// gives for reading an absent unit as `g`. Drawing a spool there is right.
    ///
    /// An unknown measure is a different thing: a NEWER Khayt wrote a unit this
    /// build has not learned. Drawing a spool for it would state something
    /// false about an item rather than merely something old, so it gets
    /// `nil` — see `SpoolCard.face`, which draws no picture at all rather than
    /// the wrong one. The row still appears with its name, quantity and colour,
    /// because a shelf that hides stock it cannot illustrate is worse than one
    /// that illustrates only what it understands.
    static func of(measure: String?) -> ItemFace? {
        guard let measure, !measure.isEmpty else { return .spool }
        switch measure {
        case "mass":   return .spool
        case "volume": return .bottle
        case "count":  return .sheets
        default:       return nil
        }
    }
}
