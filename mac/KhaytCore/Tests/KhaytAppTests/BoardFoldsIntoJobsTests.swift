import Foundation
import Testing
@testable import KhaytApp

/// Board is a view of Jobs, not a screen of its own.
///
/// The sidebar lost its Board row and Jobs gained a Board / List switch. Every
/// older way to the Board has to land in the same place: the Board menu
/// command, a `khayt://…?screen=board` link, ⌘K, a window restored from the
/// old "board" shelf.
@MainActor
struct BoardFoldsIntoJobsTests {

    static func source(_ name: String) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp/\(name)")
        return (try? ShopSources.read(url)) ?? ""
    }

    @Test("a board deep link lands on Jobs with the Board view selected")
    func deepLink() async throws {
        let shop = Shop()
        await shop.load(.sample)
        shop.shelf = .dashboard
        #expect(shop.follow(.screen("board")))
        #expect(shop.shelf == .jobs(nil))
        #expect(shop.jobsLayout == .board)
        #expect(shop.showingBoard)
    }

    @Test("the Board menu command lands on Jobs with the Board view selected")
    func menuCommand() async throws {
        // The command is `shop.shelf = .board`; assert both that it still is,
        // and what that assignment does.
        #expect(Self.source("Menus.swift").contains("{ shop.shelf = .board }"),
                "the Board command no longer routes through .board — update this test")
        let shop = Shop()
        await shop.load(.sample)
        shop.shelf = .machines
        shop.shelf = .board
        #expect(shop.shelf == .jobs(nil))
        #expect(shop.showingBoard)
    }

    @Test("a window saved on the old Board shelf restores to the Board view of Jobs")
    func restoredWindow() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let restored = try #require(Shelves.shelf("board", in: shop))
        shop.shelf = restored
        #expect(shop.shelf == .jobs(nil))
        #expect(shop.showingBoard)
    }

    @Test("the choice is remembered when you leave Jobs and come back")
    func remembered() async throws {
        let shop = Shop()
        await shop.load(.sample)
        shop.chooseJobsLayout(.board)
        shop.shelf = .customers
        #expect(!shop.showingBoard)
        shop.shelf = .jobs(nil)
        #expect(shop.showingBoard, "Jobs forgot the view it was left in")
        shop.chooseJobsLayout(.list)
        #expect(!shop.showingBoard)
        #expect(shop.shelf == .jobs(nil))
    }

    @Test("a single stage is always the table, and Board from there clears the stage")
    func stageIsATable() async throws {
        let shop = Shop()
        await shop.load(.sample)
        shop.chooseJobsLayout(.board)
        shop.shelf = .jobs(.printing)
        #expect(!shop.showingBoard, "a board filtered to one stage is a table")
        shop.chooseJobsLayout(.board)
        #expect(shop.shelf == .jobs(nil))
        #expect(shop.showingBoard)
    }

    @Test("the sidebar has no Board row and still reaches every screen")
    func sidebarList() {
        let sidebar = Self.source("Sidebar.swift")
        #expect(!sidebar.contains("mac.board"), "Board is a row in the sidebar again")
        #expect(!sidebar.contains(".tag(Shop.Shelf.board)"))
        // Every screen the app has is a tagged row somewhere in the sidebar.
        for tag in [".dashboard", ".jobs(nil)", ".library(nil)", ".catalogue", ".customers",
                    ".machines", ".inventory", ".expenses", ".reports", ".calculator",
                    ".waste", ".portfolio", ".giftCards", ".colour"] {
            #expect(sidebar.contains(".tag(Shop.Shelf\(tag))"), Comment(rawValue: "no sidebar row for \(tag)"))
        }
        // Waste, the portfolio, gift cards and the colour studio live in More.
        let more = sidebar.range(of: "DisclosureGroup")
        #expect(more != nil)
        if let more {
            let tail = String(sidebar[more.lowerBound...])
            for tag in [".waste", ".portfolio", ".giftCards", ".colour"] {
                #expect(tail.contains(".tag(Shop.Shelf\(tag))"), Comment(rawValue: "\(tag) is not under More"))
            }
        }
    }
}
