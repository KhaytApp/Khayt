import Foundation
import Testing
@testable import KhaytApp

/// A Simple shop is never pointed at a screen it cannot open, and a screen its
/// mode hides is never explained in the staff lock's words (Nov 11 2026 UI
/// review, B26 and B27).
@MainActor
struct SimpleModeDeadEndsTests {

    static func shop(mode: String?) async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        if let mode { shop.pretendMode(mode) }
        await shop.readFeatures()
        return shop
    }

    @Test("Today does not say \"Reconciled in Reports\" to a shop with no Reports")
    func noPointerToAHiddenScreen() async {
        let simple = await Self.shop(mode: "simple")
        #expect(simple.engineProblem == nil, "no engine means this proves nothing")
        #expect(!simple.has("analytics"))
        #expect(simple.monthNetNote == nil)
        // A shop whose book has not been read yet is not a Simple shop: its
        // dash keeps its explanation.
        #expect(Shop().monthNetNote != nil)
        // A Professional shop with no figure yet still gets the line.
        let pro = await Self.shop(mode: nil)
        if pro.monthNet == nil {
            #expect(pro.monthNetNote == pro.words.callIt("mac.net_in_reports"))
        } else {
            #expect(pro.monthNetNote == nil)
        }
    }

    @Test("a screen the mode hides is told apart from one the lock refuses")
    func modeIsNotTheLock() async {
        let simple = await Self.shop(mode: "simple")
        #expect(simple.hiddenByMode(.reports))
        #expect(simple.hiddenByMode(.expenses))
        #expect(!simple.hiddenByMode(.dashboard), "nothing gates Today")
        #expect(!simple.canShow(.reports))
        let pro = await Self.shop(mode: nil)
        #expect(!pro.hiddenByMode(.reports))
        #expect(pro.canShow(.reports))
    }

    @Test("the message names the mode and the app says it in every language it has")
    func theWordsExist() async {
        let shop = await Self.shop(mode: "simple")
        for key in ["mac.mode_screen_hidden", "mac.mode_open_settings"] {
            let said = shop.words.callIt(key)
            #expect(said != key && !said.isEmpty)
        }
        let source = MenuCoverageTests.source("OperatorLockViews.swift")
        #expect(source.contains("shop.hiddenByMode(shop.shelf)"))
        #expect(source.contains("mac.mode_screen_hidden"))
    }
}
