import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Prep once per line, finishing per piece, packaging by the box (#2586,
/// Turki, Nov 19) on the Mac: `test/fixtures/line-labour-vectors.json`, the
/// file `test/line-labour-vectors.test.js` holds lib to, through the Mac's
/// engine; and the Mac's own paths that must carry the mark.
@Suite struct LineLabourTests {

    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "test/fixtures")

    static func obj(_ v: JSONValue?) -> [String: JSONValue] {
        if case .object(let o)? = v { return o }
        return [:]
    }
    static func num(_ v: JSONValue?) -> Double? {
        if case .number(let n)? = v { return n }
        return nil
    }
    static func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    @Test("the 18 shared vectors, through the Mac's engine")
    func vectors() async throws {
        let file = try JSONValue.decode(JSONValue.self, from: Data(contentsOf: Self.fixtures.appending(path: "line-labour-vectors.json")))
        let v = Self.obj(file)
        guard case .array(let cases)? = v["cases"] else { Issue.record("no cases"); return }
        #expect(cases.count >= 18)
        let settings = Self.obj(v["settings"])
        let rates = Self.obj(v["rates"])
        let engine = try KhaytEngine()
        let product: [String: JSONValue] = ["id": .string("PR"), "rates": .object(rates), "parts": .array([
            .object(["name": .string("a"), "printWeight": .number(0), "printTime": .number(0), "qty": .number(1)]),
            .object(["name": .string("b"), "printWeight": .number(0), "printTime": .number(0), "qty": .number(2)])])]
        func part(_ c: [String: JSONValue]) -> [String: JSONValue] {
            var p: [String: JSONValue] = ["name": .string("p"), "printWeight": c["printWeight"] ?? .number(0),
                                          "printTime": .number(0), "spoolCost": c["spoolCost"] ?? .number(0),
                                          "spoolWeight": c["spoolWeight"] ?? .number(1000), "qty": c["qty"] ?? .number(1)]
            if let b = c["perBox"] { p["perBox"] = b }
            if c["unmarked"] != .bool(true) { p["labourPerLine"] = .bool(true) }
            for (k, x) in rates { p[k] = x }
            return p
        }
        var kinds = Set<String>()
        for value in cases {
            let c = Self.obj(value)
            let why: String = { if case .string(let s)? = c["why"] { return s }; return "?" }()
            let kind: String = { if case .string(let s)? = c["kind"] { return s }; return "" }()
            kinds.insert(kind)
            let want = c["want"]
            switch kind {
            case "lineLabour":
                var line: [String: JSONValue] = ["qty": c["qty"] ?? .number(1)]
                if c["unmarked"] != .bool(true) { line["labourPerLine"] = .bool(true) }
                for (k, x) in rates { line[k] = x }
                #expect(Self.r2(try await engine.lineLabour(.object(line))) == Self.num(want), Comment(rawValue: why))
            case "part":
                var s = settings
                if c["packaging"] != .bool(true) { s["defaultPackagingCost"] = .number(0) }
                let p = part(c)
                let costed = try await engine.costPart(.object(p), inventory: [], settings: s)
                let qty = Self.num(p["qty"]) ?? 1
                #expect(Self.r2(costed.cost * qty) == Self.num(want), Comment(rawValue: why))
            case "product", "store":
                var prod = product
                if let b = c["perBox"] { prod["perBox"] = b }
                let units = Int(Self.num(c["units"]) ?? 1)
                let jp = try await engine.productJobParts(.object(prod), inventory: [], settings: settings,
                                                          consumables: [], units: units)
                let w = Self.obj(want)
                #expect(Self.r2(jp.labourCost) == Self.num(w["labourCost"]), Comment(rawValue: why))
                #expect(Self.r2(jp.packagingCost) == Self.num(w["packagingCost"]), Comment(rawValue: why))
                let qtys = jp.parts.map { Self.num(Self.obj($0)["qty"]) }
                if case .array(let wq)? = w["partQty"] { #expect(qtys == wq.map { Self.num($0) }, Comment(rawValue: why)) }
            case "agreed":
                var p = part(c)
                var s = settings; s["defaultPackagingCost"] = .number(0)
                let costed = try await engine.costPart(.object(p), inventory: [], settings: s)
                p["baseCost"] = .number(costed.cost * (Self.num(p["qty"]) ?? 1))
                p["agreedPrice"] = c["agreedPrice"]
                let out = try await engine.newOrder(["parts": .array([.object(p)]), "project": .string("A"),
                                                     "margin": .number(30), "asQuote": .bool(true)],
                                                    orders: [], settings: settings,
                                                    now: Date(timeIntervalSince1970: 1_795_593_600),
                                                    tokens: (tracking: Array(repeating: 0, count: 16),
                                                             quoteApproval: Array(repeating: 0, count: 16)))
                let job = Self.obj(out.order)
                let w = Self.obj(want)
                #expect(Self.num(job["price"]) == Self.num(w["price"]), Comment(rawValue: why))
                if case .array(let parts)? = job["parts"] {
                    #expect(Self.r2(Self.num(Self.obj(parts.first)["baseCost"]) ?? -1) == Self.num(w["baseCost"]), Comment(rawValue: why))
                }
            case "legacyProduct":
                var prod: [String: JSONValue] = ["id": .string("OLD"), "defaultMargin": .number(30)]
                var p: [String: JSONValue] = ["name": .string("p"), "printWeight": .number(0), "printTime": .number(0),
                                              "qty": c["qty"] ?? .number(1)]
                for (k, x) in rates { p[k] = x }
                prod["parts"] = .array([.object(p)])
                if c["newCost"] == .bool(true) { prod["rates"] = .object(rates) }
                let w = Self.obj(want)
                let priced = try await engine.priceProduct(.object(prod), inventory: [], settings: settings, consumables: [])
                #expect(priced.cost == Self.num(w["cost"]), Comment(rawValue: "\(why): catalogue"))
                let jp = try await engine.productJobParts(.object(prod), inventory: [], settings: settings, consumables: [])
                let fromJob = jp.parts.reduce(0) { $0 + (Self.num(Self.obj($1)["baseCost"]) ?? 0) } + jp.labourCost + jp.packagingCost
                #expect(Self.r2(fromJob) == Self.num(w["cost"]), Comment(rawValue: "\(why): a job from it"))
                for row in jp.parts {
                    #expect((Self.obj(row)["labourPerLine"] == .bool(true)) == (c["newCost"] == .bool(true)),
                            Comment(rawValue: "\(why): the mark only on a product with its own rates"))
                }
            default:
                Issue.record("unknown kind \(kind)")
            }
        }
        #expect(kinds == ["lineLabour", "part", "product", "agreed", "store", "legacyProduct"])
    }

    /// Unsaid is ONE box for the line (a hand part's packaging, as always);
    /// a product passes its own, 1 by default (a box each).
    @Test("boxes: ceil(qty / perBox); unsaid is one box for the line")
    func boxes() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.lineBoxes(qty: 10, perBox: nil) == 1)
        #expect(try await engine.lineBoxes(qty: 10, perBox: 1) == 10)
        #expect(try await engine.lineBoxes(qty: 10, perBox: 4) == 3)
        #expect(try await engine.lineBoxes(qty: 10, perBox: 12) == 1)
    }

    /// Money review of #2586 (b): `partRows` wrote a fixed key set, so a
    /// desktop part on the new rule came back from a Mac save unmarked, on the
    /// old sum. Keys it does not own now survive; keys it does own are the
    /// sheet's, so a value the sheet removed does not come back from the old
    /// record.
    @MainActor @Test("partRows keeps the keys it does not own, and decides the ones it does")
    func partRowsPassThrough() {
        var d = NewJobSheet.Draft()
        d.name = "Bracket"; d.grams = "10"; d.hours = "1"; d.qty = 4; d.cost = 2.5
        d.raw = ["labourPerLine": .bool(true), "perBox": .number(4), "someFutureKey": .string("kept"),
                 "id": .string("P-old"), "agreedPrice": .number(9), "unitCost": .number(99), "name": .string("old name")]
        d.agreedPrice = nil
        let rows = Shop.partRows([d], spools: [], unnamed: "Part")
        guard case .object(let row)? = rows.first else { Issue.record("no row"); return }
        #expect(row["labourPerLine"] == .bool(true))
        #expect(row["perBox"] == .number(4))
        #expect(row["someFutureKey"] == .string("kept"))
        #expect(row["id"] == nil, "a copied job must not carry the old part's id")
        #expect(row["agreedPrice"] == nil, "the sheet removed the agreed price")
        #expect(row["unitCost"] == .number(2.5))
        #expect(row["baseCost"] == .number(10))
        #expect(row["name"] == .string("Bracket"))
    }

    /// A new part is marked where it is made, as the desktop marks it.
    @MainActor @Test("a new part carries labourPerLine")
    func newPartMark() {
        #expect(Shop.newPartMark == ["labourPerLine": .bool(true)])
    }

    /// An online order's product line is the pieces still to print, as the
    /// shared store-order rule builds it (`all ? qty : toPrint`).
    @MainActor @Test("an online line's count: to print, or all when the shelf covers the order")
    func lineUnits() throws {
        let some = Self.order(qty: 5, toPrint: 2, all: false)
        #expect(Shop.lineUnits(some, try #require(some.lines.first)) == 2)
        let none = Self.order(qty: 3, toPrint: 0, all: false)
        #expect(Shop.lineUnits(none, try #require(none.lines.first)) == 0)
        let shelf = Self.order(qty: 3, toPrint: 0, all: true)
        #expect(Shop.lineUnits(shelf, try #require(shelf.lines.first)) == 3)
    }

    @MainActor static func order(qty: Int, toPrint: Int, all: Bool) -> Shop.OnlineOrder {
        let reading: JSONValue = .object([
            "lines": .array([.object([
                "name": .string("Bracket"), "qty": .number(Double(qty)), "productId": .string("PR"),
                "onShelf": .number(0), "fromShelf": .number(Double(qty - toPrint)),
                "toPrint": .number(Double(toPrint))])]),
            "allFromShelf": .bool(all)])
        return Shop.OnlineOrder(item: CloudIntake.Item(id: "1", payload: .object([:]), createdAt: Date()),
                                reading: reading)
    }
}

/// The product sheet's "For N pieces" (Figma 180:223): every figure from the
/// rule, and the boxes it counts are the boxes the packaging was charged for.
@MainActor @Suite struct ProductLinePreviewTests {
    @Test("a product of 10, 4 to a box: 3 boxes, labour prep once + post × 10")
    func preview() async throws {
        let shop = Shop()
        await shop.load(.sample)
        var settings = shop.settingsDict
        let rates: [String: JSONValue] = ["laborRate": .number(90), "prepTime": .number(0.25), "postTime": .number(0.5),
                                          "wearRate": .number(0), "powerDraw": .number(0), "elecRate": .number(0),
                                          "failureRate": .number(10)]
        settings["defaultPackagingCost"] = .number(5)
        shop.settingsValue = .object(settings)
        let part: JSONValue = .object(["name": .string("a"), "printWeight": .number(0), "printTime": .number(0), "qty": .number(1)])
        var record: [String: JSONValue] = ["parts": .array([part]), "rates": .object(rates)]
        let unsaid = try #require(await shop.productLine(.object(record), units: 10))
        #expect(unsaid.boxes == 10, "a product unsaid is a box each")
        #expect(LineLabourTests.r2(unsaid.packaging) == 55)
        record["perBox"] = .number(4)
        let line = try #require(await shop.productLine(.object(record), units: 10))
        #expect(line.boxes == 3)
        #expect(LineLabourTests.r2(line.packaging) == 16.5)
        #expect(LineLabourTests.r2(line.labour) == 519.75)
        #expect(LineLabourTests.r2(line.cost) == LineLabourTests.r2(line.parts + line.labour + line.packaging))
    }
}

/// Edit Job, a part edit (`partEditCost(raw:)`) and a copied job
/// (`jobParts(fromRows:)`) all cost a part through `costedPart(extra: raw)`:
/// the part's own mark decides its labour, so an old part stays on the old
/// sum and a new one keeps prep once.
@MainActor @Suite struct PartMarkCostingTests {
    @Test("the part's own mark decides: prep once (marked) or on every piece (stored)")
    func markDecides() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let rates: [String: JSONValue] = ["laborRate": .number(90), "prepTime": .number(0.25), "postTime": .number(0.5),
                                          "wearRate": .number(0), "powerDraw": .number(0), "elecRate": .number(0),
                                          "failureRate": .number(10)]
        var marked = rates; marked["labourPerLine"] = .bool(true)
        let old = try #require(await shop.costedPart(spoolId: nil, grams: 0, hours: 0.0001, qty: 10, extra: rates))
        let new = try #require(await shop.costedPart(spoolId: nil, grams: 0, hours: 0.0001, qty: 10, extra: marked))
        // Prep 0.25 h × 90 × 1.1 charged nine times fewer on a line of 10.
        #expect(LineLabourTests.r2((old.cost - new.cost) * 10) == 222.75)
    }
}
