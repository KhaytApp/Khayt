import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The Mac's side of store orders as jobs and the QC reprint: what the job
/// inspector reads off a record, and the write the QC-failed sheet makes with
/// QC switched on.
@MainActor
struct StoreOrdersAndReprintsAppTests {

    @Test func aJobReadsItsStoreLinesAndItsReprintLinks() throws {
        let json = """
        {"id":"salla-1","status":"pending","reprintOf":"INV-1","reprintedInto":["INV-9"],
         "storeLines":[{"name":"Hood","qty":2,"productId":"PRD-1","matchedBy":"sku","sku":"FH"},
                       {"name":"Gift wrap","qty":1e30,"productId":null,"matchedBy":null}]}
        """
        let job = try JSONDecoder().decode(Order.self, from: Data(json.utf8))
        #expect(job.reprintOf == "INV-1")
        #expect(job.reprintedInto == ["INV-9"])
        #expect(job.storeLines.map(\.productId) == ["PRD-1", nil])
        #expect(job.storeLines[1].qty == 100_000, "a count off the wire is clamped, never a trap")
        #expect(StoreLinesSection.shows(job))
        #expect(ReprintLinks.shows(job))

        let plain = try JSONDecoder().decode(Order.self, from: Data(#"{"id":"x","storeLines":"junk"}"#.utf8))
        #expect(plain.storeLines.isEmpty, "a stray value does not take the job off the board")
        #expect(!StoreLinesSection.shows(plain))
        #expect(!ReprintLinks.shows(plain))
    }

    @Test func withQcOnAReprintIsMadeInTheSameWriteAndScrapMakesNothing() async throws {
        let engine = try KhaytEngine()
        let failed: JSONValue = .object([
            "id": .string("INV-2026-0003"), "project": .string("Hood"), "status": .string("qc"),
            "price": .number(50), "qcStatus": .string("fail"), "parts": .array([]),
        ])
        var root: [String: JSONValue] = [
            "printLog": .array([failed]),
            "settings": .object(["invNumNext": .number(4), "invNumYear": .number(2026)]),
        ]
        let made = try await Shop.applyQcNext(.reprint(cost: "billable"), failedId: "INV-2026-0003",
                                              root: &root, engine: engine, now: Date())
        #expect(made == "INV-2026-0004")
        let log = Shop.rows(root, "printLog")
        #expect(log.count == 2)
        let original = Shop.asObject(log[1]) ?? [:]
        #expect(original["scrapped"] == .bool(true))
        #expect(original["status"] == .string("qc"), "not sent back to Pending")
        #expect(original["reprintedInto"] == .array([.string("INV-2026-0004")]))
        #expect(Shop.asObject(log[0])?["reprintCost"] == .string("billable"))

        var other: [String: JSONValue] = ["printLog": .array([failed]), "settings": .object([:])]
        let none = try await Shop.applyQcNext(.scrap, failedId: "INV-2026-0003", root: &other,
                                              engine: engine, now: Date())
        #expect(none == nil)
        #expect(Shop.rows(other, "printLog").count == 1)
        #expect(Shop.asObject(Shop.rows(other, "printLog")[0])?["scrapped"] == .bool(true))
    }
}
