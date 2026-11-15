import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// New Job's total is the rule's (`lib/order-new.js previewTotal`), and so the
/// desktop's.
///
/// ── WHAT THIS SUITE IS GUARDING ───────────────────────────────────────────
///
/// The Mac shows the exact total the desktop shows for the same input, and
/// both show the price `newOrder` records. The cases are the desktop's own
/// (`test/order-new-preview.test.js`): a plain cart, a discount, rush and
/// shipping, rounding, a typed total, an agreed part, extra lines with a
/// percentage, a customer in another currency, and the overhead line. Each is
/// previewed and then really made, as a job and as a quote, and the two
/// figures have to be the same number.
@MainActor
struct NewJobPreviewParityTests {

    static func part(_ over: [String: JSONValue] = [:]) -> JSONValue {
        var p: [String: JSONValue] = ["name": .string("p.stl"), "material": .string("PLA"), "qty": .number(1),
                                      "printWeight": .number(100), "printTime": .number(2),
                                      "unitCost": .number(40), "baseCost": .number(40)]
        for (k, v) in over { p[k] = v }
        return .object(p)
    }

    static let clients: [JSONValue] = [.object(["id": .string("C-EUR"), "currency": .string("EUR")])]
    static let settings: [String: JSONValue] = [
        "currency": .string("SAR"), "invNumNext": .number(7), "quoteNumNext": .number(3),
        "rushFeePct": .number(25), "currencyRates": .object(["EUR": .number(4)])]
    // NOTE: the desktop's vectors set `currencyRates`, but the rule reads
    // `exchangeRates` (`jobCurrency`), so its "another currency" cart has no
    // rate and is priced in the shop's. Kept as it is, to stay the desktop's
    // case; `aCustomerAbroad` below is the one with a real rate.

    /// The desktop's nine carts, and what its own run of them comes to (the
    /// job's price), so a change to either app's arithmetic is caught here.
    static let cases: [(name: String, input: [String: JSONValue])] = [
        ("plain", ["parts": .array([part()]), "margin": .number(30)]),
        ("two parts, a discount", ["parts": .array([part(), part(["qty": .number(3), "baseCost": .number(120)])]),
                                   "margin": .number(55), "discountPct": .number(10)]),
        ("rush and shipping", ["parts": .array([part()]), "margin": .number(30),
                               "rushEnabled": .bool(true), "shippingCost": .number(25)]),
        ("rounded up to 5", ["parts": .array([part()]), "margin": .number(30),
                             "priceRound": .object(["step": .number(5), "mode": .string("up")])]),
        ("a typed total", ["parts": .array([part()]), "margin": .number(30), "priceOverride": .number(99)]),
        ("an agreed part", ["parts": .array([part(["agreedPrice": .number(70)]), part()]), "margin": .number(40)]),
        ("extra lines, one a percentage", ["parts": .array([part()]), "margin": .number(30),
            "extraLines": .array([.object(["label": .string("Paint"), "amount": .number(15)]),
                                  .object(["label": .string("Fee"), "pct": .number(5)])])]),
        ("a customer in another currency", ["parts": .array([part()]), "margin": .number(30),
                                            "clientId": .string("C-EUR")]),
        ("the overhead line", ["parts": .array([part()]), "margin": .number(30), "overheadPerHour": .number(3)]),
    ]

    @Test("the total shown is the price recorded, for each of the desktop's carts, as a job and as a quote")
    func previewIsThePriceRecorded() async throws {
        let engine = try KhaytEngine()
        for (name, base) in Self.cases {
            for asQuote in [false, true] {
                var input = base
                input["asQuote"] = .bool(asQuote)
                let shown = try await engine.previewNewOrder(input, settings: Self.settings, clients: Self.clients)
                let made = try await engine.newOrder(input, orders: [], settings: Self.settings,
                                               now: Date(timeIntervalSince1970: 1_794_733_200),
                                               tokens: (tracking: [UInt8](repeating: 0, count: 16),
                                                        quoteApproval: [UInt8](repeating: 0, count: 16)),
                                               clients: Self.clients)
                let record = try #require(Shop.asObject(made.order))
                #expect(Shop.plainNumber(record["price"]) == shown.total, "\(name)\(asQuote ? " (quote)" : "")")
                #expect(Shop.plainString(record["currency"]) == shown.currency, "\(name): currency")
            }
        }
    }

    @Test("the figures themselves: what both apps show for the plain carts")
    func theFigures() async throws {
        let engine = try KhaytEngine()
        func total(_ name: String) async throws -> KhaytEngine.NewOrderPreview {
            let input = try #require(Self.cases.first { $0.name == name }).input
            return try await engine.previewNewOrder(input, settings: Self.settings, clients: Self.clients)
        }
        let plain = try await total("plain"), rounded = try await total("rounded up to 5")
        let typed = try await total("a typed total"), agreed = try await total("an agreed part")
        #expect(plain.total == 52, "40 of cost at 30%")
        #expect(rounded.total == 55)
        #expect(typed.total == 99)
        #expect(typed.quote.priceSource == "override")
        #expect(agreed.total == 126, "70 agreed, and 40 at 40%")
        #expect(plain.currency == nil, "a job in the shop's own currency carries none")
        let noRate = try await total("a customer in another currency")
        #expect(noRate.total == 52 && noRate.currency == "SAR", "no rate on file: priced in the shop's currency, and said")
    }

    @Test("a customer kept in euros with a rate on file is previewed in euros, at the price recorded")
    func aCustomerAbroad() async throws {
        let engine = try KhaytEngine()
        var settings = Self.settings
        settings["exchangeRates"] = .object(["EUR": .number(0.25)])
        let input: [String: JSONValue] = ["parts": .array([Self.part()]), "margin": .number(30), "clientId": .string("C-EUR")]
        let shown = try await engine.previewNewOrder(input, settings: settings, clients: Self.clients)
        #expect(shown.currency == "EUR" && shown.total == 208)
        let made = try await engine.newOrder(input, orders: [], settings: settings, now: Date(),
                                             tokens: (tracking: [UInt8](repeating: 0, count: 16),
                                                      quoteApproval: [UInt8](repeating: 0, count: 16)),
                                             clients: Self.clients)
        let record = try #require(Shop.asObject(made.order))
        #expect(Shop.plainNumber(record["price"]) == 208 && Shop.plainString(record["currency"]) == "EUR")
    }

    @Test("showing the total allocates nothing")
    func previewMovesNoCounter() async throws {
        let engine = try KhaytEngine()
        // The settings go in by value; the rule is asked twice and must answer the same.
        let input = Self.cases[0].input
        let first = try await engine.previewNewOrder(input, settings: Self.settings, clients: Self.clients)
        let again = try await engine.previewNewOrder(input, settings: Self.settings, clients: Self.clients)
        #expect(first == again)
    }

    @Test("a job needs a part")
    func canTake() async throws {
        let engine = try KhaytEngine()
        let empty = try await engine.canTakeNewOrder(["parts": .array([])])
        let none = try await engine.canTakeNewOrder([:])
        let one = try await engine.canTakeNewOrder(["parts": .array([Self.part()])])
        #expect(!empty.ok && empty.reason == "no_parts")
        #expect(!none.ok && none.reason == "no_parts")
        #expect(one.ok && one.reason == nil)
    }

    @Test("the sheet previews and saves ONE input, through the rule")
    func theSheetIsWired() {
        let sheet = EmptyStateTests.source("NewJobSheet.swift")
        #expect(sheet.contains("let preview = await shop.previewNewJob(input)"))
        #expect(sheet.contains("takeable = await shop.canTakeNewJob(input)"))
        #expect(sheet.contains("await shop.createJob(jobInput(asQuote: asQuote))"))
        #expect(!sheet.contains("shop.previewQuote("), "the sheet builds its own price input again")
        #expect(sheet.components(separatedBy: "shop.newJobInput(").count - 1 == 1, "one builder for both")
    }
}
