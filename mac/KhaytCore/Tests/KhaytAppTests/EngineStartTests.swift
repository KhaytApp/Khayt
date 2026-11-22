import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The shared rules start, and the app knows if they do not.
///
/// Everything this app computes and every word it says comes through
/// JavaScriptCore, so a runtime that will not start is not a degraded app — it
/// is an app with no words, no tax, no reports and no writes. It used to fail
/// SILENTLY: `engine = try? KhaytEngine()`, and every screen carried on
/// rendering its labels as raw keys. Bundling one module whose file name did
/// not match the global it assigns did that, and only a photograph caught it.
@MainActor
struct EngineStartTests {

    @Test("opening a book starts the shared rules")
    func starts() async throws {
        let shop = Shop()
        await shop.load(.sample)
        #expect(shop.engine != nil, "the runtime did not start: \(shop.engineProblem ?? "no reason given")")
        #expect(shop.engineProblem == nil)
    }

    @Test("and the app speaks Khayt's words, not its keys")
    func words() async throws {
        let shop = Shop()
        await shop.load(.sample)
        // One key from each screen that leans on the catalogue. A key that
        // comes back as itself is what a shop sees when the runtime is dead.
        for key in ["queue.completed", "an.pnl_title", "exp.title", "waste.title",
                    "set.nav_biz", "doc.invoice", "common.save"] {
            #expect(shop.words.callIt(key) != key, "\(key) came back as its own key")
        }
    }

    @Test("every bundled module defines the global its name promises")
    func modulesDefineTheirGlobals() throws {
        // The loader checks this per module and throws on the first failure, so
        // starting the runtime at all is the assertion — but a failure names
        // only one module, and this says which list to look at.
        #expect(throws: Never.self) { _ = try KhaytEngine() }
    }
}
