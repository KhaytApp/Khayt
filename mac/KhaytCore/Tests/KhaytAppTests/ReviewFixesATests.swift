import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The money and lost-data findings of the Nov 10 2026 review
/// (~/Khayt-proposals/app-review-nov10.md, section A), each as the failure
/// it was.
@MainActor
struct ReviewFixesATests {

    // MARK: A1 — a customer's currency

    static func job(_ id: String, client: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(["id": .string(id), "clientId": .string(client), "price": .number(1000), "rev": .number(1)]
            .merging(extra) { $1 })
    }

    @Test("giving a customer a currency does not turn their old SAR jobs into it")
    func oldJobsKeepTheirCurrency() {
        var root: [String: JSONValue] = [
            "settings": .object(["currency": .string("SAR")]),
            "printLog": .array([Self.job("J1", client: "C1"),
                                Self.job("J2", client: "C1", ["currency": .string("USD")]),
                                Self.job("J3", client: "C2")]),
        ]
        var undo: [Shop.ChangedRecord] = []
        Shop.pinJobCurrencies(of: "C1", was: ["id": .string("C1")],
                              now: ["id": .string("C1"), "currency": .string("EUR")], in: &root, undo: &undo)
        guard case .array(let jobs)? = root["printLog"] else { Issue.record("no jobs"); return }
        func currency(_ i: Int) -> JSONValue? { if case .object(let o) = jobs[i] { return o["currency"] }; return nil }
        #expect(currency(0) == .string("SAR"), "read in the shop's currency before, so it says so now")
        #expect(currency(1) == .string("USD"), "a job that names its currency is left alone")
        #expect(currency(2) == nil, "another customer's job is not touched")
        #expect(undo.map(\.id) == ["J1"])
        #expect(undo.first?.collection == "printLog")
    }

    @Test("a currency that did not change touches no job; a second change keeps the first reading")
    func onlyWhenItChanges() {
        var root: [String: JSONValue] = ["printLog": .array([Self.job("J1", client: "C1")])]
        var undo: [Shop.ChangedRecord] = []
        let eur: [String: JSONValue] = ["id": .string("C1"), "currency": .string("EUR")]
        Shop.pinJobCurrencies(of: "C1", was: eur, now: eur, in: &root, undo: &undo)
        #expect(undo.isEmpty)
        Shop.pinJobCurrencies(of: "C1", was: eur, now: ["id": .string("C1"), "currency": .string("USD")],
                              in: &root, undo: &undo)
        guard case .array(let jobs)? = root["printLog"], case .object(let j) = jobs[0] else { return }
        #expect(j["currency"] == .string("EUR"), "it was read as EUR until now, and still is")
    }

    // MARK: A2 — what a phone's copy replaced

    @Test("a tie the phone's copy wins is reported, so the Mac's copy can be kept")
    func foldReportsWhatItReplaced() async throws {
        let mine: JSONValue = .object(["id": .string("J1"), "rev": .number(8), "updatedAt": .string("2026-11-10T10:00:00.000Z"),
                                       "paidAmount": .number(500)])
        let phones: JSONValue = .object(["id": .string("J1"), "rev": .number(8), "updatedAt": .string("2026-11-10T10:05:00.000Z"),
                                         "paidAmount": .number(0), "status": .string("completed")])
        let base: [String: JSONValue] = ["printLog": .array([mine])]
        let payload: [String: JSONValue] = ["deltas": .array([
            .object(["collection": .string("printLog"), "record": phones])])]
        let out = try await KhaytEngine().foldDeltas(base: base, deltas: [payload])
        #expect(out.applied == 1)
        #expect(out.conflicts.count == 1, "the rule said so; the fold used to throw it away")
        let losses = SyncLosses.compute(before: base, after: out.store, conflicts: out.conflicts)
            .filter { $0.kind == .replaced }
        #expect(losses.count == 1)
        #expect(losses.first?.record == mine, "the copy with the payment on it is the one kept")
    }

    // MARK: A5 — numbers as typed

    @Test("a typed number is read the way it was meant")
    func typedNumbers() {
        #expect(TypedNumber.parse("150") == 150)
        #expect(TypedNumber.parse("١٥٠") == 150, "an Arabic keyboard")
        #expect(TypedNumber.parse("۱۵۰") == 150, "a Persian one")
        #expect(TypedNumber.parse("٢٣٫٩") == 23.9)
        #expect(TypedNumber.parse("١٬٢٥٠٫٥") == 1250.5)
        #expect(TypedNumber.parse("1,5") == 1.5, "a comma decimal is not fifteen")
        #expect(TypedNumber.parse("12,75") == 12.75)
        #expect(TypedNumber.parse("0,125") == 0.125)
        #expect(TypedNumber.parse("1,528") == 1528, "this app's own grouped pre-fill")
        #expect(TypedNumber.parse("1,250.5") == 1250.5)
        #expect(TypedNumber.parse("1.250,5") == 1250.5)
        #expect(TypedNumber.parse("1,234,567") == 1234567)
        #expect(TypedNumber.parse(" 12. ") == 12)
        #expect(TypedNumber.parse("") == nil)
        #expect(TypedNumber.parse("abc") == nil)
        #expect(TypedNumber.parse("-5") == nil)
        #expect(TypedNumber.parse("1.2.3") == nil)
        #expect(CalculatorModel.number("١٥٠") == 150)
        #expect(CompletionSheet.number("1,5") == 1.5)
    }

    // MARK: A3 — New Job

    @Test("New Job says why its buttons are off, and that a typed part was added")
    func newJobFooter() {
        #expect(NewJobSheet.footerNote(parts: 0, pending: false, justAdded: false) == "mac.add_part_first")
        #expect(NewJobSheet.footerNote(parts: 0, pending: true, justAdded: false) == nil)
        #expect(NewJobSheet.footerNote(parts: 2, pending: false, justAdded: true) == "mac.part_added_check")
        #expect(NewJobSheet.footerNote(parts: 1, pending: false, justAdded: false) == nil)
    }

    // MARK: A6 — ids made together

    @Test("ids made in one go are all different")
    func idsDiffer() {
        let ids = Shop.uids("INV", count: 2000)
        #expect(Set(ids).count == 2000)
        #expect(ids.allSatisfy { $0.hasPrefix("INV-") })
    }

    // MARK: A9 — the payment box

    @Test("the payment sheet says the box is the total, and when it is over the bill")
    func paymentNotes() {
        #expect(PaymentSheet.note(recorded: 0, typed: 200, bill: 500) == nil)
        #expect(PaymentSheet.note(recorded: 300, typed: 300, bill: 500)?.key == "mac.pay_total_note")
        let over = PaymentSheet.note(recorded: 300, typed: 600, bill: 500)
        #expect(over?.key == "mac.pay_over_bill")
        #expect(over?.amount == 500)
    }
}
