import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Drafting purchase orders for what is low, without being asked each time.
///
/// ── THE SWITCH WAS IN THE OTHER APP ───────────────────────────────────────
///
/// `settings.autoDraftPo` has been in the shop's own book since the other app
/// added it. This one neither honoured it nor offered it, so a shop working
/// here had a setting it could not reach and an automation that never ran.
///
/// ── AND AN APP THAT WRITES UNASKED NEEDS A REASON ─────────────────────────
///
/// Three of them, and it needs all three: the setting is OPT-IN and off by
/// default, what it writes is a DRAFT rather than an order, and the shared
/// rule refuses anything already on its way. Each is pinned below, because
/// losing any one turns a convenience into an app that orders filament by
/// itself.
@MainActor
struct AutoDraftTests {

    static var shopSource: String {
        get throws {
            try String(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Sources/KhaytApp/Shop.swift"), encoding: .utf8)
        }
    }

    @Test("off unless the shop turned it on, and only on a book this app owns")
    func gated() throws {
        let shop = try Self.shopSource
        guard let at = shop.range(of: "func autoDraftIfAsked()") else {
            Issue.record("the automation is gone"); return
        }
        let body = String(shop[at.lowerBound...].prefix(900))
        #expect(body.contains("settingsDict[\"autoDraftPo\"]"),
                "it no longer asks whether the shop wanted this")
        #expect(body.contains("StoreLock.weOwnIt"), Comment(rawValue:
            "a second copy of this app drafting against the same shelf is how one "
            + "shortage becomes two orders"))
        #expect(body.contains("draftWhatIsLow"),
                "it drafts by some path other than the one the button takes")
    }

    @Test("the sample book is never written to, however the setting reads")
    func notTheSample() async {
        // `source.build` is nil for the sample, which is what stops it — the
        // same guard `draftWhatIsLow` uses. Checked because a demo book that
        // gained purchase orders on opening would be a demo nobody trusts.
        let shop = Shop()
        await shop.load(.sample)
        await shop.autoDraftIfAsked()
        #expect(shop.autoDrafted == 0)
    }

    @Test("running twice does not order twice — the rule reads what is coming")
    func noSecondOrder() async throws {
        // This is the property that makes running on every load safe, and it
        // belongs to `lib/reorder.js`, not to this app: an item with an order
        // already against it is not suggested again.
        //
        // Driven from the SAMPLE BOOK rather than a fixture built here. A
        // hand-made spool that suggests nothing would make this test pass by
        // proving nothing, which is exactly what the first version of it did.
        let shop = Shop()
        await shop.load(.sample)
        let wanted = shop.needsOrdering
        #expect(!wanted.isEmpty, "the sample suggests nothing to order, so this proves nothing")
        let first = try #require(wanted.first)

        let engine = try #require(shop.engine)
        let root = try #require(await Self.sampleRoot())
        func stillWanted(_ orders: [JSONValue]) async throws -> Bool {
            try await engine.needsOrdering(
                spools: Shop.rows(root, "inventory"),
                consumables: Shop.rows(root, "consumables"),
                orders: Shop.rows(root, "printLog"),
                purchaseOrders: orders,
                settings: shop.settingsDict, now: Date()
            ).contains { $0.id == first.id }
        }

        // An order of the RIGHT KIND silences it.
        var po: [String: JSONValue] = [
            "id": .string("PO-TEST"), "itemId": .string(first.id),
            "status": .string("ordered"), "qty": .number(5)]
        if first.consumable { po["kind"] = .string("consumable") }
        #expect(!(try await stillWanted([.object(po)])), Comment(rawValue:
            "\(first.id) is still suggested with an order already on its way — running "
            + "on every load would draft one a day until somebody noticed"))

        // AND THE WRONG KIND DOES NOT, which is deliberate and easy to lose.
        // A consumable id and a spool id are minted by the same `uid()`, so a
        // dedupe that matched across both would let an order for one silence a
        // shortage of the other. This is the case that proves it still does not.
        if first.consumable {
            var wrongKind = po
            wrongKind["kind"] = .string("filament")
            #expect(try await stillWanted([.object(wrongKind)]), Comment(rawValue:
                "a filament order silenced the consumable \(first.id) that shares its id"))
        }
    }

    static func sampleRoot() async -> [String: JSONValue]? {
        guard let url = AppResources.bundle.url(forResource: "sample-shop", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else { return nil }
        return SampleBook.rebased(root, to: Date())
    }

    @Test("it is offered in settings, and saved through the rule that keeps it")
    func offeredAndSaved() throws {
        let pane = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/SettingsWindow.swift"), encoding: .utf8)
        #expect(pane.contains("reorder.auto_toggle"),
                "the setting is honoured here and can still only be changed in the other app")
        #expect(pane.contains("\"autoDraftPo\": .bool(autoDraftPo)"),
                "the pane draws the switch and does not send it")

        // And the shared rule has to KNOW the key, or the pane sends it and
        // `settings-edit` keeps the old value: a switch that flips back.
        let edit = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Tests/KhaytAppTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/KhaytCore
            .deletingLastPathComponent()   // …/mac
            .deletingLastPathComponent()   // the repository root
            .appending(path: "lib/settings-edit.js"), encoding: .utf8)
        #expect(edit.contains("autoDraftPo"), Comment(rawValue:
            "lib/settings-edit.js does not know this key, so the pane's switch is "
            + "dropped on save and reads as off again the next time it is opened"))
    }

    @Test("what it did is said, not left to be discovered")
    func itSaysSo() throws {
        let banners = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/Banners.swift"), encoding: .utf8)
        #expect(banners.contains("reorder.auto_drafted"), Comment(rawValue:
            "the book changed while nobody was typing and nothing on screen says so"))
        #expect(banners.contains("shop.autoDrafted = 0"), "the banner cannot be dismissed")
    }
}
