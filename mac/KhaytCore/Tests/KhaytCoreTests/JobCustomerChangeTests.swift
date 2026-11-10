import Foundation
import Testing
@testable import KhaytCore

/// Changing a job's customer on the Mac runs the shared rule
/// (`lib/order-edit.js changeCustomer`, Turki's option C, Nov 10): changeable
/// until the invoice is submitted to ZATCA, voided, credited or paid; a job
/// with no customer can always be given one. test/order-customer-change.test.js
/// is the full case list; this proves the Mac reaches the same answers.
struct JobCustomerChangeTests {

    static let clients: [JSONValue] = [
        .object(["id": .string("C1"), "nameEn": .string("Acme")]),
        .object(["id": .string("C2"), "nameEn": .string("Beta"), "currency": .string("EUR")]),
    ]
    static func job(_ extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(["id": .string("J1"), "clientId": .string("C1"), "invoiceNumber": .string("INV-1"),
                 "price": .number(100)].merging(extra) { $1 })
    }

    @Test("a numbered, unpaid job changes customer and the change is in its history")
    func changes() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.customerLocked(Self.job()) == nil)
        let r = try await engine.changeCustomer(order: Self.job(), clientId: "C2", clients: Self.clients,
                                                settings: ["currency": .string("SAR")], now: Date(), editId: "E1")
        #expect(r.ok)
        #expect(r.currencyDiffers, "EUR customer on a SAR job is flagged, not converted")
        guard case .object(let o) = r.order else { Issue.record("not an object"); return }
        #expect(o["clientId"] == .string("C2"))
        #expect(o["price"] == .number(100))
        guard case .array(let hist)? = o["editHistory"] else { Issue.record("no history"); return }
        #expect(hist.count == 1)
    }

    @Test("each lock refuses, and a job with no customer is given one anyway")
    func locks() async throws {
        let engine = try KhaytEngine()
        let cases: [([String: JSONValue], String)] = [
            (["zatcaUuid": .string("u")], "zatca"), (["voidedAt": .string("2026-11-01")], "voided"),
            (["creditedAt": .string("2026-11-01")], "credited"), (["paidAmount": .number(5)], "paid"),
        ]
        for (extra, reason) in cases {
            #expect(try await engine.customerLocked(Self.job(extra)) == reason)
            let r = try await engine.changeCustomer(order: Self.job(extra), clientId: "C2", clients: Self.clients,
                                                    now: Date(), editId: "E")
            #expect(!r.ok && r.reason == reason)
            #expect(r.order == Self.job(extra), "a refused change leaves the job as it was")
            var none = extra; none["clientId"] = .null
            let given = try await engine.changeCustomer(order: Self.job(none), clientId: "C1", clients: Self.clients,
                                                        now: Date(), editId: "E")
            #expect(given.ok, "no customer → can always be given one (\(reason))")
        }
    }
}
