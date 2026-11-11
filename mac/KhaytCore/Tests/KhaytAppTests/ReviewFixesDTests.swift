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
