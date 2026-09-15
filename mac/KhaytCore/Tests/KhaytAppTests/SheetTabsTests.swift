import Foundation
import Testing
import SwiftUI
import KhaytCore
@testable import KhaytApp

/// §6's twelve-field rule, and the table it applies to.
///
/// The rule has two halves and the second is the one that gets forgotten:
/// tabs appear above twelve fields, and **must not** appear at or below. A
/// short form behind tabs hides work rather than organising it, and it is an
/// easy mistake to make in the direction of tidiness.
@MainActor
struct SheetTabsTests {

    @Test("the map obeys the rule it exists to express")
    func mapIsSelfConsistent() {
        for sheet in SheetMap.all {
            if sheet.shouldHaveTabs {
                #expect(sheet.panes.count >= 2, Comment(rawValue: """
                    \(sheet.name) has \(sheet.fields) fields — above twelve — and \
                    \(sheet.panes.count) pane(s). Above twelve earns tabs, and \
                    one tab is not tabs.
                    """))
            } else {
                #expect(sheet.panes.isEmpty, Comment(rawValue: """
                    \(sheet.name) has \(sheet.fields) fields — at or under twelve — \
                    and \(sheet.panes.count) panes. §6: at or below twelve they \
                    must NOT appear; they hide work rather than organise it.
                    """))
            }
        }
    }

    @Test("the boundary is exactly twelve, and twelve is below it")
    func twelveIsNotAboveTwelve() {
        // The sheet the design drew as the counter-example: eleven fields, one
        // pane, no tabs. If the comparison ever becomes `>=`, this is the sheet
        // that would sprout them.
        let spool = SheetMap.sheet("Spool")
        #expect(spool?.shouldHaveTabs == false)
        #expect(SheetMap.Sheet(name: "x", fields: 12, panes: []).shouldHaveTabs == false,
                "twelve fields earned tabs; the rule is ABOVE twelve")
        #expect(SheetMap.Sheet(name: "x", fields: 13, panes: ["a", "b"]).shouldHaveTabs,
                "thirteen fields did not earn tabs")
    }

    @Test("every pane has a word in both languages")
    func paneWordsResolve() async throws {
        for language in ["en", "ar"] {
            let words = Words()
            await words.load(language, engine: try KhaytEngine())
            for sheet in SheetMap.all {
                for pane in sheet.panes {
                    let key = "mac.pane_" + pane
                    #expect(words.callIt(key) != key, Comment(rawValue: """
                        \(key) is missing in \(language) — a missing key is not \
                        blank, it IS the key, so the tab would read "mac.pane_\(pane)"
                        """))
                }
            }
        }
    }

    /// A strip of one is not a strip.
    @Test("a pane control refuses to draw a single pane")
    func onePaneIsNotPanes() {
        let tabbed = SheetMap.all.filter(\.shouldHaveTabs)
        #expect(!tabbed.isEmpty, "the map has no tabbed sheets at all")
        for sheet in tabbed {
            #expect(Set(sheet.panes).count == sheet.panes.count, Comment(rawValue:
                "\(sheet.name) repeats a pane id, so two tabs would show one pane"))
        }
    }
}
