import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The app's half of applying another Mac's vault changes
/// (`Shop+VaultApply.swift`): the book edits on records of any age, where
/// bytes may be written, the staff lock, the sample book, and the triggers.
/// The changes themselves are `VaultApplyTests`, against the vault stub.
@MainActor
struct VaultApplyAppTests {

    static func book(_ records: [[String: JSONValue]]) -> [String: JSONValue] {
        ["printFiles": .array(records.map(JSONValue.object))]
    }
    static func record(_ root: [String: JSONValue], _ id: String) -> [String: JSONValue]? {
        guard case .array(let rows)? = root["printFiles"] else { return nil }
        for case .object(let r) in rows where r["id"] == .string(id) { return r }
        return nil
    }

    /// What a record written by an older build looks like: none of the vault
    /// fields, no `contentHash`, no `rev`.
    static let old: [String: JSONValue] = [
        "id": .string("PF-old"), "name": .string("Bracket"),
        "sourceFile": .object(["filename": .string("bracket.stl"), "size": .number(10)]),
    ]

    @Test("the edits land on a record from an older build that has none of the new fields")
    func editsOnAnOldRecord() throws {
        var root = Self.book([Self.old])
        Shop.applyVaultEdits([.holds(recordId: "PF-old", fileId: "f1", sha256: "ab", size: 42)], at: "T1", to: &root)
        var r = try #require(Self.record(root, "PF-old"))
        #expect(r["vaultFileId"] == .string("f1") && r["contentHash"] == .string("ab"))
        guard case .object(let source)? = r["sourceFile"] else { Issue.record("sourceFile lost"); return }
        #expect(source["size"] == .number(42) && source["filename"] == .string("bracket.stl"))
        #expect(r["name"] == .string("Bracket"), "nothing else touched")
        #expect(r["rev"] != nil, "a real change is stamped, so it syncs")

        // Trashed elsewhere: archived, because of the vault.
        Shop.applyVaultEdits([.trashed(recordId: "PF-old", fileId: "f1")], at: "T2", to: &root)
        r = try #require(Self.record(root, "PF-old"))
        #expect(r["vaultTrashedAt"] == .string("T2") && r["archivedAt"] == .string("T2"))
        #expect(r["vaultArchived"] == .bool(true))
        // Restored elsewhere: un-archived, because the vault archived it.
        Shop.applyVaultEdits([.restored(recordId: "PF-old")], at: "T3", to: &root)
        r = try #require(Self.record(root, "PF-old"))
        #expect(r["vaultTrashedAt"] == nil && r["archivedAt"] == nil && r["vaultArchived"] == nil)
        // Purged: the link goes, the record stays.
        Shop.applyVaultEdits([.purged(recordId: "PF-old", onlyCopy: false)], at: "T4", to: &root)
        r = try #require(Self.record(root, "PF-old"))
        #expect(r["vaultFileId"] == nil && r["name"] == .string("Bracket"))
    }

    @Test("a new version marks the record's figures out of date; the same bytes do not")
    func figuresMarkedStale() throws {
        var measured = Self.old
        measured["contentHash"] = .string("old-hash")
        var root = Self.book([measured, ["id": .string("PF-nohash")], ["id": .string("PF-same"), "contentHash": .string("s")]])
        Shop.applyVaultEdits([.holds(recordId: "PF-old", fileId: "f1", sha256: "new-hash", size: 1),
                              .holds(recordId: "PF-nohash", fileId: "f2", sha256: "n", size: 1),
                              .holds(recordId: "PF-same", fileId: "f3", sha256: "s", size: 1)],
                             replaced: ["PF-nohash"], at: "T", to: &root)
        #expect(Self.record(root, "PF-old")?["figuresStaleFor"] == .string("new-hash"))
        #expect(Self.record(root, "PF-nohash")?["figuresStaleFor"] == .string("n"),
                "replaced here: stale even with no hash to compare")
        #expect(Self.record(root, "PF-same")?["figuresStaleFor"] == nil)
        // Read back as the inspector reads it.
        let file = try JSONDecoder().decode(LibraryFile.self,
                                            from: JSONEncoder().encode(JSONValue.object(Self.record(root, "PF-old")!)))
        #expect(file.figuresStale)
        let fresh = try JSONDecoder().decode(LibraryFile.self, from: JSONEncoder().encode(JSONValue.object(Self.old)))
        #expect(!fresh.figuresStale, "an old record without the field is not stale")
    }

    @Test("a re-measure replaces the old bytes' figures and clears the mark; the shop's own fields stay")
    func remeasureReplacesFigures() throws {
        var stale = Self.old
        stale["contentHash"] = .string("old"); stale["figuresStaleFor"] = .string("new")
        stale["geometryKey"] = .string("1:1.0:1x1x1"); stale["geometryReader"] = .number(1)
        stale["parsed"] = .object(["printTimeMins": .number(99), "filamentGrams": .number(12)])
        stale["colors"] = .array([.object(["hex": .string("#FF0000")])])
        var root = Self.book([stale])
        let read = Shop.DownloadedRead(hash: "new", key: nil, reader: 4, colours: [], swapCount: 0, thumbFile: nil,
                                       parsed: ["printTimeMins": .number(5)], size: 77, designer: nil, licence: nil)
        Shop.applyRemeasured(["PF-old": read], to: &root)
        let r = try #require(Self.record(root, "PF-old"))
        #expect(r["figuresStaleFor"] == nil && r["contentHash"] == .string("new"))
        #expect(r["parsed"] == .object(["printTimeMins": .number(5)]), "the new slicer figures, not the old")
        #expect(r["geometryKey"] == nil, "a new file that will not measure keeps no old geometry")
        #expect(r["meshTried"] != nil && r["geometryReader"] == .number(4))
        #expect(r["colors"] == stale["colors"] && r["name"] == .string("Bracket"))
    }

    @Test("kept-both copies are never backed up or freed: known by their marker, not their name")
    func keptCopiesAreNotUploaded() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "vault-kept-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let folder = tmp.appending(path: LibraryLocation.itemDirName("PF-k"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for n in ["part.stl", "part (vault v2).stl", "own (vault v9).stl"] { try Data(n.utf8).write(to: folder.appending(path: n)) }
        // Only the one VaultApply kept carries the marker; the other is the
        // shop's own file that happens to be named like one.
        let marker = VaultApply.KeptMarker(of: "part.stl", fileId: "f", version: 2)
        try JSONEncoder().encode(marker).write(to: VaultApply.keptMarkerURL(for: folder.appending(path: "part (vault v2).stl")))
        let listed = CloudLibrary.libraryFiles(root: tmp.path)
        #expect(listed.count == 3, "the marker is hidden: never listed as a file of its own")
        let rows: [JSONValue] = [.object(["id": .string("PF-k")])]
        let kept = CloudLibrary.ownFoldersOnly(listed, printFiles: rows, orders: []).map(\.filename).sorted()
        #expect(kept == ["own (vault v9).stl", "part.stl"])
        let roots = LibraryLocation.Roots(primary: tmp.path, mirror: nil, isCustom: true, roots: [tmp.path])
        let known = [LibraryLocation.itemDirName("PF-k") + "/part.stl": "f"]
        #expect(Shop.vaultKeptCopies(rows: rows, roots: roots, known: [:]).isEmpty,
                "a marker naming no vault file this Mac knows is not offered (security M3)")
        let found = Shop.vaultKeptCopies(rows: rows, roots: roots, known: known)
        #expect(found.map(\.copy.lastPathComponent) == ["part (vault v2).stl"])
        #expect(found.first?.mine.lastPathComponent == "part.stl" && found.first?.version == 2)
        #expect(try LockRound3Tests.source("CloudLibrary.swift").contains("if VaultApply.isKeptCopy(url) { continue }"),
                "the per-import backup skips them too")
    }

    @Test("a model the shop archived itself stays archived whatever the vault does")
    func shopsOwnArchiveStays() throws {
        var mine = Self.old
        mine["archivedAt"] = .string("SHOP")
        var root = Self.book([mine])
        Shop.applyVaultEdits([.trashed(recordId: "PF-old", fileId: "f1")], at: "T2", to: &root)
        Shop.applyVaultEdits([.restored(recordId: "PF-old")], at: "T3", to: &root)
        let r = try #require(Self.record(root, "PF-old"))
        #expect(r["archivedAt"] == .string("SHOP") && r["vaultArchived"] == nil)
    }

    @Test("an edit that changes nothing is not stamped, and a record not in the book is not made")
    func noOpIsNotStamped() throws {
        var root = Self.book([Self.old])
        Shop.applyVaultEdits([.purged(recordId: "PF-old", onlyCopy: false), .restored(recordId: "PF-old"),
                              .holds(recordId: "PF-gone", fileId: "f", sha256: "x", size: 1)], at: "T", to: &root)
        #expect(Self.record(root, "PF-old") == Self.old)
        #expect(Self.record(root, "PF-gone") == nil)
    }

    @Test("bytes are written only in a record's folder under the primary root, never the shop's own file")
    func whereBytesMayGo() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "vault-apply-\(UUID().uuidString)")
        let primary = tmp.appending(path: "Library"), past = tmp.appending(path: "Old")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: primary.appending(path: "PF-here"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: past.appending(path: "PF-past"), withIntermediateDirectories: true)
        let roots = LibraryLocation.Roots(primary: primary.path, mirror: nil, isCustom: true,
                                          roots: [primary.path, past.path])
        let rows: [JSONValue] = ["PF-here", "PF-past", "PF-new"].map { .object(["id": .string($0)]) }
            + [.object(["id": .string("PF-linked"), "externalPath": .string("/Users/shop/Models/x.stl")])]
        let library = Shop.vaultLibrary(rows: rows, roots: roots)
        func folder(_ id: String) -> URL? { library.folder(library.records[id]!) }
        #expect(folder("PF-here")?.standardizedFileURL.path == primary.appending(path: "PF-here").standardizedFileURL.path)
        #expect(folder("PF-new")?.path == primary.appending(path: "PF-new").path, "made there when it is needed")
        #expect(folder("PF-past") == nil, "a folder in a past location is never shadowed")
        #expect(library.records["PF-linked"]?.inPlace == true)
    }

    // That the changes then WAIT, unapplied and unsettled, is
    // `VaultApplyTests.lockedLosesNothing`.
    @Test("with the staff lock on and nobody allowed, nothing is applied")
    func staffLock() async {
        let shop = await OperatorLockTests.shop()
        #expect(shop.needsSignIn)
        #expect(await shop.applyVaultChanges() == .locked)
        #expect(shop.vaultAppliedAt == nil, "not counted as a pass: the next trigger tries again")
    }

    @Test("the sample book is never touched")
    func sampleUntouched() async {
        let shop = Shop()
        shop.useEngine(OperatorLockTests.sharedEngine)
        await shop.load(.sample)
        let before = shop.fileRows
        #expect(await shop.applyVaultChanges() == .sample)
        #expect(shop.fileRows == before)
    }

    @Test("it runs at launch and hourly, and when the Library opens on the vault")
    func wired() throws {
        func source(_ f: String) throws -> String {
            try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appending(path: "../../Sources/KhaytApp/\(f)").standardizedFileURL, encoding: .utf8)
        }
        let app = try source("KhaytApp.swift")
        let loop = try #require(app.range(of: "while !Task.isCancelled {\n                        await shop.verifyCloudCopiesIfDue()"))
        #expect(app[loop.upperBound...].prefix(300).contains("await shop.applyVaultChangesIfDue()"))
        let screen = try source("ScreenActions.swift")
        let vault = try #require(screen.range(of: "if shop.libraryOnVault {"))
        #expect(screen[vault.upperBound...].prefix(900).contains("await shop.applyVaultChangesIfDue()"))
        let banners = try source("Banners.swift")
        #expect(banners.contains("shop.resolveVaultConflict(kept, keepMine: true)")
                && banners.contains("shop.resolveVaultConflict(kept, keepMine: false)"))
        #expect(try source("Shop+VaultApply.swift").contains("if await remeasureStaleVaultModels(build: build, engine: engine, roots: roots) > 0"),
                "a pass measures again what it replaced")
        #expect(try source("LibraryInspector.swift").contains("if file.figuresStale { return true }"))
    }
}
