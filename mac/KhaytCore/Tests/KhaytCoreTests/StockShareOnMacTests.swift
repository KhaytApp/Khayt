import Foundation
import Testing
@testable import KhaytCore

/// The Mac counts cost of goods the way Reports does: only what was stocked.
struct StockShareOnMacTests {
    static func source() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/KhaytCore/KhaytEngine.swift"), encoding: .utf8)
    }

    @Test("the dashboard tiles apply stockShare, and the P&L is given the inventory")
    func wired() throws {
        let engine = try Self.source()
        #expect(engine.contains("globalThis.KhaytPnl.stockShare(o, { inventory: ARG6 || [], settings: ARG2 })"))
        #expect(engine.contains("wasteLog: ARG7, inventory: ARG8"))
    }

    @Test("a part priced with wear, power and labour contributes only its material to cost of goods")
    func onlyStock() async throws {
        let engine = try KhaytEngine()
        let order: JSONValue = .object([
            "id": .string("J1"), "status": .string("completed"), "date": .string("2026-09-10"),
            "price": .number(100), "costBasis": .number(40),
            "parts": .array([.object([
                "qty": .number(1), "unitCost": .number(40), "baseCost": .number(40),
                "printWeight": .number(100), "spoolCost": .number(100), "spoolWeight": .number(1000),
                "printTime": .number(10), "wearRate": .number(1), "powerDraw": .number(100), "elecRate": .number(1),
            ])]),
        ])
        let rows = try await engine.pnlByPeriod(orders: [order], expenses: [], settings: [:], clients: [],
                                                currencies: [:], now: Date(timeIntervalSince1970: 1_790_000_000),
                                                inventory: [])
        let q3 = try #require(rows.first { $0.period == "2026-Q3" })
        // material 10, wear 10, power 1 → 10/21 of the frozen 40.
        #expect(abs((q3.cogs ?? 0) - 40 * 10.0 / 21.0) < 0.05)
    }
}
