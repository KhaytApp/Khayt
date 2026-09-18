import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Stopping the floor, and starting it again.
///
/// The shared rule refuses a move to printing while production is paused, and
/// this app already translated that refusal — so a shop that paused in the
/// other app arrived here to find every start refused, with nothing on screen
/// saying production was paused and no way to resume. A dead end that looks
/// like a bug.
@MainActor
struct ProductionPauseTests {

    @Test("the rule this exists for really does refuse a start")
    func theRuleRefuses() async throws {
        // Proven against the shared module rather than assumed: if this stops
        // being true, the control below is decoration.
        let engine = try KhaytEngine()
        let order: JSONValue = .object(["id": .string("A-1"), "status": .string("pending")])
        let paused = try await engine.statusGate(
            order: order, to: "printing", orders: [order],
            settings: ["productionPaused": .bool(true)])
        #expect(paused.block?.code == "production_paused", Comment(rawValue: "\(paused)"))
        let running = try await engine.statusGate(
            order: order, to: "printing", orders: [order],
            settings: ["productionPaused": .bool(false)])
        #expect(running.block?.code != "production_paused", Comment(rawValue: "\(running)"))
    }

    @Test("this app has words for that refusal, which is how the gap was found")
    func theRefusalIsTranslated() throws {
        // `gateRefusal` maps the module's CODE to a sentence. If that mapping
        // ever loses this case the refusal reaches a shop as "production_paused".
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Words.swift"), encoding: .utf8)
        #expect(source.contains("case \"production_paused\":"))
    }

    @Test("a book that is not paused reads as not paused, whatever it holds")
    func readingTheFlag() async throws {
        let shop = Shop()
        await shop.load(.sample)
        #expect(shop.productionPaused == false)
        #expect(shop.pauseReason.isEmpty)
    }

    @Test("the sample shop is told it cannot stop the floor")
    func sampleRefuses() async throws {
        let shop = Shop()
        await shop.load(.sample)
        shop.pauseProduction(reason: "waiting on filament")
        #expect(shop.writeProblem == shop.words.callIt("mac.move_sample"))
        #expect(shop.productionPaused == false, "the sample stopped its floor")
        shop.resumeProduction()
        #expect(shop.writeProblem == shop.words.callIt("mac.move_sample"))
    }

    @Test("the control and the banner are on the shell and the menu that ship")
    func wiredIn() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        func read(_ name: String) throws -> String {
            try String(contentsOf: sources.appending(path: name), encoding: .utf8)
        }
        // `Shell.swift` is the shell that ships; `Sidebar.swift` is retired,
        // and something written only into that one ships in no window.
        #expect(try read("Shell.swift").contains("shop.resumeProduction()"),
                "the shipping shell has no paused banner")
        #expect(try read("Menus.swift").contains("shop.pausingProduction = true"),
                "no menu can pause production")
        #expect(try read("Menus.swift").contains("shop.resumeProduction()"),
                "no menu can resume production")
        #expect(try read("ShopWindow.swift").contains("PauseSheet(shop: shop)"),
                "nothing raises the reason sheet")
    }

    @Test("resuming clears all three fields, the way the other app clears them")
    func resumeClearsEverything() throws {
        // `pausedAt` is written as NULL rather than removed: a field taken out
        // entirely is one a merge can resurrect from an older copy on another
        // machine, and this book syncs.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Shop.swift"), encoding: .utf8)
        guard let resume = source.range(of: "func resumeProduction()") else {
            Issue.record("resumeProduction has moved"); return
        }
        let body = source[resume.lowerBound...].prefix(900)
        #expect(body.contains("settings[\"productionPaused\"] = .bool(false)"))
        #expect(body.contains("settings[\"pauseReason\"] = .string(\"\")"))
        #expect(body.contains("settings[\"pausedAt\"] = .null"))
    }
}
