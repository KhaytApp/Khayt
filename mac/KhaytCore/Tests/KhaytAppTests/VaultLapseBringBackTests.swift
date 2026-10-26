import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Beta.8: before the vault deletes what is over its plan, the Mac names the
/// models whose only copy is in the vault and offers to bring exactly those
/// back; after, Library Health says the plan deleted them. On temporary
/// folders and the sample book only — no cloud, no real book.
@MainActor
struct VaultLapseBringBackTests {

    static func file(_ id: String, own: String = "model.stl", extra: [String: JSONValue] = [:]) throws -> LibraryFile {
        var o: [String: JSONValue] = ["id": .string(id), "name": .string(id), "title": .string(id),
                                      "sourceFile": .object(["filename": .string(own)])]
        for (k, v) in extra { o[k] = v }
        return try JSONDecoder().decode(LibraryFile.self, from: JSONEncoder().encode(JSONValue.object(o)))
    }

    /// A library folder with one model folder per entry: `side` the sidecar's
    /// provider (nil: no sidecar), `bytes` whether the model file is there.
    static func library(_ models: [(id: String, side: String?, bytes: Bool)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "khayt-vo-\(UUID().uuidString)")
        for m in models {
            let dir = root.appending(path: LibraryLocation.itemDirName(m.id))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let side = m.side {
                try Data(#"{"v":1,"size":5,"sha256":"ab","key":"k","provider":"\#(side)"}"#.utf8)
                    .write(to: dir.appending(path: "model.stl.cloud"))
            }
            if m.bytes { try Data("solid".utf8).write(to: dir.appending(path: "model.stl")) }
        }
        return root
    }

    @Test("only the models whose ONLY copy is the vault's are counted")
    func counts() throws {
        let root = try Self.library([("PF-vault", "vault", false), ("PF-both", "vault", true),
                                     ("PF-bucket", "https://s3.example.com", false), ("PF-here", nil, true)])
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try ["PF-vault", "PF-both", "PF-bucket", "PF-here", "PF-nofolder"].map { try Self.file($0) }
        #expect(Shop.vaultOnlyModels(files, roots: [root.path]) == ["PF-vault"])
        // Archived, linked: never counted.
        let archived = try Self.file("PF-vault", extra: ["archivedAt": .string("2026-10-01")])
        #expect(Shop.vaultOnlyModels([archived], roots: [root.path]).isEmpty)
    }

    @Test("the count follows the lapse: cleared once the vault is not over")
    func countFollowsLapse() async {
        let shop = Shop()
        await shop.load(.sample)
        shop.vaultOnlyIds = ["PF-sample-falcon"]
        shop.vaultLapse = .notOver
        await shop.countVaultOnlyModels()
        #expect(shop.vaultOnlyIds.isEmpty)
        #expect(shop.vaultOnlyOffer == nil)
    }

    @Test("the button names the date when the cloud set one, and read-only otherwise, in English and Arabic")
    func words() async throws {
        let engine = try KhaytEngine()
        let end = Calendar.instant("2027-01-23T09:00:00Z")!
        for lang in ["en", "ar"] {
            let w = Words(); await w.load(lang, engine: engine)
            let dated = try #require(Shop.vaultOnlyButton(.before(end), count: 3, w))
            #expect(dated.contains(Shop.day(end, w)) && dated.contains(w.counting(3, "mac.n_models")))
            let ro = try #require(Shop.vaultOnlyButton(.whileReadOnly, count: 1, w))
            #expect(ro != dated && !ro.contains("{"))
            #expect(Shop.vaultOnlyButton(nil, count: 3, w) == nil)
            #expect(Shop.vaultOnlyWarning(count: 0, w) == nil)
            let warn = try #require(Shop.vaultOnlyWarning(count: 2, w))
            #expect(!warn.contains("{"))
            for key in ["mac.lapse_vault_only", "mac.lapse_bring_back_before", "mac.lapse_bring_back_read_only",
                        "mac.lapse_bringing_back", "mac.lh_plan_deleted", "mac.lh_plan_deleted_says"] {
                #expect(w.callIt(key) != key, "\(key) has no \(lang)")
            }
        }
        #expect(Words.own["mac.lapse_vault_only"]?["ar"]?.contains("الخزنة") == true)
    }

    @Test("Bring Back asks the staff lock, runs in batches, and reaches only the vault's sidecars")
    func bringBackIsGated() {
        let src = MenuCoverageTests.source("Shop+VaultOnly.swift")
        #expect(src.contains("guard permitted(\"inventory\", \"edit\") else"))
        #expect(src.contains("for batch in VaultOnlyCopies.batches(ids)"))
        #expect(src.contains("await PinWork.run"), "the folders are read off the main actor")
        #expect(src.contains("$0.provider == VaultOnlyCopies.vaultProvider && !$0.bytesHere"))
        // The banner and the plan pane both carry it.
        let lapse = MenuCoverageTests.source("Shop+VaultLapse.swift")
        #expect(lapse.components(separatedBy: "VaultOnlyOffer(shop: shop").count - 1 == 2)
    }

    // MARK: After deletion

    @Test("a purge stamps the record only when it had a vault copy, and the vault holding it again clears it")
    func purgeStamp() throws {
        var root: [String: JSONValue] = ["printFiles": .array([
            .object(["id": .string("PF-a"), "name": .string("A"), "vaultFileId": .string("f1")]),
            .object(["id": .string("PF-b"), "name": .string("B")]),
        ])]
        Shop.applyVaultEdits([.purged(recordId: "PF-a"), .purged(recordId: "PF-b")], at: "T9", to: &root)
        func rec(_ id: String) -> [String: JSONValue]? {
            guard case .array(let rows)? = root["printFiles"] else { return nil }
            for case .object(let r) in rows where r["id"] == .string(id) { return r }
            return nil
        }
        #expect(rec("PF-a")?["vaultPurgedAt"] == .string("T9") && rec("PF-a")?["vaultFileId"] == nil)
        #expect(rec("PF-b")?["vaultPurgedAt"] == nil)
        Shop.applyVaultEdits([.holds(recordId: "PF-a", fileId: "f2", sha256: "ab", size: 5)], at: "T10", to: &root)
        #expect(rec("PF-a")?["vaultPurgedAt"] == nil && rec("PF-a")?["vaultFileId"] == .string("f2"))
    }

    @Test("Health calls a purged vault-only model deleted by the plan, not missing and not online")
    func healthSaysDeletedByPlan() throws {
        let root = try Self.library([("PF-gone", "vault", false), ("PF-kept", "vault", true), ("PF-online", "vault", false)])
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: root.appending(path: ".keep"))
        let purged: [String: JSONValue] = ["vaultPurgedAt": .string("2027-01-23T09:00:00Z")]
        let files = [try Self.file("PF-gone", extra: purged), try Self.file("PF-kept", extra: purged),
                     try Self.file("PF-online")]
        let p = Shop.healthPresence(files, roots: [root.path], online: ["PF-gone", "PF-online"],
                                    linkedOnline: { _ in false })
        #expect(p["PF-gone"] == .deletedByPlan)
        #expect(p["PF-kept"] == .here, "its bytes are on this Mac")
        #expect(p["PF-online"] == .online, "never purged: the vault still holds it")
        let groups = LibraryHealth.groups(models: files.map { Shop.healthModel($0, presence: p[$0.id]!) })
        #expect(groups.first?.kind == .deletedByPlan && groups.first?.modelIds == ["PF-gone"])
    }

    @Test("its card offers Remove from Library and no Locate")
    func healthCardFixes() {
        let view = MenuCoverageTests.source("LibraryHealthView.swift")
        #expect(view.contains("case .missing, .deletedByPlan:"))
        #expect(view.contains("if group.kind == .missing {"), "Locate is for missing files only")
        #expect(LibraryHealthView.look(.deletedByPlan).title == "mac.lh_plan_deleted")
        #expect(MenuCoverageTests.source("Shop+LibraryHealth.swift")
            .contains("group.kind == .missing || group.kind == .deletedByPlan"))
    }
}

/// Beta.8 follow-ups: counts and the menu bar no longer wait for a screen.
@MainActor
struct Beta8FollowUpTests {

    @Test("Ready to print is counted without the Library screen ever being opened")
    func readyWithoutTheLibrary() async throws {
        let shop = Shop()
        await shop.load(.sample)
        #expect(!shop.showingLibrary)
        await shop.settleLibraryFacets()
        // The sample's U1 has the Kings' colours loaded.
        #expect(shop.readyByMachine["MACH-u1"]?.contains("PF-sample-king-2") == true)
        let counted = shop.libraryCount(LibrarySmartFolder.ready.query)
        #expect(counted > 0)
        // A recount cut short (cancelled with the view that started it, or
        // overtaken) used to leave the sets as they were until the Library
        // screen started another. They are put right on their own now.
        shop.readyByMachine = [:]
        shop.spoolReadyByMachine = [:]
        #expect(shop.libraryCount(LibrarySmartFolder.ready.query) == 0)
        await shop.refreshReadiness()
        #expect(shop.libraryCount(LibrarySmartFolder.ready.query) == counted)
        #expect(!shop.showingLibrary)
        let src = MenuCoverageTests.source("Shop.swift")
        #expect(src.contains("await readLibraryFacets()\n            // The ready sets again on their own"))
        #expect(MenuCoverageTests.source("Shop+Library.swift").contains("Task { await refreshReadiness() }"),
                "a spool swap puts the sets right without the chips' recount")
    }

    @Test("the dispatcher is asked after every sweep, so the menu bar's Bed not cleared is fresh off the Machines screen")
    func dispatchAfterEverySweep() {
        let shop = MenuCoverageTests.source("Shop.swift")
        guard let start = shop.range(of: "func printersAnswered() async {"),
              let end = shop.range(of: "\n    }\n", range: start.upperBound..<shop.endIndex) else {
            Issue.record("printersAnswered not found"); return
        }
        #expect(shop[start.upperBound..<end.lowerBound].contains("await planDispatch()"))
    }
}
