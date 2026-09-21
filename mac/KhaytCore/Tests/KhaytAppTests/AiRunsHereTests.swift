import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// What this Mac says it can do with AI, against what it actually does.
///
/// `aiFeaturesOnThisMac` drives one line in Settings: *"Runs in the Windows and
/// Linux app for now."* It said `["quote"]` long after price advice, the
/// drafted reply and the assistant had all been built here — so the app told
/// the shop to go and use the other one for three things it was performing
/// itself. Its own comment had already called that out: leaving the note on a
/// working feature is as wrong as dropping it from a missing one.
///
/// A set of strings cannot be checked against behaviour by a unit test, so
/// this checks it against the CHAIN each feature needs — a view that asks, and
/// an `AiClient` entry point that answers. Read as source, because a SwiftUI
/// body cannot be instantiated and asked what it calls.
@MainActor
struct AiRunsHereTests {

    static func source(_ name: String) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp/\(name)")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Feature id -> the `Shop` method a screen calls, and the `AiClient`
    /// entry point that method reaches.
    static let chain: [String: (shopMethod: String, client: String)] = [
        "quote":     ("draftPartFromDescription", "AiClient.draftQuote"),
        "price":     ("recommendMargin",          "AiClient.recommendMargin"),
        "reply":     ("draftMessage",             "AiClient.draftReply"),
        "assistant": ("ask",                      "AiClient.ask"),
    ]

    /// Looped INSIDE the test rather than as `@Test(arguments:)`: the sets are
    /// main-actor isolated, and the argument list of a parametrised test is
    /// evaluated outside the actor.
    @Test("every AI feature this Mac claims is one it can actually reach")
    func claimedFeaturesAreWired() {
        let shop = Self.source("Shop.swift")
        #expect(!shop.isEmpty, "Shop.swift was not read — this would pass vacuously")
        #expect(!Shop.aiFeaturesOnThisMac.isEmpty, "nothing is claimed — the scan is wrong")
        for id in Shop.aiFeaturesOnThisMac.sorted() { check(id, shop) }
    }

    private func check(_ id: String, _ shop: String) {
        guard let link = Self.chain[id] else {
            Issue.record(Comment(rawValue: "`\(id)` is claimed to run here but this test knows "
                                 + "no chain for it — add it to `chain`"))
            return
        }
        // The Shop method exists and reaches the client.
        #expect(shop.contains("func \(link.shopMethod)("),
                Comment(rawValue: "Shop has no `\(link.shopMethod)` for `\(id)`"))
        #expect(shop.contains(link.client),
                Comment(rawValue: "`\(id)` never reaches `\(link.client)`"))

        // And SOME view asks for it — a Shop method nothing calls is the same
        // dead feature as a missing one.
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir,
                     includingPropertiesForKeys: nil)) ?? []
        let asked = files.filter {
            $0.pathExtension == "swift" && $0.lastPathComponent != "Shop.swift"
                && $0.lastPathComponent != "AiClient.swift"
        }.contains { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.contains("shop.\(link.shopMethod)(")
        }
        #expect(asked, Comment(rawValue: "no screen calls `shop.\(link.shopMethod)`, so `\(id)` "
                               + "is claimed to run here and cannot be reached"))
    }

    /// The other direction, which is the one that actually bit.
    ///
    /// A feature fully wired here but MISSING from the set makes Settings tell
    /// the shop to open the other app for something this one does. That is the
    /// exact defect this file was written for, and it is the half a "does the
    /// claim hold" test would not have caught.
    @Test("a feature that is fully wired here is not disclaimed")
    func wiredFeaturesAreClaimed() {
        let shop = Self.source("Shop.swift")
        #expect(!shop.isEmpty, "Shop.swift was not read — this would pass vacuously")
        for (id, link) in Self.chain.sorted(by: { $0.key < $1.key }) {
            let wired = shop.contains("func \(link.shopMethod)(") && shop.contains(link.client)
            guard wired else { continue }   // genuinely missing: the note is correct
            #expect(Shop.aiRunsHere(id),
                    Comment(rawValue: "`\(id)` is wired end to end on this Mac, but "
                            + "`aiFeaturesOnThisMac` leaves it out — Settings will tell the shop "
                            + "it runs in the Windows and Linux app"))
        }
    }

    /// The third direction, which neither of the two above covers.
    ///
    /// Both tests reason about the four features THIS FILE knows. A fifth one
    /// added to `lib/ai-privacy.js` is in neither `chain` nor
    /// `aiFeaturesOnThisMac`, so both pass — and Settings quietly draws a line
    /// telling the shop to go and use the other app for it.
    ///
    /// That line is the thing being forbidden here. A feature the shared rule
    /// offers and this app does not perform is a GAP TO CLOSE, not a note to
    /// print, so it fails the build instead: whoever adds the fifth feature is
    /// told here rather than a shop being told in Settings.
    @Test("every AI feature the shared rule offers is one this Mac performs")
    func nothingIsLeftToTheOtherApp() async throws {
        let engine = try KhaytEngine()
        let offered = try await engine.aiFeatures(settings: [:])
            .map { $0.id }.sorted()
        #expect(offered.count >= 4, "the shared rule offered \(offered) — the scan is wrong")
        for id in offered {
            #expect(Shop.aiRunsHere(id),
                    Comment(rawValue: "`\(id)` is offered by `lib/ai-privacy.js` and this Mac "
                            + "does not perform it. Build it here and add it to "
                            + "`aiFeaturesOnThisMac` and to `chain` — do not leave the shop a "
                            + "note pointing at another app."))
        }
        // And nothing is claimed that the shared rule has never heard of, which
        // would be a consent switch for a feature nobody can grant.
        for id in Shop.aiFeaturesOnThisMac.sorted() {
            #expect(offered.contains(id),
                    Comment(rawValue: "`\(id)` is claimed here and the shared rule does not "
                            + "offer it"))
        }
    }
}
