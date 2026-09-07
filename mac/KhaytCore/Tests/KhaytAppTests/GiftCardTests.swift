import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Gift cards on the Mac.
///
/// The arithmetic is `lib/gift-card.js` and is tested where it lives. What is
/// tested here is that this app ASKS it — the status shown beside a card is the
/// obvious thing to write in Swift as two date comparisons, and the two would
/// then disagree the first time either changed.
@MainActor
struct GiftCardTests {

    static func shop() async throws -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        try #require(shop.engine != nil, "the shared rules did not start")
        return shop
    }

    static func card(_ id: String, balance: Double, expires: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "code": .string(id.uppercased()),
            "balance": .number(balance), "initialBalance": .number(500),
        ]
        if let expires { o["expiresAt"] = .string(expires) }
        return .object(o)
    }

    /// THE ORDER THAT MATTERS. An expired card with nothing left on it reads
    /// EXPIRED, not "used": one says why it cannot be spent, the other suggests
    /// the customer got the benefit of it. Two Swift date comparisons written
    /// in the obvious order give the opposite answer.
    @Test("expiry beats an empty balance, and the rule decides which")
    func statusOrder() async throws {
        let shop = try await Self.shop()
        let states = try await #require(shop.engine).giftCardStatuses([
            Self.card("a", balance: 200),
            Self.card("b", balance: 0),
            Self.card("c", balance: 0, expires: "2020-01-01"),
            Self.card("d", balance: 200, expires: "2020-01-01"),
            Self.card("e", balance: 200, expires: "2099-01-01"),
        ], today: "2026-09-06")

        #expect(states["a"] == "active")
        #expect(states["b"] == "used")
        #expect(states["c"] == "expired", "an expired empty card must say why")
        #expect(states["d"] == "expired")
        #expect(states["e"] == "active")
    }

    @Test("a card expiring today is still good today")
    func expiresToday() async throws {
        let shop = try await Self.shop()
        let states = try await #require(shop.engine).giftCardStatuses(
            [Self.card("a", balance: 50, expires: "2026-09-06")], today: "2026-09-06")
        #expect(states["a"] == "active")
    }

    /// The refusals come back as KEYS, so the window says them in the shop's
    /// language. A rule that answered in English would be one the Arabic app
    /// could not use, and this is the assertion that notices if it starts to.
    @Test("a refused card is refused by key, and builds nothing")
    func refusals() async throws {
        let shop = try await Self.shop()
        let engine = try #require(shop.engine)
        let existing = [Self.card("gc1", balance: 10)]

        for (input, expected) in [
            (["code": JSONValue.string(""), "initialBalance": .number(50)], "giftCardCodeRequired"),
            (["code": .string("A-B"), "initialBalance": .number(50)], "giftCardCodeInvalid"),
            (["code": .string("GC1"), "initialBalance": .number(50)], "giftCardCodeDuplicate"),
            (["code": .string("NEW123"), "initialBalance": .number(0)], "giftCardBalanceRequired"),
        ] {
            let made = try await engine.newGiftCard(input, id: "GC-x", now: "2026-09-06T00:00:00Z",
                                                    existing: existing)
            #expect(!made.ok)
            #expect(made.error == expected, "got \(made.error ?? "nil")")
            #expect(made.card == nil, "a refused card was built anyway")
            // The words exist in both languages, or the window shows a key.
            #expect(shop.words.callIt(expected) != expected, "\(expected) has no translation")
        }
    }

    @Test("an issued card starts full and shouted")
    func issued() async throws {
        let shop = try await Self.shop()
        let made = try await #require(shop.engine).newGiftCard(
            ["code": .string("sum24"), "initialBalance": .number(250)],
            id: "GC-1", now: "2026-09-06T00:00:00Z", existing: [])
        #expect(made.ok)
        let card = try #require(made.card)
        guard case .object(let o) = card else { Issue.record("not an object"); return }
        #expect(o["code"] == .string("SUM24"))
        #expect(o["balance"] == .number(250))
        #expect(o["initialBalance"] == .number(250))
    }

    /// The suggestion only. It must not offer characters that are misheard,
    /// because the whole point of a code is being read down a telephone.
    @Test("the suggested code has no letters that sound like numbers")
    func suggestedCode() {
        for _ in 0..<200 {
            let code = Shop.giftCardCode()
            #expect(code.count == 8)
            for bad in ["I", "O", "0", "1", "5", "S", "B"] {
                #expect(!code.contains(bad), "\(code) contains \(bad)")
            }
        }
    }

    /// A shelf the sidebar offers and `Shelves` cannot name restores to the
    /// jobs table on every launch.
    @Test("the gift-cards shelf survives being written down and read back")
    func shelfRoundTrips() async throws {
        let shop = try await Self.shop()
        #expect(Shelves.name(.giftCards) == "gift-cards")
        #expect(Shelves.shelf("gift-cards", in: shop) == .giftCards)
    }
}

/// Will it go on a bed the shop owns?
///
/// The question a maker asks before any other, and one this app could not
/// answer: the rule was inside `mf-convert.js`, 1500 lines on top of Node's
/// zlib, so it could only be asked during a conversion.
@MainActor
struct PrintFitTests {

    static func shop() async throws -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        try #require(shop.engine != nil)
        return shop
    }

    static func machine(_ name: String, _ x: Double, _ y: Double, _ z: Double) -> JSONValue {
        .object(["name": .string(name),
                 "bed": .object(["x": .number(x), "y": .number(y), "z": .number(z)])])
    }

    /// A real model out of the shop's own library — 555 × 529 mm — against the
    /// one printer on its floor.
    @Test("a model far bigger than the bed fits nothing")
    func tooBig() async throws {
        let shop = try await Self.shop()
        let fit = try await #require(shop.engine).bestFit(
            (x: 555.51, y: 529.07, z: 47.48), among: [Self.machine("Snapmaker U1", 270, 270, 270)])
        #expect(fit.verdict == "none")
        #expect(fit.checked == 1, "the machine was not even tried")
    }

    @Test("a model that fits names the machine it fits")
    func fits() async throws {
        let shop = try await Self.shop()
        let fit = try await #require(shop.engine).bestFit(
            (x: 100, y: 100, z: 100), among: [Self.machine("Snapmaker U1", 270, 270, 270)])
        #expect(fit.verdict == "fits")
        guard case .object(let m)? = fit.machine else { Issue.record("no machine"); return }
        #expect(m["name"] == .string("Snapmaker U1"))
    }

    @Test("a model that only fits sideways says so rather than refusing")
    func sideways() async throws {
        let shop = try await Self.shop()
        let fit = try await #require(shop.engine).bestFit(
            (x: 290, y: 240, z: 50), among: [Self.machine("Narrow", 250, 300, 300)])
        #expect(fit.verdict == "rotate")
    }

    /// NOT KNOWING IS NOT A REFUSAL. A machine with no bed recorded is not a
    /// machine that turns the model away, and the screen stays silent — the
    /// inspector hides the line entirely when `checked` is zero.
    @Test("a machine with no bed is not counted as having refused anything")
    func unknownBed() async throws {
        let shop = try await Self.shop()
        let fit = try await #require(shop.engine).bestFit(
            (x: 555, y: 529, z: 47), among: [.object(["name": .string("Old printer")])])
        #expect(fit.checked == 0)
        #expect(fit.verdict == "none")
    }

    /// The words exist wherever the screen might say them.
    @Test("every verdict has something to say, in the shop's language")
    func wordsExist() async throws {
        let shop = try await Self.shop()
        for key in ["fit.title", "fit.yes", "fit.rotate", "fit.no"] {
            #expect(shop.words.callIt(key) != key, "\(key) has no translation")
        }
    }
}

/// The mark a shop's money is written with.
@MainActor
struct CurrencyMarkTests {
    /// U+20C0 is the codepoint everyone reaches for and it draws an empty box:
    /// it falls through to `LastResort`, Apple's tofu font, on this Mac and on
    /// an iPhone before it. The mark the system font actually carries is
    /// U+20C1, and this test exists so nobody "corrects" it back.
    @Test("the riyal is U+20C1, never U+20C0")
    func theRightCodepoint() {
        let source = BannerTests.source("Money.swift")
        #expect(source.contains("\\u{20C1}"), "the riyal mark moved off U+20C1")
        #expect(!source.contains("\\u{20C0}") || source.contains("NOT U+20C0"),
                "U+20C0 is being drawn, which is a box")
    }

    /// Only SAR, and only where the glyph exists. Every other currency keeps
    /// its code — one symbol for one shop must not become an assumption that
    /// every currency has one.
    @Test("other currencies keep their codes")
    func othersUnchanged() {
        for code in ["USD", "EUR", "AED", "GBP"] {
            #expect(Money.mark(code) == code)
            #expect(Money.text(1234.5, code).hasSuffix(" \(code)"))
        }
    }

    /// The fallback is the behaviour of yesterday, not a blank.
    @Test("SAR is either the mark or the letters, never nothing")
    func neverEmpty() {
        let mark = Money.mark("SAR")
        #expect(!mark.isEmpty)
        #expect(mark == "\u{20C1}" || mark == "SAR",
                "SAR rendered as something that is neither the mark nor the code: \(mark)")
        // And whichever it is, a figure carries it.
        #expect(Money.text(1243.08, "SAR").contains(mark))
        #expect(Money.short(52691.57, "SAR").contains(mark))
    }

    /// On a Mac whose font has the glyph, it is used. This asserts the machine
    /// the tests run on rather than the app — if it ever fails on a modern Mac,
    /// the detection has broken rather than the font.
    @Test("where the font has the glyph, the mark is what is shown")
    func usesItWhenAvailable() {
        if Money.drawsTheRiyal {
            #expect(Money.mark("SAR") == "\u{20C1}")
        } else {
            #expect(Money.mark("SAR") == "SAR")
        }
    }
}

/// Where a model came from, and whether a print of it may be sold.
@MainActor
struct LicenceStandingTests {

    static func shop() async throws -> Shop {
        let shop = Shop()
        await shop.load(.sample)
        try #require(shop.engine != nil)
        return shop
    }

    /// The question a print shop is actually asking, and the answer it must
    /// never guess at.
    @Test("a NonCommercial model says so; an unrecorded one says nothing")
    func sellable() async throws {
        let engine = try #require(try await Self.shop().engine)

        let nc = try await engine.licenceStanding(source: "printables.com/x", licence: "cc-by-nc")
        #expect(nc.known)
        #expect(nc.sellable == false)
        #expect(nc.attribution)

        let mine = try await engine.licenceStanding(source: "", licence: "own")
        #expect(mine.sellable == true)
        #expect(!mine.attribution)

        // NOT `false`. A library that has just been imported has recorded
        // nothing, and telling a shop it may not sell its own work would be
        // worse than saying nothing at all.
        let blank = try await engine.licenceStanding(source: "", licence: "")
        #expect(!blank.known)
        #expect(blank.sellable == nil, "an unrecorded licence was decided")
    }

    /// Every licence the menu offers has words in both languages, or the
    /// inspector shows a raw key like `plib.licence_cc_by_nc_sa`.
    @Test("every licence the rule offers can be said in the shop's language")
    func everyLicenceHasWords() async throws {
        let shop = try await Self.shop()
        for id in ["own", "cc0", "cc-by", "cc-by-sa", "cc-by-nd",
                   "cc-by-nc", "cc-by-nc-sa", "cc-by-nc-nd", "commercial"] {
            let key = "plib.licence_" + id.replacingOccurrences(of: "-", with: "_")
            #expect(shop.words.callIt(key) != key, "\(id) has no words")
        }
        for key in ["plib.source", "plib.licence", "plib.provenance"] {
            #expect(shop.words.callIt(key) != key, "\(key) has no words")
        }
    }
}
