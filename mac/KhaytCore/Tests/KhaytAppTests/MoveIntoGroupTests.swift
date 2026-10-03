import Foundation
import Testing
import SwiftUI
import AppKit
import KhaytCore
@testable import KhaytApp

/// "Move into Group…": several groups under one parent in one write, and
/// renaming a group through the same write.
///
/// The shop's real case: an old import filed "pose 1", "pose 2" and "tete
/// multipart" as top-level groups when they are sub-folders of "Baby
/// Grendizer". Each move is driven here exactly as `Shop.moveGroups` writes
/// it — the plan's targets, `moveRecord`, `groupMoveRoot` — through the same
/// `applyFileEdit` whose result is the ONE Undo the shop gets.
@MainActor
struct MoveIntoGroupTests {

    /// A book with `count` files in each group, ids `<group>#<n>`.
    static func book(_ groups: [String: Int], kinds: [String: String] = [:]) -> [String: JSONValue] {
        var rows: [JSONValue] = []
        for (group, count) in groups.sorted(by: { $0.key < $1.key }) {
            for n in 1...count {
                rows.append(.object(["id": .string("\(group)#\(n)"),
                                     "group": .string(group), "folder": .string(group)]))
            }
        }
        var settings: [String: JSONValue] = ["currency": .string("SAR")]
        if !kinds.isEmpty {
            settings["libraryGroups"] = .object(kinds.mapValues { .object(["kind": .string($0)]) })
        }
        return ["settings": .object(settings), "printFiles": .array(rows)]
    }

    static func files(_ root: [String: JSONValue]) -> [(id: String, group: String?)] {
        GroupsReadClearlyTests.files(root)
    }

    static func groupOf(_ root: [String: JSONValue], _ id: String) -> String? {
        files(root).first { $0.id == id }?.group
    }

    /// `Shop.moveGroups`' / `renameGroup`'s write, on a book in memory.
    static func apply(_ plan: GroupMovePlan, newKinds: [String: GroupKind] = [:],
                      to root: inout [String: JSONValue]) -> Shop.LibraryUndo {
        let wanted = plan.wanted
        return Shop.applyFileEdit(&root, ids: plan.ids,
                                  alsoRoot: Shop.groupMoveRoot(plan, newKinds: newKinds)) { record in
            Shop.moveRecord(&record, wanted: wanted)
        }
    }

    @Test("three groups go under a new parent, keeping their names, kinds and depth; one Undo puts them all back")
    func threeUnderANewParent() {
        var root = Self.book(["pose 1": 2, "pose 2": 1, "pose 2/left": 1, "tete multipart": 3, "Other": 1],
                             kinds: ["pose 1": "collection", "tete multipart": "parts",
                                     "pose 2/left": "collection", "Other": "collection"])
        let before = root
        let plan = Shop.planGroupMove(["pose 1", "pose 2", "tete multipart"], under: "Baby Grendizer",
                                      files: Self.files(root))
        #expect(plan.canMove)
        #expect(plan.moves.map(\.to).sorted()
                == ["Baby Grendizer/pose 1", "Baby Grendizer/pose 2", "Baby Grendizer/tete multipart"])
        #expect(plan.moves.allSatisfy { !$0.joins })
        #expect(plan.ids.count == 7)

        let kinds: [String: GroupKind] = Shop.kindForFiling(.parts, into: "Baby Grendizer",
                                                            existing: Self.files(root).map(\.group))
        let undo = Self.apply(plan, newKinds: kinds, to: &root)

        #expect(Self.groupOf(root, "pose 1#1") == "Baby Grendizer/pose 1")
        #expect(Self.groupOf(root, "pose 2/left#1") == "Baby Grendizer/pose 2/left", "a sub-folder lost its depth")
        #expect(Self.groupOf(root, "tete multipart#3") == "Baby Grendizer/tete multipart")
        #expect(Self.groupOf(root, "Other#1") == "Other", "a group nobody chose moved")

        // EVERY moved group's kind went with it — not only the first one
        // carried. (Carrying one move at a time pruned the later groups'
        // entries before they could be carried.)
        let after = GroupsReadClearlyTests.kinds(root)
        #expect(after["Baby Grendizer/pose 1"] == .collection)
        #expect(after["Baby Grendizer/tete multipart"] == .parts)
        #expect(after["Baby Grendizer/pose 2/left"] == .collection)
        #expect(after["Baby Grendizer"] == .parts, "the new parent did not get the kind chosen for it")
        #expect(after["pose 1"] == nil && after["tete multipart"] == nil, "a kind was copied, not moved")
        #expect(after["Other"] == .collection)

        // ONE undo, and it is the whole of it.
        #expect(undo.files.count == 7)
        _ = Shop.applyRestore(&root, undo)
        for (id, group) in Self.files(before) { #expect(Self.groupOf(root, id) == group) }
        #expect(GroupsReadClearlyTests.kinds(root) == GroupsReadClearlyTests.kinds(before))
    }

    @Test("a name already taken under the parent: the models join it, it keeps its kind, and the plan says so")
    func joinsAnExistingGroup() {
        var root = Self.book(["Blue": 2, "Grendizer/Blue": 1, "Red": 1],
                             kinds: ["Blue": "parts", "Grendizer/Blue": "collection"])
        let plan = Shop.planGroupMove(["Blue", "Red"], under: "Grendizer", files: Self.files(root))
        #expect(plan.canMove)
        #expect(plan.moves.first { $0.from == "Blue" }?.joins == true, "the merge was not announced")
        #expect(plan.moves.first { $0.from == "Red" }?.joins == false)
        let undo = Self.apply(plan, to: &root)
        #expect(Self.groupOf(root, "Blue#1") == "Grendizer/Blue")
        #expect(Self.groupOf(root, "Grendizer/Blue#1") == "Grendizer/Blue")
        #expect(GroupsReadClearlyTests.kinds(root)["Grendizer/Blue"] == .collection,
                "joining a group re-kinded it")
        #expect(undo.files["Grendizer/Blue#1"] == nil, "a model that was already there was written")
        _ = Shop.applyRestore(&root, undo)
        #expect(Self.groupOf(root, "Blue#2") == "Blue")
        #expect(GroupsReadClearlyTests.kinds(root)["Blue"] == .parts)
    }

    @Test("Undo of a group move is field-level: it puts back the paths, and keeps what was written since")
    func undoIsFieldLevel() throws {
        var root = Self.book(["pose 1": 2, "pose 2": 1], kinds: ["pose 1": "collection"])
        let plan = Shop.planGroupMove(["pose 1", "pose 2"], under: "Baby Grendizer", files: Self.files(root))
        let undo = Self.apply(plan, to: &root)
        // Since the move: another machine renames a moved model, and the shop
        // switches the moved group's kind.
        guard case .array(var rows)? = root["printFiles"] else { Issue.record("no rows"); return }
        for i in rows.indices {
            guard case .object(var r) = rows[i], r["id"] == .string("pose 1#1") else { continue }
            r["name"] = .string("Renamed on the phone")
            rows[i] = .object(r)
        }
        root["printFiles"] = .array(rows)
        GroupKinds.write(["Baby Grendizer/pose 1": .parts], into: &root)

        let redo = Shop.applyRestore(&root, undo)
        #expect(Self.groupOf(root, "pose 1#1") == "pose 1")
        #expect(Self.groupOf(root, "pose 2#1") == "pose 2")
        let renamed = Shop.rows(root, "printFiles").first { row in
            if case .object(let r) = row { return r["id"] == .string("pose 1#1") } else { return false }
        }
        if case .object(let r)? = renamed {
            #expect(r["name"] == .string("Renamed on the phone"), "Undo wrote back a field the move never changed")
        }
        // The group's own kind comes back; the kind the shop set on the moved
        // path since is not overwritten blind — it is reported as not undone.
        #expect(GroupsReadClearlyTests.kinds(root)["pose 1"] == .collection)
        #expect(redo.notUndone.contains("Baby Grendizer/pose 1"), Comment(rawValue: "\(redo.notUndone)"))
    }

    @Test("Move into Group and Move Folder refuse at the same length")
    func oneLimit() {
        let root = Self.book(["eyes": 1])
        for n in [54, 55, 56] {
            let parent = String(repeating: "x", count: n)
            let plan = Shop.planGroupMove(["eyes"], under: parent, files: Self.files(root))
            #expect(plan.canMove == Shop.folderMoveFits(plan.wanted), "the two rules disagree at \(n)")
            #expect(plan.canMove == (n + 5 <= Shop.groupPathLimit))
        }
    }

    @Test("two chosen groups with one name are refused, not mixed")
    func twoChosenWithOneName() {
        let root = Self.book(["Helmet/Blue": 1, "Kit/Blue": 1])
        let plan = Shop.planGroupMove(["Helmet/Blue", "Kit/Blue"], under: "Colours", files: Self.files(root))
        #expect(plan.refusal == .sameName("Blue"))
        #expect(!plan.canMove)
    }

    @Test("a path past 60 characters is refused, by name")
    func sixtyCharacters() {
        let long = "Iron Man Helmet MK 4-6-7 (the complete wearable build)"   // 54
        let root = Self.book(["motorization parts": 1, "eyes": 1])
        let plan = Shop.planGroupMove(["motorization parts", "eyes"], under: long, files: Self.files(root))
        #expect(plan.refusal == .tooLong(long + "/motorization parts"))
        #expect(!plan.canMove)
        // Exactly 60 is fine: the cut is AT 60, not before it.
        let parent = String(repeating: "x", count: 55)
        let fits = Shop.planGroupMove(["eyes"], under: parent, files: Self.files(root))
        #expect(fits.canMove, "\(parent)/eyes is 60 units and was refused")
    }

    @Test("moving into itself is refused; a group inside another chosen one rides along; one already there is skipped")
    func nestingRules() {
        let root = Self.book(["A": 1, "A/B": 1, "C": 1, "D/E": 1])
        let into = Shop.planGroupMove(["A", "C"], under: "A/B", files: Self.files(root))
        #expect(into.refusal == .intoItself("A"))

        let riding = Shop.planGroupMove(["A", "A/B", "C"], under: "D", files: Self.files(root))
        #expect(riding.canMove)
        #expect(riding.riding == ["A/B"])
        #expect(riding.moves.map(\.from).sorted() == ["A", "C"], "A/B was moved twice")
        #expect(riding.wanted["A/B#1"] == "D/A/B")

        let there = Shop.planGroupMove(["D/E", "C"], under: "D", files: Self.files(root))
        #expect(there.alreadyThere == ["D/E"])
        #expect(there.moves.map(\.from) == ["C"])
    }

    @Test("renaming a group moves its subtree and its kinds, flattens a slash, and joins a sibling it names")
    func rename() {
        var root = Self.book(["Helmet/pose 1": 1, "Helmet/pose 1/Blue": 1, "Helmet/pose 2": 1],
                             kinds: ["Helmet/pose 1": "collection"])
        let plan = Shop.planGroupRename("Helmet/pose 1", to: "Pose one", files: Self.files(root))
        #expect(plan.moves.map(\.to) == ["Helmet/Pose one"])
        _ = Self.apply(plan, to: &root)
        #expect(Self.groupOf(root, "Helmet/pose 1/Blue#1") == "Helmet/Pose one/Blue")
        #expect(GroupsReadClearlyTests.kinds(root)["Helmet/Pose one"] == .collection)

        let slashed = Shop.planGroupRename("Helmet/pose 2", to: "Left/Right", files: Self.files(root))
        #expect(slashed.moves.map(\.to) == ["Helmet/Left \u{2013} Right"], "a typed slash made a level")

        let joins = Shop.planGroupRename("Helmet/pose 2", to: "Pose one", files: Self.files(root))
        #expect(joins.moves.first?.joins == true)
        #expect(Shop.planGroupRename("Helmet/pose 2", to: "  ", files: Self.files(root)).refusal == .emptyName)
        #expect(!Shop.planGroupRename("Helmet/pose 2", to: "pose 2", files: Self.files(root)).canMove)
    }

    @Test("a typed parent that matches a group, ignoring case and spaces, IS that group")
    func typedDestination() {
        let known = ["Baby Grendizer", "Grendizer by Santome"]
        #expect(Shop.resolveGroupDestination("baby  grendizer ", known: known) == "Baby Grendizer")
        #expect(Shop.resolveGroupDestination("Iron Man/Helmet", known: known) == "Iron Man \u{2013} Helmet")
        #expect(Shop.resolveGroupDestination("New One", known: known) == "New One")
    }

    // MARK: Selection

    static func shop() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        let row = LibrarySelectionVisibleTests.row
        shop.pretendLibrary([row("PF-p1", "pose a", "pose 1"), row("PF-p2", "pose b", "pose 2"),
                             row("PF-t", "tete", "tete multipart"), row("PF-loose", "loose", nil)])
        shop.libraryShowArchived = false
        shop.clearLibraryFilter()
        shop.search = ""
        shop.librarySort = .name
        shop.shelf = .library(nil)
        shop.libraryFlat = false
        return shop
    }

    @Test("⌘- and ⇧-click choose group tiles; a chosen group is not its models")
    func choosing() async {
        let shop = await Self.shop()
        #expect(shop.visibleGroupPaths == ["pose 1", "pose 2", "tete multipart"])
        shop.selectGroup("pose 1", modifiers: .toggle)
        shop.selectGroup("tete multipart", modifiers: .extend)
        #expect(shop.selectedGroups == ["pose 1", "pose 2", "tete multipart"])
        #expect(shop.selectedIds.isEmpty, "choosing a group tile selected the models hidden in it")
        #expect(shop.groupsActedOn(from: "pose 2") == ["pose 1", "pose 2", "tete multipart"])
        shop.selectGroup("pose 2", modifiers: .toggle)
        #expect(shop.groupsActedOn(from: "pose 2") == ["pose 2"], "an unchosen tile acted on the selection")

        // One kind of selection at a time.
        let loose = shop.visibleFiles.first { $0.id == "PF-loose" }!
        shop.select(loose, modifiers: .toggle)
        #expect(shop.groupSelection.isEmpty, "a model and groups were chosen together")
        shop.selectGroup("pose 1", modifiers: .toggle)
        #expect(shop.fileSelection.isEmpty)
    }

    @Test("the group selection holds only tiles on screen")
    func pruning() async {
        let shop = await Self.shop()
        shop.selectGroup("pose 1", modifiers: .toggle)
        shop.selectGroup("tete multipart", modifiers: .toggle)
        shop.search = "tete"                 // pose 1 is no longer drawn
        #expect(shop.groupSelection == ["tete multipart"])
        shop.search = ""
        shop.libraryFlat = true              // All models: no kinds → parts tiles stay
        #expect(shop.groupSelection == Set(shop.visibleGroupPaths).intersection(["tete multipart"]))
        shop.libraryFlat = false
        shop.selectGroup("pose 2", modifiers: .toggle)
        shop.shelf = .library("pose 2")      // opening a group: another view, nothing carried
        #expect(shop.groupSelection.isEmpty)
    }

    @Test("the tile, the strip and the window are wired to it")
    func wired() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        func read(_ name: String) throws -> String {
            try String(contentsOf: src.appending(path: name), encoding: .utf8)
        }
        let grid = try read("LibraryGrid.swift")
        #expect(grid.contains("GroupTileActions(shop: shop, path: path)"))
        #expect(grid.contains("shop.selectGroup(path, modifiers: .toggle)"))
        #expect(try read("GroupMenu.swift").contains("GroupTileActions(shop: shop, path: chosenGroups[0])"))
        #expect(try read("ShopWindow.swift").contains("GroupMoveSheet(shop: shop, request: $0)"))
        // ONE write, through the path every library edit takes (and so one Undo).
        let move = try read("LibraryGroupMove.swift")
        #expect(move.contains("alsoRoot: Self.groupMoveRoot(plan, newKinds: newKinds)) { record in"))
        #expect(move.contains("Self.moveRecord(&record, wanted: wanted)"))
        #expect(move.components(separatedBy: "editFiles(").count == 2, "more than one write per move")
    }
}

/// The Groups view with chosen group tiles, and the confirmation, photographed
/// in whatever language `KHAYT_LANG` asks for. Writes only when
/// KHAYT_SNAPSHOT_DIR is set, like `SnapshotTests`.
@Suite(.serialized) @MainActor
struct MoveIntoGroupSnapshotTests {

    private var lang: String { ProcessInfo.processInfo.environment["KHAYT_LANG"] ?? "en" }

    /// A sheet, photographed in a real window rather than by `ImageRenderer`,
    /// which draws a text field and a pop-up as a "no entry" placeholder.
    private func hosted(_ view: some View, _ name: String, _ size: CGSize, dark: Bool = false) {
        guard let dir = SnapshotTests.outputDir else { return }
        let rtl = Direction.rtlLanguages.contains(Direction.shopLanguage())
        let host = NSHostingView(rootView: view
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            .environment(\.photographFlat, true)
            .frame(width: size.width, height: size.height)
            .background(Khayt.surface))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: dir.appending(path: name + ".png"))
    }

    static func shop() async -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        let row = LibrarySelectionVisibleTests.row
        var rows: [JSONValue] = []
        for (group, n) in [("Baby Grendizer", 3), ("pose 1", 2), ("pose 2", 2), ("tete multipart", 4),
                           ("Grendizer by Santome", 5), ("Blue", 1), ("Red", 1),
                           ("Iron Man Helmet MK 4-6-7", 6), ("eyes", 2)] {
            for i in 1...n { rows.append(row("PF-\(group)-\(i)", "\(group) \(i)", group)) }
        }
        rows.append(row("PF-Baby-pose-2", "pose 2 extra", "Baby Grendizer/pose 2"))
        shop.pretendLibrary(rows)
        shop.libraryShowArchived = false
        shop.clearLibraryFilter()
        shop.search = ""
        shop.librarySort = .name
        shop.shelf = .library(nil)
        shop.libraryFlat = false
        return shop
    }

    @Test("the Groups view with three group tiles chosen, and the move confirmation")
    func pictures() async throws {
        let shop = await Self.shop()
        for p in ["pose 1", "pose 2", "tete multipart"] { shop.selectGroup(p, modifiers: .toggle) }
        let s = SnapshotTests()
        // The grid's own tiles, as the grid draws them (a LazyVGrid inside a
        // ScrollView photographs blank, so the rows are laid out here).
        let entries = shop.shownEntries
        let tiles = VStack(alignment: .leading, spacing: 12) {
            Label(shop.words.callIt("mac.group_n_groups",
                                    ["groups": .string(shop.words.counting(shop.selectedGroups.count, "mac.n_groups"))]),
                  systemImage: "square.stack")
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.primary.opacity(0.08), in: Capsule())
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                ForEach(Array(stride(from: 0, to: entries.count, by: 5)), id: \.self) { start in
                    GridRow {
                        ForEach(entries[start..<min(start + 5, entries.count)]) { entry in
                            if case .folder(let name, let path, let count, _) = entry {
                                FolderCell(name: name, count: count, thumbnail: nil, words: shop.words,
                                           kind: shop.groupKind(path),
                                           selected: shop.groupSelection.contains(path))
                                    .frame(width: 150)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Khayt.ground)
        try s.render(tiles, "d2-groups-selected-\(lang)", size: CGSize(width: 830, height: 520))
        try s.renderDark(tiles, "d2-groups-selected-\(lang)-dark", size: CGSize(width: 830, height: 520))

        let request = GroupMoveRequest(paths: shop.selectedGroups, renaming: false)
        let size = CGSize(width: SheetMetrics.outerWidth(GroupMoveSheet.width), height: 400)
        hosted(GroupMoveSheet(shop: shop, request: request, typed: "baby grendizer"),
               "d2-move-sheet-\(lang)", size)
        hosted(GroupMoveSheet(shop: shop, request: request, typed: "baby grendizer"),
               "d2-move-sheet-\(lang)-dark", size, dark: true)
        hosted(GroupMoveSheet(shop: shop, request: GroupMoveRequest(paths: ["pose 1", "Blue"], renaming: false),
                              typed: String(repeating: "Grendizer ", count: 6)),
               "d2-move-sheet-refused-\(lang)", CGSize(width: size.width, height: 420))
        hosted(GroupMoveSheet(shop: shop, request: GroupMoveRequest(paths: ["Baby Grendizer"], renaming: true),
                              typed: "Baby Grendizer (complete)"),
               "d2-rename-sheet-\(lang)", CGSize(width: size.width, height: 300))
    }
}
