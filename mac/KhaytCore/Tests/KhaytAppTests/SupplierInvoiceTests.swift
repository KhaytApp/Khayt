import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The supplier's own bill, against the order it belongs to.
///
/// ── WHY THE RULE IS SHARED AND NOT WRITTEN HERE ───────────────────────────
///
/// "Does this invoice match?" is a question a shop can be told two different
/// answers to, and the tolerance is the kind of number somebody adjusts in one
/// place. So it lives in `lib/supplier-invoice.js`, both apps ask, and these
/// tests go through the bridge rather than reimplementing the arithmetic in
/// Swift where it could quietly disagree.
@MainActor
struct SupplierInvoiceTests {

    /// 750 g at 0.085/g — a real filament order — is 63.75.
    static func order(_ status: String = "received") -> JSONValue {
        .object(["id": .string("PO-1"), "qty": .number(750),
                 "unitPrice": .number(0.085), "status": .string(status)])
    }

    @Test("what the order expected is the rule's arithmetic, not this app's")
    func expectedComesFromTheRule() async throws {
        let engine = try KhaytEngine()
        let expected = try await engine.expectedInvoiceAmount(Self.order())
        #expect((expected * 100).rounded() / 100 == 63.75)
        // The defect this replaces read fields nothing writes, so the expected
        // amount was always zero and a mismatch was never once flagged.
        #expect(try await engine.expectedInvoiceAmount(
            .object(["weightOrdered": .number(750), "unitCost": .number(0.085)])) == 0)
    }

    @Test("a rounding difference agrees; a bill an order of magnitude out does not")
    func theVerdict() async throws {
        let engine = try KhaytEngine()
        let close = try await engine.recordSupplierInvoice(
            on: Self.order(), number: "INV-9", amount: 63.75, date: "2026-09-20")
        #expect(!close.invoiceDiscrepancy)
        let wrong = try await engine.recordSupplierInvoice(
            on: Self.order(), number: "INV-9", amount: 637.50, date: "2026-09-20")
        #expect(wrong.invoiceDiscrepancy,
                "a bill ten times the order did not flag — the 1000x defect, seen from the bill")
    }

    @Test("the two fields are what gets merged, and nothing else is")
    func onlyTwoFields() async throws {
        let engine = try KhaytEngine()
        let recorded = try await engine.recordSupplierInvoice(
            on: Self.order(), number: " INV-9 ", amount: 63.75, date: "2026-09-20")
        #expect(Set(recorded.fields.keys) == ["supplierInvoice", "invoiceDiscrepancy"],
                "a merge that carried more would overwrite what an order knows and this does not")
        #expect(recorded.supplierInvoice.number == "INV-9", "the number was not trimmed")
        #expect(recorded.supplierInvoice.amount == 63.75)
    }

    @Test("a bill cannot be recorded before the goods have arrived")
    func onlyOnceItIsHere() async throws {
        let engine = try KhaytEngine()
        #expect(try await engine.canBillOrder(Self.order("received")))
        #expect(try await engine.canBillOrder(Self.order("partial")),
                "a part delivery is still billed, often for the part that arrived")
        #expect(!(try await engine.canBillOrder(Self.order("ordered"))))
        #expect(!(try await engine.canBillOrder(Self.order("draft"))))
    }

    @Test("a bill nobody typed is not a bill, and a reference alone is")
    func worthRecording() {
        #expect(!Shop.Bill().isWorthRecording)
        #expect(!Shop.Bill(number: "   ", amount: 0).isWorthRecording)
        // A shop that files the paper and records only its reference has
        // recorded something worth keeping.
        #expect(Shop.Bill(number: "INV-9").isWorthRecording)
        #expect(Shop.Bill(amount: 63.75).isWorthRecording)
    }

    @Test("the sheet asks for it, says whether it agrees, and sends it on")
    func wired() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/KhaytApp")
        let sheet = try String(contentsOf: sources.appending(path: "ReceiveSheet.swift"),
                               encoding: .utf8)
        #expect(sheet.contains("po.sup_inv_num"), "there is nowhere to record a bill")
        #expect(sheet.contains("po.ap_mismatch"),
                "a bill that does not match the order is accepted in silence")
        #expect(sheet.contains("invoice: paper"), "the sheet collects a bill and drops it")
        // The verdict must come from the rule. A tolerance compared in Swift
        // is a second tolerance, and the day one moves a shop is told its
        // invoice matches in one app and not the other.
        #expect(sheet.contains("shop.billVerdict"), "the sheet judges the bill itself")
        #expect(!sheet.contains("> 1"), "a tolerance appears to be compared in the sheet")

        let engine = try String(contentsOf: sources.deletingLastPathComponent()
            .appending(path: "KhaytCore/KhaytEngine.swift"), encoding: .utf8)
        #expect(engine.contains("\"supplier-invoice\","),
                "the module is not bundled, so every call above fails silently")
    }
}
