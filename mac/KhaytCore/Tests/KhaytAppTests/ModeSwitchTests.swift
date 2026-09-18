import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Choosing how much of the app the shop wants.
///
/// This app has HONOURED the mode since the shells were fixed — Simple hides
/// Expenses and Reports — and had no way to set one, so a shop that wanted its
/// Mac simpler had to open the other app to say so.
@MainActor
struct ModeSwitchTests {

    @Test("the modes offered are the two Khayt offers, and enthusiast is not one")
    func onlyTheTwo() {
        // `enthusiast` is Bed Ready's only mode and was retired as a Khayt one.
        // Offering it back would undo the migration every reader performs.
        #expect(Shop.modes == ["simple", "professional"])
        #expect(!Shop.modes.contains("enthusiast"))
    }

    @Test("a mode Khayt does not offer is refused, not written")
    func unknownRefused() async throws {
        let shop = Shop()
        await shop.load(.sample)
        await shop.chooseMode("enthusiast")
        #expect(shop.writeProblem == shop.words.callIt("mac.mode_unknown"))
        await shop.chooseMode("")
        #expect(shop.writeProblem == shop.words.callIt("mac.mode_unknown"))
    }

    @Test("the sample shop is told it cannot switch, rather than failing quietly")
    func sampleRefuses() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let before = shop.mode
        // The sample book is Professional, so this is a real change being asked
        // for rather than a no-op that would return early.
        #expect(before == "professional")
        await shop.chooseMode("simple")
        #expect(shop.writeProblem == shop.words.callIt("mac.move_sample"))
        #expect(shop.mode == before, "the sample changed mode")
    }

    @Test("what the shop is on now, read the way every other reader reads it")
    func modeIsResolved() async throws {
        let shop = Shop()
        await shop.load(.sample)
        // A book written before modes existed means Professional, and a book
        // carrying Bed Ready's mode reads as Simple here. Both are decisions
        // `KhaytEngine.featureEnabled` already makes; this is the same answer
        // so the picker cannot show one thing while the shelves obey another.
        for (stored, expected) in [("simple", "simple"), ("professional", "professional"),
                                   ("enthusiast", "simple"), ("", "professional")] {
            let settings: JSONValue = .object(["mode": .string(stored)])
            let resolved = Shop.modeOf(settings)
            #expect(resolved == expected, Comment(rawValue: "\(stored.debugDescription)"))
            let engineSays = try await shop.engine?.featureEnabled("expenses", mode: stored)
            #expect(engineSays == (resolved == "professional"),
                    Comment(rawValue: "the picker and the shelves disagree about \(stored)"))
        }
        #expect(Shop.modeOf(.object([:])) == "professional")
        #expect(Shop.modeOf(.null) == "professional")
    }

    @Test("the picker is on the shell that ships")
    func wiredIn() throws {
        let pane = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/SettingsWindow.swift"), encoding: .utf8)
        #expect(pane.contains("shop.chooseMode(wanted)"),
                "nothing in Settings can set the mode")
        #expect(pane.contains("set.mode_simple") && pane.contains("set.mode_pro"))
    }
}
