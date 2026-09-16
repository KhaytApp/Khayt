import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// What the shop's chosen mode includes.
///
/// ── WHAT THIS APP USED TO DO ──────────────────────────────────────────────
///
/// Nothing. Khayt has two modes, `lib/feature-tiers.js` is the single source
/// of truth for the boundary, and this app read `settings.mode` nowhere at
/// all — so a shop set to Simple in the other app opened this one and found
/// the whole Professional surface. Two apps disagreeing about what a shop
/// has is exactly what the shared rules exist to stop.
///
/// Of the nine Professional features this app has built four: full analytics,
/// expense tracking, machine maintenance, and ZATCA e-invoicing. Those four
/// are what there is to gate, and the list is checked against the rule below
/// rather than restated.
@MainActor
struct FeatureModeTests {

    @Test("every feature this app gates is one the rule actually calls Professional")
    func gatesOnlyRealProFeatures() async throws {
        let engine = try KhaytEngine()
        for key in Shop.gatedFeatures {
            // On for a Professional shop…
            #expect(try await engine.featureEnabled(key, mode: "professional"),
                    Comment(rawValue: "\(key) is off for a Professional shop"))
            // …and off for a Simple one, which is what makes it worth gating.
            #expect(!(try await engine.featureEnabled(key, mode: "simple")),
                    Comment(rawValue: "\(key) is gated here but Simple shops get it — gating it hides "
                                      + "something the other app shows"))
        }
    }

    @Test("an absent mode is Professional, so an older book loses nothing")
    func absentModeIsProfessional() async throws {
        let engine = try KhaytEngine()
        for key in Shop.gatedFeatures {
            #expect(try await engine.featureEnabled(key, mode: nil), Comment(rawValue: key))
            #expect(try await engine.featureEnabled(key, mode: ""), Comment(rawValue: key))
        }
    }

    @Test("an enthusiast book is read as Simple, not honoured")
    func enthusiastIsMigrated() async throws {
        // `enthusiast` is Bed Ready's only mode and was retired as a Khayt
        // one; `applyMode()` migrates a Khayt book carrying it to Simple.
        // Honouring it here would strip every commerce surface from a book
        // the other app had already decided to treat as Simple.
        let engine = try KhaytEngine()
        #expect(!(try await engine.featureEnabled("analytics", mode: "enthusiast")))
        // Clients are commerce. A book honoured AS enthusiast would lose them;
        // read as Simple it keeps them, and keeping them is the whole point of
        // the migration. So this asserts what the migration achieves, not what
        // the raw tier table says about `enthusiast`.
        #expect(try await engine.featureEnabled("clients", mode: "simple"))
        #expect(try await engine.featureEnabled("clients", mode: "enthusiast"),
                "an enthusiast book was honoured rather than read as Simple, and lost its customers")
    }

    @Test("a feature this app has not classified is never hidden")
    func unknownFeaturesStayOn() async throws {
        let shop = Shop()
        await shop.load(.sample)
        // A screen added and not classified must not vanish; only the four
        // named above are gated at all.
        #expect(shop.has("waste"))
        #expect(shop.has("colourStudio"))
        #expect(shop.has("somethingNobodyHasWrittenYet"))
    }

    @Test("the sample book is Professional, so every gated screen is there")
    func sampleKeepsEverything() async throws {
        let shop = Shop()
        await shop.load(.sample)
        for key in Shop.gatedFeatures {
            #expect(shop.has(key), Comment(rawValue: "\(key) is hidden on the sample book"))
        }
        // And the shelves that depend on them are reachable.
        #expect(shop.has("analytics") && shop.has("expenses"))
    }
}
