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
        Shop.applyVaultEdits([.purged(recordId: "PF-old")], at: "T4", to: &root)
        r = try #require(Self.record(root, "PF-old"))
        #expect(r["vaultFileId"] == nil && r["name"] == .string("Bracket"))
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
        Shop.applyVaultEdits([.purged(recordId: "PF-old"), .restored(recordId: "PF-old"),
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
        #expect(try source("Banners.swift").contains("shop.vaultConflictNote"))
    }
}
