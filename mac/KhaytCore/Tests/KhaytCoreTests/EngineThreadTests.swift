import Foundation
import Testing
@testable import KhaytCore

/// JavaScriptCore runs on the engine's own thread — never the main thread,
/// never a 512 KB pool thread — and calls still run one at a time, in order.
struct EngineThreadTests {

    @Test("engine calls run on the engine's own big-stack thread, not the main one")
    @MainActor
    func callsRunOnItsThread() async throws {
        // Made on the main thread, as `Shop` makes it.
        let engine = try KhaytEngine()
        let place = await engine.whereItRuns()
        #expect(place.onItsThread)
        #expect(!place.isMain)
        #expect(place.stackBytes >= EngineThread.stackBytes)
    }

    @Test("concurrent callers are served one at a time, every answer intact")
    func concurrentCallersAreSerial() async throws {
        let engine = try KhaytEngine()
        let rows: [JSONValue] = (0..<2_000).map { i in
            .object(["id": .string("r\(i)"), "category": .string("Category \(i % 37)")])
        }
        let answers = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<16 {
                group.addTask { ((try? await engine.categoryCounts(rows)) ?? []).count }
            }
            var all: [Int] = []
            for await n in group { all.append(n) }
            return all
        }
        #expect(answers == Array(repeating: 37, count: 16))
    }

    @Test("an engine that goes away is let go")
    func engineIsReleased() async throws {
        weak var gone: KhaytEngine?
        do {
            let engine = try KhaytEngine()
            gone = engine
            _ = await engine.whereItRuns()
        }
        // Released once the last call has returned; give the hop back a moment.
        for _ in 0..<200 where gone != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(gone == nil)
    }

    /// #1867 gave every engine a thread of its own, and the test bundle keeps
    /// hundreds of engines alive at once: 1,100 engine threads at the peak of a
    /// full run, and the LAN tests starved of the main thread. However many
    /// engines there are, the threads are a fixed few.
    @Test("many engines at once share a few threads")
    func manyEnginesFewThreads() async throws {
        let count = EngineThread.poolSize * 6
        var engines: [KhaytEngine] = []
        for _ in 0..<count { engines.append(try KhaytEngine()) }
        let places = await withTaskGroup(of: Bool.self) { group in
            for engine in engines {
                group.addTask { await engine.whereItRuns().onItsThread }
            }
            var all: [Bool] = []
            for await onIt in group { all.append(onIt) }
            return all
        }
        let made = EngineThread.made
        #expect(places == Array(repeating: true, count: count))
        #expect(made <= EngineThread.poolSize, "\(made) engine threads for \(count) engines")
    }

    @Test("an engine made from an engine thread is built there, in place, without waiting")
    func madeOnAnEngineThread() throws {
        let outer = EngineThread.forNewEngine()
        let answer = try outer.sync { () -> (same: Bool, inner: Int) in
            let inner = EngineThread.forNewEngine()
            let n = try inner.sync { 7 }
            return (inner === outer, n)
        }
        #expect(answer.same)
        #expect(answer.inner == 7)
    }
}
