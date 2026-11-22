import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The consent sheet says when it installs over a version the shop has
/// (Lamha 1.0.0 → 1.1.1, Nov 10: it read like a first install).
@MainActor
struct ConnectorConsentUpdatesTests {

    static func offer(_ version: String, replacing: String?) -> ConnectorOffer {
        ConnectorOffer(manifestId: "app.khayt.samples.lamha", name: "Lamha", version: version,
                       reviewedBy: "khayt-2026-11", manifest: .null, rows: [], scopes: [],
                       replacing: replacing)
    }

    @Test("an update names the version it replaces, in the shop's words")
    func updates() async throws {
        let words = Words()
        await words.load("en", engine: try KhaytEngine())
        let line = try #require(ConnectorConsentSheet.updatesLine(Self.offer("1.1.1", replacing: "1.0.0"), words: words))
        #expect(line.contains("1.0.0"))
        #expect(!line.contains("{from}"))
        #expect(!line.contains("plg."), "the key itself, not words: \(line)")
    }

    @Test("a first install, or the same version again, says nothing")
    func firstInstall() async throws {
        let words = Words()
        await words.load("en", engine: try KhaytEngine())
        #expect(ConnectorConsentSheet.updatesLine(Self.offer("1.1.1", replacing: nil), words: words) == nil)
        #expect(ConnectorConsentSheet.updatesLine(Self.offer("1.1.1", replacing: "1.1.1"), words: words) == nil)
    }
}
