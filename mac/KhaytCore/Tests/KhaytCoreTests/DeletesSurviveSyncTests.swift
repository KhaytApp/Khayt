import Foundation
import Testing
@testable import KhaytCore

/// A record deleted on the Mac stays deleted after the next sync.
///
/// It did not. The Mac wrote no tombstone, so the cloud merge that runs before
/// every send found the record in the cloud's copy and put it back. The shop
/// saw its deletes come back and could only make them stick by taking the
/// cloud's copy.
struct DeletesSurviveSyncTests {

    static func product(_ id: String, rev: Double) -> JSONValue {
        .object(["id": .string(id), "nameEn": .string(id), "rev": .number(rev)])
    }

    static func book(_ ids: [String]) -> [String: JSONValue] {
        ["products": .array(ids.map { product($0, rev: 3) }),
         "printLog": .array([]),
         "settings": .object([:])]
    }

    static func tempBook(_ root: [String: JSONValue]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "deletes-\(UUID().uuidString)").appending(path: "khayt-store.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(root).write(to: url)
        return url
    }

    static func read(_ url: URL) throws -> [String: JSONValue] {
        try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
    }

    static func tombs(_ root: [String: JSONValue]) -> [[String: JSONValue]] {
        guard case .array(let t)? = root["tombstones"] else { return [] }
        return t.compactMap { if case .object(let o) = $0 { return o } else { return nil } }
    }

    @Test("a write that removes a record leaves a tombstone carrying the deleted rev")
    func deleteLeavesATombstone() throws {
        let url = try Self.tempBook(Self.book(["A", "B"]))
        try StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            root["products"] = .array([Self.product("A", rev: 3)])
        }
        let t = Self.tombs(try Self.read(url))
        #expect(t.count == 1)
        #expect(t.first?["id"] == .string("B"))
        #expect(t.first?["collection"] == .string("products"))
        #expect(t.first?["rev"] == .number(3))
        if case .string(let at)? = t.first?["deletedAt"] { #expect(at.hasSuffix("Z")) } else { Issue.record("no deletedAt") }
    }

    @Test("an edit leaves no tombstone, and a record already tombstoned is not tombstoned twice")
    func onlyRealDeletes() throws {
        var root = Self.book(["A"])
        var after = root
        after["products"] = .array([Self.product("A", rev: 4)])
        StoreWriter.recordDeletions(before: root, after: &after)
        #expect(Self.tombs(after).isEmpty)

        root["tombstones"] = .array([.object(["id": .string("A"), "collection": .string("products"),
                                              "rev": .number(3), "deletedAt": .string("2026-09-01T00:00:00.000Z")])])
        after = root
        after["products"] = .array([])
        StoreWriter.recordDeletions(before: root, after: &after)
        #expect(Self.tombs(after).count == 1)
    }

    @Test("ids are per collection: a deleted product does not hide a job with the same id")
    func perCollection() {
        var root = Self.book(["X"])
        root["printLog"] = .array([Self.product("X", rev: 1)])
        var after = root
        after["products"] = .array([])
        StoreWriter.recordDeletions(before: root, after: &after)
        #expect(Self.tombs(after).map { $0["collection"] } == [.string("products")])
    }

    @Test("a merge write opts out and records nothing")
    func mergeOptsOut() throws {
        let url = try Self.tempBook(Self.book(["A", "B"]))
        try StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }, recordingDeletes: false) { root in
            root["products"] = .array([Self.product("A", rev: 3)])
        }
        #expect(Self.tombs(try Self.read(url)).isEmpty)
    }

    @Test("the list is capped as the desktop caps it, keeping the newest")
    func capped() {
        let old: [JSONValue] = (0..<StoreWriter.tombstoneCap).map {
            .object(["id": .string("old\($0)"), "collection": .string("products"), "rev": .number(1),
                     "deletedAt": .string("2026-01-01T00:00:00.000Z")])
        }
        var root = Self.book(["A"])
        root["tombstones"] = .array(old)
        var after = root
        after["products"] = .array([])
        StoreWriter.recordDeletions(before: root, after: &after)
        let t = Self.tombs(after)
        #expect(t.count == StoreWriter.tombstoneCap)
        #expect(t.last?["id"] == .string("A"))
    }

    /// The bug itself, end to end through the shared merge the send path runs.
    @Test("deleted here, still in the cloud: the merge before a send keeps it deleted")
    func survivesTheMerge() async throws {
        let engine = try KhaytEngine()
        let url = try Self.tempBook(Self.book(["A", "B"]))
        try StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            root["products"] = .array([Self.product("A", rev: 3)])
        }
        let local = try Self.read(url)
        let cloud = Self.book(["A", "B"])
        let merged = try await engine.mergeFromCloud(local: local, server: cloud)
        guard case .array(let products)? = merged.store["products"] else { Issue.record("no products"); return }
        let ids = products.compactMap { row -> String? in
            if case .object(let o) = row, case .string(let id)? = o["id"] { return id } else { return nil }
        }
        #expect(ids == ["A"], "the cloud's copy put the deleted record back")

        // And the send carries the delete to the cloud.
        let outbox = try await engine.changesToSend(local: merged.store, server: cloud)
        #expect(outbox.tombstones.count == 1)
    }

    /// Undo after a delete. The tombstone has usually reached the cloud by then,
    /// and a delete there wins over the same id for good.
    @Test("a record put back after a delete comes back under a new id, with its links, and survives the merge")
    func undoSurvivesTheSync() async throws {
        var root = Self.book(["A", "B"])
        root["printLog"] = .array([.object(["id": .string("J1"), "productId": .string("B"), "rev": .number(1)])])
        root["settings"] = .object(["storefront": .object(["prices": .object(["B": .string("40")])])])
        let url = try Self.tempBook(root)

        // Delete B: the job loses its link, as deleteProduct does.
        try StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { r in
            r["products"] = .array([Self.product("A", rev: 3)])
            r["printLog"] = .array([.object(["id": .string("J1"), "productId": .null, "rev": .number(2)])])
        }
        let deleted = try Self.read(url)
        #expect(Self.tombs(deleted).map { $0["id"] } == [.string("B")])

        // Undo: B and the job's link come back under the old id.
        try StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { r in
            r["products"] = .array([Self.product("A", rev: 3), Self.product("B", rev: 3)])
            r["printLog"] = .array([.object(["id": .string("J1"), "productId": .string("B"), "rev": .number(2)])])
        }
        let undone = try Self.read(url)
        guard case .array(let products)? = undone["products"],
              case .object(let revived)? = products.last,
              case .string(let newId)? = revived["id"] else { Issue.record("no revived record"); return }
        #expect(newId != "B")
        if case .number(let rev)? = revived["rev"] { #expect(rev > 3) } else { Issue.record("not stamped") }
        guard case .array(let log)? = undone["printLog"], case .object(let job)? = log.first else { Issue.record("no job"); return }
        #expect(job["productId"] == .string(newId), "the job still points at the deleted id")
        if case .number(let rev)? = job["rev"] { #expect(rev > 2) } else { Issue.record("job not stamped") }
        guard case .object(let settings)? = undone["settings"], case .object(let sf)? = settings["storefront"],
              case .object(let prices)? = sf["prices"] else { Issue.record("no prices"); return }
        #expect(prices[newId] == .string("40"))
        #expect(prices["B"] == nil)

        // The cloud already holds B's tombstone. The revived record survives it.
        let engine = try KhaytEngine()
        var cloud = Self.book(["A"])
        cloud["tombstones"] = deleted["tombstones"]
        let merged = try await engine.mergeFromCloud(local: undone, server: cloud)
        guard case .array(let after)? = merged.store["products"] else { Issue.record("no products"); return }
        #expect(after.contains { if case .object(let o) = $0 { return o["id"] == .string(newId) } else { return false } })
        let outbox = try await engine.changesToSend(local: merged.store, server: cloud)
        #expect(outbox.deltas.contains { if case .object(let d) = $0, case .object(let r)? = d["record"] { return r["id"] == .string(newId) } else { return false } })
    }

    @Test("a record removed and re-added in ONE write keeps its id")
    func sameWriteKeepsId() {
        var root = Self.book(["A"])
        root["tombstones"] = .array([])
        var after = root
        after["products"] = .array([Self.product("A", rev: 4)])
        StoreWriter.reviveUnderNewIds(before: root, after: &after)
        guard case .array(let p)? = after["products"], case .object(let a)? = p.first else { return }
        #expect(a["id"] == .string("A"))
    }

    @Test("a fresh id keeps the old prefix")
    func freshIdPrefix() {
        let id = StoreWriter.freshId(like: "PROD-mth8nqkoVJC")
        #expect(id.hasPrefix("PROD-"))
        #expect(id != "PROD-mth8nqkoVJC")
    }
}
