import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A job's cost on the Mac comes from ONE place: the shared rule
/// (`lib/order-money.js jobCost`, #2581), through the engine. The #2581 money
/// review found the ledger summing `costBasis + componentsCost` itself, which
/// missed overhead and a product's labour and packaging, and compared a
/// shop-currency cost with a foreign-currency price.
@Suite struct JobCostTests {

    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Sources/KhaytApp")

    /// The ratchet: no Swift outside the engine bridge adds up a job's cost
    /// fields. A new reader goes through `OrderFigures.cost` / `jobCost`.
    @Test("no direct sums of a job's cost fields in the app")
    func ratchet() throws {
        let fields = "(costBasis|componentsCost|overheadCost|labourCost|packagingCost|baseCost)"
        // A field next to a + or a reduce, on a line that is not a comment.
        let sum = try Regex("(\\.\(fields)\\b\\s*[+])|([+]\\s*[A-Za-z_.?()]*\\.\(fields)\\b)|(reduce[^\\n]*\\.\(fields)\\b)")
        var hits: [String] = []
        let files = try FileManager.default.contentsOfDirectory(at: Self.sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") || code.hasPrefix("///") { continue }
                if code.contains(sum) { hits.append("\(file.lastPathComponent):\(n + 1): \(code)") }
            }
        }
        #expect(hits.isEmpty, "sum a job's cost through OrderFigures.cost / KhaytEngine.jobCost:\n\(hits.joined(separator: "\n"))")
    }

    /// The figure the ledger reads: parts, components, overhead, labour and
    /// packaging, in the job's currency.
    @MainActor @Test("OrderFigures.cost is jobCost; a USD job's ledger margin is in SAR, both sides")
    func figuresCost() async throws {
        let engine = try KhaytEngine()
        let sar: JSONValue = .object(["id": .string("A"), "price": .number(300), "costBasis": .number(100),
                                      "parts": .array([.object(["baseCost": .number(100)])]),
                                      "componentsCost": .number(10), "overheadCost": .number(5),
                                      "labourCost": .number(74.25), "packagingCost": .number(5)])
        let usd: JSONValue = .object(["id": .string("B"), "price": .number(80), "currency": .string("USD"),
                                      "fxRate": .number(3.75), "costBasis": .number(150),
                                      "parts": .array([.object(["baseCost": .number(150)])])])
        let figures = try await engine.orderFigures([sar, usd], settings: ["currency": .string("SAR")], clients: [])
        let shared = try await engine.jobCost(sar)
        #expect(abs((figures["A"]?.cost ?? -1) - shared) < 1e-9)
        #expect(abs(shared - 194.25) < 1e-9, "parts + components + overhead + labour + packaging")
        #expect(figures["B"]?.cost == 150 && figures["B"]?.fx == 3.75)
        // An 80 USD job at 3.75 that cost 150 SAR: 300 SAR charged, 150 SAR made,
        // 50%. Before: 80 − 150 = −70, "sold below cost".
        var b = try JSONDecoder().decode(Order.self, from: JSONEncoder().encode(usd))
        b.figures = figures["B"]
        let money = Shop.ledgerMoney(b)
        #expect(money.charged == 300)
        #expect(money.marginMoney.map { abs($0 - 150) < 1e-9 } == true, "\(String(describing: money.marginMoney))")
        #expect(money.margin.map { abs($0 - 0.5) < 1e-9 } == true)
        // The same job in SAR reads the same.
        let sarJob: JSONValue = .object(["id": .string("C"), "price": .number(300), "costBasis": .number(150),
                                         "parts": .array([.object(["baseCost": .number(150)])])])
        var c = try JSONDecoder().decode(Order.self, from: JSONEncoder().encode(sarJob))
        c.figures = try await engine.orderFigures([sarJob], settings: ["currency": .string("SAR")], clients: [])["C"]
        #expect(Shop.ledgerMoney(c).marginMoney == money.marginMoney)
    }

    /// The ledger measures a job's margin without its overhead, as the
    /// desktop's Orders Log does (`jobCost(o, {overhead: false})`; release
    /// money review M3). `OrderFigures.cost` keeps it for every other reader.
    @MainActor @Test("the ledger's cost leaves the overhead out, as the desktop's Orders Log")
    func ledgerWithoutOverhead() async throws {
        let engine = try KhaytEngine()
        let job: JSONValue = .object(["id": .string("A"), "price": .number(300), "costBasis": .number(100),
                                      "parts": .array([.object(["baseCost": .number(100)])]),
                                      "overheadCost": .number(20)])
        let figures = try #require(try await engine.orderFigures([job], settings: ["currency": .string("SAR")], clients: [])["A"])
        #expect(figures.cost == 120, "OrderFigures.cost keeps the overhead")
        #expect(figures.costWithoutOverhead == (try await engine.jobCost(job, overhead: false)))
        #expect(figures.costWithoutOverhead == 100)
        var order = try JSONDecoder().decode(Order.self, from: JSONEncoder().encode(job))
        order.figures = figures
        let money = Shop.ledgerMoney(order)
        #expect(money.marginMoney.map { abs($0 - 200) < 1e-9 } == true, "300 − 100: the overhead is not in the ledger's cost")
    }

    /// A part of a product that charges its labour once carries
    /// `orderLevelCosts` (#2581). Re-costed, it is costed without labour and
    /// packaging; an unmarked part on the same job (one added by hand) keeps
    /// them, as on the desktop. And the Mac writes the mark when it saves.
    @MainActor @Test("a marked part is costed without labour, and the mark is saved")
    func markedPart() async throws {
        let engine = try KhaytEngine()
        var fields: [String: JSONValue] = ["printWeight": .number(50), "printTime": .number(2), "qty": .number(1),
                                           "spoolCost": .number(80), "spoolWeight": .number(1000),
                                           "laborRate": .number(30), "prepTime": .number(1), "postTime": .number(1)]
        let settings: [String: JSONValue] = ["currency": .string("SAR")]
        let plain = try await engine.costPart(.object(fields), inventory: [], settings: settings)
        fields["orderLevelCosts"] = .bool(true)
        let marked = try await engine.costPart(.object(fields), inventory: [], settings: settings)
        #expect(marked.cost + 59 < plain.cost, "two hours at 30 come off: \(plain.cost) → \(marked.cost)")
        #expect(marked.cost > 0)

        var draft = try #require(NewJobSheet.Draft.from(.object(fields)))
        draft.cost = marked.cost
        let saved = Shop.partRows([draft], spools: [], unnamed: "Part")
        guard case .object(let row)? = saved.first else { Issue.record("no row"); return }
        #expect(row["orderLevelCosts"] == .bool(true))
        let unmarked = Shop.partRows([try #require(NewJobSheet.Draft.from(.object(["printWeight": .number(5)])))],
                                     spools: [], unnamed: "Part")
        if case .object(let r)? = unmarked.first { #expect(r["orderLevelCosts"] == nil) }
    }

    /// The shop's rule for a part added by hand (`addedPartMark`), through the
    /// Mac's engine: the shared vectors, as the switch stands and flipped.
    @Test("a hand part's mark: the shared vectors, both ways")
    func handPartMarkVectors() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "test/fixtures/added-part-mark-vectors.json")
        let v = try JSONValue.decode(JSONValue.self, from: Data(contentsOf: url))
        guard case .object(let file) = v, case .array(let cases)? = file["cases"] else { Issue.record("no cases"); return }
        #expect(cases.count >= 7)
        let engine = try KhaytEngine()
        for value in cases {
            guard case .object(let c) = value else { continue }
            let why: String = { if case .string(let s)? = c["why"] { return s }; return "?" }()
            let order = c["order"] ?? .null
            #expect(try await engine.addedPartMark(order) == (c["want"] == .bool(true)), "\(why)")
            #expect(try await engine.addedPartMark(order, flipped: true) == (c["flipped"] == .bool(true)), "\(why), flipped")
        }
        // The switch is put back: asking flipped leaves the shop's answer alone.
        let once: JSONValue = .object(["labourCost": .number(20)])
        _ = try await engine.addedPartMark(once, flipped: true)
        #expect(try await engine.addedPartMark(once) == (file["switch"] == .bool(true)))
    }

    /// Both places a part is added by hand ask that rule, and ask it before
    /// the part is costed (a mark set afterwards stores labour it then "shares").
    @Test("hand parts ask the rule, before costing")
    func handPartsAskTheRule() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        for (file, anchor) in [("Shop+JobSheet.swift", "let mark = await handPartMark(orderId)"),
                               ("NewJobSheet.swift", "let mark = await shop.handPartMark(cart)")] {
            let text = try String(contentsOf: src.appending(path: file), encoding: .utf8)
            guard let ask = text.range(of: anchor) else { Issue.record("\(file) does not ask addedPartMark"); continue }
            let cost = text.range(of: "costedPart(", range: ask.upperBound..<text.endIndex)
            #expect(cost != nil, "\(file): costed after the rule is asked")
        }
    }
}
