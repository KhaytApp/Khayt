import Testing
import Foundation
@testable import KhaytApp

/// Grouping was only in the toolbar, and a shop looking to group prints
/// right-clicks them. These hold the right-click menu to offering it, and the
/// action to filing what was clicked.
@MainActor
struct GroupFromRightClickTests {

    @Test("the model's right-click menu offers Group, New Group and Remove")
    func menuOffersGroup() throws {
        let src = try String(contentsOf: Self.source("FileActions.swift"), encoding: .utf8)
        let body = try #require(src.range(of: "struct ModelActions")).upperBound
        let menu = String(src[body...])
        #expect(menu.contains("\"mac.group\""))
        #expect(menu.contains("\"mac.new_group\""))
        #expect(menu.contains("\"mac.remove_from_group\""))
        #expect(menu.contains("fileSelection(under:"))
    }

    @Test("right-clicking a model outside the selection groups that model alone")
    func outsideTheSelection() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let files = shop.shownFiles
        try #require(files.count >= 2)
        shop.select(files[0], modifiers: .replace)
        // What the menu does for a model that is not selected.
        if !shop.fileSelection.contains(files[1].id) { shop.select(files[1], modifiers: .replace) }
        #expect(shop.fileSelection == [files[1].id])
    }

    @Test("New Group from the right-click opens the toolbar's naming popover")
    func newGroupOpensNaming() throws {
        let src = try String(contentsOf: Self.source("GroupMenu.swift"), encoding: .utf8)
        #expect(src.contains("$shop.namingGroup"))
    }

    @Test("the default layout shows Group, Category and Source above the library")
    func defaultShellHasTheMenus() throws {
        // The new shell has no window toolbar; these lived only in it.
        let src = try String(contentsOf: Self.source("ScreenActions.swift"), encoding: .utf8)
        for menu in ["GroupMenu(shop: shop)", "CategoryMenu(shop: shop)", "ProvenanceMenu(shop: shop)"] {
            #expect(src.contains(menu), "\(menu) is missing from the new shell's strip")
        }
    }

    static func source(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/KhaytApp/\(name)")
    }
}
