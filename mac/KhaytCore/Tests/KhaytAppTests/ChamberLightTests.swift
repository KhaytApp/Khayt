import Foundation
import Testing
@testable import KhaytApp

/// What the chamber-light switch draws for each state (Figma 181:247), and
/// that the last tile going away ends the keep-awake without a stop.
@MainActor
@Suite struct ChamberLightTests {
    @Test("each light state draws as the frame says")
    func reading() {
        #expect(ChamberLightButton.reading(.on) == (true, false))
        #expect(ChamberLightButton.reading(.off) == (false, false))
        // Switching shows where it is going and holds the switch.
        #expect(ChamberLightButton.reading(.switching(to: true)) == (true, true))
        #expect(ChamberLightButton.reading(.switching(to: false)) == (false, true))
        // A switch that did not take snaps back to what the printer says.
        #expect(ChamberLightButton.reading(.failed(was: false)) == (false, false))
        #expect(ChamberLightButton.reading(.failed(was: true)) == (true, false))
    }

    @Test("two tiles on one machine: the renewal stops only when both are gone")
    func watchersCount() {
        let camera = Camera()
        camera.watchers["m1"] = 2
        camera.waking["m1"] = Task {}
        camera.unwatch("m1")
        #expect(camera.watchers["m1"] == 1)
        #expect(camera.waking["m1"] != nil)
        camera.unwatch("m1")
        #expect(camera.watchers["m1"] == nil)
        #expect(camera.waking["m1"] == nil)
        // An extra disappear (SwiftUI can send one) is harmless.
        camera.unwatch("m1")
        #expect(camera.watchers["m1"] == nil)
    }

    /// A renewal that stops by itself (not a camera that needs keeping) leaves
    /// no count behind, so a tile that appears later starts it again (#2589
    /// review L4: the count stayed at 1 with no task, and never restarted).
    @Test("a renewal that ends by itself forgets the machine")
    func stoppedWakingClears() {
        let camera = Camera()
        camera.watchers["m1"] = 1
        camera.waking["m1"] = Task {}
        camera.stoppedWaking("m1")
        #expect(camera.watchers["m1"] == nil)
        #expect(camera.waking["m1"] == nil)
    }
}
