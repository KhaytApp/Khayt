import Foundation
import Testing
@testable import KhaytCore

/// Store orders as real jobs, and the linked reprint after a QC failure,
/// through the engine the Mac and the phone run.
///
/// `test/store-order-job.test.js` and `test/reprint.test.js` pin the rules.
/// What matters here is that the bundle reaches them: the webhook the Mac's
/// LAN server answers builds parts, and a reprint is a new linked job.
@Suite struct StoreOrdersAndReprintsTests {

    static let product: JSONValue = .object([
        "id": .string("PRD-HOOD"), "nameEn": .string("Falcon hood"), "sku": .string("FH-01"),
        "parts": .array([.object([
            "name": .string("Shell"), "qty": .number(1), "printWeight": .number(40),
            "printTime": .number(2), "filamentId": .string("SP-1"),
            "spoolCost": .number(100), "spoolWeight": .number(1000), "printFileId": .string("PF-1"),
        ])]),
    ])

    static func book(_ log: [JSONValue] = []) -> JSONValue {
        .object([
            "printLog": .array(log),
            "products": .array([product]),
            "inventory": .array([.object(["id": .string("SP-1"), "material": .string("PLA")])]),
            "settings": .object(["currency": .string("SAR")]),
        ])
    }

    static func salla(_ items: [JSONValue]) -> JSONValue {
        .object(["data": .object([
            "reference_id": .string("S-1"),
            "amounts": .object(["total": .object(["amount": .number(90)])]),
            "items": .array(items),
        ])])
    }

    static func object(_ v: JSONValue?) -> [String: JSONValue] {
        if case .object(let o)? = v { return o }
        return [:]
    }

    @Test func aStoreLineMatchedBySkuBringsTheProductsParts() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.storefrontRecord(
            source: "salla",
            payload: Self.salla([.object(["name": .string("Hood"), "sku": .string("fh-01"), "quantity": .number(3)])]),
            store: Self.book(), id: "salla-1", day: "2026-11-04", at: "2026-11-04T08:00:00Z")
        let order = Self.object(out.order)
        #expect(order["productId"] == .string("PRD-HOOD"))
        guard case .array(let parts)? = order["parts"], let first = parts.first else {
            Issue.record("no parts on the store job"); return
        }
        let part = Self.object(first)
        #expect(part["qty"] == .number(3))
        #expect(part["filamentId"] == .string("SP-1"))
        #expect(part["printFileId"] == .string("PF-1"))
        #expect(part["material"] == .string("PLA"))
        #expect(order["price"] == .number(90))
    }

    @Test func anUnmatchedLineIsKeptAndThenPlacedByTheShop() async throws {
        let engine = try KhaytEngine()
        let out = try await engine.storefrontRecord(
            source: "salla",
            payload: Self.salla([.object(["name": .string("Something else"), "quantity": .number(2)])]),
            store: Self.book(), id: "salla-2", day: "2026-11-04", at: "2026-11-04T08:00:00Z")
        let order = Self.object(out.order)
        #expect(order["parts"] == nil)
        guard case .string(let notes)? = order["notes"] else { Issue.record("no notes"); return }
        #expect(notes.contains("Not matched to a product: Something else × 2"))

        let placed = try await engine.storeOrderAssign(
            order: out.order ?? .null, index: 0, product: Self.product,
            book: .object(["settings": .object([:]), "inventory": .array([]), "consumables": .array([])]))
        let after = Self.object(placed)
        #expect(after["productId"] == .string("PRD-HOOD"))
        if case .array(let parts)? = after["parts"] { #expect(parts.count == 1) } else { Issue.record("no parts") }
        if case .string(let n)? = after["notes"] { #expect(!n.contains("Not matched")) }
        // A placed line is not placed twice.
        let again = try await engine.storeOrderAssign(order: placed, index: 0, product: Self.product,
                                                      book: .object([:]))
        #expect(again == .null)
    }

    @Test func aQcReprintIsANewLinkedJob() async throws {
        let engine = try KhaytEngine()
        let failed: JSONValue = .object([
            "id": .string("INV-2026-0003"), "project": .string("Hood"), "status": .string("qc"),
            "price": .number(50), "qcStatus": .string("fail"),
            "parts": .array([.object(["id": .string("PRT-1"), "name": .string("Shell"), "qty": .number(1),
                                      "printWeight": .number(40), "spoolCost": .number(100),
                                      "spoolWeight": .number(1000)])]),
        ])
        let scrapped = try await engine.qcMarkScrapped(failed, at: "2026-11-04T09:00:00Z")
        #expect(Self.object(scrapped)["scrapped"] == .bool(true))
        #expect(Self.object(scrapped)["status"] == .string("qc"))

        guard let made = try await engine.linkedReprint(
            of: "INV-2026-0003", printLog: [scrapped],
            settings: ["invNumNext": .number(4), "invNumYear": .number(2026)],
            now: ISO8601DateFormatter().date(from: "2026-11-04T09:00:00Z")!,
            tokens: (tracking: Array(repeating: 1, count: 16), quoteApproval: Array(repeating: 2, count: 16)),
            inventory: [], consumables: [], clients: [], reason: "qc_fail", cost: "shop",
            partIdBase: "PRT-R") else {
            Issue.record("no reprint made"); return
        }
        let job = Self.object(made.order)
        #expect(job["id"] == .string("INV-2026-0004"))
        #expect(job["reprintOf"] == .string("INV-2026-0003"))
        #expect(job["reprintReason"] == .string("qc_fail"))
        #expect(job["price"] == .number(0))
        #expect(job["status"] == .string("pending"))
        #expect(made.printLog.count == 2)
        let original = Self.object(made.printLog[1])
        #expect(original["reprintedInto"] == .array([.string("INV-2026-0004")]))
        #expect(made.settings["invNumNext"] == .number(5))

        let none = try await engine.linkedReprint(
            of: "NOPE", printLog: [scrapped], settings: [:], now: Date(),
            tokens: (tracking: [], quoteApproval: []), inventory: [], consumables: [], clients: [],
            reason: "qc_fail", cost: "shop", partIdBase: "PRT-R")
        #expect(none == nil)
    }
}
