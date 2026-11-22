import Foundation
import Testing
@testable import KhaytCore

/// Writes off the main thread must still never overtake each other.
///
/// Every write used to run on the main thread, and that alone kept a read
/// inside one write from being overtaken by another's swap. `updateOffMain`
/// gives that up, so the write chain has to give it back — and a lost update
/// is silent: the book is valid JSON, it just no longer has the shop's change.
struct StoreWriteChainTests {

    private func book() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-chain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "khayt-store.json")
        let root: [String: JSONValue] = ["counters": .array([]), "settings": .object([:])]
        try JSONEncoder().encode(root).write(to: url)
        return url
    }

    private static func append(_ tag: String, to root: inout [String: JSONValue]) {
        var rows: [JSONValue] = []
        if case .array(let r)? = root["counters"] { rows = r }
        rows.append(.object(["id": .string(tag)]))
        root["counters"] = .array(rows)
    }

    @Test("off-main writes and synchronous writes interleaved lose nothing")
    func noLostUpdates() async throws {
        let url = try book()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<12 {
                group.addTask {
                    _ = try? await StoreWriter.updateOffMain(storeURL: url, owns: { true },
                                                             whoHasIt: { nil }) { root -> Bool in
                        Self.append("off-\(i)", to: &root)
                        return true
                    }
                }
                group.addTask {
                    try? StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
                        Self.append("sync-\(i)", to: &root)
                    }
                }
            }
        }
        let root = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        var ids = Set<String>()
        if case .array(let rows)? = root["counters"] {
            for case .object(let o) in rows { if case .string(let id)? = o["id"] { ids.insert(id) } }
        }
        #expect(ids.count == 24, "a write was overtaken and lost: \(24 - ids.count) missing")
    }

    @Test("work already on the chain may ask for the chain again without waiting on itself (never to write)")
    func reentrant() async throws {
        let url = try book()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let nested = try await StoreWriter.updateOffMain(storeURL: url, owns: { true },
                                                         whoHasIt: { nil }) { _ -> Int in
            StoreWriter.serialised { 7 }
        }
        #expect(nested == 7)
    }

    /// The async `update`'s compare-and-swap waited for the chain with
    /// `chain.sync` on the main thread: a scan's whole-book write ahead of it
    /// froze the window for its full length.
    ///
    /// Checked by what the code DOES, not by asking the main thread to answer
    /// while the chain is held. That first version deadlocked on CI and only
    /// there: other suites run beside this one, and one of them doing a
    /// synchronous write on the main thread waited for the chain this test
    /// held, while this test waited for the main thread (Oct 14 2026). A test
    /// must not hold the chain and wait on anything outside it, which is the
    /// rule the code keeps too.
    @Test("the async update takes the chain without holding its caller's thread")
    func asyncUpdateNeverWaitsOnTheCallersThread() throws {
        let source = try Self.writerSource()
        let start = try #require(source.range(of: "owns: @Sendable () -> Bool,"),
                                 "the async update's signature moved")
        let end = try #require(source.range(of: "// MARK: - The write chain", range: start.upperBound..<source.endIndex))
        // The code only: the comments there tell the story of `serialised`.
        let body = source[start.upperBound..<end.lowerBound]
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(body.contains("try await onChain {"), "the swap no longer waits for the chain off the caller's thread")
        #expect(!body.contains("serialised"), "the swap waits for the chain with chain.sync on the caller's thread again")
        #expect(!body.contains("chain.sync"), "the swap waits for the chain with chain.sync on the caller's thread again")
    }

    @Test("an async update behind a busy chain waits for it and loses nothing")
    func asyncUpdateBehindABusyChain() async throws {
        let url = try book()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // The chain held for a moment by another writer that waits on nothing
        // outside it, and lets go by itself.
        await withCheckedContinuation { (held: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                StoreWriter.serialised {
                    held.resume()
                    Thread.sleep(forTimeInterval: 0.3)
                }
            }
        }
        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            await Task.yield()   // an async mutate: the async `update`, not the synchronous one
            Self.append("async", to: &root)
        }
        try StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            Self.append("sync", to: &root)
        }
        let root = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        var ids = Set<String>()
        if case .array(let rows)? = root["counters"] {
            for case .object(let o) in rows { if case .string(let id)? = o["id"] { ids.insert(id) } }
        }
        #expect(ids == ["async", "sync"])
    }

    static func writerSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Tests/KhaytCoreTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/KhaytCore
            .appending(path: "Sources/KhaytCore/StoreWriter.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("a refused write throws, and the book is untouched")
    func refusal() async throws {
        let url = try book()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let before = try Data(contentsOf: url)
        await #expect(throws: StoreWriter.Refusal.self) {
            _ = try await StoreWriter.updateOffMain(storeURL: url, owns: { false },
                                                    whoHasIt: { "Khayt" }) { root -> Bool in
                Self.append("never", to: &root)
                return true
            }
        }
        #expect(try Data(contentsOf: url) == before)
    }
}
