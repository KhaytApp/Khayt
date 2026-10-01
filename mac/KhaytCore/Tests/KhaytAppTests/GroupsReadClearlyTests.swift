import Foundation
import Testing
import SwiftUI
import KhaytCore
@testable import KhaytApp

/// Groups that read as groups.
///
/// ── WHAT WAS REPORTED ─────────────────────────────────────────────────────
///
/// *"I created a group, but one group is now one file and the group I created
/// still appears as single models in All models and a group under Groups."*
///
/// The book said why. The shop typed "Luffy Card/Poster"; a group is a PATH,
/// so that became a folder "Luffy Card" holding a folder "Poster" holding one
/// model. In Groups the folder tile was the same shape as a model with a
/// 12-point glyph, so it read as one model; in "All models" every model is drawn
/// flat and nothing said which were grouped.
@MainActor
struct GroupsReadClearlyTests {

    // MARK: A typed slash is not a level

    @Test("a slash typed into the group name is flattened, not nested")
    func slashFlattened() {
        #expect(TypedGroupName.flatten("Luffy Card/Poster") == "Luffy Card \u{2013} Poster")
        #expect(TypedGroupName.flatten("  Luffy Card / Poster  ") == "Luffy Card \u{2013} Poster")
        #expect(TypedGroupName.flatten("Luffy\\Poster") == "Luffy \u{2013} Poster")
        #expect(TypedGroupName.flatten("/Kings//Saud/") == "Kings \u{2013} Saud")
        #expect(!TypedGroupName.flatten("a/b/c").contains(ImportGrouping.separator))
    }

    @Test("a name with no slash is only trimmed, and a hyphen is left alone")
    func plainNamesUntouched() {
        #expect(TypedGroupName.flatten("  Saudi Kings ") == "Saudi Kings")
        #expect(TypedGroupName.flatten("T-Rex") == "T-Rex")
        #expect(TypedGroupName.flatten("") == "")
        #expect(TypedGroupName.flatten(" / ") == "")
    }

    @Test("typing an existing group's path keeps it — that is choosing a folder")
    func existingPathKept() {
        let known = ["MyProject", "MyProject/pose 1"]
        #expect(TypedGroupName.flatten("myproject/Pose 1", known: known) == "MyProject/pose 1")
        #expect(TypedGroupName.flatten("MyProject/pose 9", known: known) == "MyProject \u{2013} pose 9")
    }

    @Test("the naming popover files under the flattened name")
    func popoverFlattens() throws {
        let src = try String(contentsOf: GroupFromRightClickTests.source("GroupMenu.swift"), encoding: .utf8)
        #expect(src.contains("TypedGroupName.flatten(name, known: shop.groups)"))
        #expect(src.contains("\"mac.group_slash_flattened\""),
                "the popover does not say the name will change before it does")
    }

    @Test("a flattened name files ONE group, not a folder in a folder")
    func flattenedIsOneLevel() {
        let name = TypedGroupName.flatten("Luffy Card/Poster")
        let files = [LibraryNestingTests.file("a", group: name),
                     LibraryNestingTests.file("b", group: name)]
        let top = LibraryEntry.top(of: files, order: LibraryNestingTests.order)
        #expect(LibraryNestingTests.names(top) == ["Luffy Card \u{2013} Poster/ (2)"])
    }

    // MARK: All models says which models are grouped

    @Test("a matched model names its group, and not inside that group")
    func cellNamesGroup() {
        let grouped = LibraryNestingTests.file("a", group: "Luffy Card")
        let loose = LibraryNestingTests.file("b", group: nil)
        #expect(Cell.groupShown(for: grouped, shelf: .library(nil)) == "Luffy Card")
        #expect(Cell.groupShown(for: loose, shelf: .library(nil)) == nil)
        #expect(Cell.groupShown(for: grouped, shelf: .library("Luffy Card")) == nil)
        // A level above still says which level it is in.
        let deep = LibraryNestingTests.file("c", group: "MyProject/pose 1")
        #expect(Cell.groupShown(for: deep, shelf: .library("MyProject")) == "MyProject/pose 1")
        #expect(Shop.groupLeaf("MyProject/pose 1") == "pose 1")
        #expect(Shop.groupLeaf("Luffy Card") == "Luffy Card")
    }

    @Test("the grid hands each tile its group and a way to open it")
    func gridWiresGroupLabel() throws {
        let src = try String(contentsOf: GroupFromRightClickTests.source("LibraryGrid.swift"), encoding: .utf8)
        #expect(src.contains("group: Cell.groupShown(for: file, shelf: shop.shelf)"))
        #expect(src.contains("openGroup: { shop.showGroup($0) }"))
    }

    @Test("opening a group from a tile's label ends the search and filters, so the group shows whole")
    func showGroupOpens() {
        let shop = Shop()
        shop.search = "luffy"
        shop.libraryNeverPrintedOnly = true
        shop.groupNote = .init(text: "x", path: "Luffy Card")
        #expect(shop.libraryShowsMatches)
        shop.showGroup("Luffy Card")
        #expect(shop.shelf == .library("Luffy Card"))
        #expect(shop.search.isEmpty)
        #expect(!shop.libraryFilterOn)
        #expect(shop.groupNote == nil)
    }

    // MARK: All models: a print in parts is one tile, a collection is models

    static func f(_ id: String, _ group: String?) -> LibraryFile { LibraryNestingTests.file(id, group: group) }

    /// In the order the grid draws them (newest first, say).
    static let library = [
        f("king-1", "Saudi Kings"),                   // collection
        f("luffy-card", "Luffy Card"),                // parts, said so
        f("loose-1", nil),
        f("grendizer-head", "Baby Grendizer"),        // no kind written: parts
        f("king-2", "Saudi Kings"),
        f("luffy-stand", "Luffy Card"),
        f("x-alone", "Collection X"),                 // a model of collection X
        f("x-set-a-1", "Collection X/Set A"),         // parts inside a collection
        f("grendizer-arm", "Baby Grendizer"),
        f("x-set-a-2", "Collection X/Set A/Blue"),    // a colour level of Set A
        f("pose-blue", "Pose/Blue"),                  // Pose is parts: Blue folds in
        f("loose-2", nil),
    ]
    static let kinds: [String: GroupKind] = [
        "Saudi Kings": .collection,
        "Luffy Card": .parts,
        "Collection X": .collection,
        "Pose/Blue": .collection,                     // never reached: Pose is parts first
    ]

    static func names(_ entries: [LibraryEntry]) -> [String] {
        entries.map { entry in
            switch entry {
            case .folder(let name, let path, let count, _): return "[\(name) @\(path) ×\(count)]"
            case .file(let file): return file.id
            }
        }
    }

    @Test("All models: parts groups fold to one tile where their first model stood; collections stay models")
    func allModelsRule() {
        let got = Self.names(LibraryEntry.allModels(of: Self.library, kinds: Self.kinds,
                                                    order: LibraryNestingTests.order))
        #expect(got == [
            "king-1",
            "[Luffy Card @Luffy Card ×2]",
            "loose-1",
            "[Baby Grendizer @Baby Grendizer ×2]",
            "king-2",
            "x-alone",
            "[Set A @Collection X/Set A ×2]",
            "[Pose @Pose ×1]",
            "loose-2",
        ], Comment(rawValue: got.joined(separator: "\n")))
    }

    @Test("a group with no kind written is parts — the one default")
    func missingKindIsParts() {
        #expect(GroupKind.assumed == .parts)
        #expect(GroupKinds.kind(of: "Never Said", in: [:]) == .parts)
        #expect(LibraryEntry.partsGroup(of: "Baby Grendizer", kinds: [:]) == "Baby Grendizer")
        #expect(LibraryEntry.partsGroup(of: "Saudi Kings", kinds: Self.kinds) == nil)
        #expect(LibraryEntry.partsGroup(of: "Collection X/Set A/Blue", kinds: Self.kinds) == "Collection X/Set A")
        #expect(LibraryEntry.partsGroup(of: nil, kinds: Self.kinds) == nil)
    }

    @Test("a collection of collections shows every model")
    func allCollections() {
        let kinds: [String: GroupKind] = ["A": .collection, "A/B": .collection]
        let files = [Self.f("1", "A"), Self.f("2", "A/B"), Self.f("3", nil)]
        #expect(Self.names(LibraryEntry.allModels(of: files, kinds: kinds,
                                                  order: LibraryNestingTests.order)) == ["1", "2", "3"])
    }

    @Test("one function decides the tiles: All models, a search in it, Groups, and inside a folder")
    func entryBuilder() {
        let o = LibraryNestingTests.order
        let all = Shop.libraryEntries(Self.library, under: nil, flat: true, showingMatches: false,
                                      kinds: Self.kinds, order: o)
        #expect(Self.names(all) == Self.names(LibraryEntry.allModels(of: Self.library, kinds: Self.kinds, order: o)))
        // Searching or filtering in All models: every match flat, parts too.
        let matches = Shop.libraryEntries(Self.library, under: nil, flat: true, showingMatches: true,
                                          kinds: Self.kinds, order: o)
        #expect(Self.names(matches) == Self.library.map(\.id))
        // Groups: unchanged, every group a tile whatever its kind.
        let groups = Shop.libraryEntries(Self.library, under: nil, flat: false, showingMatches: false,
                                         kinds: Self.kinds, order: o)
        #expect(Self.names(groups) == Self.names(LibraryEntry.top(of: Self.library, order: o)))
        #expect(groups.contains { if case .folder(_, "Saudi Kings", _, _) = $0 { true } else { false } })
        // Inside a folder, either view: that folder's levels.
        for flat in [true, false] {
            let inside = Shop.libraryEntries(Self.library, under: "Collection X", flat: flat,
                                             showingMatches: false, kinds: Self.kinds, order: o)
            #expect(Self.names(inside) == ["[Set A @Collection X/Set A ×2]", "x-alone"])
        }
    }

    @Test("a search or filter is what flattens All models, and blank space is not a search")
    func showsMatches() {
        let shop = Shop()
        #expect(shop.libraryFlat, "All models is no longer the default")
        #expect(!shop.libraryShowsMatches)
        shop.search = "  "
        #expect(!shop.libraryShowsMatches)
        shop.search = "luffy"
        #expect(shop.libraryShowsMatches)
        shop.search = ""
        shop.libraryCategory = .named("Busts")
        #expect(shop.libraryShowsMatches)
        shop.clearLibraryFilter()
        #expect(!shop.libraryShowsMatches)
        let src = MenuCoverageTests.source("Shop.swift")
        #expect(src.contains("return Self.libraryEntries(shownFiles, under: group, flat: libraryFlat,"))
    }

    // MARK: Where the kind is kept

    static func book(_ groups: JSONValue?) -> [String: JSONValue] {
        var settings: [String: JSONValue] = ["currency": .string("SAR"), "vatRate": .string("15")]
        if let groups { settings["libraryGroups"] = groups }
        return ["settings": .object(settings), "printFiles": .array([])]
    }

    @Test("a kind is written to settings.libraryGroups, keeping everything else as the book spells it")
    func writesKind() {
        var root = Self.book(.object([
            "Saudi Kings": .object(["kind": .string("collection"), "cover": .string("k1")]),
            "Luffy Card": .object(["kind": .string("parts"), "note": .string("kept")]),
        ]))
        GroupKinds.write(["Luffy Card": .collection, "New One": .parts], into: &root)
        guard case .object(let settings)? = root["settings"],
              case .object(let map)? = settings["libraryGroups"] else { Issue.record("no map"); return }
        #expect(settings["vatRate"] == .string("15"), "a setting this never touched was re-spelled")
        #expect(settings["currency"] == .string("SAR"))
        #expect(map["Saudi Kings"] == .object(["kind": .string("collection"), "cover": .string("k1")]))
        #expect(map["Luffy Card"] == .object(["kind": .string("collection"), "note": .string("kept")]))
        #expect(map["New One"] == .object(["kind": .string("parts")]))
        let read = GroupKinds.read(settings)
        #expect(read == ["Saudi Kings": .collection, "Luffy Card": .collection, "New One": .parts])
    }

    @Test("a book with no map gets one; a malformed entry reads as the default")
    func noMapAndMalformed() {
        var root = Self.book(nil)
        GroupKinds.write(["A": .collection], into: &root)
        guard case .object(let settings)? = root["settings"] else { Issue.record("no settings"); return }
        #expect(GroupKinds.read(settings) == ["A": .collection])
        let odd: [String: JSONValue] = ["libraryGroups": .object([
            "A": .string("collection"), "B": .object(["kind": .string("bogus")]),
            "C": .object(["kind": .string("collection")])])]
        #expect(GroupKinds.read(odd) == ["C": .collection])
    }

    @Test("moving a folder carries its kind and every kind beneath it")
    func moveCarriesKind() {
        var root = Self.book(.object([
            "Blue": .object(["kind": .string("collection")]),
            "Blue/left": .object(["kind": .string("parts"), "x": .number(1)]),
            "Bluefin": .object(["kind": .string("collection")]),
            "Helmet/Blue": .object(["kind": .string("parts")]),
        ]))
        GroupKinds.carry(from: "Blue", to: "Pose/Blue", in: &root)
        guard case .object(let settings)? = root["settings"] else { Issue.record("no settings"); return }
        let kinds = GroupKinds.read(settings)
        #expect(kinds["Pose/Blue"] == .collection)
        #expect(kinds["Pose/Blue/left"] == .parts)
        #expect(kinds["Pose/Bluefin"] == nil, "a sibling sharing the prefix came along")
        #expect(kinds["Blue"] == .collection, "the old entry is kept so Undo finds it")
        if case .object(let map)? = settings["libraryGroups"] {
            #expect(map["Pose/Blue/left"] == .object(["kind": .string("parts"), "x": .number(1)]))
        }
        // Into a group that already has a kind: that group keeps it.
        GroupKinds.carry(from: "Blue", to: "Helmet/Blue", in: &root)
        guard case .object(let after)? = root["settings"] else { return }
        #expect(GroupKinds.read(after)["Helmet/Blue"] == .parts)
        #expect(GroupKinds.read(after)["Helmet/Blue/left"] == .parts)
    }

    @Test("the folder move and New Group write the kind in the same write as the files")
    func kindWiring() throws {
        let shop = MenuCoverageTests.source("Shop.swift")
        #expect(shop.contains("alsoRoot: { root in GroupKinds.carry(from: path, to: destination, in: &root) }"))
        #expect(shop.contains("{ root in GroupKinds.write([written: kind], into: &root) }"))
        #expect(shop.contains("alsoRoot?(&root)"))
        #expect(shop.contains("libraryGroupKinds = GroupKinds.read(Self.settings(root))"))
        let menu = try String(contentsOf: GroupFromRightClickTests.source("GroupMenu.swift"), encoding: .utf8)
        #expect(menu.contains("GroupKindChoice(words: words, kind: $kind)"))
        #expect(menu.contains("fileSelection(under: wanted, kind: isNew ? kind : nil)"))
        let grid = try String(contentsOf: GroupFromRightClickTests.source("LibraryGrid.swift"), encoding: .utf8)
        #expect(grid.contains("GroupKindMenu(shop: shop, path: path)"), "a group tile cannot be switched")
        #expect(grid.contains("shop.setGroupKind(group, kind)"), "the crumb cannot switch the group")
        #expect(grid.contains("kind: shop.groupKind(path)"))
    }

    // MARK: A group tile says it is a group

    @Test("a group tile's accessibility label says group, name and count", arguments: ["en", "ar"])
    func folderAccessibility(_ lang: String) async throws {
        let words = try await ArabicDualTests.words(lang)
        for kind in GroupKind.allCases {
            let said = FolderCell.accessibilityText(name: "Luffy Card", count: 3, kind: kind, words: words)
            #expect(said.contains("Luffy Card"))
            #expect(said.contains(words.callIt(kind.wordKey)))
            #expect(said.contains(FolderCell.counted(kind: kind, count: 3, words: words)))
        }
        // A print has parts; a collection has models. Two read differently.
        #expect(FolderCell.caption(kind: .parts, count: 3, words: words)
                != FolderCell.caption(kind: .collection, count: 3, words: words))
        #expect(GroupKind.parts.symbol != GroupKind.collection.symbol)
    }

    // MARK: Filing says where the models went

    @Test("filing into a group leaves a note with Show, but only when it was written")
    func filingConfirms() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let files = Array(shop.shownFiles.prefix(3))
        try #require(files.count == 3)
        shop.fileSelection = Set(files.map(\.id))
        // The sample book cannot be written, so nothing may claim it worked.
        await shop.fileSelection(under: "Luffy Card", kind: .parts)
        #expect(shop.groupNote == nil)
        let src = MenuCoverageTests.source("Shop.swift")
        #expect(src.contains("guard wrote, !name.isEmpty else { return }"))
        let banners = MenuCoverageTests.source("Banners.swift")
        #expect(banners.contains("shop.showGroup(note.path)"))
        #expect(banners.contains("\"mac.show_group\""))
    }

    @Test("the note's words exist in English and Arabic")
    func noteWords() async throws {
        for key in ["mac.filed_in_group", "mac.show_group", "mac.group_tile_a11y",
                    "mac.group_tile_parts", "mac.group_tile_collection", "mac.n_parts",
                    "mac.group_kind_parts", "mac.group_kind_collection", "mac.group_kind_menu",
                    "mac.group_kind_hint", "mac.open_group", "mac.group_slash_flattened"] {
            for lang in ["en", "ar"] {
                let words = try await ArabicDualTests.words(lang)
                #expect(words.callIt(key) != key, "\(key) has no \(lang)")
            }
        }
    }
}

/// Pictures of the two library views with a grouped sample, to LOOK at.
/// Writes only when KHAYT_SNAPSHOT_DIR is set (see `SnapshotTests`); the
/// language comes from KHAYT_LANG, as it does there.
@Suite @MainActor struct GroupSnapshots {

    static func file(_ id: String, name: String, group: String?, source: String? = nil,
                     printed: Int = 0, colours: [String] = []) -> LibraryFile {
        var row: [String: JSONValue] = ["id": .string(id), "name": .string(name), "size": .number(2_400_000)]
        if let group { row["folder"] = .string(group) }
        if let source { row["source"] = .string(source) }
        if printed > 0 { row["timesPrinted"] = .number(Double(printed)) }
        if !colours.isEmpty {
            row["colors"] = .array(colours.map { .object(["hex": .string($0)]) })
            row["swapCount"] = .number(Double(colours.count - 1))
        }
        return try! JSONDecoder().decode(LibraryFile.self,
                                         from: JSONEncoder().encode(JSONValue.object(row)))
    }

    static let width: CGFloat = 176

    enum Shot { case groups, allModels, matches }

    func tiles(_ words: Words, _ shot: Shot) -> some View {
        let king1 = Self.file("k1", name: "King Abdulaziz relief", group: "Saudi Kings", printed: 12,
                              colours: ["#2B2B2B", "#D9D9D9"])
        let king2 = Self.file("k2", name: "King Saud relief", group: "Saudi Kings", printed: 9)
        let luffy = Self.file("l1", name: "Luffy_Gear_5_card", group: "Luffy Card", source: "Printables",
                              printed: 4, colours: ["#E63946", "#F1FAEE", "#1D3557"])
        let setA = Self.file("a1", name: "Set A base", group: "Collection X/Set A")
        let loose = Self.file("x1", name: "Filament clip", group: nil, source: "Thingiverse")
        let w = Self.width
        func cell(_ f: LibraryFile, selected: Bool = false) -> some View {
            Cell(file: f, thumbnail: nil, selected: selected, words: words,
                 group: Cell.groupShown(for: f, shelf: .library(nil))).frame(width: w)
        }
        return HStack(alignment: .top, spacing: 16) {
            switch shot {
            case .groups:   // every group a tile, whatever its kind
                FolderCell(name: "Luffy Card", count: 3, thumbnail: nil, words: words, kind: .parts).frame(width: w)
                FolderCell(name: "Saudi Kings", count: 7, thumbnail: nil, words: words, kind: .collection).frame(width: w)
                FolderCell(name: "Luffy Card \u{2013} Poster", count: 1, thumbnail: nil, words: words, kind: .parts).frame(width: w)
                cell(loose)
            case .allModels:   // a print in parts is one tile; a collection's models are models
                cell(king1)
                FolderCell(name: "Luffy Card", count: 3, thumbnail: nil, words: words, kind: .parts).frame(width: w)
                cell(loose, selected: true)
                cell(king2)
                FolderCell(name: "Set A", count: 2, thumbnail: nil, words: words, kind: .parts).frame(width: w)
            case .matches:   // a search: every match flat, each naming its group
                cell(luffy)
                cell(king1)
                cell(setA)
                cell(loose)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Khayt.ground)
    }

    func note(_ words: Words) -> some View {
        Banner(text: words.callIt("mac.filed_in_group", [
                    "models": .string(words.counting(3, "mac.n_models")),
                    "name": .string("Luffy Card")]),
               symbol: "checkmark.circle", tint: Khayt.done) {
            Button(words.callIt("mac.show_group")) {}
            BannerClose(words: words) {}
        }
        .frame(width: 720)
    }

    @Test("Groups, All models, a search's matches and the filed note, light and dark")
    func render() async throws {
        guard SnapshotTests.outputDir != nil else { return }
        let lang = Direction.shopLanguage()
        let words = try await ArabicDualTests.words(lang)
        let snap = SnapshotTests()
        let size = CGSize(width: 1000, height: 300)
        for (shot, name) in [(Shot.groups, "groups-view"), (.allModels, "all-models"), (.matches, "search-matches")] {
            try snap.render(tiles(words, shot), "\(name)-\(lang)-light", size: size)
            try snap.renderDark(tiles(words, shot), "\(name)-\(lang)-dark", size: size)
        }
        try snap.render(note(words), "filed-note-\(lang)-light", size: CGSize(width: 720, height: 40))
        try snap.renderDark(note(words), "filed-note-\(lang)-dark", size: CGSize(width: 720, height: 40))
    }
}
