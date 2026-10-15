import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The October 2026 review of the Mac app: an accepted quote invoiced as
/// `QUO-…`, a per-kilo price read off what is left on the roll, a search box
/// that was a picture of one, report labels that named two figures one word,
/// colour pills squeezed empty, a library search that cared how Arabic was
/// typed, and "VAT" in English on an Arabic job.
@MainActor
struct MacReviewFixesTests {

    // MARK: - 1. An accepted quote is numbered by the invoice counter

    static func quoteBook(status: String = "quote", extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var job: [String: JSONValue] = [
            "id": .string("QUO-2026-0007"), "project": .string("Lamp"), "status": .string(status),
            "price": .number(100), "parts": .array([]),
            "invoiceNum": .null, "invoiceNumber": .null,
        ]
        for (k, v) in extra { job[k] = v }
        return [
            "printLog": .array([.object(job)]),
            "inventory": .array([]), "consumables": .array([]), "machines": .array([]),
            "clients": .array([]),
            "settings": .object(["invNumNext": .number(12), "invNumYear": .number(2026)]),
        ]
    }

    static func job(_ root: [String: JSONValue]) -> [String: JSONValue]? {
        guard case .array(let rows)? = root["printLog"], case .object(let job)? = rows.first else { return nil }
        return job
    }

    static func counter(_ root: [String: JSONValue]) -> JSONValue? {
        guard case .object(let s)? = root["settings"] else { return nil }
        return s["invNumNext"]
    }

    @Test("a quote moved to Pending is given the next invoice number, in the same write")
    func moveOutOfQuoteNumbersIt() async throws {
        let engine = try KhaytEngine()
        let words = Words()
        await words.load("en", engine: engine)
        var root = Self.quoteBook()
        _ = try await Shop.applyMove(to: &root, id: "QUO-2026-0007", stage: .pending,
                                     engine: engine, words: words)
        let job = try #require(Self.job(root))
        let year = Calendar.book.component(.year, from: Date())
        let expected = "INV-\(year)-" + (year == 2026 ? "0012" : "0001")
        #expect(job["invoiceNumber"] == .string(expected))
        #expect(job["invoiceNum"] == .string(expected))
        #expect(job["id"] == .string("QUO-2026-0007"), "the id is the record's key and is not renumbered")
        let next = Self.counter(root)
        #expect(next == .number(year == 2026 ? 13 : 2), "the counter that issued it moved in the same write")
    }

    @Test("a quote cancelled is not given a number")
    func cancelledQuoteIsNotNumbered() async throws {
        let engine = try KhaytEngine()
        let words = Words()
        await words.load("en", engine: engine)
        var root = Self.quoteBook()
        _ = try await Shop.applyMove(to: &root, id: "QUO-2026-0007", stage: .cancelled,
                                     engine: engine, words: words)
        let job = try #require(Self.job(root))
        #expect(job["invoiceNumber"] == .null)
        #expect(Self.counter(root) == .number(12))
    }

    @Test("the customer's LAN approval numbers the job and hands back the advanced settings")
    func lanApprovalNumbersIt() async throws {
        let engine = try KhaytEngine()
        let store = JSONValue.object(Self.quoteBook())
        let result = try await engine.lanQuoteApply(store: store, orderId: "QUO-2026-0007",
                                                    nowIso: "2026-10-15T09:00:00.000Z")
        #expect(result.found && result.error == nil)
        guard case .object(let order)? = result.order else { Issue.record("no order"); return }
        let number = order["invoiceNumber"]
        #expect(number == .string("INV-2026-0012"))
        guard case .object(let settings)? = result.settings else { Issue.record("no settings back"); return }
        #expect(settings["invNumNext"] == .number(13))
    }

    @Test("an approval refused hands back no settings to write")
    func refusedApprovalWritesNoCounter() async throws {
        let engine = try KhaytEngine()
        let store = JSONValue.object(Self.quoteBook(status: "pending"))
        let result = try await engine.lanQuoteApply(store: store, orderId: "QUO-2026-0007",
                                                    nowIso: "2026-10-15T09:00:00.000Z")
        #expect(result.error == "cannot_approve")
        #expect(result.settings == nil)
    }

    @Test("the shape an older build left — approved, no number — is owed one, once")
    func oldBookIsHealedOnIssue() async throws {
        let engine = try KhaytEngine()
        let old = JSONValue.object([
            "id": .string("QUO-2026-0003"), "status": .string("completed"),
            "quoteAcceptedAt": .string("2026-09-02"), "clientApprovedAt": .string("2026-09-02T10:00:00.000Z"),
        ])
        let settings: [String: JSONValue] = ["invNumNext": .number(40), "invNumYear": .number(2026)]
        let owed = try await engine.invoiceNumberOwed(order: old, settings: settings)
        #expect(owed)
        let first = try await engine.ensureInvoiceNumber(order: old, settings: settings, year: 2026)
        #expect(first.number == "INV-2026-0040")
        guard case .object(let after) = first.settings else { Issue.record("no settings"); return }
        let again = try await engine.ensureInvoiceNumber(order: first.order, settings: after, year: 2026)
        #expect(again.number == nil, "a second issue spends no second number")
    }

    @Test("the sheet's number is the document's: invoice number for an invoice, id for a quote")
    func sheetNumberFollowsTheDocument() throws {
        let row = JSONValue.object(["invoiceNumber": .string("INV-2026-0031")])
        let accepted = try Self.order(id: "QUO-2026-0007", status: "pending")
        let quote = try Self.order(id: "QUO-2026-0008", status: "quote")
        #expect(InvoiceSheet.documentNumber(accepted, row: row) == "INV-2026-0031")
        #expect(InvoiceSheet.documentNumber(quote, row: row) == "QUO-2026-0008")
        #expect(InvoiceSheet.documentNumber(accepted, row: .object([:])) == "QUO-2026-0007")
        let older = JSONValue.object(["invoiceNum": .string("INV-2026-0030")])
        #expect(InvoiceSheet.documentNumber(accepted, row: older) == "INV-2026-0030")
    }

    static func order(id: String, status: String) throws -> Order {
        let json: [String: Any] = ["id": id, "status": status, "project": "Lamp", "price": 100, "parts": []]
        return try JSONDecoder().decode(Order.self, from: JSONSerialization.data(withJSONObject: json))
    }

    // MARK: - 2. Per kilo is over what the roll held

    @Test("a half-used roll costs per kilo what the same roll cost new")
    func perKiloUsesTheFullSpool() {
        let halfUsed = SpoolSheet.perKilo(cost: 80, isNew: false, weight: 500, fullWeight: 1000)
        #expect(halfUsed == 80)
        let new = SpoolSheet.perKilo(cost: 80, isNew: true, weight: 1000, fullWeight: 0)
        #expect(new == 80)
        let unknown = SpoolSheet.perKilo(cost: 80, isNew: false, weight: 500, fullWeight: 0)
        #expect(unknown == nil, "no full weight is no figure, not the remainder's")
    }

    // MARK: - 6. Pills drop whole

    @Test("colour pills are offered two, then one, then none — never cut short")
    func pillChoicesDropWhole() {
        let three = JobTitleCell.pillChoices(["sand", "black", "red"])
        #expect(three == [["sand", "black"], ["sand"], []])
        #expect(JobTitleCell.pillChoices([]) == [[]])
    }

    // MARK: - 7. Library search

    @Test("Arabic spelled either way, width and case are one search")
    func searchFolds() {
        #expect(SearchText.contains("أحمد", "احمد"))
        #expect(SearchText.contains("إطار", "اطار"))
        #expect(SearchText.contains("آلة", "الة"))
        #expect(SearchText.contains("مكتبة", "مكتبه"))
        #expect(SearchText.contains("مستشفى", "مستشفي"))
        #expect(SearchText.contains("أَحْمَد", "احمد"))
        #expect(SearchText.contains("ＰＬＡ", "pla"))
        #expect(SearchText.contains("Café", "CAFE"))
        #expect(!SearchText.contains("benchy", "boat"))
    }

    @Test("a renamed model is still found by its file's name")
    func searchFindsTheFileName() throws {
        let json: [String: Any] = ["id": "m1", "name": "Boat",
                                   "sourceFile": ["filename": "Benchy_v3_0.4mm.3mf"]]
        let file = try JSONDecoder().decode(LibraryFile.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(file.matches(search: "benchy"))
        #expect(file.matches(search: "BOAT"))
        #expect(!file.matches(search: "lamp"))
    }

    // MARK: - 5 and 8. Words

    @Test("the tax line is labelled in the app's language")
    func taxLabelIsArabicInArabic() async throws {
        let engine = try KhaytEngine()
        let words = Words()
        await words.load("ar", engine: engine)
        let label = Shop.taxLabel("VAT", words: words)
        #expect(label == "ضريبة القيمة المضافة")
        #expect(Shop.taxLabel("GST", words: words) == "GST", "a name the catalogue has no word for stays as written")
    }

    @Test("the reports name what each figure is, in both languages")
    func reportWords() async throws {
        let engine = try KhaytEngine()
        let en = Words()
        await en.load("en", engine: engine)
        let ar = Words()
        await ar.load("ar", engine: engine)
        #expect(en.callIt("mac.pnl_col_margin") == "Gross margin")
        #expect(ar.callIt("mac.pnl_col_margin") == "الهامش الإجمالي")
        #expect(en.callIt("mac.pnl_col_operating") == "Operating costs")
        #expect(ar.callIt("mac.pnl_col_operating") == "تكاليف التشغيل")
        let heading = Reports.Totals.netHeading(en)
        #expect(heading == "Net Income · all time")
    }
}
