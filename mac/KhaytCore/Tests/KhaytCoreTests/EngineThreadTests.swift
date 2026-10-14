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

    @Test("an engine that goes away takes its thread with it")
    func engineReleasesItsThread() async throws {
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
}
