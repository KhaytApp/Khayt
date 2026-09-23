import Foundation
import Testing
@testable import KhaytApp

/// The storefront's prices reach Khayt Cloud when the shop saves them, and the
/// shop can see that they did.
///
/// Both were missing: the publisher ran 90 seconds after launch and then every
/// six hours, so switching storefront pricing on reached the storefront up to
/// six hours later, and its outcome went only to stderr.
@MainActor
struct QuoteSheetStatusTests {

    static func source(_ name: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/\(name)"), encoding: .utf8)
    }

    @Test("saving the storefront's pricing publishes it now, not on the next six-hour tick")
    func publishesOnSave() throws {
        let lan = try Self.source("LanServer.swift")
        #expect(lan.contains("if intakeQuote != nil { await publishQuoteSheet() }"))
    }

    @Test("the Online pane says where the storefront's prices went")
    func saysSo() throws {
        let pane = try Self.source("OnlinePane.swift")
        #expect(pane.contains("shop.quoteSheetSaid"), "the outcome is computed and never shown")
        #expect(pane.contains("mac.qs_needs_cloud"), "a shop not signed in to the cloud is not told why nothing is sent")
    }

    @Test("with no cloud connection nothing is claimed")
    func notConnectedSaysNothing() async {
        let shop = Shop()
        await shop.load(.sample)
        await shop.publishQuoteSheet()
        #expect(shop.quoteSheetSaid == nil)
        #expect(!shop.quoteSheetProblem)
    }
}
