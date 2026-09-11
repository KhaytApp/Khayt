import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Which shape the shelf draws for an inventory item.
///
/// The bug these exist for: the shelf drew a filament spool for everything on
/// it. A 500 ml bottle of resin was a spool, a stack of plywood was a spool, and
/// the only thing saying otherwise was the unit after the number. It was not a
/// decision — the field was simply never asked for, the same shape as the
/// machine card that gave a laser cutter a nozzle diameter.
///
/// So the real guard here is not the three mappings. It is that the set of
/// measures is read out of `lib/inventory-units.js` rather than copied, so a
/// FOURTH unit cannot be added without somebody deciding what it looks like.
@Suite struct ItemFaceTests {

    @Test("every unit the shared module offers has a shape to be drawn as")
    func everyUnitHasAFace() async throws {
        let engine = try KhaytEngine()
        // Straight from the module — not a list written out here, which is the
        // whole point. `inventoryUnitChoices` is what the spool editor fills its
        // unit picker from, so a unit added to `UNITS` tomorrow becomes offerable
        // tomorrow, appears in this test tomorrow, and fails it until somebody
        // has decided what it looks like on the shelf.
        let units = try await engine.inventoryUnitChoices()
        #expect(units.count >= 3, "the module offers fewer units than it used to — check UNITS")

        for choice in units {
            let face = ItemFace.of(measure: choice.measure)
            #expect(face != nil, """
                a unit the editor can offer has no shape on the shelf — add one to ItemFace
                """)
            if face == nil {
                Issue.record("\(choice.unit) is measured in \(choice.measure) and the shelf cannot draw it")
            }
        }
    }

    @Test("the three shapes are the three things on a shop's shelf")
    func theKnownMeasures() {
        #expect(ItemFace.of(measure: "mass") == .spool)
        #expect(ItemFace.of(measure: "volume") == .bottle)
        #expect(ItemFace.of(measure: "count") == .sheets)
    }

    @Test("no unit at all is filament, and that is not a guess")
    func absentIsFilament() {
        // Every item in every book written before `unit` existed is filament in
        // grams, because nothing else could be recorded. `inventory-units.js`
        // reads an absent unit as `g` for the same reason, and the picture has
        // to agree with the number underneath it.
        #expect(ItemFace.of(measure: nil) == .spool)
        #expect(ItemFace.of(measure: "") == .spool)
    }

    @Test("a measure this build has not learned is drawn as nothing, not as a spool")
    func unknownMeasureDrawsNothing() {
        // A NEWER Khayt wrote a unit this one does not know. Drawing a spool for
        // it would state something false about the item rather than merely
        // something old — and the row still appears with its name, quantity and
        // colour, because a shelf that hides stock it cannot illustrate is worse
        // than one that illustrates only what it understands.
        #expect(ItemFace.of(measure: "length") == nil)
        #expect(ItemFace.of(measure: "area") == nil)
    }
}
