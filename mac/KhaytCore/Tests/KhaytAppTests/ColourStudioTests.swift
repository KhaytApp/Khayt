import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Colour, and the one place where "obvious" is wrong.
///
/// The arithmetic is `lib/color-mix.js` and is tested where it lives. What is
/// tested here is that this app asks it rather than guessing — because the
/// guess is easy to write, looks right in a unit test with primary colours, and
/// hands a shop the wrong spool on the colours it actually owns.
@MainActor
struct ColourStudioTests {

    static func shop() async throws -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        try #require(shop.engine != nil, "the shared rules did not start")
        return shop
    }

    /// THE CASE THAT SEPARATES THE TWO METHODS.
    ///
    /// Target `#B1FC74`, a light yellow-green. Two spools:
    ///
    /// | | plain RGB distance | ΔE (CIEDE2000) |
    /// |---|---|---|
    /// | `#F9B9ED` pink  | **155.9** — nearer | 66.3 — nothing like it |
    /// | `#25EA27` green | 160.8 — further    | **10.6** — a usable match |
    ///
    /// A nearest-hex-triple search hands the shop the PINK. That is not a
    /// contrived pair; it falls out of sRGB not being perceptually uniform, and
    /// it is the whole reason this screen asks a module instead of subtracting
    /// three numbers.
    @Test("closest means how it looks, not how near the hex is")
    func perceptualNotArithmetic() async throws {
        let shop = try await Self.shop()
        let target = "#B1FC74"
        let candidates: [JSONValue] = [
            .object(["id": .string("pink"), "color": .string("#F9B9ED")]),
            .object(["id": .string("green"), "color": .string("#25EA27")]),
        ]
        let ranked = try await #require(shop.engine).nearestFilaments(to: target, among: candidates)
        #expect(ranked.first?.id == "green",
                "a nearest-hex search would have answered pink")
        #expect(try #require(ranked.first).deltaE < 12, "and it is a match a shop could use")

        // The arithmetic that would have been wrong, spelled out so the table
        // above is checkable rather than asserted — and so this test fails
        // loudly if the example ever stops being an example.
        func plain(_ a: String, _ b: String) -> Double {
            let x = Swatch.rgb(fromHex: a)!, y = Swatch.rgb(fromHex: b)!
            return (((x.r - y.r) * (x.r - y.r) + (x.g - y.g) * (x.g - y.g)
                     + (x.b - y.b) * (x.b - y.b)).squareRoot()) * 255
        }
        #expect(plain(target, "#F9B9ED") < plain(target, "#25EA27"),
                "the pink is the nearer hex; if it stops being so this case proves nothing")
    }

    @Test("a colour matches itself exactly, and the list is closest first")
    func ordering() async throws {
        let shop = try await Self.shop()
        let candidates: [JSONValue] = [
            .object(["id": .string("far"), "color": .string("#FFFFFF")]),
            .object(["id": .string("exact"), "color": .string("#C0392B")]),
            .object(["id": .string("near"), "color": .string("#B93A2C")]),
        ]
        let ranked = try await #require(shop.engine).nearestFilaments(to: "#C0392B", among: candidates)
        #expect(ranked.map(\.id) == ["exact", "near", "far"])
        #expect(ranked.first!.deltaE < 0.001, "the same colour is no distance from itself")
    }

    /// A filament with no hex is not ranked at all — `deltaE` is not finite, so
    /// the module drops it. A row in a ranked list with no distance would be a
    /// row that means nothing.
    @Test("a filament with no colour is left out rather than ranked last")
    func colourless() async throws {
        let shop = try await Self.shop()
        let candidates: [JSONValue] = [
            .object(["id": .string("named"), "color": .string("black")]),
            .object(["id": .string("none")]),
            .object(["id": .string("real"), "color": .string("#123456")]),
        ]
        let ranked = try await #require(shop.engine).nearestFilaments(to: "#123456", among: candidates)
        #expect(ranked.map(\.id) == ["real"])
    }

    /// Mixing happens in LINEAR light, so the midpoint of black and white is
    /// not `#808080`. It is around `#BC`, because sRGB is gamma-encoded and
    /// averaging the encoded values darkens the result — the classic mistake,
    /// and the one that makes a gradient look muddy in the middle.
    @Test("two colours mix in linear light, not by averaging their hex")
    func linearBlend() async throws {
        let shop = try await Self.shop()
        let mid = try await #require(shop.engine).blend("#000000", "#FFFFFF", 0.5)
        let value = try #require(Swatch.rgb(fromHex: try #require(mid)))
        #expect(value.r > 0.65, "an sRGB average would put this at 0.5")
        #expect(abs(value.r - value.g) < 0.001 && abs(value.g - value.b) < 0.001, "still grey")
    }

    @Test("a gradient keeps both ends and has the number of steps asked for")
    func gradientEnds() async throws {
        let shop = try await Self.shop()
        let ramp = try await #require(shop.engine).gradient("#FF0000", "#0000FF", steps: 5)
        #expect(ramp.count == 5)
        #expect(ramp.first?.uppercased() == "#FF0000")
        #expect(ramp.last?.uppercased() == "#0000FF")
    }

    /// Nothing rather than a guess. A gradient drawn between a colour and a
    /// word would be five swatches of something nobody chose.
    @Test("a gradient from something that is not a colour is empty")
    func gradientRefuses() async throws {
        let shop = try await Self.shop()
        #expect(try await #require(shop.engine).gradient("#FF0000", "royal blue", steps: 4).isEmpty)
    }

    /// The picker hands back a `Color` that may be in Display P3. Reading its
    /// components without converting gives values outside 0-1 for a saturated
    /// colour, and `#00FF00` for something that is not green.
    @Test("a colour from the picker is written down in sRGB")
    func hexThroughSRGB() throws {
        let hex = try #require(ColourStudio.hex(.init(red: 0.2, green: 0.4, blue: 0.6)))
        #expect(hex.hasPrefix("#") && hex.count == 7)
        let back = try #require(Swatch.rgb(fromHex: hex))
        #expect(abs(back.r - 0.2) < 0.01 && abs(back.g - 0.4) < 0.01 && abs(back.b - 0.6) < 0.01)
    }

    /// The screen is reachable and comes back after a relaunch. A shelf the
    /// sidebar offers and `Shelves` cannot name restores to the jobs table
    /// every time the app opens.
    @Test("the colour shelf survives being written down and read back")
    func shelfRoundTrips() async throws {
        let shop = try await Self.shop()
        #expect(Shelves.name(.colour) == "colour")
        #expect(Shelves.shelf("colour", in: shop) == .colour)
    }
}

/// The portfolio: every photograph on every job, in one grid.
@MainActor
struct PortfolioTests {

    static func shop() async throws -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        return shop
    }

    /// The flattening is the whole of this screen's logic, so it is the whole
    /// of the test: two photos on one job and one on another are three cells,
    /// each knowing which job it came from.
    @Test("photos from every job are one list, in the book's order")
    func flattens() async throws {
        let shop = try await Self.shop()
        let book: [String: JSONValue] = ["printLog": .array([
            .object(["id": .string("ORD-1"), "project": .string("Bracket"),
                     "date": .string("2026-01-02"),
                     "printPhotos": .array([
                        .object(["thumb": .string("data:image/png;base64,AA"), "filename": .string("a.jpg")]),
                        .object(["thumb": .string("data:image/png;base64,BB"), "filename": .string("b.jpg")]),
                     ])]),
            .object(["id": .string("ORD-2"), "project": .string("Jig"),
                     "printPhotos": .array([
                        .object(["thumb": .string("data:image/png;base64,CC")]),
                     ])]),
            // A job with no photos contributes nothing rather than an empty cell.
            .object(["id": .string("ORD-3"), "project": .string("Nothing")]),
        ])]
        shop.readSnapshotsForTests(book)

        #expect(shop.snapshots.map(\.id) == ["ORD-1#0", "ORD-1#1", "ORD-2#0"])
        #expect(shop.snapshots.first?.project == "Bracket")
        #expect(shop.snapshots.first?.date == "2026-01-02")
        // No file on this Mac, so nothing to open — and the row is still there,
        // because the thumbnail lives in the book.
        #expect(shop.snapshots.allSatisfy { $0.file == nil })
        #expect(shop.snapshots.last?.thumb == "data:image/png;base64,CC")
    }

    @Test("a book with no photographs has no portfolio at all")
    func empty() async throws {
        let shop = try await Self.shop()
        shop.readSnapshotsForTests(["printLog": .array([
            .object(["id": .string("ORD-1"), "printPhotos": .array([])]),
        ])])
        #expect(shop.snapshots.isEmpty)
        // And the shelf refuses to restore, so a relaunch cannot land on it.
        #expect(Shelves.shelf("portfolio", in: shop) == nil)
    }
}

/// The sample book has to DEMONSTRATE the app, not merely load into it.
///
/// Both of these screens shipped their empty state on sample data: not one of
/// the six spools carried a hex colour, and not one of forty-two jobs carried a
/// photograph. Nothing was broken — the matcher had nothing to rank and the
/// grid had nothing to draw — and the two shelves a person is most likely to
/// click on first looked like features that had not been finished.
///
/// The tests above prove the rules are right. These prove somebody can SEE
/// them, which is a separate thing and the one that was missing.
@MainActor
struct SampleBookShowsTheAppTests {

    static func shop() async throws -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        return shop
    }

    /// `spool-edit.js:82` writes `color` as a hex and defaults it to `#888888`,
    /// so a book whose spools have none is a book no run of the app produced.
    ///
    /// Ranked through `shop.inventoryRows`, which is what the screen hands the
    /// module — a test that colours the decoded `Spool`s and ranks those would
    /// pass with the raw rows the screen actually reads left empty.
    @Test("the sample shop's spools have colours, so the matcher can rank them")
    func spoolsAreColoured() async throws {
        let shop = try await Self.shop()
        let coloured = shop.spools.filter { Swatch.rgb(fromHex: $0.color) != nil }
        #expect(coloured.count == shop.spools.count,
                """
                \(shop.spools.count - coloured.count) sample spool(s) have no hex colour — \
                Colour Studio shows its empty state instead of the shop's shelf
                """)
        #expect(coloured.count >= 4, "too few to make a ranked list worth looking at")

        // The limit is the SHELF, not the eight this shop happened to have when
        // this was written: the assertion is that every coloured row can be
        // ranked, and a cap smaller than the shelf makes it a test of the cap.
        let ranked = try await #require(shop.engine)
            .nearestFilaments(to: "#2E6F9E", among: shop.inventoryRows,
                              limit: shop.inventoryRows.count)
        #expect(ranked.count == coloured.count, "the raw rows the screen reads carry no colour")
        // Spread out, or every answer is a tie and the ranking teaches nothing.
        #expect((ranked.last?.deltaE ?? 0) - (ranked.first?.deltaE ?? 0) > 20,
                "the sample colours sit on top of each other; the ranking looks arbitrary")
    }

    /// The same lesson a third time. Colour Studio and the portfolio both
    /// shipped showing their empty state on sample data; the gift cards screen
    /// was heading the same way, and its status column is the part that has
    /// nothing to say unless the cards are in different states.
    @Test("the sample shop's gift cards show every state the rule can return")
    func giftCardsAreWorthLookingAt() async throws {
        let shop = try await Self.shop()
        #expect(shop.giftCards.count >= 3,
                "\(shop.giftCards.count) sample card(s) — the screen shows its empty state")
        let states = Set(shop.giftCardStatuses.values)
        #expect(states == ["active", "used", "expired"],
                "the sample shows only \(states.sorted()); the status column teaches nothing")
        // One expired card with money still on it — the case a shop has to be
        // able to SEE, and the one an "expired means empty" reading would miss.
        let expired = shop.giftCards.filter { shop.giftCardStatuses[$0.id] == "expired" }
        #expect(expired.contains { ($0.balance ?? 0) > 0 })
    }

    /// A fourth screen that would have shipped showing only one of its states.
    /// The shelf's whole job is saying which spool is about to run out, and a
    /// shelf where nothing is low cannot show that it would.
    @Test("the sample shelf has a spool running low, and the rule agrees")
    func shelfShowsLow() async throws {
        let shop = try await Self.shop()
        let low = shop.spools.filter { shop.lowSpools[$0.id] == true }
        #expect(!low.isEmpty, "no low item — the shelf cannot show its warning")
        // Under the shared rule's default threshold, and visibly so. The
        // FILAMENT one, which is what this test was written about and the only
        // kind of item the shelf held when it was.
        let lowFilament = low.filter { shop.unit(of: $0)?.unit ?? "g" == "g" }
        #expect(lowFilament.count == 1)
        #expect((lowFilament.first?.weight ?? 999) < 200)
        // And most are not, or every card would wear the warning.
        #expect(shop.lowSpools.values.filter { $0 }.count < shop.spools.count / 2)
    }

    /// The delta, pinned separately: "low" now means something different per
    /// unit, and the shelf has to be able to draw that. Two sheets left is low
    /// and 180 g of the same number is not — under the old single gram
    /// threshold the acrylic would have looked fully stocked at two sheets.
    @Test("low means something different on the sheet rack than on the spool shelf")
    func lowIsPerUnit() async throws {
        let shop = try await Self.shop()
        let sheets = shop.spools.filter { shop.unit(of: $0)?.unit == "sheet" }
        #expect(!sheets.isEmpty, "nothing on the shelf is counted in sheets")
        let lowSheets = sheets.filter { shop.lowSpools[$0.id] == true }
        #expect(!lowSheets.isEmpty,
                "no sheet stock is low, so the per-unit threshold is never drawn")
        // And it is low at a figure the gram rule would have called plenty.
        #expect((lowSheets.first?.weight ?? 999) < 200)
    }

    @Test("the sample shop has photographs, so the portfolio is a portfolio")
    func jobsArePhotographed() async throws {
        let shop = try await Self.shop()
        #expect(shop.snapshots.count >= 5,
                """
                only \(shop.snapshots.count) sample photo(s) — the portfolio grid shows \
                its empty state, or a single lonely cell
                """)
        // Drawn from several jobs, or it is one job's gallery rather than a
        // portfolio of the shop's work.
        #expect(Set(shop.snapshots.map(\.orderId)).count >= 5)
        #expect(shop.snapshots.allSatisfy { ($0.thumb ?? "").hasPrefix("data:image/") },
                "a thumbnail that is not inline is a cell that cannot draw on a read-only book")
    }
}

/// Arrows have to turn round in Arabic.
///
/// `arrow.right` and `arrow.forward` are the same glyph in English, so the
/// difference is invisible until the app is run right-to-left — where the two
/// spool pickers swap sides and a fixed right-pointing arrow says the gradient
/// runs from the TO colour to the FROM one, contradicting the swatches drawn
/// directly underneath it. Found by photographing the screen in Arabic, which
/// is the only way it could have been.
@MainActor
struct DirectionalGlyphTests {
    @Test("no screen pins an arrow to a side of the window")
    func arrowsFollowTheWriting() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let files = try FileManager.default.contentsOfDirectory(at: views, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(files.count > 30, "the source moved — this is reading the wrong directory")

        var pinned: [String] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                for glyph in ["\"arrow.right\"", "\"arrow.left\"",
                              "\"chevron.right\"", "\"chevron.left\""] where trimmed.contains(glyph) {
                    pinned.append("\(file.lastPathComponent):\(n + 1)  \(trimmed)")
                }
            }
        }
        #expect(pinned.isEmpty, """
            \(pinned.count) arrow(s) point at a side of the window rather than forward:

            \(pinned.joined(separator: "\n"))

            Use `arrow.forward` / `arrow.backward` (and `chevron.forward` /
            `chevron.backward`), which turn round in Arabic.
            """)
    }
}
