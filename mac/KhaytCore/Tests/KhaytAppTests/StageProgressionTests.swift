import Foundation
import Testing
@testable import KhaytApp

/// "Along" and "back", for a shop that does not want to name the stage.
///
/// The board's column order is not the order work goes in: `on_hold` sits
/// between `pending` and `printing` because that is where a held job is
/// easiest to find. Stepping a pending job "along" by one COLUMN would put it
/// on hold — the app reading "get on with it" as "stop".
///
/// So there are two lists, and this is what keeps them from being confused
/// for each other.
@MainActor
struct StageProgressionTests {

    @Test("the board's order is not the order work goes in")
    func holdIsAColumnNotAStep() {
        #expect(Stage.boardColumns.contains(.on_hold), "hold is a column — a held job has to be findable")
        #expect(!Stage.progression.contains(.on_hold), "hold is not a STEP; along must never mean stop")
        // Otherwise the two agree, in the same order.
        #expect(Stage.progression == Stage.boardColumns.filter { $0 != .on_hold })
    }

    @Test("along goes to the next piece of work, not the next column")
    func alongSkipsHold() {
        // The case that made this necessary: on the board, the column after
        // `pending` is `on_hold`.
        #expect(Stage.pending.stepped(by: 1) == .printing)
        #expect(Stage.printing.stepped(by: -1) == .pending)
    }

    @Test("every step lands somewhere, forwards and back", arguments: [1, -1])
    func stepsAreReversible(_ delta: Int) {
        for stage in Stage.progression {
            guard let there = stage.stepped(by: delta) else { continue }   // the ends
            #expect(there != stage, "a step must move")
            #expect(there.stepped(by: -delta) == stage,
                    Comment(rawValue: "\(stage) -> \(there) does not come back"))
        }
    }

    @Test("the ends of the progression have nowhere further to go")
    func endsStop() {
        #expect(Stage.progression.first?.stepped(by: -1) == nil)
        #expect(Stage.progression.last?.stepped(by: 1) == nil)
    }

    /// A held job is a decision, not a step.
    ///
    /// Where it goes back to depends on why it was held, which the app does
    /// not know — so it offers nothing here rather than guessing, and the same
    /// menu lists every stage by name.
    @Test("a job on hold has no along and no back")
    func holdHasNoStep() {
        #expect(Stage.on_hold.stepped(by: 1) == nil)
        #expect(Stage.on_hold.stepped(by: -1) == nil)
    }

    /// Shipped is the last step, and it is not a status.
    ///
    /// `lib/order-status.js` makes it a DATE on a job that stays `completed`,
    /// which is why the menu performs it with `markShipped` rather than a
    /// move — the same exception the board's drop handler makes, for the same
    /// reason. This pins that it really is the end of the line, so the
    /// exception is reachable and is the only one.
    @Test("shipped is where the progression ends")
    func shippedIsLast() {
        #expect(Stage.progression.last == .shipped)
        #expect(Stage.completed.stepped(by: 1) == .shipped)
    }
}
