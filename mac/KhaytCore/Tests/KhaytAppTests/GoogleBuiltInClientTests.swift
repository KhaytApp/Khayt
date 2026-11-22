import Foundation
import Testing
@testable import KhaytApp

/// Connect Google Drive uses Khayt's own client when the build carries one,
/// and a shop's own client only when it chose one.
@MainActor
struct GoogleBuiltInClientTests {
    @Test("a test build carries no Google client, so the shop's own is asked for, as before")
    func noneInTests() {
        #expect(Shop.builtInGoogleClient == nil)
    }

    @Test("the build injects the client from outside the repository, and the pane prefers it")
    func wired() throws {
        let make = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "make-app.sh"), encoding: .utf8)
        #expect(make.contains("KhaytGoogleClientID"))
        #expect(make.contains("~/.khayt/google-oauth.json"))
        let pane = try QuoteSheetStatusTests.source("CloudLibrarySettings.swift")
        #expect(pane.contains("clientId: own ? draft.driveClientId : \"\""))
        let lib = try QuoteSheetStatusTests.source("CloudLibrary.swift")
        #expect(lib.contains("let own = Self.builtInGoogleClient"))
    }
}
