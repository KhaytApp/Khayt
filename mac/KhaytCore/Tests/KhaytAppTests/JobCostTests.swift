import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// A job's cost on the Mac comes from ONE place: the engine's
/// `OrderFigures.cost` (`lib/order-money.js jobCost` once #2581 lands). The #2581 money
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
        #expect(hits.isEmpty, "sum a job's cost through OrderFigures.cost:\n\(hits.joined(separator: "\n"))")
    }

    /// The figure the ledger reads: parts, components, overhead, labour and
    /// packaging, in the job's currency.
    @MainActor @Test("OrderFigures.cost is jobCost; a USD job's ledger margin is in SAR, both sides")
    func figuresCost() async throws {
        let engine = try KhaytEngine()
        let sar: JSONValue = .object(["id": .string("A"), "price": .number(300), "costBasis": .number(100),
                                      "parts": .array([.object(["baseCost": .number(100)])]),
                                      "componentsCost": .number(10), "overheadCost": .number(5)])
        let usd: JSONValue = .object(["id": .string("B"), "price": .number(80), "currency": .string("USD"),
                                      "fxRate": .number(3.75), "costBasis": .number(150),
                                      "parts": .array([.object(["baseCost": .number(150)])])])
        let figures = try await engine.orderFigures([sar, usd], settings: ["currency": .string("SAR")], clients: [])
        #expect(abs((figures["A"]?.cost ?? -1) - 115) < 1e-9, "parts + components + overhead")
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
}
