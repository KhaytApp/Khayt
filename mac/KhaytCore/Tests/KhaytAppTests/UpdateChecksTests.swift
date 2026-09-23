import Foundation
import Testing
@testable import KhaytApp

/// The app looks for updates by itself, at launch and hourly, and a shop can
/// say otherwise. `test/mac-release-lane.test.js` holds the Info.plist keys
/// `make-app.sh` writes; this holds the launch check and the switches.
@MainActor
struct UpdateChecksTests {

    @Test("it looks once at launch, only when automatic checks are on")
    func launchCheck() {
        let src = MenuCoverageTests.source("Updates.swift")
        guard let guardAt = src.range(of: "if controller.updater.automaticallyChecksForUpdates {"),
              let checkAt = src.range(of: "controller.updater.checkForUpdatesInBackground()") else {
            Issue.record("the launch check is gone"); return
        }
        #expect(guardAt.upperBound <= checkAt.lowerBound, "the launch check ignores the shop's choice")
        #expect(!src.contains("controller.updater.checkForUpdates()\n"),
                "a launch check with a dialog in front of the shop")
    }

    @Test("the switches are in Settings, on this Mac, and a local build has none to flip")
    func switches() {
        #expect(MenuCoverageTests.source("SettingsWindow.swift").contains("UpdateToggles(shop: shop)"))
        // `swift test` runs with no SUFeedURL, so the updater never starts:
        // the switches read off rather than pretending.
        #expect(!Updates.shared.isAvailable)
        #expect(!Updates.shared.checksAutomatically)
    }
}
