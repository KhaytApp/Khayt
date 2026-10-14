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
    @MainActor
    @Test("the async update waits for a busy chain without holding the main thread")
    func asyncUpdateWaitsOffMain() async throws {
        let url = try book()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // The chain busy for 400 ms — let go by the holding thread itself, so
        // nothing here depends on the cooperative pool (`noLostUpdates` fills
        // it with blocked synchronous writes).
        await withCheckedContinuation { (held: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                StoreWriter.serialised { held.resume(); Thread.sleep(forTimeInterval: 0.4) }
            }
        }
        // Work queued on the main thread for 100 ms from now: it runs on time
        // only if the main thread is free while the update waits.
        let start = Date()
        let ranAt = Stamp()
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
            ranAt.set(Date().timeIntervalSince(start))
        }
        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            await Task.yield()   // an async mutate: the async `update`, not the synchronous one
            Self.append("async", to: &root)
        }
        let returned = Date().timeIntervalSince(start)
        // And a synchronous write from main straight after still gets in.
        try StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            Self.append("sync", to: &root)
        }
        #expect(returned > 0.3, "the update did not wait for the chain")
        let ran = try #require(ranAt.value, "the main thread never got to its work")
        #expect(ran < 0.3, "the main thread was held while the chain was busy (ran at \(Int(ran * 1000)) ms)")
        let root = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        var ids = Set<String>()
        if case .array(let rows)? = root["counters"] {
            for case .object(let o) in rows { if case .string(let id)? = o["id"] { ids.insert(id) } }
        }
        #expect(ids == ["async", "sync"])
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

/// A time the main queue writes and the test reads.
private final class Stamp: @unchecked Sendable {
    private let lock = NSLock()
    private var at: TimeInterval?
    func set(_ t: TimeInterval) { lock.withLock { at = t } }
    var value: TimeInterval? { lock.withLock { at } }
}
