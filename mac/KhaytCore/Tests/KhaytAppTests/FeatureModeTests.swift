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

    /// THE ONE THING THE FEATURE EXISTS TO DO.
    ///
    /// Every test here loaded the bundled sample, which carries no `mode` at
    /// all and is therefore Professional, and asserted that everything was
    /// present. Nothing anywhere proved that a Simple shop actually LOSES a
    /// screen through the path the app really takes — so when somebody set the
    /// sample to Simple, photographed the sidebar and saw Expenses and Reports
    /// still on it, there was no test to say whether the app was wrong or the
    /// experiment was. (It was the experiment: a stale resource bundle, so the
    /// running app never saw the edited book. Measured through this path, all
    /// four gated features come back off.)
    ///
    /// Driven through `readFeatures` with the engine the real load built, so
    /// what is proved is the rule, the engine binding and the app's own reading
    /// of them — not a reimplementation of the tier table.
    @Test("a Simple shop loses the screens its mode does not include")
    func simpleHidesWhatItShould() async throws {
        let shop = Shop()
        await shop.load(.sample)
        #expect(shop.engineProblem == nil, "no engine means this proves nothing")

        shop.pretendMode("simple")
        await shop.readFeatures()
        for key in Shop.gatedFeatures {
            #expect(!shop.has(key), Comment(rawValue: "\(key) is still on for a Simple shop"))
        }
        // And the two the sidebar actually gates on, named so a rename is caught.
        #expect(!shop.has("expenses"))
        #expect(!shop.has("analytics"))
        // What is NOT gated stays, whatever the mode.
        #expect(shop.has("waste"))

        // Back to Professional and they all return, so the test is measuring
        // the mode rather than something that fails closed.
        shop.pretendMode("professional")
        await shop.readFeatures()
        for key in Shop.gatedFeatures {
            #expect(shop.has(key), Comment(rawValue: "\(key) did not come back"))
        }
    }

    /// THE GAP THIS CLOSED.
    ///
    /// Purchase orders arrived on the Mac in 4.0.0-alpha.27 and arrived
    /// ungated: `renderer/index.html` carries `pro-only` on the purchase-order
    /// section, the suppliers card and the auto-draft switch, so a Simple shop
    /// sees none of it in the other window and saw all of it here. Two apps
    /// disagreeing about what a shop has is exactly what the modes exist to
    /// stop.
    ///
    /// The source check is the half that matters: `has("purchasing")` coming
    /// back false proves the rule, and proves nothing at all about whether any
    /// screen asks.
    @Test("a Simple shop sees no purchase orders, as it sees none in the other app")
    func simpleHidesPurchasing() async throws {
        let shop = Shop()
        await shop.load(.sample)
        #expect(shop.engineProblem == nil, "no engine means this proves nothing")

        shop.pretendMode("simple")
        await shop.readFeatures()
        #expect(!shop.has("purchasing"))
        shop.pretendMode("professional")
        await shop.readFeatures()
        #expect(shop.has("purchasing"), "purchasing did not come back for a Professional shop")

        // And every shelf surface that raises or shows one asks.
        let floor = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "Sources/KhaytApp/ShopFloor.swift"),
            encoding: .utf8)
        let asks = floor.ranges(of: "has(\"purchasing\")").count
        #expect(asks >= 5, Comment(rawValue:
            "only \(asks) shelf surfaces ask whether this shop has purchase orders — "
            + "what is on order, what is over-priced, the batch draft, the suppliers "
            + "card and the two draft menu items all must"))
    }

    /// AND WHY LOYALTY IS NOT GATED, although the tier table calls it
    /// Professional.
    ///
    /// The loyalty settings card in `renderer/index.html` carries no
    /// `pro-only` class, so a Simple shop can switch the rewards programme on
    /// in the other window. Gating it here would hide from that shop something
    /// it has and is using — the same disagreement, from the other end. If the
    /// other app ever gates it, this test is the place that says so.
    @Test("loyalty is deliberately not gated here, because the other app does not gate it")
    func loyaltyIsNotGated() throws {
        #expect(!Shop.gatedFeatures.contains("loyalty"))
        let html = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appending(path: "renderer/index.html"),
            encoding: .utf8)
        // The card the switch lives in. If it grows a `pro-only` class this
        // fails, and the answer is to gate it here rather than to loosen this.
        guard let at = html.range(of: "set_loyaltyEnabled") else {
            Issue.record("the loyalty switch has moved — this check has rotted"); return
        }
        let card = html[html.index(at.lowerBound, offsetBy: -600)..<at.lowerBound]
        #expect(!card.contains("pro-only"),
                "the other app now hides loyalty from Simple shops, so this app must too")
    }

    @Test("an enthusiast book is read as Simple, and keeps its customers")
    func enthusiastReadsAsSimple() async throws {
        let shop = Shop()
        await shop.load(.sample)
        shop.pretendMode("enthusiast")
        await shop.readFeatures()
        #expect(!shop.has("analytics"))
        #expect(shop.has("clients"), "clients is not gated, and an enthusiast book kept its customers")
    }

    @Test("a book with no mode at all is Professional, not empty")
    func noModeIsProfessional() async throws {
        // A book written before modes existed must not lose half its screens.
        let shop = Shop()
        await shop.load(.sample)
        shop.pretendMode(nil)
        await shop.readFeatures()
        for key in Shop.gatedFeatures {
            #expect(shop.has(key), Comment(rawValue: "\(key) vanished from a book with no mode"))
        }
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
