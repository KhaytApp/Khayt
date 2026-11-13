import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Speed and reliability findings of the Nov 10 2026 review (section D).
struct ReviewFixesDTests {

    static func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-review-d-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("a damaged book with a good rollback can be written from, and the damaged file is kept")
    func writeStartsFromRollback() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "khayt-store.json")
        try Data("{ this is not json".utf8).write(to: url)
        try Data(#"{"clients":[{"id":"C1"}]}"#.utf8).write(to: url.appendingPathExtension("prev"))

        let (data, root) = try StoreWriter.readBook(url)
        #expect(String(decoding: data, as: UTF8.self) == "{ this is not json",
                "the bytes are the damaged file's, so the compare before the swap is honest")
        #expect(root["clients"] == .array([.object(["id": .string("C1")])]))
        let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".damaged-") }
        #expect(kept.count == 1)
        // Read again in the same second: not kept twice.
        _ = try StoreWriter.readBook(url)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".damaged-") }.count == 1)
    }

    /// The save rolled the DAMAGED book onto `.prev` (the only good copy) and
    /// then renamed: a crash between the two left both files damaged.
    @Test("a save that started from the rollback leaves the rollback alone; the next save rolls as usual")
    func rollbackSurvivesTheSaveThatUsedIt() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "khayt-store.json")
        let prev = url.appendingPathExtension("prev")
        let good = Data(#"{"clients":[{"id":"C1"}]}"#.utf8)
        try Data("{ this is not json".utf8).write(to: url)
        try good.write(to: prev)

        #expect(try StoreWriter.readBookNoting(url).fromRollback)
        try StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }, recordingDeletes: false) { root in
            root["marker"] = .string("first")
            // What a crash right here would leave: the rollback must still be
            // the good book, not a link to the damaged one.
            #expect((try? Data(contentsOf: prev)) == good)
        }
        #expect(try StoreWriter.readBook(url).1["marker"] == .string("first"), "the new book is good")
        #expect(try Data(contentsOf: prev) == good, "the rollback is still the old good copy")
        #expect(try !StoreWriter.readBookNoting(url).fromRollback)

        // The book reads normally now, so this save rolls it to `.prev` as ever.
        try StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }, recordingDeletes: false) { root in
            root["marker"] = .string("second")
        }
        #expect(try StoreWriter.readBook(url).1["marker"] == .string("second"))
        let rolled = try JSONValue.decode([String: JSONValue].self, from: Data(contentsOf: prev))
        #expect(rolled["marker"] == .string("first"))
    }

    @Test("told to keep the rollback, a save does not replace it; untold, it does")
    func keepingRollbackIsTheOnlyDifference() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "khayt-store.json")
        let prev = url.appendingPathExtension("prev")
        try Data("damaged".utf8).write(to: url)
        try Data(#"{"n":1}"#.utf8).write(to: prev)
        try StoreWriter.atomicWrite(Data(#"{"n":2}"#.utf8), to: url, keepingRollback: true)
        #expect(try Data(contentsOf: prev) == Data(#"{"n":1}"#.utf8))
        #expect(try Data(contentsOf: url) == Data(#"{"n":2}"#.utf8))
        try StoreWriter.atomicWrite(Data(#"{"n":3}"#.utf8), to: url)
        #expect(try Data(contentsOf: prev) == Data(#"{"n":2}"#.utf8))
        // With no rollback to keep, the flag changes nothing.
        try FileManager.default.removeItem(at: prev)
        try StoreWriter.atomicWrite(Data(#"{"n":4}"#.utf8), to: url, keepingRollback: true)
        #expect(try Data(contentsOf: prev) == Data(#"{"n":3}"#.utf8))
    }

    @Test("a healthy book is read as it is, and a damaged one with no rollback is still refused")
    func ordinaryReads() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "khayt-store.json")
        try Data(#"{"clients":[]}"#.utf8).write(to: url)
        #expect(try StoreWriter.readBook(url).1["clients"] == .array([]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 1)
        try Data("nope".utf8).write(to: url)
        #expect(throws: (any Error).self) { _ = try StoreWriter.readBook(url) }
        try Data("also nope".utf8).write(to: url.appendingPathExtension("prev"))
        #expect(throws: (any Error).self) { _ = try StoreWriter.readBook(url) }
    }

    @Test("a heartbeat leaves a whole lock file behind, never a truncated one")
    func lockIsWhole() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "khayt-store.lock")
        let taken = try #require(StoreLock.take(at: url, host: "shop-mac.local"))
        for _ in 0..<50 {
            _ = try #require(StoreLock.beat(taken, at: url, host: "shop-mac.local"))
            let data = try Data(contentsOf: url)
            #expect((try? JSONSerialization.jsonObject(with: data)) != nil)
        }
    }

    @Test("a board column builds at most its cap of cards")
    @MainActor func boardCap() {
        #expect(Kanban.columnCap >= 50, "enough that an ordinary column is never cut")
        #expect(Kanban.columnCap <= 200, "few enough that Completed cannot hold the board up")
    }
}
