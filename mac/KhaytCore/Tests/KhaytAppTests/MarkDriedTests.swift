import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Saying a spool has been dried.
///
/// ── AN APP THAT NAGGED AND WOULD NOT BE ANSWERED ──────────────────────────
///
/// The shelf draws `due` and `overdue` from `lib/filament-dryness.js`, which
/// reads `driedAt` and nothing else. This app had no field for it and no
/// action, so a spool it called overdue stayed overdue for ever.
///
/// The other app could not clear it either, for a different reason: its drying
/// log wrote `dryingLog` and never `driedAt`, and the main window did not even
/// LOAD the rule. Two apps, one verdict, and nothing in either that could
/// answer it.
@MainActor
struct MarkDriedTests {

    @Test("the verdict this app draws reads the field this app now writes")
    func endToEnd() async throws {
        let engine = try KhaytEngine()
        let wet = JSONValue.object(["id": .string("SP-1"), "material": .string("PETG"),
                                    "weight": .number(800), "storage": .string("shelf")])
        // Overdue, or at least not good, with nothing recorded.
        let before = try await engine.dryness(spools: [wet], now: Date())
        #expect(before["SP-1"]?.state != "good", Comment(rawValue:
            "\(before["SP-1"]?.state ?? "nil") — the fixture is already dry, so this proves nothing"))

        // What `markDried` sends, through the same rule it sends it through.
        let dried = try await engine.editSpool(
            wet,
            input: ["material": .string("PETG"), "driedAt": .string(Shop.localDay())],
            settings: [:], today: Shop.today())
        let after = try await engine.dryness(spools: [try #require(dried.spool)], now: Date())
        #expect(after["SP-1"]?.state == "good", Comment(rawValue:
            "\(after["SP-1"]?.state ?? "nil") — the nag cannot be cleared"))
    }

    @Test("the shelf offers it, and it is a write so a read-only book refuses")
    func wired() throws {
        let floor = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/ShopFloor.swift"), encoding: .utf8)
        #expect(floor.contains("mac.mark_dried"), "there is no way to say a spool was dried")
        #expect(floor.contains("shop.markDried(spool.id)"), "the menu item writes nothing")
        // The state it answers is drawn on the same card.
        #expect(floor.contains("state == \"overdue\" || state == \"due\""),
                "the nag this answers is no longer drawn, so the action is orphaned")
    }

    @Test("it goes through the spool rule rather than writing the field itself")
    func throughTheRule() throws {
        let shop = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Shop.swift"), encoding: .utf8)
        guard let at = shop.range(of: "func markDried(") else {
            Issue.record("markDried is gone"); return
        }
        let body = String(shop[at.lowerBound...].prefix(1600))
        #expect(body.contains("engine.editSpool"), Comment(rawValue:
            "the date is written straight onto the record, so the one rule that decides "
            + "what a spool may hold has been stepped around"))
        #expect(body.contains("StoreLock.weOwnIt"), "a book this app does not own is written to")
    }
}
