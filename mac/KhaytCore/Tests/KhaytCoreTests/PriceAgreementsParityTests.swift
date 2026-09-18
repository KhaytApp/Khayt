import Foundation
import Testing
@testable import KhaytCore

/// A customer's agreed prices, against the JavaScript they came from.
///
/// This decides what a customer is charged, and the module's own note records
/// what happened the last time it was slightly wrong: the agreed figure went
/// into the COST, so the job's margin went on top of it — a part agreed at 50
/// on a 30% job billed 65, and the profit report showed it sold at cost.
///
/// So the rule that gets tested hardest is the one that looks like a detail:
/// the FIRST entry whose product the name contains wins, even when that entry
/// has no price.
@MainActor
struct PriceAgreementsParityTests {

    private func js() throws -> JSModule { try JSModule(["price-agreements"]) }

    private func theirPrice(_ js: JSModule, _ list: [JSONValue],
                            _ name: JSONValue) throws -> Double? {
        let answer = try js.value("""
            (function (list, name) {
              var e = globalThis.KhaytPriceAgreements.find(list, name);
              return e ? +e.price : null;
            })(ARG0, ARG1)
            """, [.array(list), name])
        if case .number(let n) = answer { return n }
        return nil
    }

    private func checkPrice(_ list: [JSONValue], _ name: JSONValue,
                            _ what: String, _ js: JSModule) throws {
        let mine = PriceAgreements.price(in: list, name: name)
        let theirs = try theirPrice(js, list, name)
        #expect(mine == theirs, Comment(rawValue:
            "\(what): swift \(mine.map { "\($0)" } ?? "nil") vs js \(theirs.map { "\($0)" } ?? "nil")"))
    }

    private func agreement(_ product: JSONValue?, _ price: JSONValue?) -> JSONValue {
        var e: [String: JSONValue] = [:]
        if let product { e["product"] = product }
        if let price { e["price"] = price }
        return .object(e)
    }

    @Test("a real customer's price list")
    func realList() throws {
        let js = try js()
        let list = [agreement(.string("bracket"), .number(12.50)),
                    agreement(.string("keychain"), .number(8)),
                    agreement(.string("lamp shade"), .number(45))]
        for name in ["Turbine bracket", "bracket", "BRACKET", "Keychain ×4",
                     "lamp shade, large", "Lamp Shade", "dragon bust", "", "  "] {
            try checkPrice(list, .string(name), "part \(name.debugDescription)", js)
        }
    }

    @Test("the FIRST match wins, even when it has no price")
    func firstMatchWinsWithoutAPrice() throws {
        // A shop that wrote a product down with no price has said "this one is
        // not agreed". A later entry must not quietly stand in for it, or a
        // part the shop deliberately left open gets priced.
        let js = try js()
        let list = [agreement(.string("bracket"), .number(0)),
                    agreement(.string("brack"), .number(99))]
        try checkPrice(list, .string("Turbine bracket"), "zero first", js)
        #expect(PriceAgreements.price(in: list, name: .string("Turbine bracket")) == nil,
                "a later entry stood in for one the shop left unpriced")

        // And the other way round, so the test is about ORDER and not about
        // zero.
        let reversed = [agreement(.string("brack"), .number(99)),
                        agreement(.string("bracket"), .number(0))]
        try checkPrice(reversed, .string("Turbine bracket"), "zero second", js)
        #expect(PriceAgreements.price(in: reversed, name: .string("Turbine bracket")) == 99)
    }

    @Test("a price that is not a positive number is not an agreement")
    func pricesMustBePositive() throws {
        let js = try js()
        // `"Infinity"` is the bridge artifact pinned below: both sides find
        // the entry and only JSON loses the figure.
        let numbers = Awkward.numbers.filter { $0.isFinite && abs($0) < 1e300 }
        let notNumbers = Awkward.notNumbers.filter { $0 != .string("Infinity") }
        for value in notNumbers + numbers.map({ JSONValue.number($0) }) {
            try checkPrice([agreement(.string("bracket"), value)],
                           .string("Turbine bracket"), "price \(value)", js)
        }
        try checkPrice([agreement(.string("bracket"), nil)],
                       .string("Turbine bracket"), "no price field", js)
    }

    @Test("the part name contains the product, not the other way round")
    func matchDirection() throws {
        // "Turbine bracket" matches "bracket". "bracket" does NOT match
        // "Turbine bracket" — getting this backwards prices nothing at all.
        let js = try js()
        try checkPrice([agreement(.string("Turbine bracket"), .number(50))],
                       .string("bracket"), "product longer than the name", js)
        try checkPrice([agreement(.string("bracket"), .number(50))],
                       .string("Turbine bracket"), "name longer than the product", js)
        #expect(PriceAgreements.price(in: [agreement(.string("bracket"), .number(50))],
                                      name: .string("Turbine bracket")) == 50)
    }

    @Test("a product or a name that is not a string")
    func oddFields() throws {
        let js = try js()
        for value in [JSONValue.null, .string(""), .number(7), .bool(true), .bool(false),
                      .array([]), .object([:])] {
            try checkPrice([agreement(value, .number(10)),
                            agreement(.string("bracket"), .number(20))],
                           .string("Turbine bracket 7"), "product \(value)", js)
            try checkPrice([agreement(.string("bracket"), .number(20))],
                           value, "name \(value)", js)
        }
    }

    @Test("an agreed price past Double's range is found here, and lost by the bridge")
    func infinitePriceCrossesTheBridgeAsNull() throws {
        // `+"Infinity" > 0` is true, so both sides FIND the agreement. JSON
        // then writes `null`, and a host reading the figure gets nothing —
        // the same artifact pinned in the other ports. Natively the figure
        // survives, which is one fewer place a price can vanish.
        let js = try js()
        let list = [agreement(.string("bracket"), .string("Infinity"))]
        #expect(PriceAgreements.price(in: list, name: .string("Turbine bracket"))?.isInfinite == true)
        guard case .bool(true) = try js.value("""
            !!globalThis.KhaytPriceAgreements.find(ARG0, "Turbine bracket")
            """, [.array(list)]) else {
            Issue.record("the original stopped finding it — this note can go"); return
        }
        #expect(try theirPrice(js, list, .string("Turbine bracket")) == nil,
                "JSON no longer drops it")
    }

    @Test("a list that is not a list, and entries that are not entries")
    func degenerateLists() throws {
        let js = try js()
        try checkPrice([], .string("bracket"), "empty list", js)
        try checkPrice([.null, .bool(false), .number(0), .string("x"),
                        agreement(.string("bracket"), .number(20))],
                       .string("Turbine bracket"), "a mix", js)
        try checkPrice([.null, .string("x")], .string("bracket"), "nothing usable", js)
    }

    @Test("applying to a cart prices the parts it covers and clears the rest")
    func applyMatches() throws {
        let js = try js()
        let list = [agreement(.string("bracket"), .number(12.5)),
                    agreement(.string("keychain"), .number(8))]
        let parts: [JSONValue] = [
            .object(["name": .string("Turbine bracket"), "unitCost": .number(30)]),
            .object(["name": .string("Keychain"), "unitCost": .number(3),
                     // Left by a PREVIOUS customer — the cart belongs to this
                     // one now.
                     "agreedPrice": .number(999)]),
            .object(["name": .string("Dragon bust"), "unitCost": .number(80),
                     "agreedPrice": .number(555)]),
            .object(["unitCost": .number(1)]),
        ]
        let mine = PriceAgreements.apply(to: parts, priceList: list)
        guard case .array(let theirs) = try js.value("""
            (function (parts, list) {
              var n = globalThis.KhaytPriceAgreements.apply(parts, list);
              return [parts, n];
            })(ARG0, ARG1)[0]
            """, [.array(parts), .array(list)]) else { Issue.record("no answer"); return }
        #expect(mine.parts == theirs, Comment(rawValue:
            "\n  swift \(mine.parts)\n  js    \(theirs)"))
        #expect(mine.applied == 2, "the count is what tells a host whether to say anything")

        // Said outright: the cost is untouched and the stale figure is gone.
        guard case .object(let bust) = mine.parts[2] else { Issue.record("no part"); return }
        #expect(bust["agreedPrice"] == nil, "a previous customer's price survived")
        #expect(bust["unitCost"] == .number(80), "the cost was changed — it is a PRICE, not a cost")
        guard case .object(let bracket) = mine.parts[0] else { Issue.record("no part"); return }
        #expect(bracket["agreedPrice"] == .number(12.5))
        #expect(bracket["unitCost"] == .number(30), "the agreed figure went into the cost again")
    }

    @Test("the applied count is what a host says 'applied' on")
    func appliedCountMatches() throws {
        let js = try js()
        let list = [agreement(.string("bracket"), .number(12.5))]
        for parts in [[], [.object(["name": .string("nope")])],
                      [.object(["name": .string("bracket")])],
                      [.object(["name": .string("bracket")]), .object(["name": .string("bracket")])],
                      [.null, .object(["name": .string("bracket")])]] as [[JSONValue]] {
            let mine = PriceAgreements.apply(to: parts, priceList: list).applied
            guard case .number(let theirs) = try js.value(
                "globalThis.KhaytPriceAgreements.apply(ARG0, ARG1)",
                [.array(parts), .array(list)]) else { Issue.record("no count"); continue }
            #expect(mine == Int(theirs),
                    Comment(rawValue: "\(parts.count) parts: swift \(mine) vs js \(Int(theirs))"))
        }
    }
}
