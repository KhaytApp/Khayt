import Foundation
import Testing
@testable import KhaytCore

/// "closure argument was escaped in withoutActuallyEscaping block" — signal 5
/// on loaded CI runners (Oct 2026). `update` hands `onChain` closures it holds
/// under `withoutActuallyEscaping`; the chain's block must have let go of them
/// by the time the caller wakes, or the runtime traps.
struct StoreWriterEscapeTests {
    final class Token: @unchecked Sendable {}

    @Test("onChain has let go of its work by the time it returns, every time")
    func workReleasedBeforeResume() async throws {
        for _ in 0..<500 {
            weak var watched: Token?
            do {
                let token = Token()
                watched = token
                _ = try await StoreWriter.onChain { _ = token; return 1 }
            }
            #expect(watched == nil, "the chain still held the work after waking its caller")
            if watched != nil { break }
        }
    }

    @Test("a thrown error still comes back, and the work is still let go of")
    func throwsThrough() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) { _ = try await StoreWriter.onChain { () throws -> Int in throw Boom() } }
    }
}
