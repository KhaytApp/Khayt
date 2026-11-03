import Foundation
import Testing

/// Today in the system-sidebar window is the home screen for every level, and
/// the shop's figures on it answer to the lock the navy strip always asked.
///
/// The beta.18 review found the default window drawing `Dashboard` straight
/// from `classicScreens`, where `showsMoney` asked only the shop's MODE — so an
/// operator signed in to a locked Mac saw what is owed, the month's net, the
/// goal, the takings and the chase list. These pin the two halves of the fix.
struct TodayLockTests {
    static func source(_ name: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: "Sources/KhaytApp/\(name)"), encoding: .utf8)
    }

    @Test("Today's money and the chase list ask the lock, not only the shop's mode")
    func moneyAsksTheLock() throws {
        let today = try Self.source("Dashboard.swift")
        #expect(today.contains(#"let showsMoney = shop.facts?.showsMoney != false && shop.lockAllows("analytics", "view")"#))
        #expect(today.contains(#"if shop.lockAllows("analytics", "view"), ToChase(shop: shop).hasRows"#))
    }

    @Test("the default window's home goes through Triage, which gates the Ledger")
    func homeGoesThroughTriage() throws {
        let window = try Self.source("ShopWindow.swift")
        let classic = try #require(window.range(of: "private var classicScreens"))
        let tail = String(window[classic.upperBound...].prefix(900))
        #expect(tail.contains("Triage(shop: shop)"))
        #expect(!tail.contains("Dashboard(shop: shop)"))
    }

    @Test("Due this week leaves shipped and delivered jobs out and names every open stage")
    func dueKnowsEveryStage() throws {
        let pieces = try Self.source("TodayPieces.swift")
        #expect(pieces.contains(#"static let closed: Set<String> = ["completed", "shipped", "delivered", "cancelled"]"#))
        for stage in ["on_hold", "post", "qc"] {
            #expect(pieces.contains(#"w.callIt("queue.\#(stage)")"#))
        }
    }
}
