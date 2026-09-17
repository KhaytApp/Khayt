import Foundation
import Testing
@testable import KhaytApp

/// The menu bar, checked against the app rather than against itself.
///
/// "Use the menu bar to give people easy access to all the commands they need
/// to do things in your app" — and three screens the sidebar had always shown
/// were not in it at all, so the only way to reach Expenses, Waste or Reports
/// was to click a row. A screen with no menu route has no keyboard route
/// either, and nothing failed: the sidebar worked, so nobody looked.
///
/// Read as source, because a `Commands` builder cannot be instantiated and
/// asked what is in it.
@MainActor
struct MenuCoverageTests {

    static var menus: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp/Menus.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Every destination the sidebar offers, as the enum spells it.
    static let shelves = ["dashboard", "board", "machines", "inventory",
                          "catalogue", "expenses", "waste", "reports", "customers"]

    /// One of the app's own source files, by name.
    static func source(_ name: String) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp/\(name)")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Where a job can be sent, offered wherever a job is.
    ///
    /// Moving a job along is the thing a shop does most, and it was the one
    /// thing only the MENU BAR could do. The right-click menu on the orders
    /// table had edit, payment, hold, delivered and invoice — and no stages —
    /// so changing a status meant selecting the row and going up to the menu
    /// bar for a decision already made about the row under the pointer. A card
    /// on the board was worse: no context menu at all, so a stage change was a
    /// drag across as many as six columns.
    @Test("a job can be moved from the menu bar, the table and the board")
    func everyPlaceOffersTheStages() {
        let menus = Self.menus
        let table = Self.source("OrdersTable.swift")
        let board = Self.source("Kanban.swift")
        #expect(!menus.isEmpty && !table.isEmpty && !board.isEmpty, "a source file moved")

        // The menu bar, as before.
        #expect(menus.contains("ForEach(Stage.destinations)"))
        // The orders table's right-click menu.
        #expect(table.contains("ForEach(Stage.destinations)"),
                "the right-click menu offers no stages; a status change still needs the menu bar")
        // A card on the board, which had no context menu at all.
        #expect(board.contains("JobActions(shop: shop, job: job)"),
                "a board card cannot be right-clicked, so a move is still a drag")
    }

    /// The list itself, in one place.
    ///
    /// Three menus offering three lists is three chances for which menu you
    /// opened to decide where a job may go.
    @Test("the stages a job can be sent to are written down once")
    func oneListOfDestinations() {
        let order = Self.source("Order.swift")
        #expect(order.contains("static let destinations: [Stage] ="),
                "the shared list has moved out of Stage")
        for name in ["Menus.swift", "OrdersTable.swift", "Kanban.swift"] {
            let text = Self.source(name)
            #expect(!text.contains("[.quote, .pending, .printing, .post, .qc, .completed]"),
                    "\(name) has grown its own copy of the destinations")
        }
    }

    /// The move must leave the same record whichever menu started it.
    @Test("every route asks the same two questions before moving a job")
    func everyRouteAsksTheRules() {
        for name in ["Menus.swift", "OrdersTable.swift"] {
            let text = Self.source(name)
            #expect(text.contains("shop.questionFor("),
                    "\(name) moves a job without asking whether the move needs a question first")
            #expect(text.contains("shop.moveJob("),
                    "\(name) does not go through moveJob")
        }
    }

    @Test("every screen in the sidebar can be reached from the menu bar")
    func everyShelfIsInTheGoMenu() {
        let text = Self.menus
        #expect(!text.isEmpty, "Menus.swift moved")
        for shelf in Self.shelves {
            #expect(text.contains("shop.shelf = .\(shelf)"),
                    "the Go menu has no way to reach .\(shelf)")
        }
        // The two that take an argument.
        #expect(text.contains("shop.shelf = .jobs(nil)"))
        #expect(text.contains("shop.shelf = .library(nil)"))
    }

    /// Two commands on one key is not a conflict anybody is told about: one of
    /// them silently stops working, and which one is undefined.
    @Test("no two commands claim the same key")
    func shortcutsAreUnique() {
        var seen: [String: Int] = [:]
        let text = Self.menus
        for line in text.split(separator: "\n") {
            guard let at = line.range(of: ".keyboardShortcut(") else { continue }
            let call = String(line[at.upperBound...])
            guard let quote = call.firstIndex(of: "\"") else {
                // `.cancelAction` / `.defaultAction` — the system's, not ours.
                continue
            }
            let rest = call[call.index(after: quote)...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            let key = String(rest[..<end])
            let mods = call.contains("modifiers:")
                ? String(call[call.range(of: "modifiers:")!.upperBound...].prefix(30))
                : "command"
            let normalised = mods
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                .split(separator: ")").first.map(String.init) ?? mods
            seen["\(key)+\(normalised)", default: 0] += 1
        }
        let clashes = seen.filter { $0.value > 1 }.keys.sorted()
        #expect(clashes.isEmpty, "two menu items share: \(clashes.joined(separator: ", "))")
        #expect(seen.count > 12, "only \(seen.count) shortcuts found — the parse is wrong")
    }

    /// The two Finder gestures a file library is expected to answer.
    @Test("a print file can be looked at without opening a slicer")
    func quickLookIsReachable() {
        #expect(Self.menus.contains("quickLookSelection"), "no Quick Look in the Model menu")
        let grid = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp/LibraryGrid.swift")
        let text = (try? String(contentsOf: grid, encoding: .utf8)) ?? ""
        #expect(text.contains(".onKeyPress(.space)"), "Space does nothing in the library")
    }

    /// A toolbar search field that only the mouse can reach is a search field
    /// in the wrong app.
    @Test("the search field can be reached from the keyboard")
    func findIsWired() {
        #expect(Self.menus.contains("searchWanted"))
        let window = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp/ShopWindow.swift")
        let text = (try? String(contentsOf: window, encoding: .utf8)) ?? ""
        #expect(text.contains("focusedSceneValue(\\.searchWanted"),
                "the window publishes nothing for ⌘F to act on")
        #expect(text.contains("focusSearchWhenAsked"))
    }
}
