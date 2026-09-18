import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A Simple shop cannot REACH the screens its mode does not include.
///
/// ── THE BUG THIS EXISTS FOR ───────────────────────────────────────────────
///
/// The gate was written as two `if`s in `Sidebar.swift` — and that is the
/// shell the app used to open with. The redesigned one has shipped by default
/// since 4.0.0-alpha.12 and asked nothing, so a Simple shop saw Expenses and
/// Reports exactly as a Professional one did.
///
/// What made it hard to place is that everything else was right: the shared
/// rule was right, the book reached the app as Simple, and the old shell's
/// gate was correct. `shop.has("analytics")` returned false the whole time.
/// Nothing was asking it.
///
/// The menu bar and the restore path never asked either, so hiding the row
/// alone would still have left ⌘9, ⌘0 and a reopened window going straight to
/// the screen.
///
/// `BothShellsPresentTests` exists for exactly this class — "a sheet added to
/// one shell and not the other" — and guards only sheets. This guards the gate.
@MainActor
struct SimpleModeHidesItTests {

    static func source(_ file: String) -> String {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp/\(file)")
        return (try? String(contentsOf: path, encoding: .utf8)) ?? ""
    }

    /// A shop whose book says Simple.
    ///
    /// Driven through `readFeatures` with the engine the real load built — the
    /// same path `FeatureModeTests` uses — so what is proved is the rule, the
    /// binding and the app's own reading of them rather than a second copy of
    /// the tier table.
    static func simpleShop() async throws -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        #expect(shop.engineProblem == nil, "no engine means this proves nothing")
        shop.pretendMode("simple")
        await shop.readFeatures()
        return shop
    }

    @Test("the rule really does exclude them, or this test proves nothing")
    func theRuleExcludes() async throws {
        let shop = try await Self.simpleShop()
        #expect(!shop.has("expenses"), "Simple now includes expenses — this test is stale")
        #expect(!shop.has("analytics"), "Simple now includes analytics — this test is stale")
        // And the ungated one is untouched: the waste log is not gated in
        // `lib/feature-tiers.js` either.
        #expect(shop.has("waste"))
    }

    @Test("a Simple shop cannot reach the screens, whatever the route")
    func everyRouteIsClosed() async throws {
        let shop = try await Self.simpleShop()
        #expect(!shop.canShow(.expenses))
        #expect(!shop.canShow(.reports))
        #expect(shop.canShow(.waste), "the waste log is not gated")
        #expect(shop.canShow(.dashboard))
        // And a Professional shop reaches everything.
        let pro = Shop()
        await pro.load(.sample)
        #expect(pro.canShow(.expenses) && pro.canShow(.reports),
                "the sample book stopped being Professional")
    }

    @Test("every gated feature has a screen, and every gated screen asks")
    func theGateAndTheShelvesAgree() {
        // `maintenance` and `zatca` gate parts of a screen rather than a whole
        // one — named here so adding a third does not pass by being forgotten.
        let partsOfScreens: Set<String> = ["maintenance", "zatca"]
        let wholeScreens = Set(Shop.gatedFeatures).subtracting(partsOfScreens)
        let gated = Set([Shop.Shelf.expenses, .reports].compactMap(Shop.gate(of:)))
        #expect(gated == wholeScreens, Comment(rawValue:
            "a gated feature has no screen behind it, or a screen has no gate: "
            + "\(wholeScreens.symmetricDifference(gated).sorted())"))
    }

    @Test("the shipping shell asks the gate")
    func theShippingShellAsks() {
        // Structural, because what is being checked is that the shell CONSULTS
        // it — which no screenshot of a Professional shop shows.
        let shell = Self.source("Shell.swift")
        #expect(!shell.isEmpty, "Shell.swift moved — this test is reading nothing")
        #expect(shell.contains("canShow"), """
            the shipping sidebar does not ask the feature gate. That is the \
            original bug: the gate lived in Sidebar.swift, which is the shell \
            switched off by default.
            """)
    }

    @Test("the menu bar and the restore path ask too")
    func theOtherRoutesAsk() {
        for file in ["Menus.swift", "ShopWindow.swift"] {
            let text = Self.source(file)
            #expect(!text.isEmpty, Comment(rawValue: "\(file) moved"))
            #expect(text.contains("canShow"), Comment(rawValue: """
                \(file) can navigate to a gated screen without asking the gate. \
                Hiding the sidebar row alone leaves the keyboard shortcut and a \
                reopened window going straight there.
                """))
        }
    }

    @Test("the old shell still agrees, while it is still here")
    func bothShellsAgree() {
        // The two shells must not drift again while the migration finishes.
        // When Sidebar.swift goes, so does this.
        let old = Self.source("Sidebar.swift")
        guard !old.isEmpty else { return }
        #expect(old.contains("has(\"expenses\")") || old.contains("canShow"),
                "the retired shell stopped gating expenses")
        #expect(old.contains("has(\"analytics\")") || old.contains("canShow"),
                "the retired shell stopped gating reports")
    }
}
