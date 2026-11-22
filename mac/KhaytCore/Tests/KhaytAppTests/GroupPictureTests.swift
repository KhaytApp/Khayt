import Foundation
import AppKit
import SwiftUI
import Testing
import KhaytCore
@testable import KhaytApp

/// A group can wear a picture the shop chose.
///
/// Reported: *"I can't seem able to add a photo for a group."* A group tile
/// only ever borrowed the first model's thumbnail. The picture is kept beside
/// the group's kind, in `settings.libraryGroups[path].cover`, so it follows
/// the group the way the kind does: through a folder move, back through its
/// undo, and out with the prune when the group is gone.
@MainActor
struct GroupPictureTests {

    typealias Book = GroupsReadClearlyTests

    static func map(_ root: [String: JSONValue]) -> [String: JSONValue] {
        guard case .object(let m)? = Shop.settings(root)["libraryGroups"] else { return [:] }
        return m
    }

    static func covers(_ root: [String: JSONValue]) -> [String: GroupCover] {
        GroupKinds.covers(Shop.settings(root))
    }

    @Test("a picture is set beside the kind, and taken off without touching it")
    func setAndRemove() {
        var root = Book.book(.object([
            "Saudi Kings": .object(["kind": .string("collection"), "note": .string("kept")]),
        ]), files: ["Saudi Kings", "Luffy Card"])
        let rel = "group-pictures/Saudi_Kings-mf3k2.jpg"
        let had = GroupKinds.setCover(.image(rel), for: "Saudi Kings", into: &root)
        #expect(had == nil)
        #expect(Self.map(root)["Saudi Kings"] == .object([
            "kind": .string("collection"), "note": .string("kept"),
            "cover": .object(["image": .string(rel)])]))
        #expect(Book.kinds(root)["Saudi Kings"] == .collection, "setting a picture changed the kind")
        #expect(Self.covers(root) == ["Saudi Kings": .image(rel)])

        // A group with no entry yet gets one holding only the picture — and
        // still reads as the default kind.
        GroupKinds.setCover(.model("f-Luffy Card"), for: "Luffy Card", into: &root)
        #expect(Self.map(root)["Luffy Card"] == .object(["cover": .object(["model": .string("f-Luffy Card")])]))
        #expect(GroupKinds.kind(of: "Luffy Card", in: Book.kinds(root)) == GroupKind.assumed)

        // Off again: the kind and the note stay; an entry left empty goes.
        let was = GroupKinds.setCover(nil, for: "Saudi Kings", into: &root)
        #expect(was == .image(rel))
        #expect(Self.map(root)["Saudi Kings"] == .object(["kind": .string("collection"), "note": .string("kept")]))
        GroupKinds.setCover(nil, for: "Luffy Card", into: &root)
        #expect(Self.map(root)["Luffy Card"] == nil, "an entry with nothing in it was left behind")
        #expect(Self.covers(root).isEmpty)
    }

    @Test("setting the same picture twice writes nothing the second time")
    func idempotent() {
        var root = Book.book(nil, files: ["A"])
        GroupKinds.setCover(.model("f-A"), for: "A", into: &root)
        let once = root
        GroupKinds.setCover(.model("f-A"), for: "A", into: &root)
        #expect(root == once)
        // And taking off a picture a group never had leaves a book with no
        // map exactly as it was — not an empty map written in.
        var bare = Book.book(nil, files: ["A"])
        let before = bare
        GroupKinds.setCover(nil, for: "A", into: &bare)
        #expect(bare == before)
    }

    @Test("the picture moves with its folder, and its undo brings it back")
    func carriedOnMove() {
        var root = Book.book(.object([
            "Blue": .object(["kind": .string("collection"),
                             "cover": .object(["image": .string("group-pictures/Blue-1.jpg")])]),
            "Blue/left": .object(["cover": .object(["model": .string("f-Blue/left")])]),
        ]), files: ["Blue", "Blue/left", "Pose"])
        let before = root
        let undo = Book.move("Blue", to: "Pose/Blue", in: &root)
        let covers = Self.covers(root)
        #expect(covers["Pose/Blue"] == .image("group-pictures/Blue-1.jpg"), "the picture stayed behind")
        #expect(covers["Pose/Blue/left"] == .model("f-Blue/left"))
        #expect(covers["Blue"] == nil && covers["Blue/left"] == nil, "the picture was copied, not moved")
        #expect(Book.kinds(root)["Pose/Blue"] == .collection)
        _ = Shop.applyRestore(&root, undo)
        #expect(Self.covers(root) == Self.covers(before), "undoing the move lost the picture")
    }

    @Test("a group nobody is in any more loses its picture with its kind")
    func pruned() {
        var root = Book.book(.object([
            "Gone": .object(["cover": .object(["image": .string("group-pictures/Gone-1.jpg")])]),
            "Here": .object(["kind": .string("parts")]),
        ]), files: ["Here"])
        GroupKinds.setCover(.model("f-Here"), for: "Here", into: &root)
        #expect(Self.map(root)["Gone"] == nil, "a dead group's picture would be inherited by the next of that name")
        #expect(Self.covers(root) == ["Here": .model("f-Here")])
    }

    @Test("a cover off a synced book cannot name a file outside the pictures folder")
    func refusesPaths() {
        #expect(GroupCover(.object(["image": .string("../../../.ssh/id_rsa")])) == nil)
        #expect(GroupCover(.object(["image": .string("group-pictures/../x.jpg")])) == .image("group-pictures/x.jpg"))
        #expect(GroupCover(.object(["image": .string("group-pictures/a b.jpg")])) == nil, "not a name this app writes")
        #expect(GroupCover(.object(["image": .string("group-pictures/x.png")])) == nil)
        #expect(GroupCover(.string("k1")) == nil)
        #expect(GroupCover(.object(["model": .string("")])) == nil)
        #expect(GroupPictures.leaf(of: GroupPictures.filename(for: "Saudi/Kings – Set A")) != nil,
                "a name this app writes is refused when read back")
    }

    @Test("a new picture is a new FILE, so nothing that drew the old one shows it again")
    func freshNames() {
        let a = GroupPictures.filename(for: "Saudi Kings", at: Date(timeIntervalSince1970: 1))
        let b = GroupPictures.filename(for: "Saudi Kings", at: Date(timeIntervalSince1970: 2))
        #expect(a != b)
        #expect(a.hasPrefix("Saudi_Kings-") && a.hasSuffix(".jpg"))
    }

    @Test("the picture file is found in any of the library's folders, and written upright")
    func fileOnDisk() throws {
        let fm = FileManager.default
        let old = fm.temporaryDirectory.appending(path: "khayt-gp-old-\(UUID().uuidString)").path
        let now = fm.temporaryDirectory.appending(path: "khayt-gp-new-\(UUID().uuidString)").path
        let source = try PhotoOrientationTests.fixtureFile()
        let rel = try GroupPictures.write(GroupPictures.encode(source), for: "Saudi Kings", under: old)
        #expect(rel.hasPrefix("group-pictures/"))
        // Moved library: the old folder is still searched, as a model's is.
        let url = try #require(GroupPictures.url(of: rel, roots: [now, old]))
        PhotoOrientationTests.expectUpright(PhotoOrientationTests.stored(try Data(contentsOf: url)), "the group picture")
        #expect(GroupPictures.url(of: rel, roots: [now]) == nil)
        // And a library move takes it along: it is Khayt's own folder.
        let walked = LibraryMove.walk(old, recordDirs: [])
        #expect(walked.contains { $0.rel == rel }, "a library move would leave the group pictures behind")
    }

    @Test("the tile wears the chosen picture, and the menus offer it")
    func wired() throws {
        let grid = MenuCoverageTests.source("LibraryGrid.swift")
        #expect(grid.contains("thumbnail: shop.groupThumbnail(path, automatic: cover)"),
                "the tile ignores the group's chosen picture")
        #expect(grid.components(separatedBy: "GroupPictureItems(shop: shop, path:").count - 1 == 2,
                "the tile's right-click and the crumb both offer the picture")
        let shop = MenuCoverageTests.source("Shop.swift")
        #expect(shop.contains("libraryGroupCovers = GroupKinds.covers(Self.settings(root))"))
    }

    @Test("the words exist in English and Arabic")
    func words() async throws {
        for key in ["mac.group_picture_set", "mac.group_picture_use_model", "mac.group_picture_remove",
                    "mac.group_picture_choose", "mac.rotate_left", "mac.rotate_right", "mac.rotate_failed"] {
            for lang in ["en", "ar"] {
                let words = try await ArabicDualTests.words(lang)
                #expect(words.callIt(key) != key, "\(key) has no \(lang)")
            }
        }
    }

    // MARK: - Pictures

    @Test("a group tile wearing a chosen picture beside one borrowing, en/ar")
    func render() async throws {
        guard SnapshotTests.outputDir != nil else { return }
        let lang = Direction.shopLanguage()
        let words = try await ArabicDualTests.words(lang)
        // A "photo": the fixture turned upright, scaled up to tile size.
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-gp-shot-\(UUID().uuidString)")
        let rel = try GroupPictures.write(GroupPictures.encode(PhotoOrientationTests.fixtureFile()),
                                          for: "Saudi Kings", under: dir.path)
        let url = try #require(GroupPictures.url(of: rel, roots: [dir.path]))
        let w: CGFloat = 176
        let view = HStack(alignment: .top, spacing: 16) {
            FolderCell(name: "Saudi Kings", count: 7, thumbnail: .file(url), words: words, kind: .collection)
                .frame(width: w)
            FolderCell(name: "Luffy Card", count: 3, thumbnail: nil, words: words, kind: .parts)
                .frame(width: w)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Khayt.ground)
        let size = CGSize(width: 440, height: 280)
        try SnapshotTests().render(view, "group-picture-\(lang)-light", size: size)
        try SnapshotTests().renderDark(view, "group-picture-\(lang)-dark", size: size)
    }
}
