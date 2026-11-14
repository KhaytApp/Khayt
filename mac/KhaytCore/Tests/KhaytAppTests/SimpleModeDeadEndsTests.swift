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

    @Test("the message names the screen and the mode, offers the switch, in every language it has")
    func theWordsExist() async {
        let shop = await Self.shop(mode: "simple")
        for key in ["sm.gated_title", "sm.gated_body", "sm.gated_switch"] {
            let said = shop.words.callIt(key)
            #expect(said != key && !said.isEmpty)
        }
        #expect(shop.words.callIt("sm.gated_title", ["feature": .string("Kiosk")]).contains("Kiosk"))
        let source = MenuCoverageTests.source("OperatorLockViews.swift")
        #expect(source.contains("shop.hiddenByMode(shop.shelf)"))
        #expect(source.contains("PartOfProfessional("))
        #expect(source.contains("sm.gated_switch"))
    }

    @Test("S4: what the shared map calls Professional is out of Simple, and back in Professional")
    func professionalOnlyRows() async {
        let simple = await Self.shop(mode: "simple")
        #expect(simple.engineProblem == nil, "no engine means this proves nothing")
        for key in Shop.simpleMapKeys {
            #expect(simple.professionalOnly(key), "\(key) is `pro` in SIMPLE_MAP")
        }
        #expect(SettingsWindow.professionalOnly(.team, simple))
        #expect(SettingsWindow.professionalOnly(.assistant, simple))
        #expect(!SettingsWindow.professionalOnly(.integrations, simple), "connectors stay in both modes")
        // The old name for Simple reads the same.
        let enthusiast = await Self.shop(mode: "enthusiast")
        #expect(enthusiast.professionalOnly("kiosk"))
        let pro = await Self.shop(mode: nil)
        for key in Shop.simpleMapKeys { #expect(!pro.professionalOnly(key), "\(key)") }
        #expect(!SettingsWindow.professionalOnly(.team, pro))
    }

    @Test("S4: every entry point to a Professional-only feature asks first")
    func entryPointsAsk() {
        let menus = MenuCoverageTests.source("Menus.swift")
        for key in ["kiosk", "ai", "campaigns", "paymentPlans"] {
            #expect(menus.contains("professionalOnly(\"\(key)\")"), "\(key)")
        }
        #expect(MenuCoverageTests.source("OrderInspector.swift").contains("professionalOnly(\"proforma\")"))
        #expect(MenuCoverageTests.source("OrdersTable.swift").contains("professionalOnly(\"proforma\")"))
        #expect(MenuCoverageTests.source("Kiosk.swift").contains("professionalOnly(\"kiosk\")"))
    }
}
