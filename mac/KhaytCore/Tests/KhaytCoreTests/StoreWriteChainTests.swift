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
    /// Asked of the main thread by the write holding the chain, not timed by
    /// a clock: the whole suite shares the main thread, so a stopwatch here
    /// measured the other tests. A main thread stuck in `chain.sync` behind
    /// the holder cannot answer it at all.
    @MainActor
    @Test("the async update waits for a busy chain without holding the main thread")
    func asyncUpdateWaitsOffMain() async throws {
        let url = try book()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let answered = Answer()
        // The chain held by another writer, which — once the update is
        // waiting behind it — asks the main thread to do one small thing.
        // Let go by the holding thread itself, so nothing depends on the
        // cooperative pool (`noLostUpdates` fills it with blocked writes).
        await withCheckedContinuation { (held: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                StoreWriter.serialised {
                    held.resume()
                    Thread.sleep(forTimeInterval: 0.2)
                    let main = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async { main.signal() }
                    answered.set(main.wait(timeout: .now() + 3) == .success)
                }
            }
        }
        try await StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            await Task.yield()   // an async mutate: the async `update`, not the synchronous one
            Self.append("async", to: &root)
        }
        // And a synchronous write from main straight after still gets in.
        try StoreWriter.update(storeURL: url, owns: { true }, whoHasIt: { nil }) { root in
            Self.append("sync", to: &root)
        }
        #expect(answered.value == true, "the main thread was held while the chain was busy")
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

/// What the holding writer heard back from the main thread.
private final class Answer: @unchecked Sendable {
    private let lock = NSLock()
    private var got: Bool?
    func set(_ v: Bool) { lock.withLock { got = v } }
    var value: Bool? { lock.withLock { got } }
}
