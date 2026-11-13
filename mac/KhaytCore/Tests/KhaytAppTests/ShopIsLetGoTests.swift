import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A shop nobody holds any more is let go, and its engine with it.
///
/// ── WHY THIS IS HELD ──────────────────────────────────────────────────────
///
/// An engine is a JavaScript context with every shared rule loaded: about
/// 20 MB. The test process makes 2,467 of them on a full run, and what keeps
/// that from being 50 GB is two things. One is that only so many tests are in
/// flight at once (`TestsInFlightAreBoundedTests`). The other is this: when a
/// test ends, its shop goes, and the engine goes with it. Measured on that
/// full run, four engines were alive at the end.
///
/// A shop that could not be let go — a watch or a timer it started holding
/// the shop itself — would not fail any test. It would put the 20 MB back,
/// once per test that loads a book, and 410 of them load this one.
@MainActor
struct ShopIsLetGoTests {

    @Test("a shop that loaded a book is let go when nothing holds it, and its engine with it")
    func aLoadedShopIsLetGo() async throws {
        weak var shop: Shop?
        weak var engine: KhaytEngine?
        do {
            let loaded = Shop()
            await loaded.load(.sample)
            #expect(!loaded.orders.isEmpty, "the sample book did not load, so nothing was started")
            shop = loaded
            engine = loaded.engine
        }
        // Whatever the shop started may be in the middle of a pass, and
        // holds the shop until that pass ends. A hang guard (two minutes),
        // not a speed limit: on a quiet Mac this is under a second.
        for _ in 0..<2_400 where shop != nil || engine != nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(shop == nil, "something the shop started still holds the shop")
        #expect(engine == nil, "the shop went and its engine did not")
    }
}
