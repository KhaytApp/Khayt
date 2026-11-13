import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The order editor's customer picker (Turki's option C, Nov 10): shut only
/// when the job is locked AND has a customer; a change is handed to the save
/// only when the shop made one; another currency is warned about.
@MainActor
struct JobCustomerPickerTests {

    @Test("the picker is shut only for a locked job that has a customer")
    func shut() {
        #expect(OrderDetailsSheet.customerShut(lock: "paid", openedWith: "C1"))
        #expect(!OrderDetailsSheet.customerShut(lock: "paid", openedWith: ""), "no customer → can always be given one")
        #expect(!OrderDetailsSheet.customerShut(lock: nil, openedWith: "C1"))
    }

    @Test("only a changed customer is handed to the save, and blank means none")
    func handed() {
        var a = OrderDetailsSheet.Form(); a.clientId = "C1"
        var b = a
        #expect(OrderDetailsSheet.customerChange(opened: a, now: b) == .none)
        b.clientId = "C2"
        #expect(OrderDetailsSheet.customerChange(opened: a, now: b) == .some("C2"))
        b.clientId = ""
        #expect(OrderDetailsSheet.customerChange(opened: a, now: b) == .some(nil))
        // The customer is not one of applyDetails' fields.
        #expect(OrderDetailsSheet.fields(opened: a, now: b)["clientId"] == nil)
    }

    @Test("another currency is flagged; blank is the shop's")
    func currency() {
        #expect(OrderDetailsSheet.currencyDiffers(job: "", was: nil, shop: "SAR", client: "EUR"))
        #expect(!OrderDetailsSheet.currencyDiffers(job: "", was: nil, shop: "SAR", client: ""))
        #expect(!OrderDetailsSheet.currencyDiffers(job: "EUR", was: nil, shop: "SAR", client: "EUR"))
        #expect(!OrderDetailsSheet.currencyDiffers(job: "", was: nil, shop: "SAR", client: nil))
        // A job with no currency of its own is in its CUSTOMER's (beta.34
        // review, L3): the warning read it in the shop's, so these two were
        // each the wrong way round.
        #expect(!OrderDetailsSheet.currencyDiffers(job: "", was: "EUR", shop: "SAR", client: "EUR"))
        #expect(OrderDetailsSheet.currencyDiffers(job: "", was: "EUR", shop: "SAR", client: ""))
    }

    /// The warning and the write must be one rule. Every mix of the job's own
    /// currency, the customer it has and the customer it is given is asked of
    /// both; the lib's `currencyDiffers` is the answer.
    @Test("the warning agrees with lib/order-edit.js changeCustomer in every case")
    func currencyMatchesTheLib() async throws {
        let engine = try KhaytEngine()
        // id → currency ("" = bills in the shop's).
        let book: [String: String] = ["CS": "", "CE": "EUR", "CE2": "EUR", "CU": "USD", "CR": "SAR"]
        let clients: [JSONValue] = book.sorted { $0.key < $1.key }.map { id, cur in
            var c: [String: JSONValue] = ["id": .string(id), "nameEn": .string(id)]
            if !cur.isEmpty { c["currency"] = .string(cur) }
            return .object(c)
        }
        var asked = 0
        for shopCur in ["SAR", "EUR"] {
            for jobCur in ["", "SAR", "EUR", "USD"] {
                for from in [nil, "CS", "CE", "CU", "CR"] as [String?] {
                    for to in ["CS", "CE", "CE2", "CU", "CR"] where to != from {
                        var order: [String: JSONValue] = ["id": .string("J1"), "price": .number(100)]
                        if let from { order["clientId"] = .string(from) }
                        if !jobCur.isEmpty { order["currency"] = .string(jobCur) }
                        let r = try await engine.changeCustomer(
                            order: .object(order), clientId: to, clients: clients,
                            settings: ["currency": .string(shopCur)], now: Date(), editId: "E1")
                        #expect(r.ok)
                        let ours = OrderDetailsSheet.currencyDiffers(
                            job: jobCur, was: from.flatMap { book[$0] }, shop: shopCur, client: book[to])
                        #expect(ours == r.currencyDiffers,
                                "shop \(shopCur), job '\(jobCur)', \(from ?? "none") → \(to)")
                        asked += 1
                    }
                }
            }
        }
        #expect(asked == 168)
    }

    @Test("the order editor closes on a written change, shows a refusal, and one press saves once")
    func closesOnTheWrite() {
        let sheet = MenuCoverageTests.source("OrderDetailsSheet.swift")
        #expect(sheet.contains("let wrote = await shop.editOrderDetails(id, fields: fields, customer: customer)"))
        #expect(sheet.contains("if wrote { shop.clearQuestion() }"))
        #expect(sheet.contains("@State private var saving = false"))
        #expect(sheet.contains("guard !saving else { return }"))
        #expect(sheet.contains("saving = false"))
        #expect(sheet.contains(".disabled(saving)"))
        #expect(sheet.contains("SaveProblem(text: shop.moveProblem)"), "a refusal is said IN the sheet")
        // Never closed before the write again: the only close in `commit` is
        // the one after `wrote`.
        let commit = sheet[(sheet.range(of: "private func commit() {")!.upperBound)...]
        #expect(commit.components(separatedBy: "shop.clearQuestion()").count == 2)
    }

    @Test("the job's own customer stays offered even when it is not in the book")
    func keepsCurrent() {
        #expect(OrderDetailsSheet.customerChoices([], current: "C9").map(\.id) == ["C9"])
        #expect(OrderDetailsSheet.customerChoices([], current: "").isEmpty)
    }
}
