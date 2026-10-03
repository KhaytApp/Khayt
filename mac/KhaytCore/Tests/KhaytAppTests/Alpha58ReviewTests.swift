import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The alpha.58 UI review's findings, each held to what was fixed.
@MainActor
struct Alpha58ReviewTests {

    static func source(_ name: String) -> String { MenuCoverageTests.source(name) }

    static func tempStore() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-a58-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "khayt-store.json")
    }

    static func loss(_ id: String, _ kind: SyncLoss.Kind = .replaced) -> SyncLoss {
        SyncLoss(kind: kind, collection: "clients", recordId: id,
                 record: .object(["id": .string(id), "name": .string("Client " + id)]), replacedBy: nil)
    }

    // MARK: 1. What sync took survives a relaunch and a stray ✕

    @Test("the sync-losses notice is rebuilt from disk until the shop closes it")
    func syncLossesComeBack() throws {
        let store = try Self.tempStore()
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }
        #expect(SyncLosses.unreviewed(for: store).notice == nil, "a book with no kept merges has a notice")

        let first = SyncLosses.fileURL(for: store, at: Date(timeIntervalSince1970: 1_790_000_000))
        try SyncLosses.keep([Self.loss("C-A"), Self.loss("C-B", .removed)], at: first)
        // A relaunch: nothing in memory, the notice comes from the copies.
        let opened = try #require(SyncLosses.unreviewed(for: store).notice, "a relaunch lost the notice")
        #expect(opened.losses.count == 2 && opened.files == [first])
        #expect(opened.outstanding(putBack: ["replaced:clients:C-A"]).map(\.recordId) == ["C-B"])

        // Closed by the shop: remembered, so the next launch says nothing.
        try SyncLossReview.markReviewed(opened, storeURL: store)
        #expect(SyncLosses.unreviewed(for: store).notice == nil, "a closed notice came back")
        #expect(FileManager.default.fileExists(atPath: first.path), "closing the notice deleted the copies")

        // A LATER merge is a new notice, its own records only.
        let second = SyncLosses.fileURL(for: store, at: Date(timeIntervalSince1970: 1_790_000_100))
        try SyncLosses.keep([Self.loss("C-A")], at: second)
        let later = try #require(SyncLosses.unreviewed(for: store).notice)
        #expect(later.files == [second] && later.losses.count == 1)
        #expect(SyncLosses.unreviewed(for: store).putBack.isEmpty,
                "the earlier put-back would mark the later loss of the same record as already back")
        // The review file is not mistaken for a kept merge.
        #expect(SyncLosses.keptFiles(for: store).map(\.lastPathComponent).allSatisfy { $0.hasPrefix("sync-") })
    }

    @Test("the notice is rebuilt on every load, and the ✕ asks while records are still out")
    func syncLossesWired() {
        let shop = Self.source("Shop.swift")
        #expect(shop.contains("reloadSyncLosses(for: next.build)"), "load does not rebuild the notice")
        let banners = Self.source("Banners.swift")
        #expect(banners.contains("SyncLossBanner(shop: shop, lost: lost)"))
        #expect(!banners.contains("shop.dismissSyncLosses()"), "the ✕ still drops the notice in one click")
        let parts = Self.source("BannerParts.swift")
        #expect(parts.contains("if outstanding > 0 { asking = outstanding } else { shop.closeSyncLosses() }"))
    }

    // MARK: 2. Keep or Move, labelled and not remembered

    @Test("the Add panel's choice is labelled, warns on Move, and is never remembered")
    func importChoice() async throws {
        let words = try await ArabicDualTests.words("en")
        let keep = ImportOriginalsChoice(words: words, moves: false)
        #expect(!keep.moves)
        let move = ImportOriginalsChoice(words: words, moves: true)
        #expect(move.moves)
        let shop = Self.source("Shop.swift")
        #expect(!shop.contains("UserDefaults.standard.set(moves, forKey: Self.importMovesOriginalsKey)"),
                "the panel's Move still applies to every later drop")
        #expect(shop.contains("ImportOriginalsChoice(words: words, moves: importMovesOriginals)"))
        let choice = Self.source("ImportOriginalsChoice.swift")
        #expect(choice.contains("mac.import_originals_title") && choice.contains("mac.import_originals_hint"))
        // A drop asks nothing and uses Settings' answer.
        #expect(Self.source("LibraryGrid.swift").contains("await shop.addModelsToLibrary(urls)"))
    }

    @Test("an import that trashed originals says how many, and archive scratch copies are not originals")
    func trashedNote() async throws {
        let words = try await ArabicDualTests.words("en")
        let scratch = URL(fileURLWithPath: "/tmp/khayt-archive-x")
        let note = Shop.trashedNote([URL(fileURLWithPath: "/Users/s/Downloads/a.stl"),
                                     URL(fileURLWithPath: "/Users/s/Downloads/b.stl"),
                                     scratch.appending(path: "c.stl")],
                                    scratches: [scratch], words: words)
        #expect(note == " 2 originals moved to the Trash.")
        #expect(Shop.trashedNote([], scratches: [], words: words) == "")
        let one = Shop.trashedNote([URL(fileURLWithPath: "/a.stl")], scratches: [], words: words)
        #expect(one == " 1 original moved to the Trash.")
        let ar = try await ArabicDualTests.words("ar")
        let three = Shop.trashedNote((1...3).map { URL(fileURLWithPath: "/m\($0).stl") }, scratches: [], words: ar)
        #expect(three.contains("ملفات"), "Arabic three-to-ten took the wrong form: \(three)")
    }

    // MARK: 3. Held prices as money, with the way to edit

    @Test("a held price reads as money both sides, and an empty 'was' is left out")
    func heldPrices() {
        let both = HeldPriceRow.figures(WebStorePriceChange(id: "P", name: "Vase", was: "50", now: "48.5"),
                                        currency: "SAR")
        #expect(both.contains(Money.text(50, "SAR")) && both.contains(Money.text(48.5, "SAR")))
        #expect(both.contains("\u{2192}"))
        #expect(both.hasPrefix("\u{2066}"), "the line is not held left to right, so Arabic reverses it")
        let noWas = HeldPriceRow.figures(WebStorePriceChange(id: "P", name: "Vase", was: "", now: "48.5"),
                                         currency: "SAR")
        #expect(noWas == Money.text(48.5, "SAR"))
        #expect(Self.source("WebStore.swift").contains("guard let product = await shop.productForEditing(change.id)"))
    }

    // MARK: 4. Only the prices that move

    @Test("the spool repair lists and counts only rows whose price changes")
    func spoolRepairRows() async throws {
        let words = try await ArabicDualTests.words("en")
        func change(_ id: String, _ was: Double, _ now: Double) -> Shop.SpoolRepairChange {
            Shop.SpoolRepairChange(id: id, name: id, was: .object([:]), now: [:], priceWas: was, priceNow: now)
        }
        let all = [change("A", 50, 48), change("B", 30, 30), change("C", 12, 13)]
        #expect(SpoolRepairSheet.repriced(all).map(\.id) == ["A", "C"])
        #expect(SpoolRepairSheet.applyLabel(all, words: words) == words.counting(2, "mac.spool_repair_apply"))
        #expect(SpoolRepairSheet.applyLabel([change("B", 30, 30)], words: words)
                == words.callIt("mac.spool_repair_apply_costs"))
    }

    // MARK: 5. A cloud that went backwards

    @Test("going backwards is said in the shop's language, with the numbers")
    func wentBackwardsWords() async throws {
        let ar = try await ArabicDualTests.words("ar")
        let said = ar.cloudFailure(.wentBackwards(seen: 41, got: 7))
        #expect(said.contains("41") && said.contains("7"))
        #expect(!said.contains("Khayt Cloud answered"), "still the hard-coded English")
        let en = try await ArabicDualTests.words("en")
        #expect(en.cloudFailure(.unauthorised) == CloudReader.Failure.unauthorised.description)
        let shop = Self.source("Shop.swift")
        #expect(!shop.contains("""
            } catch let failure as CloudReader.Failure {
                        cloudProblem = failure.description
            """))
        #expect(Self.source("Banners.swift").contains("WentBackwardsBanner(shop: shop)"))
        #expect(Self.source("CloudCheckSheet.swift").contains("shop.acceptCloudRollbackAndSync()"))
    }

    // MARK: 6. The spool-repair banner on every screen

    @Test("the spool-size banner and its sheet are the window's, not the catalogue's")
    func spoolBannerEverywhere() {
        #expect(Self.source("Banners.swift").contains("SpoolRepairBanner(shop: shop)"))
        #expect(Self.source("ShopWindow.swift").contains(".sheet(isPresented: $shop.showingSpoolRepair)"))
        #expect(!Self.source("Catalogue.swift").contains(".sheet(isPresented: $shop.showingSpoolRepair)"),
                "two sheets bound to one flag")
    }

    // MARK: 7. Rename and move from inside a group

    @Test("the crumb offers Rename and Move, and an open group is followed when it moves")
    func crumbActions() {
        let grid = Self.source("LibraryGrid.swift")
        #expect(grid.contains("GroupTileActions(shop: shop, path: group)"))
        let rename = Shop.planGroupRename("Kings/Set A", to: "Set B",
                                          files: [("f1", "Kings/Set A"), ("f2", "Kings/Set A/left")])
        #expect(Shop.followed("Kings/Set A", by: rename) == "Kings/Set B")
        #expect(Shop.followed("Kings/Set A/left", by: rename) == "Kings/Set B/left")
        #expect(Shop.followed("Other", by: rename) == nil)
    }

    // MARK: 8. A greyed action says why

    @Test("a strip action that is off says why on hover")
    func lockedReason() {
        let actions = Self.source("ScreenActions.swift")
        #expect(actions.contains("whyNot: shop.lockedReason"))
        #expect(actions.contains(".help(enabled ? word : (whyNot.map"))
        #expect(Self.source("CustomersTable.swift").contains("WhyLockedNote(shop: shop)"))
    }

    // MARK: 9. The job id, and a hash in front of a file name

    @Test("a hash in front of a printer's file name is not a title")
    func hashPrefix() {
        let hash = String(repeating: "d0de11b4", count: 4)
        #expect(JobTitle.withoutHashPrefix(hash + "_PLA_4h29m") == "PLA_4h29m")
        #expect(JobTitle.withoutHashPrefix("cafe_stand") == "cafe_stand")
        #expect(JobTitle.withoutHashPrefix(hash) == hash, "a bare hash is for looksLikeHash, not this")
        let part = UI57FixTests.part(["fileRef": .string("/sd/" + hash + "_PLA_4h29m.gcode")])
        #expect(JobTitle.shown(project: hash, parts: [part], fileTitle: { _ in nil }, untitled: "U")
                == "PLA_4h29m")
        #expect(Self.source("OrdersTable.swift").contains("ViewThatFits(in: .horizontal) {\n                Text(job.id)"))
    }

    // MARK: 10. A narrow strip

    @Test("the strip collapses its decoration below its width, not when unmeasured")
    func compactStrip() {
        #expect(!StripWidth.compact(0))
        #expect(StripWidth.compact(900))
        #expect(!StripWidth.compact(1440))
    }

    // MARK: 13. Arabic counts its units

    @Test("four rolls is لفات, two is the dual, eleven is the singular")
    func arabicUnits() async throws {
        let ar = try await ArabicDualTests.words("ar")
        #expect(ar.amount("4", "roll").contains("4 لفات"))
        #expect(ar.amount("6", "each").contains("6 حبات"))
        #expect(ar.amount("2", "rolls").contains("لفتان") && !ar.amount("2", "rolls").contains("2"))
        #expect(ar.amount("11", "roll").contains("11 لفة"))
        #expect(ar.amount("1", "roll").contains("1 لفة"))
        #expect(ar.amount("2.5", "kg").contains("2.5 كغ"), "a measure is not counted")
        #expect(ar.amount("٤", "roll").contains("لفات"))
        let en = try await ArabicDualTests.words("en")
        #expect(en.amount("4", "rolls") == "\u{2068}4 rolls\u{2069}")
    }

    // MARK: 16. Group pictures through moves, prunes and Remove

    @Test("a group moved into one with no picture brings its picture; one with a picture keeps it")
    func coverOnJoin() {
        typealias Book = GroupsReadClearlyTests
        let mine = JSONValue.object(["image": .string("group-pictures/Src-1.jpg")])
        var root = Book.book(.object([
            "Dest": .object(["kind": .string("collection")]),
            "Src": .object(["cover": mine]),
        ]), files: ["Dest", "Src"])
        _ = Book.move("Src", to: "Dest", in: &root)
        let covers = GroupKinds.covers(Shop.settings(root))
        #expect(covers["Dest"] == .image("group-pictures/Src-1.jpg"), "the moving group's picture was dropped")
        #expect(Book.kinds(root)["Dest"] == .collection, "the destination lost its own kind")

        var kept = Book.book(.object([
            "Dest": .object(["cover": .object(["image": .string("group-pictures/Dest-1.jpg")])]),
            "Src": .object(["cover": mine]),
        ]), files: ["Dest", "Src"])
        _ = Book.move("Src", to: "Dest", in: &kept)
        #expect(GroupKinds.covers(Shop.settings(kept))["Dest"] == .image("group-pictures/Dest-1.jpg"))
    }

    @Test("a parent group whose models are all in sub-groups keeps its picture through a prune")
    func parentCoverSurvivesPrune() {
        typealias Book = GroupsReadClearlyTests
        var root = Book.book(.object([
            "Kings": .object(["cover": .object(["image": .string("group-pictures/Kings-1.jpg")])]),
        ]), files: ["Kings/Set A", "Kings/Set B"])
        GroupKinds.write(["Kings/Set A": .parts], into: &root)
        #expect(GroupKinds.covers(Shop.settings(root))["Kings"] == .image("group-pictures/Kings-1.jpg"))
    }

    @Test("a dropped picture goes to the Trash only when nothing names it, and comes back with its entry")
    func picturesSettle() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "khayt-gp-settle-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let rel = try GroupPictures.write(GroupPictures.encode(PhotoOrientationTests.fixtureFile()),
                                          for: "Kings", under: root.path)
        let shared = GroupCover.image(rel)
        // Two entries named it; one is dropped — the file stays.
        GroupPictures.settle(GroupCoverChange(before: ["A": shared, "B": shared], after: ["B": shared]),
                             roots: [root.path], primary: root.path)
        #expect(GroupPictures.url(of: rel, roots: [root.path]) != nil, "a picture still worn went to the Trash")
        // The last one is dropped — the file goes to the Trash.
        GroupPictures.settle(GroupCoverChange(before: ["B": shared], after: [:]),
                             roots: [root.path], primary: root.path)
        #expect(GroupPictures.url(of: rel, roots: [root.path]) == nil, "an unworn picture stayed for nobody")
        // An Undo names it again — it comes back out of the Trash.
        GroupPictures.settle(GroupCoverChange(before: [:], after: ["B": shared]),
                             roots: [root.path], primary: root.path)
        #expect(GroupPictures.url(of: rel, roots: [root.path]) != nil, "Undo brought back a picture with no file")
    }

    @Test("Remove and Replace Group Picture are undoable")
    func pictureUndo() {
        let picture = Self.source("GroupPicture.swift")
        #expect(picture.contains("registerUndo(of: undo, named: words.callIt(cover == nil ? \"mac.group_picture_remove\""))
        #expect(Self.source("Shop.swift").contains("settleGroupPictures(covers)"))
    }

    // MARK: 15. A turned photo never overwrites its original before the save

    @Test("a product save writes turned photos to new files and trashes the old only after the record")
    func rotateSaveOrder() {
        let shop = Self.source("Shop.swift")
        #expect(shop.contains("written.append(staged![i].path)"))
        #expect(shop.contains("for name in written { ProductPhotos.discard(name, in: build) }"))
        #expect(shop.contains("registerPicturesPutBack(trashed, in: build)"))
    }

    // MARK: 17. Title case on the strip

    @Test("the strip's actions are in title case")
    func stripCasing() async throws {
        let en = try await ArabicDualTests.words("en")
        for key in ["mac.new_job", "mac.new_product", "mac.new_customer", "mac.add_printer",
                    "mac.new_spool", "mac.import_models", "mac.issue_gift_card"] {
            let said = en.callIt(key)
            let words = said.split(separator: " ").filter { $0.count > 3 }
            #expect(words.allSatisfy { $0.first?.isUppercase == true }, "\(key) reads \"\(said)\"")
        }
    }

    // MARK: 18. Snapshots photograph the sample

    @Test("every snapshot mode photographs the sample book unless the real one is asked for")
    func snapshotsUseTheSample() {
        #expect(!Snapshot.usesSample([:]), "an ordinary launch opened the sample")
        #expect(Snapshot.usesSample(["KHAYT_SNAPSHOT_DIR": "/tmp/x"]))
        #expect(Snapshot.usesSample(["KHAYT_SNAPSHOT_DIR": "/tmp/x", "KHAYT_SNAPSHOT_DARK": "1"]),
                "the dark run photographed the real book again (#1108)")
        #expect(Snapshot.usesSample(["KHAYT_SNAPSHOT_DIR": "/tmp/x", "KHAYT_LANG": "ar"]))
        #expect(!Snapshot.usesSample(["KHAYT_SNAPSHOT_DIR": "/tmp/x", "KHAYT_SNAPSHOT_REAL": "1"]))
        #expect(Snapshot.usesSample(["KHAYT_BOOK": "sample"]))
        // And no snapshot path opens the real book by its own road.
        let app = Self.source("KhaytApp.swift")
        let real = app.components(separatedBy: "Shop.available.first(where: \\.isReal)").count - 1
        let gated = app.components(separatedBy: "Snapshot.forcedSample ? .sample : (Shop.available.first(where: \\.isReal)").count - 1
        #expect(real - gated == 1, "a snapshot path loads the real book without asking forcedSample")
    }

    // MARK: The review's words

    @Test("every word the review added has English and Arabic, and none shadows one in Words.swift")
    func reviewWords() throws {
        for (key, langs) in ReviewWords.alpha58 {
            #expect(langs["en"]?.isEmpty == false, "\(key) has no English")
            #expect(langs["ar"]?.isEmpty == false, "\(key) has no Arabic")
            #expect(Words.own[key] == langs, "\(key) is shadowed by Words.base")
        }
        let base = Self.source("Words.swift")
        for key in ReviewWords.alpha58.keys {
            #expect(!base.contains("\"\(key)\":"), "\(key) is in both tables")
        }
    }
}
