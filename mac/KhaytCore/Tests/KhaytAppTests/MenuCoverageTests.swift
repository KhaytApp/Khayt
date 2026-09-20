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

    /// The way out of a library folder.
    ///
    /// Tapping a folder put the whole grid inside it and left NOTHING on screen
    /// to get out again: the routes were the sidebar's Library row and the Go
    /// menu, neither of which is where somebody who has just tapped a folder is
    /// looking.
    ///
    /// It cannot live in the filter bar, which draws nothing when there are no
    /// chips — so a group with one category and no tags, the plainest folder
    /// there is, would have had no way back at all.
    @Test("a library folder has a way back out of it")
    func libraryGroupHasAWayBack() {
        let grid = Self.source("LibraryGrid.swift")
        #expect(!grid.isEmpty, "LibraryGrid.swift moved")
        #expect(grid.contains("GroupCrumb(shop: shop, group: group)"),
                "nothing on screen leaves a library folder")
        // ONE LEVEL UP, which at the top IS out — `above.last?.path` is nil
        // there. This used to pin the literal `.library(nil)`, and a folder
        // three deep that jumped straight to the top on ⌘[ would have passed
        // it while being the wrong behaviour. What matters is that the button
        // goes somewhere, and that somewhere is computed from where you are.
        #expect(grid.contains("shop.shelf = .library(above.last?.path)"),
                "the way back does not go anywhere")
        #expect(grid.contains("ForEach(above.dropLast()"), Comment(rawValue:
            "a project several levels deep offers no way to the middle of it — only "
            + "back one step at a time or out altogether"))
        // Drawn above the filter bar, which renders nothing without chips.
        let crumbAt = grid.range(of: "GroupCrumb(shop: shop")?.lowerBound
        let barAt = grid.range(of: "LibraryFilterBar(shop: shop)")?.lowerBound
        #expect(crumbAt != nil && barAt != nil && crumbAt! < barAt!,
                "the way back sits below a bar that can draw nothing")
        // ⌘[ is what every other Mac app uses to go back.
        #expect(grid.contains("keyboardShortcut(\"[\", modifiers: .command)"),
                "there is no keyboard route back")
    }

    @Test("the back shortcut does not collide with another command")
    func backShortcutIsItsOwn() {
        // ⌘[ belongs to the library crumb. Nothing in the menu bar may claim it
        // — a shortcut that does two things depending on focus is one nobody
        // trusts.
        let menus = Self.menus
        #expect(!menus.contains("keyboardShortcut(\"[\""),
                "the menu bar has taken ⌘[ as well")
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

    /// Every sheet the window can present has something that presents it.
    ///
    /// `addingSpool` was declared on `Shop`, bound to `SpoolSheet(existing:
    /// nil)`, and set back to false after a save. Nothing in the whole app
    /// ever set it to TRUE — so the sheet's new-spool half, its catalogue
    /// lookup, and `saveSpool(id: nil)` (which has its own passing test) were
    /// all unreachable, and a shop could correct a spool on the Mac but never
    /// add one. Nothing failed, because every piece was individually right.
    ///
    /// Read as source for the reason the rest of this file is: a `View` body
    /// cannot be instantiated and asked which sheets it offers.
    @Test("a sheet nothing can open is not a sheet")
    func everyPresentedSheetHasAWayIn() {
        let app = Self.source("ShopWindow.swift")
        // `.sheet(isPresented: $shop.NAME)` — the one-way flags. A `sheet(item:)`
        // is presented by assigning the item itself, so it cannot be dead this
        // way, and a Toggle or Picker bound to `$shop.NAME` sets it through the
        // binding.
        let pattern = #/\.sheet\(isPresented: \$shop\.([a-zA-Z]+)\)/#
        let presented = app.matches(of: pattern).map { String($0.1) }
        #expect(presented.count > 5, "only \(presented.count) sheets found — the parse is wrong")

        // Everything the app is, in one string, so a setter anywhere counts.
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir,
                     includingPropertiesForKeys: nil)) ?? []
        let everything = files.filter { $0.pathExtension == "swift" }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        let dead = presented.filter { !everything.contains("\($0) = true") }
        #expect(dead.isEmpty,
                Comment(rawValue: "presented but never opened: \(dead.joined(separator: ", "))"))
    }
}
