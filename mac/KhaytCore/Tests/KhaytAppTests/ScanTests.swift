import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Reading back a label this app printed.
///
/// ── THE LOOP THIS SUITE IS GUARDING ───────────────────────────────────────
///
/// `ShelfLabels` writes the code and `lib/scan.js` reads it. The two have to
/// agree, and the only way they can be made to agree is for the reader and the
/// writer to be the same pair of modules in both apps — so every assertion
/// below goes through the engine rather than through a regular expression
/// written here, and the last one takes what `ShelfLabels` actually prints and
/// hands it straight to the reader.
@MainActor
struct ScanTests {

    @Test("the three shapes a Khayt label carries")
    func theThreeShapes() async throws {
        let engine = try KhaytEngine()

        let spool = try await engine.scanCode("KHAYT-SPOOL:sp-1")
        #expect(spool.type == "spool")
        #expect(spool.id == "sp-1")

        let order = try await engine.scanCode("KHAYT-ORDER:ORD-1000")
        #expect(order.type == "order")
        #expect(order.id == "ORD-1000")

        let track = try await engine.scanCode("https://cloud.khaytapp.com/p/abc123")
        #expect(track.type == "track")
        #expect(track.token == "abc123")
    }

    @Test("anything else is not a Khayt label, and says so rather than guessing")
    func notALabel() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.scanCode("").type == "empty")
        #expect(try await engine.scanCode("   ").type == "empty")
        // A filament label from a manufacturer is a real thing to scan and not
        // one of ours; the other app falls through to its text parser here.
        #expect(try await engine.scanCode("Sunlu PETG 1kg Black").type == "unknown")
    }

    // MARK: - The loop: what this app prints is what it reads

    @Test("a label this app prints reads back as the record it was printed for")
    func whatIsPrintedIsWhatIsRead() async throws {
        let engine = try KhaytEngine()

        // A parcel with the cloud connected carries the customer's own link,
        // and without it the order's id. Both are printed by the same function
        // and both must come back pointing at the same job.
        let linked = ShelfLabels.orderCode(id: "ORD-1000", trackingToken: "tok-9",
                                           cloudURL: "https://cloud.khaytapp.com", cloudOn: true)
        let readLinked = try await engine.scanCode(linked)
        #expect(readLinked.type == "track", "a printed tracking link does not read as one")
        #expect(readLinked.token == "tok-9")

        let bare = ShelfLabels.orderCode(id: "ORD-1000", trackingToken: nil,
                                         cloudURL: nil, cloudOn: false)
        let readBare = try await engine.scanCode(bare)
        #expect(readBare.type == "order", "a printed order label does not read as one")
        #expect(readBare.id == "ORD-1000")
    }

    // MARK: - Where it goes

    @Test("a scanned spool opens the spool, on the screen it lives on")
    func aSpoolOpens() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let spool = try #require(shop.spools.first)

        let said = await shop.followScan("KHAYT-SPOOL:" + spool.id)
        #expect(said == nil, "a spool that is on the shelf was not found")
        #expect(shop.editingSpool?.id == spool.id)
        #expect(shop.shelf == .inventory, "the sheet opened behind whatever screen was showing")
    }

    @Test("a scanned job is selected, and the search box is cleared so it can be seen")
    func aJobIsSelected() async throws {
        // A job filtered out of the table cannot be selected, so a scan that
        // landed on one would look like a scan that did nothing.
        let shop = Shop()
        await shop.load(.sample)
        let job = try #require(shop.orders.first)
        shop.search = "something that matches nothing"

        let said = await shop.followScan("KHAYT-ORDER:" + job.id)
        #expect(said == nil)
        #expect(shop.selection == job.id)
        #expect(shop.search.isEmpty, "the job was selected behind a filter that hides it")
    }

    @Test("a customer's tracking link finds the job it was printed for")
    func aTrackingLinkFindsTheJob() async throws {
        // The label a shop with the cloud connected prints on a parcel. It
        // names the order by TOKEN and never by id, which is the point of it —
        // so following it is a different lookup, and one the sample book could
        // not reach until an order in it carried a token.
        let shop = Shop()
        await shop.load(.sample)
        let tokened = shop.orderRows.compactMap { row -> (String, String)? in
            guard case .object(let o) = row,
                  let token = Shop.plainString(o["trackingToken"]), !token.isEmpty,
                  let id = Shop.recordId(row) else { return nil }
            return (id, token)
        }
        let (id, token) = try #require(tokened.first,
            "no sample order carries a tracking token, so this branch is never followed")

        let said = await shop.followScan("https://cloud.khaytapp.com/p/" + token)
        #expect(said == nil, "a link printed for an order in this book was not followed")
        #expect(shop.selection == id)

        // A token nobody has is not somebody else's order.
        #expect(await shop.followScan("https://cloud.khaytapp.com/p/not-a-token") != nil)
    }

    @Test("a code for something this book does not have says so")
    func missing() async throws {
        let shop = Shop()
        await shop.load(.sample)
        #expect(await shop.followScan("KHAYT-SPOOL:not-a-spool") != nil)
        #expect(await shop.followScan("KHAYT-ORDER:not-an-order") != nil)
        #expect(await shop.followScan("hello") != nil)
        #expect(await shop.followScan("") != nil)
        // And nothing moved.
        #expect(shop.editingSpool == nil)
        #expect(shop.selection == nil)
    }

    @Test("the sheet is reachable and presented")
    func reachable() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let menus = try String(contentsOf: sources.appending(path: "Menus.swift"), encoding: .utf8)
        #expect(menus.contains("shop.scanning = true"), "there is no way to open the sheet")
        let window = try String(contentsOf: sources.appending(path: "ShopWindow.swift"),
                                encoding: .utf8)
        #expect(window.contains("ScanSheet(shop: shop)"), "the sheet is never presented")

        // A scanner types and presses Return: the field has to act on submit,
        // or the shop holds a scanner to a label and nothing happens.
        let sheet = try String(contentsOf: sources.appending(path: "ScanSheet.swift"),
                               encoding: .utf8)
        #expect(sheet.contains(".onSubmit(follow)"))

        let engineSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytCore/KhaytEngine.swift")
        let text = try String(contentsOf: engineSource, encoding: .utf8)
        #expect(text.contains("\"scan\","), "the module is not on the bundled list")
    }
}
