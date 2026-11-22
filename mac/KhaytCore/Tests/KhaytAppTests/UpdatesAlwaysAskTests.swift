import Foundation
import Testing

/// "It should never auto update, it should always ask for permission" — the
/// shop, Sep 2026. Pinned in the two places that could quietly undo it.
struct UpdatesAlwaysAskTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("the built app tells Sparkle automatic installs are not allowed")
    func bundleRefuses() throws {
        let script = try String(contentsOf: Self.root.deletingLastPathComponent().appending(path: "make-app.sh"),
                                encoding: .utf8)
        #expect(script.contains("<key>SUAllowsAutomaticUpdates</key><false/>"))
        #expect(!script.contains("<key>SUAutomaticallyUpdate</key><true/>"))
    }

    @Test("the app turns silent installs off at launch and offers no switch to turn them on")
    func appRefuses() throws {
        let source = try String(contentsOf: Self.root.appending(path: "Sources/KhaytApp/Updates.swift"), encoding: .utf8)
        #expect(source.contains("automaticallyDownloadsUpdates = false"))
        #expect(!source.contains("automaticallyDownloadsUpdates = newValue"), "a switch that installs without asking is back")
        #expect(!source.contains("automaticallyDownloadsUpdates = true"))
    }
}

/// An update is verified before it is unpacked. The feed is not signed yet, so
/// demanding a signed one would strand every installed copy.
struct UpdatesVerifiedFirstTests {
    @Test("the built app verifies the archive's signature before extracting it, and does not yet demand a signed feed")
    func verifiedBeforeExtraction() throws {
        let script = try String(contentsOf: UpdatesAlwaysAskTests.root.deletingLastPathComponent()
            .appending(path: "make-app.sh"), encoding: .utf8)
        #expect(script.contains("<key>SUVerifyUpdateBeforeExtraction</key><true/>"))
        #expect(!script.contains("<key>SURequireSignedFeed</key>"),
                "a signed feed is required before the appcast is signed: no copy could update")
    }
}
