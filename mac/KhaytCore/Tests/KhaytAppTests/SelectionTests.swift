import Foundation
import Testing
@testable import KhaytApp

/// Moving through the library with the keyboard.
///
/// Against the sample shop, which is committed and therefore the same for
/// everyone, over the model TILES it draws (`visibleFiles`): in All models
/// its "Dental" group is one print in parts and so one tile, not two models.
@MainActor
struct SelectionTests {

    static func loadedShop() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        shop.shelf = .library(nil)
        return shop
    }

    @Test("the first arrow press picks an end rather than doing nothing")
    func firstPress() async {
        let shop = await Self.loadedShop()
        #expect(shop.fileSelection.isEmpty)
        #expect(shop.moveSelection(by: 1, extending: false))
        #expect(shop.fileSelection == [shop.visibleFiles.first!.id],
                "a Finder window selects the first item, it does not sit there")

        let backwards = await Self.loadedShop()
        #expect(backwards.moveSelection(by: -1, extending: false))
        #expect(backwards.fileSelection == [backwards.visibleFiles.last!.id],
                "arriving from the other direction should land on the other end")
    }

    @Test("it stops at the ends and says so, so the beep still means something")
    func stopsAtTheEnds() async {
        // Through `select`, not by assigning `fileSelection`: clicking is what
        // sets the keyboard's position, and a test that sets the selection
        // behind its back is testing a state the app cannot be in.
        let atStart = await Self.loadedShop()
        atStart.select(atStart.visibleFiles.first!, modifiers: .replace)
        #expect(!atStart.moveSelection(by: -1, extending: false),
                "before the first must be unhandled, not silently clamped")
        #expect(atStart.fileSelection == [atStart.visibleFiles.first!.id], "and must not move")
        #expect(atStart.moveSelection(by: 1, extending: false), "forward from the first works")

        let atEnd = await Self.loadedShop()
        atEnd.select(atEnd.visibleFiles.last!, modifiers: .replace)
        #expect(!atEnd.moveSelection(by: 1, extending: false),
                "past the last must be unhandled")
        #expect(atEnd.fileSelection == [atEnd.visibleFiles.last!.id], "and must not move")
    }

    @Test("a whole row down lands a row down, and past the bottom does nothing")
    func rowMoves() async {
        let shop = await Self.loadedShop()
        let rows = shop.visibleFiles
        shop.select(rows[0], modifiers: .replace)
        #expect(shop.moveSelection(by: 4, extending: false))
        #expect(shop.fileSelection == [rows[4].id])
        // From near the end, a whole row down falls off — and is refused whole
        // rather than landing on the last item, which would be a different
        // place from the one under the cursor.
        shop.select(rows[rows.count - 2], modifiers: .replace)
        #expect(!shop.moveSelection(by: 4, extending: false))
    }

    @Test("shift grows the selection, and shift back shrinks it again")
    func extending() async {
        let shop = await Self.loadedShop()
        let rows = shop.visibleFiles
        shop.select(rows[2], modifiers: .replace)

        _ = shop.moveSelection(by: 1, extending: true)
        _ = shop.moveSelection(by: 1, extending: true)
        #expect(shop.fileSelection == Set(rows[2...4].map(\.id)), "three, from where it started")

        // Back towards the anchor. Growing from the anchor rather than from
        // wherever the last step landed is what makes this shrink instead of
        // adding to the other end.
        _ = shop.moveSelection(by: -1, extending: true)
        #expect(shop.fileSelection == Set(rows[2...3].map(\.id)))
    }

    @Test("select all takes what is on screen, not the whole library")
    func selectAllRespectsTheFilter() async {
        let shop = await Self.loadedShop()
        shop.shelf = .library("Saudi Kings")
        let shown = shop.visibleFiles
        #expect(shown.count < shop.files.count, "the group must actually be filtering")
        shop.selectAllShown()
        #expect(shop.fileSelection == Set(shown.map(\.id)),
                "⌘A on a filtered shelf must not reach past the filter")
    }
}
