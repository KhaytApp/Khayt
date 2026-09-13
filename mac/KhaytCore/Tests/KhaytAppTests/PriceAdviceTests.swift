import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Asking what to charge.
///
/// ── THE SMALLER HALF, AND THE OPTIONAL ONE ────────────────────────────────
///
/// The shop has already been shown its own median — computed on this Mac, net
/// of tax, with no model, no key and no network. What the model adds is a
/// second opinion that can weigh an outlier or a thin sample and say why.
///
/// So the thing to pin is that it stays a second opinion: it is grounded ONLY
/// in the comparables it is given, it never invents a price, and when it gives
/// nothing usable the shop's own median is what comes back rather than a
/// failure.
@MainActor
struct PriceAdviceTests {

    static func settings(price: Bool = true, master: Bool = true) -> [String: JSONValue] {
        ["ai": .object([
            "enabled": .bool(master), "provider": .string("anthropic"),
            "apiKey": .string("sk-test"),
            "features": .object(["price": .bool(price)]),
        ])]
    }

    /// Three PETG jobs at a 15% inclusive-VAT shop: 115/50, 230/100, 57.5/25.
    /// Gross that is 56.5%; what the shop KEPT is 50%.
    static let history: [JSONValue] = [
        .object(["status": .string("completed"), "price": .number(115),
                 "costBasis": .number(50), "date": .string("2026-09-01"),
                 "project": .string("A"), "parts": .array([.object(["material": .string("PETG")])])]),
        .object(["status": .string("completed"), "price": .number(230),
                 "costBasis": .number(100), "date": .string("2026-09-02"),
                 "project": .string("B"), "parts": .array([.object(["material": .string("PETG")])])]),
        .object(["status": .string("completed"), "price": .number(57.5),
                 "costBasis": .number(25), "date": .string("2026-09-03"),
                 "project": .string("C"), "parts": .array([.object(["material": .string("PETG")])])]),
    ]

    static let saudi: [String: JSONValue] = [
        "enableVat": .bool(true), "vatRate": .number(15),
        "vat": .string("310122393500003"), "country": .string("SA"),
    ]

    // MARK: - The comparables, which need no model at all

    @Test("the median is what the shop KEPT, not what it charged")
    func medianIsNetOfTax() async throws {
        let engine = try KhaytEngine()
        let c = try await engine.priceComparables(orders: Self.history, material: "PETG",
                                                  settings: Self.saudi)
        #expect(c.hasHistory)
        #expect(c.sameMaterial, "three PETG jobs did not count as same-material comparables")
        #expect(c.medianMarginPct == 50,
                Comment(rawValue: "median came out \(c.medianMarginPct ?? -1) — the gross is 56.5"))
        #expect(c.count == 3)
    }

    @Test("a shop with no priced history is told so, not shown a median of nothing")
    func noHistorySaysSo() async throws {
        let engine = try KhaytEngine()
        let c = try await engine.priceComparables(orders: [], material: "PETG", settings: [:])
        #expect(!c.hasHistory)
        #expect(c.basis == "none")
    }

    @Test("too few in a material falls back to everything, and says which")
    func thinSampleFallsBack() async throws {
        // A median over two jobs presented as "your margin on PETG" is the sort
        // of figure that gets acted on and should not be. `basis` is how the
        // screen knows to say "median of your finished jobs" instead.
        let engine = try KhaytEngine()
        let mixed = Self.history + [
            .object(["status": .string("completed"), "price": .number(300),
                     "costBasis": .number(90), "date": .string("2026-09-04"),
                     "parts": .array([.object(["material": .string("PLA")])])]),
        ]
        let one = try await engine.priceComparables(orders: mixed, material: "ABS", settings: [:])
        #expect(one.basis == "all", Comment(rawValue: "basis was \(one.basis)"))
        #expect(one.count == 4, "the fallback did not use every priced job")
    }

    // MARK: - The optional second opinion

    @Test("the model is given the comparables and told not to invent figures")
    func groundedInTheComparables() async throws {
        let engine = try KhaytEngine()
        let raw = try await engine.rawPriceComparables(orders: Self.history, material: "PETG",
                                                       settings: Self.saudi)
        let req = try await engine.aiPriceRequest(
            settings: Self.settings(), comparables: raw,
            job: .object(["material": .string("PETG"), "grams": .number(180),
                          "hours": .number(4.5), "cost": .number(60),
                          "currency": .string("SAR")]),
            shopName: "Tuwaiq Additive", language: "en", apiKey: "sk-test")
        guard case .object(let body) = req.body else { Issue.record("no body"); return }
        let text = String(data: try JSONEncoder().encode(body), encoding: .utf8) ?? ""
        #expect(text.contains("Comparable history"), "the comparables did not reach the model")
        #expect(text.contains("50"), "the shop's own median did not reach the model")
        guard case .string(let system)? = body["system"] else { Issue.record("no system"); return }
        #expect(system.contains("do not invent"), Comment(rawValue: system))
        #expect(system.contains("median"), "the model is not told to favour the median")
    }

    @Test("consent is checked where the data leaves")
    func consentIsChecked() async throws {
        let engine = try KhaytEngine()
        let raw = try await engine.rawPriceComparables(orders: Self.history, material: "PETG",
                                                       settings: [:])
        for (why, s) in [("the feature is off", Self.settings(price: false)),
                         ("AI assist is off", Self.settings(master: false))] {
            var said = ""
            do {
                _ = try await engine.aiPriceRequest(
                    settings: s, comparables: raw, job: .object([:]),
                    shopName: "T", language: "en", apiKey: "sk-test")
                Issue.record(Comment(rawValue: "a request was built when \(why)"))
            } catch { said = String(describing: error) }
            #expect(said.contains("AI_FEATURE_NOT_CONSENTED"),
                    Comment(rawValue: "\(why): refused with \(said)"))
        }
    }

    @Test("a useless answer falls back to the shop's OWN median, not to a failure")
    func fallsBackToTheShopsOwnNumber() async throws {
        // The median was computed on this Mac before anything was sent. If the
        // model refuses or answers with nothing, that number is still the right
        // answer — reporting a failure would throw away a figure the shop
        // already had.
        let engine = try KhaytEngine()
        let refused = JSONValue.object(["stop_reason": .string("refusal"), "content": .array([])])
        let out = try await engine.aiPriceRead(settings: Self.settings(), response: refused,
                                               fallbackMargin: 50)
        #expect(out.ok, "a refusal threw away the shop's own median")
        #expect(out.suggestedMargin == 50, Comment(rawValue: "\(out.suggestedMargin ?? -1)"))
    }

    @Test("with no median to fall back to, a refusal is a refusal")
    func noFallbackIsHonest() async throws {
        let engine = try KhaytEngine()
        let refused = JSONValue.object(["stop_reason": .string("refusal"), "content": .array([])])
        let out = try await engine.aiPriceRead(settings: Self.settings(), response: refused,
                                               fallbackMargin: nil)
        #expect(!out.ok)
        #expect(!(out.problem ?? "").isEmpty)
    }

    @Test("a recommendation comes back with its reason")
    func readsARecommendation() async throws {
        let engine = try KhaytEngine()
        let good = JSONValue.object(["content": .array([.object([
            "type": .string("tool_use"), "name": .string("price_advice"),
            "input": .object(["suggestedMargin": .number(44),
                              "suggestedPrice": .number(107.14),
                              "rationale": .string("Three comparables, one well above the rest.")]),
        ])])])
        let out = try await engine.aiPriceRead(settings: Self.settings(), response: good,
                                               fallbackMargin: 50)
        #expect(out.ok)
        #expect(out.suggestedMargin == 44)
        #expect(out.rationale?.contains("comparables") == true)
    }
}

/// That the button is reachable and the reason is always shown.
@MainActor
struct PriceAdviceWiringTests {

    static func source(_ file: String) throws -> String {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/KhaytApp")
        return try String(contentsOf: dir.appending(path: file), encoding: .utf8)
    }

    @Test("the job sheet offers it, only with consent, and shows the reason")
    func itIsReachable() throws {
        let sheet = try Self.source("NewJobSheet.swift")
        #expect(sheet.contains("shop.recommendMargin("), "nothing asks for a recommendation")
        #expect(sheet.contains("if shop.aiPriceAllowed"),
                "the button is offered on a shop that switched the feature off")
        // A margin that changed with no sentence beside it is a number a shop
        // cannot argue with when a customer does.
        #expect(sheet.contains("mac.advice_no_reason"),
                "a recommendation with no rationale would change the margin silently")
    }

    @Test("the comparables are shown without any of this")
    func theFreeHalfStandsAlone() throws {
        // The median needs no model, no key and no network, and must not be
        // behind the AI consent — that is most of the value of the feature.
        let sheet = try Self.source("NewJobSheet.swift")
        guard let shown = sheet.range(of: "if let c = comparables, c.hasHistory"),
              let gate = sheet.range(of: "if shop.aiPriceAllowed") else {
            Issue.record("could not find both the comparables and the AI gate"); return
        }
        #expect(shown.lowerBound < gate.lowerBound,
                "the shop's own median is drawn inside the AI consent gate")
    }
}
