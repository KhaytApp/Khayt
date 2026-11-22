import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The scheduling behind automatic sync, and the hook that starts it.
///
/// SERIALIZED, because `StoreWriter.didWrite` is one global listener and there
/// is only ever one of it — a second test installing its own mid-run takes the
/// first one's writes with it. That is not a flaw in the hook: the app has
/// exactly one `Shop` listening, and making it a list to please a test runner
/// would be inventing a shape nothing uses. The tests below also ignore any
/// path outside their own temp directory, so a suite added later that writes a
/// store cannot make them pass or fail by accident.
@MainActor
@Suite(.serialized)
struct AutoSyncTests {

    // MARK: - Backoff

    /// Khayt's own shape: base, then doubling, then a ceiling it never passes.
    @Test("a failing sync backs off by doubling and stops at five minutes")
    func backoff() {
        #expect(AutoSync.retryDelay(attempt: 0) == .seconds(5))
        #expect(AutoSync.retryDelay(attempt: 1) == .seconds(10))
        #expect(AutoSync.retryDelay(attempt: 2) == .seconds(20))
        #expect(AutoSync.retryDelay(attempt: 5) == .seconds(160))
        // 5 · 2^6 = 320, past the ceiling.
        #expect(AutoSync.retryDelay(attempt: 6) == .seconds(300))
        // And it stays there rather than overflowing. A shop left offline over
        // a weekend reaches attempt numbers nobody writes a test for by hand,
        // and `base << steps` is an integer shift — 5 << 64 is not 5 minutes.
        #expect(AutoSync.retryDelay(attempt: 40) == .seconds(300))
        #expect(AutoSync.retryDelay(attempt: 10_000) == .seconds(300))
    }

    /// Nonsense in, something sane out — this feeds a sleep.
    @Test("a negative attempt is treated as the first one")
    func negativeAttempt() {
        #expect(AutoSync.retryDelay(attempt: -3) == .seconds(5))
    }

    // MARK: - The floor under whole-book pushes

    /// A shop whose delta chain the service has closed pushes its ENTIRE store
    /// every time, and on this app that means a backup, a merge, a rewrite of
    /// the book and a megabyte on the wire. Two and a half seconds after every
    /// edit would turn a day of typing into a hundred full uploads.
    @Test("the whole book waits fifteen minutes between pushes")
    func floor() {
        let now = Date()
        // Never pushed this session: always allowed. That first push is the one
        // carrying whatever changed while the app was closed.
        #expect(AutoSync.mayPushWholeBook(lastAt: nil, now: now))

        #expect(!AutoSync.mayPushWholeBook(lastAt: now, now: now))
        #expect(!AutoSync.mayPushWholeBook(lastAt: now.addingTimeInterval(-60), now: now))
        #expect(!AutoSync.mayPushWholeBook(lastAt: now.addingTimeInterval(-899), now: now))
        #expect(AutoSync.mayPushWholeBook(lastAt: now.addingTimeInterval(-900), now: now))
        #expect(AutoSync.mayPushWholeBook(lastAt: now.addingTimeInterval(-3600), now: now))
    }

    /// The floor is short enough that a second machine is never far behind, and
    /// long enough that the expensive path is not the normal one. Pinned so
    /// changing it is a decision rather than a typo.
    @Test("the floor is a quarter of an hour and the debounce is Khayt's")
    func constants() {
        #expect(AutoSync.wholeBookFloor == 15 * 60)
        #expect(AutoSync.debounce == .milliseconds(2500))
        #expect(AutoSync.retryBase == .seconds(5))
        #expect(AutoSync.retryCeiling == .seconds(300))
    }

    // MARK: - Whether a write is ours to send

    /// All three have to hold, and each of them is a different silence.
    ///
    /// This was an early return inside `bookChanged`, which is the worst place
    /// for this decision to live: when it answers no, nothing happens and
    /// nothing is said, and the shop learns about it from the other machine a
    /// week later.
    @Test("a write is pushed only when the cloud is on, unlocked, and this Mac owns the book")
    func theThreeConditions() {
        #expect(AutoSync.shouldSyncOnWrite(unlocked: true, connected: true, canWrite: true))

        // Locked: the key lives no longer than the app, by design.
        #expect(!AutoSync.shouldSyncOnWrite(unlocked: false, connected: true, canWrite: true))
        // No cloud on this book, or the sample shop.
        #expect(!AutoSync.shouldSyncOnWrite(unlocked: true, connected: false, canWrite: true))
        // Read-only: Khayt has the book, and Khayt is syncing it.
        #expect(!AutoSync.shouldSyncOnWrite(unlocked: true, connected: true, canWrite: false))
    }

    // MARK: - The hook that makes any of it happen

    /// THE WIRING PROOF.
    ///
    /// Twenty-one places in `Shop` change the book. Automatic sync hears about
    /// them through one hook inside `atomicWrite`, which is where every write
    /// actually lands — so this test is really asking whether a write path
    /// added next month will be heard without anybody remembering to say so.
    ///
    /// Delete the `didWrite` call in `StoreWriter.atomicWrite` and this fails.
    @Test("every successful write tells the listener, whichever path wrote it")
    func writesAreHeard() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "khayt-autosync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appending(path: "khayt-store.json")
        try Data(#"{"printLog":[]}"#.utf8).write(to: store)

        let heard = Heard()
        StoreWriter.didWrite = { url in if url == store { heard.note(url) } }
        defer { StoreWriter.didWrite = nil }

        // The synchronous path.
        try StoreWriter.update(storeURL: store, owns: { true }, whoHasIt: { nil }) { root in
            root["marker"] = .string("one")
        }
        // …and the async one, which is a separate implementation and would be
        // the easy one to forget.
        try await StoreWriter.update(storeURL: store, owns: { true }, whoHasIt: { nil }) { root in
            root["marker"] = .string("two")
        }

        try await Task.sleep(for: .milliseconds(300))   // the hook hops to the main actor
        #expect(heard.urls.count == 2)
        #expect(heard.urls.allSatisfy { $0 == store })
    }

    /// A write that was REFUSED changed nothing, and must not schedule a push
    /// of something that is not in the book. The book is not ours here, which
    /// is the ordinary case on a Mac where Khayt has the store open.
    @Test("a refused write says nothing")
    func refusedWritesAreSilent() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "khayt-autosync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appending(path: "khayt-store.json")
        try Data(#"{"printLog":[]}"#.utf8).write(to: store)

        let heard = Heard()
        StoreWriter.didWrite = { url in if url == store { heard.note(url) } }
        defer { StoreWriter.didWrite = nil }

        #expect(throws: (any Error).self) {
            try StoreWriter.update(storeURL: store, owns: { false },
                                   whoHasIt: { "Khayt has it" }) { root in
                root["marker"] = .string("nope")
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(heard.urls.isEmpty)
    }

    /// Somewhere to collect what the hook said, from the main actor it fires on.
    @MainActor final class Heard {
        var urls: [URL] = []
        func note(_ url: URL) { urls.append(url) }
    }
}
