import Foundation
import Testing
@testable import KhaytApp

/// The spool on a card is wound to what is left in it.
///
/// The picture was full on every card regardless — a spool down to its last
/// 120 g drawn exactly like an untouched kilo, with a number underneath saying
/// otherwise. The biggest thing on the card was the one part of it that was not
/// true.
///
/// These test `fill`, which is what the drawing reads. They are about the two
/// answers that matter: a proportion where one is knowable, and NOTHING where
/// it is not.
struct SpoolFillTests {

    static func spool(left: Double?, new: Double?) -> Spool {
        Spool(id: "S1", material: "PLA", cost: 75, vatAmount: nil,
              weight: left, spoolWeight: new, openedAt: nil, storage: nil,
              colourVariant: nil, color: nil, materialType: nil, lot: nil,
              purchasedAt: nil, reorderPoint: nil, reorderQty: nil,
              printTemp: nil, bedTemp: nil, maxSpeed: nil, priceHistory: nil)
    }

    @Test("a spool that knows what it weighed new is wound to what is left")
    func proportion() {
        #expect(Self.spool(left: 1000, new: 1000).fill == 1)
        #expect(Self.spool(left: 500, new: 1000).fill == 0.5)
        #expect(Self.spool(left: 120, new: 1000).fill == 0.12)
        // A 750 g spool half gone is half gone, not 480/1000.
        #expect(Self.spool(left: 375, new: 750).fill == 0.5)
    }

    /// The same rule as `costPerKilo`, and it is the whole point: a spool bought
    /// before Khayt recorded the original weight has no record of the half
    /// already printed. Assuming a kilo would draw a half-empty roll as
    /// two-thirds full — a picture that is confidently wrong.
    @Test("a spool with no record of its original weight claims nothing")
    func unknowable() {
        #expect(Self.spool(left: 640, new: nil).fill == nil)
        #expect(Self.spool(left: nil, new: 1000).fill == nil)
        #expect(Self.spool(left: nil, new: nil).fill == nil)
        // A zero original weight is a divide by zero, not a full spool.
        #expect(Self.spool(left: 640, new: 0).fill == nil)
    }

    /// A shop that tops a roll up, or mistypes 10000 for 1000, gets a full spool
    /// rather than a ring drawn wider than the flange it sits in.
    @Test("a spool cannot be more than full or less than empty")
    func clamped() {
        #expect(Self.spool(left: 1400, new: 1000).fill == 1)
        #expect(Self.spool(left: -50, new: 1000).fill == 0)
        #expect(Self.spool(left: 0, new: 1000).fill == 0)
    }

    /// An empty spool is still a spool: the ring winds down to the hub and stops
    /// there, so the card shows bare flange rather than a vanished mark. This
    /// pins the arithmetic the drawing does, which is the part that would
    /// silently produce a negative radius.
    @Test("the wound radius never goes inside the hub")
    func woundRadiusStaysOnTheFlange() {
        let outer = 36.0, hub = 11.0
        for grams in stride(from: 0.0, through: 1000.0, by: 50) {
            let fill = Self.spool(left: grams, new: 1000).fill!
            let wound = hub + (outer - hub) * fill
            #expect(wound >= hub, "\(grams) g winds to \(wound), inside the hub")
            #expect(wound <= outer, "\(grams) g winds to \(wound), past the flange")
        }
    }
}
