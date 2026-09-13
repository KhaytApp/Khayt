import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Storefronts and payment systems, for the market the shop sells in.
///
/// ── WHAT A MAC-ONLY SHOP COULD NOT DO ─────────────────────────────────────
///
/// Connect a store at all. Khayt's cloud serves an import route per platform
/// and a feed route back, and both URLs were built and shown only by
/// `renderer/settings.js` — so a shop keeping its book on this app had the
/// cloud, had the shop id, and no way to find out what to paste.
@MainActor
struct IntegrationsTests {

    // MARK: - The registry itself

    @Test("every market crosses over with its storefronts and payment systems")
    func marketsCrossOver() async throws {
        let engine = try KhaytEngine()
        let markets = try await engine.integrationMarkets(in: "en")
        #expect(markets.count >= 7, Comment(rawValue: "only \(markets.count) markets"))
        #expect(markets.contains { $0.id == "ar" }, "the market this app was built for is missing")

        // The Gulf, which is the one that matters here.
        let gulf = try await engine.integrationMarket("ar")
        #expect(gulf.storefronts.contains { $0.id == "salla" })
        #expect(gulf.storefronts.contains { $0.id == "zid" })
        #expect(gulf.payments.contains { $0.id == "mada" })
        #expect(gulf.payments.contains { $0.id == "stcpay" })
        // Not Stripe: it is not available in Saudi, which is the whole reason
        // the list is per market rather than one list with everything on it.
        #expect(!gulf.payments.contains { $0.id == "stripe" },
                "a Riyadh shop is being offered a gateway it cannot use")
    }

    @Test("a market name is shown in the reader's own language")
    func marketNamesAreTranslated() async throws {
        let engine = try KhaytEngine()
        let english = try await engine.integrationMarkets(in: "en")
        let arabic = try await engine.integrationMarkets(in: "ar")
        let gulfEn = english.first { $0.id == "ar" }?.title
        let gulfAr = arabic.first { $0.id == "ar" }?.title
        #expect(gulfEn != gulfAr, "the market list reads the same in both languages")
        #expect(gulfAr?.contains("السعودية") == true, Comment(rawValue: gulfAr ?? "nil"))
    }

    @Test("a language with no curated list falls back rather than showing nothing")
    func unknownLocaleFallsBack() async throws {
        // The rule's own fallback, not a Swift one — a shop running Turkish
        // gets the global list in both apps rather than an empty screen in one.
        let engine = try KhaytEngine()
        let unknown = try await engine.integrationMarket("tr")
        let global = try await engine.integrationMarket("en")
        #expect(!unknown.storefronts.isEmpty, "an unlisted language got an empty directory")
        #expect(unknown.storefronts.map(\.id) == global.storefronts.map(\.id))
    }

    @Test("directions cross over, and a one-way platform says so")
    func directionsSurvive() async throws {
        let engine = try KhaytEngine()
        let gulf = try await engine.integrationMarket("ar")
        let salla = try #require(gulf.storefronts.first { $0.id == "salla" })
        #expect(salla.importsOrders && salla.publishesCatalogue)

        // Medusa takes orders and does not publish, and a row offering a feed
        // link for it would be a link to a route the cloud does not serve.
        let medusa = try #require(gulf.storefronts.first { $0.id == "medusa" })
        #expect(medusa.importsOrders)
        #expect(!medusa.publishesCatalogue, "Medusa was offered a catalogue feed")
    }

    @Test("the one platform that cannot be connected with a link says so")
    func subscriberSetupIsFlagged() async throws {
        // "A platform with no webhook UI needs the code as well as the URL —
        // the link alone is a URL with nowhere to paste it."
        let engine = try KhaytEngine()
        for locale in ["ar", "en", "de", "ja"] {
            let market = try await engine.integrationMarket(locale)
            let medusa = try #require(market.storefronts.first { $0.id == "medusa" },
                                      Comment(rawValue: "Medusa is absent from \(locale)"))
            #expect(medusa.needsSubscriberCode,
                    Comment(rawValue: "Medusa in \(locale) is offered only a link"))
        }
        // And nothing else claims to need it, or every row would grow a button
        // that produces a file for the wrong platform.
        let market = try await engine.integrationMarket("en")
        #expect(market.storefronts.filter(\.needsSubscriberCode).map(\.id) == ["medusa"])
    }

    // MARK: - The two links

    @Test("the import and feed links are the cloud's own routes")
    func linksAreBuiltByTheRule() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.storefrontImportURL(
            cloud: "https://cloud.khayt.app", shopId: "SHOP-1", platform: "salla")
                == "https://cloud.khayt.app/v1/shops/SHOP-1/import/salla")
        #expect(try await engine.storefrontFeedURL(
            cloud: "https://cloud.khayt.app", shopId: "SHOP-1", platform: "shopify")
                == "https://cloud.khayt.app/v1/shops/SHOP-1/feed/shopify")
    }

    @Test("a cloud address typed with a trailing slash still makes one URL")
    func trailingSlashIsTrimmed() async throws {
        // A shop types its cloud URL by hand, and a browser's address bar hands
        // over "https://cloud.example.com/". `//v1/shops/…` is a different path
        // — one the cloud does not serve, and one the store reports as
        // delivered because a 404 is a response.
        let engine = try KhaytEngine()
        #expect(try await engine.storefrontImportURL(
            cloud: "https://cloud.khayt.app///", shopId: "SHOP-1", platform: "zid")
                == "https://cloud.khayt.app/v1/shops/SHOP-1/import/zid")
    }

    @Test("the Medusa subscriber carries the shop's own import URL")
    func subscriberCarriesTheURL() async throws {
        let engine = try KhaytEngine()
        let url = try await engine.storefrontImportURL(
            cloud: "https://cloud.khayt.app", shopId: "SHOP-9", platform: "medusa")
        let source = try await engine.medusaSubscriber(importURL: url)
        #expect(source.contains(url), "the subscriber does not name the shop's own cloud")
        #expect(!source.isEmpty)
        let path = try await engine.medusaSubscriberPath()
        #expect(path.hasSuffix(".ts"), Comment(rawValue: path))
    }

    @Test("a URL that could close the string literal is escaped, not trusted")
    func subscriberEscapesTheURL() async throws {
        // The module's own note: it is the app's own cloud URL rather than
        // anything a stranger supplies, but "it came from our own settings" is
        // how injection bugs are argued for.
        //
        // ── AND THE FIRST VERSION OF THIS ASSERTION PROVED NOTHING ────────
        //
        // It checked that the source did not contain `"; evil()`. The ESCAPED
        // form is `\"; evil()`, which contains that substring — so the test
        // matched both the safe output and the unsafe one and would have passed
        // either way. What actually has to hold is that the quote arrives with
        // a backslash in front of it and the literal does not end early.
        let engine = try KhaytEngine()
        let source = try await engine.medusaSubscriber(importURL: #"https://x/"; evil()//"#)
        #expect(source.contains(#"https://x/\""#),
                "the quote in the URL reached the TypeScript source unescaped")
        #expect(!source.contains(#"= "https://x/";"#),
                "the string literal was closed by the URL's own quote")
    }

    // MARK: - Saving what the shop switched on

    @Test("saving one market does not switch another market's providers off")
    func savingOneMarketKeepsTheRest() async throws {
        // THE BUG THIS GUARDS. The directory shows ONE market at a time, and a
        // shop selling into two has providers configured outside the list on
        // screen. A form carrying only the visible market, written straight
        // over the map, silently switches the others off — and the shop finds
        // out when an invoice stops offering a way to pay.
        let engine = try KhaytEngine()
        let held: [String: JSONValue] = [
            "paymentProviders": .object([
                "stripe": .object(["enabled": .bool(true),
                                   "payLink": .string("https://pay.stripe.com/{amount}")]),
                "mada": .object(["enabled": .bool(true), "payLink": .string("")]),
            ]),
        ]
        // A Gulf-market save that never mentions Stripe.
        let out = try await engine.applySettings(held, form: [
            "paymentProviders": .object([
                "mada": .object(["enabled": .bool(false), "payLink": .string("")]),
                "tabby": .object(["enabled": .bool(true), "payLink": .string("  https://tabby  ")]),
            ]),
        ], year: 2026)
        guard case .object(let saved)? = out["paymentProviders"] else {
            Issue.record("paymentProviders is no longer a map"); return
        }
        guard case .object(let stripe)? = saved["stripe"] else {
            Issue.record("Stripe was switched off by a save that never mentioned it"); return
        }
        #expect(stripe["enabled"] == JSONValue.bool(true))
        #expect(stripe["payLink"] == JSONValue.string("https://pay.stripe.com/{amount}"),
                "a provider outside the visible market lost its pay link")
        // And the visible market's edits landed.
        guard case .object(let mada)? = saved["mada"], case .object(let tabby)? = saved["tabby"] else {
            Issue.record("the visible market's edits were not saved"); return
        }
        #expect(mada["enabled"] == JSONValue.bool(false))
        #expect(tabby["payLink"] == JSONValue.string("https://tabby"),
                "a pasted link kept the spaces around it")
    }

    @Test("a save that does not mention providers leaves them all alone")
    func otherPanesDoNotTouchThem() async throws {
        // Every pane saves only the keys it shows. The Business pane writing a
        // phone number must not clear the payment directory.
        let engine = try KhaytEngine()
        let held: [String: JSONValue] = [
            "paymentProviders": .object([
                "stripe": .object(["enabled": .bool(true), "payLink": .string("https://x")]),
            ]),
        ]
        let out = try await engine.applySettings(held, form: ["phone": .string("+966 50 000 0000")],
                                                 year: 2026)
        guard case .object(let saved)? = out["paymentProviders"],
              case .object(let stripe)? = saved["stripe"] else {
            Issue.record("the payment directory was cleared by an unrelated save"); return
        }
        #expect(stripe["enabled"] == JSONValue.bool(true))
    }

    @Test("an entry carrying more than a flag and a link is trimmed to those two")
    func onlyTheTwoFields() async throws {
        // This file has no business deciding a provider id is obsolete — the
        // registry is curated and changes between releases — but it does decide
        // the SHAPE. Whatever wrote a third field on an entry does not get it
        // carried into an invoice.
        let engine = try KhaytEngine()
        let out = try await engine.applySettings([:], form: [
            "paymentProviders": .object([
                "mada": .object(["enabled": .bool(true), "payLink": .string("https://x"),
                                 "secretKey": .string("sk_live_should_not_be_here")]),
            ]),
        ], year: 2026)
        guard case .object(let saved)? = out["paymentProviders"],
              case .object(let mada)? = saved["mada"] else {
            Issue.record("nothing was saved"); return
        }
        #expect(Set(mada.keys) == ["enabled", "payLink"],
                Comment(rawValue: "an entry carries \(Set(mada.keys).sorted())"))
    }
}

/// That the directory is REACHED.
@MainActor
struct IntegrationWiringTests {

    static func source(_ file: String) throws -> String {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        return try String(contentsOf: dir.appending(path: file), encoding: .utf8)
    }

    @Test("the settings window has an Integrations pane")
    func thePaneIsWired() throws {
        let window = try Self.source("SettingsWindow.swift")
        #expect(window.contains("IntegrationsPane(shop: shop)"),
                "the directory exists and no settings tab opens it")
        #expect(window.contains("case business, invoice, payments, operations, integrations"),
                "the pane has no tag, so it cannot be restored or deep-linked to")
    }

    @Test("the pane asks the rule for everything it draws")
    func nothingIsHardcoded() throws {
        let pane = try Self.source("Integrations.swift")
        for (call, why) in [
            ("engine?.integrationMarkets(", "the market list is not the registry's"),
            ("engine?.integrationMarket(", "the storefronts are not the registry's"),
            ("storefrontImportURL(", "the import link is built somewhere other than the rule"),
            ("storefrontFeedURL(", "the feed link is built somewhere other than the rule"),
            ("medusaSubscriber(", "the subscriber code is not the shared one"),
        ] {
            #expect(pane.contains(call), Comment(rawValue: why))
        }
        // The route shape in particular: a second copy is a URL a store reports
        // as delivered and the cloud never sees.
        #expect(!pane.contains("/v1/shops/"),
                "the pane spells a cloud route itself instead of asking the rule")
    }
}
