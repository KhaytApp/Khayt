import Testing
import Foundation
@testable import KhaytCore

/// What it costs to stand the shared rules up from nothing.
///
/// Asked because the Quick Look preview builds an engine per launch to read one
/// file's settings — a whole JavaScriptCore context for one question. That is
/// only the right trade if it is fast; if it is not, a preview would appear
/// late and the honest answer would be a lighter engine, not a second copy of
/// the rule in Swift.
struct EngineCostTests {
    @Test func anEngineIsCheapEnoughForAPreviewToBuildOne() async throws {
        let t0 = Date()
        let engine = try KhaytEngine()
        let started = Date().timeIntervalSince(t0)
        let t1 = Date()
        _ = try await engine.printFacts(
            projectSettings: #"{"printer_model":"U1","layer_height":"0.2"}"#,
            modelSettings: "", prusa: "")
        let called = Date().timeIntervalSince(t1)
        print(String(format: "engine start %.0f ms, first call %.0f ms",
                     started * 1000, called * 1000))
        // Generous, because a loaded CI box is not this Mac. The number that
        // matters is the one printed above; this only catches it becoming a
        // different order of magnitude.
        #expect(started < 2.0, "an engine took \(started)s to start")
    }
}
