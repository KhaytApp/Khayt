import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// Where failures cost, and "Log as waste…" from a failed print's notice.
///
/// The grouping is `lib/failed-print-cost.js`'s `byGroup` (its Node tests
/// hold the arithmetic and the Unknown bucket); this proves the Mac reaches
/// it through the engine and decodes its rows. The prefill is the waste
/// sheet's starting values, and nothing else: it writes nothing.
@MainActor
struct FailureCostTests {

    static func obj(_ fields: [String: JSONValue]) -> JSONValue { .object(fields) }

    static let log: [JSONValue] = [
        obj(["id": .string("W1"), "orderId": .string("J1"), "machineId": .string("M1"),
             "material": .string("PLA"), "cost": .number(4),
             "costMaterial": .number(4), "costMachine": .number(6), "costPower": .number(1),
             "costFull": .number(11)]),
        // Legacy: `cost` only.
        obj(["id": .string("W2"), "machineId": .string("M2"), "material": .string("PETG"),
             "cost": .number(2.5)]),
        // No printer, no job.
        obj(["id": .string("W3"), "material": .string("PLA"), "cost": .number(1)]),
    ]
    static let orders: [JSONValue] = [
        obj(["id": .string("J1"), "machineId": .string("M1"), "clientId": .string("C1")]),
    ]
    static let machines: [JSONValue] = [
        obj(["id": .string("M1"), "name": .string("U1")]),
        obj(["id": .string("M2"), "name": .string("X1C")]),
    ]
    static let clients: [JSONValue] = [obj(["id": .string("C1"), "name": .string("Noura")])]

    @Test("the engine bridge returns byGroup's rows, biggest first, with the Unknown bucket")
    func bridge() async throws {
        let engine = try KhaytEngine()
        let byPrinter = try await engine.failedCostByGroup(
            wasteLog: Self.log, by: "machine", orders: Self.orders, machines: Self.machines,
            spools: [], clients: Self.clients)
        #expect(byPrinter.map(\.label) == ["U1", "X1C", "Unknown"])
        #expect(byPrinter.map(\.full) == [11, 2.5, 1])
        #expect(byPrinter.map(\.count) == [1, 1, 1])
        #expect(byPrinter[0].machine == 6 && byPrinter[0].power == 1 && byPrinter[0].material == 4)
        #expect(byPrinter[2].unknown && byPrinter[2].key == nil)
        #expect(Set(byPrinter.map(\.id)).count == 3, "every row has its own id, Unknown included")

        let byCustomer = try await engine.failedCostByGroup(
            wasteLog: Self.log, by: "customer", orders: Self.orders, machines: Self.machines,
            spools: [], clients: Self.clients)
        #expect(byCustomer.map(\.label) == ["Noura", "Unknown"])
        #expect(byCustomer.map(\.count) == [1, 2])

        // The same "full" as the totals the Waste screen already shows.
        let totals = try await engine.failedCostTotals(wasteLog: Self.log)
        let byMaterial = try await engine.failedCostByGroup(
            wasteLog: Self.log, by: "material", orders: Self.orders, machines: Self.machines, spools: [])
        #expect(byMaterial.reduce(0) { $0 + $1.full } == totals.full)
    }

    // MARK: - "Log as waste…" prefill

    @Test("grams are the job's grams × how far the print got, only when both are known")
    func prefillGrams() {
        let half = WastePrefill.make(machineId: "M1", orderId: "J1", jobGrams: 120, progress: 42)
        #expect(half == WastePrefill(machineId: "M1", orderId: "J1", grams: 50.4, material: nil))
        // Over 100% is the whole job, never more.
        #expect(WastePrefill.make(machineId: "M1", orderId: "J1", jobGrams: 80, progress: 140).grams == 80)
        // Either side missing, zero or nonsense: left for the shop to fill.
        #expect(WastePrefill.make(machineId: "M1", orderId: "J1", jobGrams: 120, progress: nil).grams == nil)
        #expect(WastePrefill.make(machineId: "M1", orderId: "J1", jobGrams: nil, progress: 50).grams == nil)
        #expect(WastePrefill.make(machineId: "M1", orderId: "J1", jobGrams: 0, progress: 50).grams == nil)
        #expect(WastePrefill.make(machineId: "M1", orderId: "J1", jobGrams: 120, progress: 0).grams == nil)
        #expect(WastePrefill.make(machineId: "M1", orderId: "J1", jobGrams: .nan, progress: 50).grams == nil)
        // No job: the machine alone, and an empty id is no job.
        let bare = WastePrefill.make(machineId: "M2", orderId: "", jobGrams: nil, progress: 30, material: "")
        #expect(bare == WastePrefill(machineId: "M2", orderId: nil, grams: nil, material: nil))
    }

    @Test("from a notice: the machine, the job the book has, its grams and material")
    func prefillFromNotice() throws {
        let job = try JSONDecoder().decode(Order.self, from: Data(#"""
            {"id":"J1","status":"printing","machineId":"M1","parts":[
              {"name":"a","material":"PETG","qty":2,"printWeight":30,"supportWeight":5},
              {"name":"b","material":"PLA","qty":1,"printWeight":10}]}
            """#.utf8))
        let failed = PrinterNotice.Notice(machineId: "M1", machine: "U1", kind: "failed",
                                          title: "", body: "", at: Date(),
                                          orderId: "J1", progress: 25)
        // (30 + 5) × 2 + 10 = 80 g; a quarter of it.
        #expect(WastePrefill.from(failed, orders: [job])
                == WastePrefill(machineId: "M1", orderId: "J1", grams: 20, material: "PETG"))

        // A job the book no longer has is no job — and so no grams.
        #expect(WastePrefill.from(failed, orders: [])
                == WastePrefill(machineId: "M1", orderId: nil, grams: nil, material: nil))

        // The printer never said how far it got.
        let noProgress = PrinterNotice.Notice(machineId: "M1", machine: "U1", kind: "failed",
                                              title: "", body: "", at: Date(), orderId: "J1")
        #expect(WastePrefill.from(noProgress, orders: [job]).grams == nil)
        #expect(WastePrefill.from(noProgress, orders: [job]).orderId == "J1")
    }
}
