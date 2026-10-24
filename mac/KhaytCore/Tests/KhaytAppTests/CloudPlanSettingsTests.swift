import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The plan pane's own rules: which move says what happens to products.
struct CloudPlanSettingsTests {
    static func plan(_ name: String, publishing: Bool?) throws -> CloudPlans.Plan {
        let limits = publishing.map { #"{"publishing":\#($0)}"# } ?? "{}"
        return try JSONDecoder().decode(CloudPlans.Plan.self, from: Data(#"{"name":"\#(name)","limits":\#(limits)}"#.utf8))
    }

    @Test("only a move off a selling plan onto one without selling mentions products")
    func losesSelling() throws {
        let creator = try Self.plan("creator", publishing: true), studio = try Self.plan("studio", publishing: true)
        let maker = try Self.plan("maker", publishing: nil), free = try Self.plan("free", publishing: false)
        #expect(CloudPlanSettings.losesSelling(maker, from: creator))
        #expect(CloudPlanSettings.losesSelling(free, from: studio))
        #expect(!CloudPlanSettings.losesSelling(creator, from: studio))
        #expect(!CloudPlanSettings.losesSelling(free, from: maker))
        #expect(!CloudPlanSettings.losesSelling(free, from: nil))
    }
}
