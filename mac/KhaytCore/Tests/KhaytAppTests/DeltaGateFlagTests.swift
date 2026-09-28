import Foundation
import Testing
@testable import KhaytApp

/// The "chain is closed" mark is what the LAST send found, so a Mac that
/// once pushed the whole book goes back to fast delta syncs once the gate
/// accepts deltas again, without being relaunched.
@MainActor
struct DeltaGateFlagTests {
    @Test("a delta send clears the closed-chain mark a whole-book push set")
    func clears() throws {
        let shop = try QuoteSheetStatusTests.source("Shop.swift")
        let at = try #require(shop.range(of: "if cloudSent?.wholeStore == true {"))
        let tail = shop[at.lowerBound...].prefix(260)
        #expect(tail.contains("} else if cloudSent != nil {"))
        #expect(tail.contains("chainIsClosed = false"))
    }
}
