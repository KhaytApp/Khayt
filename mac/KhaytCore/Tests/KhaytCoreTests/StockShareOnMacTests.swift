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
        // Through the shared dashboard rule, which applies `stockShare` itself
        // (`KhaytKpiRows.orderCost`), handed the inventory.
        #expect(engine.contains("globalThis.KhaytKpiRows.orderCost(o,")
                && engine.contains("{ settings: ARG2, inventory: ARG6 || [], clients: ARG1, consumables: ARG7 || [] }"))
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

    @Test("a part's own consumables are not cost of goods — bought as an expense, as the node rule says")
    func partConsumablesAreNotStock() async throws {
        let engine = try KhaytEngine()
        // 100 g of a 100-a-kilo spool = 10.00, plus 4 magnets at 2.00 = 8.00:
        // the job cost 18, the P&L's cost of goods is the 10 of filament.
        func job(_ magnets: Bool) -> JSONValue {
            var part: [String: JSONValue] = [
                "qty": .number(1), "printWeight": .number(100), "spoolCost": .number(100),
                "spoolWeight": .number(1000), "baseCost": .number(magnets ? 18 : 10),
            ]
            if magnets {
                part["consumables"] = .array([.object(["consumableId": .string("mag"),
                                                       "qty": .number(4), "unitCost": .number(2)])])
            }
            return .object([
                "id": .string("J1"), "status": .string("completed"), "date": .string("2026-09-10"),
                "price": .number(50), "costBasis": .number(magnets ? 18 : 10), "parts": .array([.object(part)]),
            ])
        }
        for magnets in [true, false] {
            let rows = try await engine.pnlByPeriod(orders: [job(magnets)], expenses: [], settings: [:], clients: [],
                                                    currencies: [:], now: Date(timeIntervalSince1970: 1_790_000_000),
                                                    inventory: [])
            let q3 = try #require(rows.first { $0.period == "2026-Q3" })
            #expect(abs((q3.cogs ?? 0) - 10) < 0.005, "magnets: \(magnets)")
        }
    }

    @Test("the machine P&L splits what was stocked with the shelf, as Reports' P&L does")
    func machinePLHasTheShelf() async throws {
        let engine = try KhaytEngine()
        // Wear 10, and 100 g of TPU priced off the shelf (100 per kg) = 10.
        let order: JSONValue = .object([
            "id": .string("J1"), "status": .string("completed"), "date": .string("2026-09-10"),
            "machineId": .string("M1"), "price": .number(100), "costBasis": .number(20),
            "parts": .array([.object([
                "qty": .number(1), "baseCost": .number(20), "printTime": .number(10), "wearRate": .number(1),
                "extraMaterials": .array([.object(["material": .string("TPU"), "weight": .number(100)])]),
            ])]),
        ])
        let shelf: [JSONValue] = [.object(["id": .string("s1"), "material": .string("TPU"),
                                           "cost": .number(100), "weight": .number(1000)])]
        func material(_ inventory: [JSONValue]) async throws -> Double? {
            try await engine.machineProfit(
                machines: [.object(["id": .string("M1"), "name": .string("U1")])], completed: [order],
                expenses: [], maintenance: [], settings: [:], clients: [], unassigned: "—",
                inventory: inventory).rows.first?.materialCost
        }
        // With the shelf: half the part is stocked (the TPU), half is wear.
        #expect(try await material(shelf) == 10)
        // Without it the TPU has no price, and the stocked share is nothing.
        #expect(try await material([]) == 0)
        let engineSource = try Self.source()
        #expect(engineSource.contains("var ctx = { settings: ARG4, clients: ARG5, inventory: ARG10 };"))
    }
}
