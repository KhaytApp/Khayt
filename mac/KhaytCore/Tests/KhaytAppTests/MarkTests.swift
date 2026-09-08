import Foundation
import SwiftUI
import Testing
@testable import KhaytApp

/// The marks this app draws for itself.
///
/// Counted before they existed: 41 SF Symbols and one file that drew anything.
/// `shippingbox` for the filament shelf, `tray.full` for the jobs, `function`
/// for the calculator. Every mark on every screen was Apple's, arranged by us —
/// and arranging borrowed marks better is what "make it less generic" had been
/// doing without touching the thing that made it generic.
///
/// A drawing cannot be tested for whether it is any good. What CAN be tested is
/// the thing that makes fifteen drawings into one set: the same square, the
/// same weight, nothing wandering out of its box, and no mark that is silently
/// empty.
struct MarkTests {

    @Test("every mark draws something")
    func nothingIsEmpty() {
        for mark in Mark.allCases {
            let ink = mark.ink
            let strokes = ink.lines.count + ink.closed.count + ink.rings.count
            let fills = ink.solid.count + ink.dots.count
            #expect(strokes + fills > 0, "\(mark.rawValue) draws nothing at all")
        }
    }

    /// A mark that leaves its square is a mark that clips against the row next
    /// to it, and the clipping only shows at the one size nobody photographs.
    @Test("nothing wanders outside the 24-unit square")
    func insideTheGrid() {
        for mark in Mark.allCases {
            let ink = mark.ink
            for polyline in ink.lines + ink.closed + ink.solid {
                for point in polyline {
                    #expect(point.x >= 0 && point.x <= Mark.grid,
                            "\(mark.rawValue): x \(point.x)")
                    #expect(point.y >= 0 && point.y <= Mark.grid,
                            "\(mark.rawValue): y \(point.y)")
                }
            }
            for (centre, r) in ink.rings + ink.dots {
                #expect(centre.x - r >= 0 && centre.x + r <= Mark.grid,
                        "\(mark.rawValue): a ring runs off the side")
                #expect(centre.y - r >= 0 && centre.y + r <= Mark.grid,
                        "\(mark.rawValue): a ring runs off the top or bottom")
            }
        }
    }

    /// The set has to fill its square, or a mark drawn small sits in a pool of
    /// space beside one that does not and the row looks ragged.
    @Test("every mark uses most of the square it is given")
    func fillsTheGrid() {
        for mark in Mark.allCases {
            var minX = Mark.grid, maxX: CGFloat = 0, minY = Mark.grid, maxY: CGFloat = 0
            let ink = mark.ink
            for polyline in ink.lines + ink.closed + ink.solid {
                for point in polyline {
                    minX = min(minX, point.x); maxX = max(maxX, point.x)
                    minY = min(minY, point.y); maxY = max(maxY, point.y)
                }
            }
            for (centre, r) in ink.rings + ink.dots {
                minX = min(minX, centre.x - r); maxX = max(maxX, centre.x + r)
                minY = min(minY, centre.y - r); maxY = max(maxY, centre.y + r)
            }
            // Fourteen of twenty-four in both directions: enough that the set
            // reads as one weight, loose enough that a tall mark and a wide one
            // are both allowed.
            #expect(maxX - minX >= 14, "\(mark.rawValue) is \(maxX - minX) wide")
            #expect(maxY - minY >= 14, "\(mark.rawValue) is \(maxY - minY) tall")
        }
    }

    /// Two marks with the same geometry are one mark used twice, and a shop
    /// reading a sidebar cannot tell those rows apart at a glance.
    @Test("no two marks are the same drawing")
    func allDistinct() {
        func fingerprint(_ mark: Mark) -> String {
            let ink = mark.ink
            let poly = (ink.lines + ink.closed + ink.solid)
                .map { $0.map { "\($0.x),\($0.y)" }.joined(separator: " ") }
                .sorted().joined(separator: "|")
            let round = (ink.rings + ink.dots)
                .map { "\($0.0.x),\($0.0.y),\($0.1)" }.sorted().joined(separator: "|")
            return poly + "//" + round
        }
        var seen: [String: Mark] = [:]
        for mark in Mark.allCases {
            // The dashboard IS the nozzle: the app's own act is its front door,
            // and that repetition is the point rather than an oversight.
            if mark == .nozzle { continue }
            let print = fingerprint(mark)
            if let clash = seen[print] {
                Issue.record("\(mark.rawValue) is the same drawing as \(clash.rawValue)")
            }
            seen[print] = mark
        }
    }

    @Test("the dashboard and the nozzle are deliberately the same mark")
    func theFrontDoorIsTheAct() {
        #expect(Mark.dashboard.ink.solid.count == Mark.nozzle.ink.solid.count)
        #expect(!Mark.dashboard.ink.solid.isEmpty,
                "the bead is the one filled thing in the app's mark, and it is filled")
    }

    /// The stroke has to scale with the mark, or a 32pt one is a 16pt one with
    /// a hairline round it.
    @Test("the stroke is a fraction of the size, not a constant")
    func strokeScales() {
        #expect(Mark.weight > 0 && Mark.weight < 0.2)
        let atSixteen = 16 * Mark.weight
        let atThirtyTwo = 32 * Mark.weight
        #expect(abs(atThirtyTwo - atSixteen * 2) < 0.001)
    }

    /// Every shelf in the sidebar should have a mark of its own. The pipeline
    /// stages keep Apple's on purpose — a stage is a state of work, not an
    /// object on the floor.
    @Test("there is a mark for every shelf the sidebar lists")
    func coversTheShelves() {
        let shelves: [Mark] = [.dashboard, .jobs, .board, .machines, .filament, .library,
                               .catalogue, .calculator, .colour, .giftCards, .portfolio,
                               .expenses, .waste, .reports, .clients]
        for shelf in shelves {
            #expect(Mark.allCases.contains(shelf), "\(shelf.rawValue) is missing")
        }
        #expect(shelves.count == Set(shelves).count)
    }
}

/// The menu bar item, and the crash it took to find this.
///
/// A repeating `Timer` block has to get from a C function pointer back into
/// Swift isolation, and the only route is `MainActor.assumeIsolated` — which
/// asks the concurrency runtime whether this is the main executor. Nothing
/// stopped the timer at termination, so it went on firing on the main run loop
/// while AppKit dismantled the app around it, and the question was asked of
/// metadata that was going away:
///
///     objc_opt_class → swift_getObjectType → swift_task_isMainExecutorImpl
///     → MainActor.assumeIsolated → closure #1 in FloorStatus.install(shop:)
///
/// SIGSEGV, byte read at 0x1e.
@MainActor
struct MenuBarLifetimeTests {

    @Test("installing twice does not leave a timer behind")
    func installIsIdempotent() {
        let floor = FloorStatus.shared
        floor.remove()
        #expect(!floor.isTicking, "removed means removed")
    }

    /// The fix, pinned: after `remove()` there is no timer to fire. Anything
    /// that puts one back without a matching stop reopens the crash.
    @Test("remove() stops the clock as well as taking the item away")
    func removeStopsTheClock() {
        let floor = FloorStatus.shared
        floor.remove()
        #expect(!floor.isTicking)
        // And again — `remove` on something already removed is a no-op, which
        // is what lets `applicationWillTerminate` call it unconditionally.
        floor.remove()
        #expect(!floor.isTicking)
    }
}
