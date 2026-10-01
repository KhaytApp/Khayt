import Foundation
import Testing
import SwiftUI
import KhaytCore
@testable import KhaytApp

/// The alpha.57 review's fixes: the rules, then pictures of them to LOOK at.
@MainActor struct UI57FixTests {

    static func part(_ row: [String: JSONValue]) -> Order.Part {
        try! JSONDecoder().decode(Order.Part.self, from: JSONEncoder().encode(JSONValue.object(row)))
    }

    static func job(_ row: [String: JSONValue]) -> Order {
        try! JSONDecoder().decode(Order.self, from: JSONEncoder().encode(JSONValue.object(row)))
    }

    // ── A hash is not a title ─────────────────────────────────────────────

    @Test("a 32, 40 or 64 hex-digit project is a hash; a name with hex in it is not")
    func hashes() {
        #expect(JobTitle.looksLikeHash("d0de11b4e5a09b4119ca41bdab22300d"))
        #expect(JobTitle.looksLikeHash(String(repeating: "a", count: 40)))
        #expect(JobTitle.looksLikeHash(String(repeating: "F", count: 64)))
        #expect(!JobTitle.looksLikeHash("cafe"))
        #expect(!JobTitle.looksLikeHash("Bed 2 plate"))
        #expect(!JobTitle.looksLikeHash(String(repeating: "a", count: 33)))
        #expect(!JobTitle.looksLikeHash("d0de11b4e5a09b4119ca41bdab22300z"))
    }

    @Test("a hashed job shows its library model, else its file, else a part, else Untitled — and a name is kept")
    func hashedTitle() {
        let hash = "d0de11b4e5a09b4119ca41bdab22300d"
        let linked = Self.part(["name": .string(hash), "printFileId": .string("f1"),
                                "fileRef": .string("/data/Benchy_plate.gcode.3mf")])
        let lookup: (String) -> String? = { $0 == "f1" ? "Benchy" : nil }
        #expect(JobTitle.shown(project: hash, parts: [linked], fileTitle: lookup, untitled: "U") == "Benchy")
        // No library link: the printed file, without folder or extensions.
        let fileOnly = Self.part(["fileRef": .string("/data/Benchy_plate.gcode.3mf")])
        #expect(JobTitle.shown(project: hash, parts: [fileOnly], fileTitle: { _ in nil }, untitled: "U")
                == "Benchy_plate")
        // The file is a hash too: a part's own name.
        let named = Self.part(["name": .string("Hinge"), "fileRef": .string(hash + ".gcode")])
        #expect(JobTitle.shown(project: hash, parts: [named], fileTitle: { _ in nil }, untitled: "U") == "Hinge")
        // Nothing usable at all.
        #expect(JobTitle.shown(project: hash, parts: [], fileTitle: { _ in nil }, untitled: "U") == "U")
        // A real name is never second-guessed.
        #expect(JobTitle.shown(project: "Luffy card", parts: [linked], fileTitle: lookup, untitled: "U")
                == "Luffy card")
    }

    // ── The group tile names its parent ───────────────────────────────────

    @Test("a nested tile names its parent unless that parent is the open group")
    func parentSubtitle() {
        #expect(FolderCell.parent(of: "Collection X/Set A", open: .library(nil)) == "Collection X")
        #expect(FolderCell.parent(of: "A/B/C", open: .library(nil)) == "B")
        #expect(FolderCell.parent(of: "Set A", open: .library(nil)) == nil)
        #expect(FolderCell.parent(of: "Collection X/Set A", open: .library("Collection X")) == nil)
    }

    @Test("the All models / Groups switch is offered only with no group open")
    func viewSwitch() {
        #expect(LibraryFilterBar.offersViewSwitch(.library(nil)))
        #expect(!LibraryFilterBar.offersViewSwitch(.library("Saudi Kings")))
    }

    // ── Counted, in both languages ────────────────────────────────────────

    @Test("the off-screen refusal agrees with its count, in English and Arabic")
    func counted() async throws {
        let en = try await ArabicDualTests.words("en")
        #expect(en.counting(1, "mac.delete_not_on_screen").contains("1 of the chosen models is not"))
        #expect(en.counting(5, "mac.delete_not_on_screen").contains("5 of the chosen models are not"))
        let ar = try await ArabicDualTests.words("ar")
        #expect(ar.counting(1, "mac.delete_not_on_screen").contains("نموذج واحد"))
        #expect(!ar.counting(1, "mac.delete_not_on_screen").contains("1"))
        #expect(ar.counting(2, "mac.delete_not_on_screen").contains("نموذجان"))
        #expect(ar.counting(7, "mac.delete_not_on_screen").contains("7"))
    }

    @Test("the new words exist in both languages, and the collection tile no longer says group")
    func words() async throws {
        for key in ["mac.group_in_parent", "mac.untitled_print", "mac.own_print",
                    "mac.delete_not_on_screen_one", "mac.delete_not_on_screen_two",
                    "mac.delete_many_title", "mac.delete_many_title_one"] {
            for lang in ["en", "ar"] {
                let w = try await ArabicDualTests.words(lang)
                #expect(w.callIt(key) != key, "\(key) has no \(lang)")
            }
        }
        let ar = try await ArabicDualTests.words("ar")
        #expect(ar.callIt("mac.group_tile_collection") == ar.callIt("mac.group_kind_collection"))
    }
}

/// Pictures. Written only when KHAYT_SNAPSHOT_DIR is set; language from
/// KHAYT_LANG, as `SnapshotTests`.
@Suite(.serialized) @MainActor struct UI57Snapshots {

    func shop(_ lang: String) async throws -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        await shop.words.load(lang, engine: try KhaytEngine())
        return shop
    }

    /// A model tile beside group tiles — one nested — so their tops,
    /// pictures and lines can be compared.
    func tiles(_ words: Words) -> some View {
        let w = GroupSnapshots.width
        let model = GroupSnapshots.file("m1", name: "Filament clip", group: nil, source: "Thingiverse")
        return HStack(alignment: .top, spacing: 16) {
            Cell(file: model, thumbnail: nil, selected: false, words: words).frame(width: w)
            FolderCell(name: "Set A", count: 2, thumbnail: nil, words: words, kind: .parts,
                       parent: "Collection X").frame(width: w)
            FolderCell(name: "left", count: 3, thumbnail: nil, words: words, kind: .parts,
                       parent: "Baby Grendizer").frame(width: w)
            FolderCell(name: "Saudi Kings", count: 7, thumbnail: nil, words: words, kind: .collection)
                .frame(width: w)
            Cell(file: model, thumbnail: nil, selected: true, words: words).frame(width: w)
        }
        // A rule along the tops and one along the picture's floor.
        .overlay(alignment: .top) { Rectangle().fill(.red.opacity(0.5)).frame(height: 1).padding(.top, 6) }
        .overlay(alignment: .top) {
            Rectangle().fill(.red.opacity(0.5)).frame(height: 1).padding(.top, 6 + w - 12)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Khayt.ground)
    }

    func filterAndCrumb(_ shop: Shop) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            LibraryFilterBar(shop: shop)
            Divider()
            GroupCrumb(shop: shop, group: "Collection X/Set A")
            Spacer(minLength: 0)
        }
        .background(Khayt.ground)
    }

    func newGroup(_ words: Words, typed: String) -> some View {
        NameAGroup(words: words, typed: .constant(typed), known: [], done: { _, _ in })
            .background(Khayt.ground)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Khayt.ground)
    }

    /// The multi-delete question's content, laid out the way the system
    /// dialog lays it: title, message, the two buttons.
    func deleteQuestion(_ shop: Shop) -> some View {
        let names = ["Luffy_Gear_5_card", "King Abdulaziz relief", "King Saud relief",
                     "Set A base", "Set A lid", "Filament clip", "Cable tidy", "Hook", "Spool hub",
                     "Bracket"]
        let chosen = names.enumerated().map { i, n in
            GroupSnapshots.file("d\(i)", name: n, group: i < 3 ? "Saudi Kings" : nil)
        }
        return VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
            Text(shop.words.counting(chosen.count, "mac.delete_many_title")).font(.headline)
            Text(verbatim: shop.libraryDeleteMessage(chosen))
                .font(.callout).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(shop.words.callIt("mac.delete_n_models", ["n": .number(Double(chosen.count))]),
                   role: .destructive) {}
                .frame(maxWidth: .infinity)
            Button(shop.words.callIt("common.cancel"), role: .cancel) {}
                .frame(maxWidth: .infinity)
            Text(verbatim: shop.words.counting(1, "mac.delete_not_on_screen"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: shop.words.counting(2, "mac.delete_not_on_screen"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Khayt.ground)
    }

    func jobRows(_ shop: Shop) -> some View {
        let hash = "d0de11b4e5a09b4119ca41bdab22300d"
        let rows: [(Order, Bool)] = [
            (UI57FixTests.job(["id": .string("ORD-1041"), "project": .string(hash), "status": .string("completed"),
                               "parts": .array([.object(["fileRef": .string("Benchy_plate.gcode.3mf")])])]), true),
            (UI57FixTests.job(["id": .string("ORD-1042"), "project": .string(hash), "status": .string("completed"),
                               "nonBusiness": .bool(true)]), false),
            (UI57FixTests.job(["id": .string("ORD-1043"), "project": .string("Luffy card set"),
                               "status": .string("completed"), "price": .number(50),
                               "parts": .array([.object(["colour": .string("sand")])])]), false),
            (UI57FixTests.job(["id": .string("ORD-1044"), "project": .string("Spool hub"),
                               "status": .string("completed"), "nonBusiness": .bool(true)]), true),
        ]
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                JobTitleCell(shop: shop, job: row.0,
                             thumbnail: row.1 ? .inlineData("data:image/png;base64,") : nil)
                    .padding(.vertical, 4)
                    .border(.red.opacity(0.3))
            }
            Text(shop.words.callIt("mac.set_elec_rate_hint",
                                   ["rate": .string(Money.text(0.18, shop.currency))]))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
        .frame(width: 420)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Khayt.ground)
    }

    func titleBar(_ shop: Shop) -> some View {
        ShellTitleBar(shop: shop, searchWanted: .constant(false))
    }

    @Test("tiles, the crumb, New Group, the delete question, job rows, the strip — light and dark")
    func render() async throws {
        guard SnapshotTests.outputDir != nil else { return }
        let lang = Direction.shopLanguage()
        let shop = try await shop(lang)
        let snap = SnapshotTests()
        func both(_ view: some View, _ name: String, _ size: CGSize) throws {
            try snap.render(view, "\(name)-\(lang)-light", size: size)
            try snap.renderDark(view, "\(name)-\(lang)-dark", size: size)
        }
        try both(tiles(shop.words), "ui57-tiles", CGSize(width: 1000, height: 300))
        shop.shelf = .library(nil)
        try both(filterAndCrumb(shop), "ui57-filter-top", CGSize(width: 900, height: 90))
        shop.shelf = .library("Collection X/Set A")
        try both(filterAndCrumb(shop), "ui57-filter-in-group", CGSize(width: 900, height: 90))
        try both(newGroup(shop.words, typed: ""), "ui57-new-group-empty", CGSize(width: 300, height: 300))
        try both(newGroup(shop.words, typed: "Luffy Card/Poster"), "ui57-new-group-slash",
                 CGSize(width: 300, height: 340))
        try both(deleteQuestion(shop), "ui57-delete-many", CGSize(width: 380, height: 640))
        try both(jobRows(shop), "ui57-job-rows", CGSize(width: 480, height: 300))
        shop.shelf = .library(nil)
        shop.fileSelection = Set(shop.visibleFiles.prefix(4).map(\.id))
        try both(titleBar(shop), "ui57-strip-many-selected", CGSize(width: 1100, height: 40))
        try both(titleBar(shop), "ui57-strip-narrow", CGSize(width: 900, height: 40))
    }
}
