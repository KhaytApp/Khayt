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
}
