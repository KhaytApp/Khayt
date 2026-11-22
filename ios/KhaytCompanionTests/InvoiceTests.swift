import KhaytCore
import XCTest
@testable import KhaytCompanion

/// A job's invoice on the phone: the Mac's document from the book the phone
/// keeps, and the rules for when there is none.
@MainActor
final class InvoiceTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("inv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    /// The sample shop, changed by `edit`, behind a reader.
    private func reader(scope: BookScope.Taken? = SampleShop.scope(),
                        _ edit: (inout [String: JSONValue]) -> Void = { _ in }) throws -> BookReader {
        var store = SampleShop.book()
        edit(&store)
        let folder = dir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let book = CompanionBook(directory: folder)
        try book.replace(with: store, scope: scope)
        return BookReader(book: book)
    }

    private func addOrder(_ store: inout [String: JSONValue], _ fields: [String: JSONValue]) {
        guard case .array(var rows)? = store["printLog"] else { return }
        var o: [String: JSONValue] = ["client": .string("Maya Chen"), "clientId": .string("C-3"),
                                      "date": .string("2026-10-20"), "price": .number(115),
                                      "parts": .array([.object(["qty": .number(1)])]), "rev": .number(1)]
        o.merge(fields) { _, new in new }
        rows.append(.object(o))
        store["printLog"] = .array(rows)
    }

    func testAJobsInvoiceIsTheSharedDocumentUnderItsNumber() async throws {
        let build = try await reader().invoice(orderId: "S-1038", language: "en")
        guard case .paper(let doc, let filename) = build else { return XCTFail("expected paper, got \(build)") }
        XCTAssertTrue(doc.html.contains("S-1038"), "a job that was never a quote prints its id as its number")
        XCTAssertTrue(doc.html.contains("Sample Print Shop"))
        XCTAssertTrue(doc.html.contains("Planter"))
        XCTAssertEqual(filename, "S-1038.pdf")
    }

    func testTheTaxIsSplitByTheShopsOwnRule() async throws {
        let r = try reader { store in
            guard case .object(var s)? = store["settings"] else { return }
            s["enableVat"] = .bool(true); s["vatRate"] = .number(15)
            store["settings"] = .object(s)
            self.addOrder(&store, ["id": .string("S-2001"), "status": .string("completed"), "project": .string("Sign")])
        }
        guard case .paper(let doc, _) = try await r.invoice(orderId: "S-2001", language: "en") else {
            return XCTFail("expected paper")
        }
        // 115 inclusive of 15%: the tax inside it is 15, and the paper says
        // it is included rather than adding it again.
        XCTAssertTrue(doc.html.contains("15.00"), "the tax line")
        XCTAssertTrue(doc.html.contains("VAT (15%)"))
        XCTAssertFalse(doc.html.contains("130.00"), "an inclusive price is not taxed twice")
    }

    func testQuotesAndCancelledJobsHaveNoInvoice() async throws {
        let r = try reader { store in
            self.addOrder(&store, ["id": .string("QUO-7"), "status": .string("quote")])
            self.addOrder(&store, ["id": .string("S-2002"), "status": .string("on_hold"), "hasQuote": .bool(true)])
            self.addOrder(&store, ["id": .string("S-2003"), "status": .string("cancelled")])
        }
        let quote = try await r.invoice(orderId: "QUO-7", language: "en")
        let held = try await r.invoice(orderId: "S-2002", language: "en")
        let cancelled = try await r.invoice(orderId: "S-2003", language: "en")
        let missing = try await r.invoice(orderId: "NOPE", language: "en")
        guard case .refused(.quote) = quote, case .refused(.quote) = held,
              case .refused(.cancelled) = cancelled, case .refused(.missing) = missing else {
            return XCTFail("\(quote) \(held) \(cancelled) \(missing)")
        }
    }

    func testThePhoneNeverNumbersAnAcceptedQuote() async throws {
        let r = try reader { store in
            // Accepted, moved on, and never drawn on the Mac: owed a number.
            self.addOrder(&store, ["id": .string("QUO-8"), "status": .string("pending"),
                                   "quoteAcceptedAt": .string("2026-10-21")])
            // Numbered on the Mac: prints that number.
            self.addOrder(&store, ["id": .string("QUO-9"), "status": .string("completed"),
                                   "quoteAcceptedAt": .string("2026-10-01"),
                                   "invoiceNumber": .string("INV-2026-0042"), "invoiceNum": .string("INV-2026-0042")])
        }
        let owed = try await r.invoice(orderId: "QUO-8", language: "en")
        guard case .refused(.notNumbered) = owed else { return XCTFail("\(owed)") }
        let book = try await r.wholeBook()
        guard case .object(let settings)? = book["settings"] else { return XCTFail() }
        XCTAssertNil(settings["invNumNext"], "the counter is untouched")

        guard case .paper(let doc, let filename) = try await r.invoice(orderId: "QUO-9", language: "en") else {
            return XCTFail("expected paper")
        }
        XCTAssertTrue(doc.html.contains("INV-2026-0042"))
        XCTAssertEqual(filename, "INV-2026-0042.pdf")
    }

    /// A proforma asks for payment before the work is invoiced: the shared
    /// paper with its proforma option, under the job's own id, no ZATCA QR,
    /// and nothing numbered — so even a job still owed a number has one.
    func testAProformaIsTheSharedPaperAndNumbersNothing() async throws {
        let r = try reader { store in
            guard case .object(var s)? = store["settings"] else { return }
            s["enableZatca"] = .bool(true)
            store["settings"] = .object(s)
            self.addOrder(&store, ["id": .string("QUO-8"), "status": .string("pending"),
                                   "quoteAcceptedAt": .string("2026-10-21")])
            self.addOrder(&store, ["id": .string("S-3001"), "status": .string("completed")])
            self.addOrder(&store, ["id": .string("S-3002"), "status": .string("printing"), "price": .number(0)])
        }
        guard case .paper(let doc, let filename) = try await r.invoice(orderId: "QUO-8", language: "en",
                                                                       proforma: true) else {
            return XCTFail("expected paper")
        }
        XCTAssertTrue(doc.html.lowercased().contains("proforma"))
        XCTAssertTrue(doc.html.contains("QUO-8"))
        XCTAssertFalse(doc.html.contains("alt=\"ZATCA\""), "a proforma is not a tax invoice")
        XCTAssertEqual(filename, "Proforma-QUO-8.pdf")
        let book = try await r.wholeBook()
        guard case .object(let settings)? = book["settings"] else { return XCTFail() }
        XCTAssertNil(settings["invNumNext"], "the counter is untouched")

        for refused in ["S-3001", "S-3002"] {
            let build = try await r.invoice(orderId: refused, language: "en", proforma: true)
            guard case .refused(.noProforma) = build else { return XCTFail("\(refused): \(build)") }
        }
    }

    /// The ZATCA QR's total and VAT are riyals: a scanner reads the bare
    /// number as SAR. A job saved in a client's currency is converted at the
    /// rate stored on it; with no stored rate there is no QR, and the paper
    /// says why in its place.
    func testTheZatcaQrStatesRiyalsOrSaysWhyNot() async throws {
        let r = try reader { store in
            guard case .object(var s)? = store["settings"] else { return }
            s["enableZatca"] = .bool(true); s["vat"] = .string("300000000000003")
            s["currency"] = .string("SAR")
            store["settings"] = .object(s)
            self.addOrder(&store, ["id": .string("S-4001"), "status": .string("completed")])
            self.addOrder(&store, ["id": .string("S-4002"), "status": .string("completed"),
                                   "currency": .string("EUR"), "fxRate": .number(4.05)])
            self.addOrder(&store, ["id": .string("S-4003"), "status": .string("completed"),
                                   "currency": .string("EUR")])
        }
        for ok in ["S-4001", "S-4002"] {
            guard case .paper(let doc, _) = try await r.invoice(orderId: ok, language: "en") else {
                return XCTFail("\(ok): expected paper")
            }
            XCTAssertTrue(doc.html.contains("alt=\"ZATCA\""), "\(ok) carries a QR")
            XCTAssertFalse(doc.html.contains("no saved rate"), ok)
        }
        guard case .paper(let doc, _) = try await r.invoice(orderId: "S-4003", language: "en") else {
            return XCTFail("expected paper")
        }
        XCTAssertFalse(doc.html.contains("alt=\"ZATCA\""), "no riyal figure, so no QR")
        XCTAssertTrue(doc.html.contains("no saved rate to state it in SAR"), "the reason prints in its place")
    }

    func testAPartialHistoryPrintsNoLoyaltyBadge() async throws {
        let base = SampleShop.scope()
        var held = base.collections
        held["printLog"] = .init(whole: false, sent: 11, available: 900)
        let partial = BookScope.Taken(collections: held, omitted: base.omitted, takenAt: base.takenAt)
        let r = try reader(scope: partial) { store in
            guard case .object(var s)? = store["settings"] else { return }
            s["loyaltyEnabled"] = .bool(true)
            store["settings"] = .object(s)
        }
        XCTAssertFalse(r.holdsAll("printLog"))
        guard case .paper = try await r.invoice(orderId: "S-1036", language: "en") else {
            return XCTFail("a partial book still draws the invoice")
        }
    }

    func testTheShopsFieldsAreEnglishFirst() {
        let fields = ShopFields.document([
            "bizAr": .string("ورشة"), "addrAr": .string("الرياض"), "addrEn": .string(""), "taglineEn": .string("Made here"),
        ])
        XCTAssertEqual(fields["biz"], .string("ورشة"))
        XCTAssertEqual(fields["addr"], .string("الرياض"), "an empty English field falls through")
        XCTAssertEqual(fields["tagline"], .string("Made here"))
        XCTAssertEqual(fields["footer"], .string(""))
    }

    func testTheFileIsNamedAsTheMacNamesIt() {
        XCTAssertEqual(BookReader.invoiceFilename(number: "INV/2026:7", project: nil), "INV-2026-7.pdf")
        XCTAssertEqual(BookReader.invoiceFilename(number: "", project: "Planter"), "Planter.pdf")
    }

    // MARK: - A voided or credited invoice is stamped (Turki, Nov 2026)

    func testAVoidedInvoicePrintsStampedVoidWithItsDay() async throws {
        let r = try reader { store in
            self.addOrder(&store, ["id": .string("S-2101"), "status": .string("completed"), "project": .string("Sign"),
                                   "voidedAt": .string("2026-11-02T09:30:00.000Z"),
                                   "voidedReason": .string("Duplicate invoice"), "paymentStatus": .string("voided")])
            self.addOrder(&store, ["id": .string("S-2102"), "status": .string("completed"), "project": .string("Plain")])
        }
        guard case .paper(let doc, let filename) = try await r.invoice(orderId: "S-2101", language: "en") else {
            return XCTFail("a voided invoice still prints — stamped")
        }
        XCTAssertTrue(doc.html.contains("data-stamp=\"void\""), "the shared document stamps the paper")
        XCTAssertTrue(doc.html.contains("inv-reversal-mark"), "the word across the page")
        XCTAssertTrue(doc.html.contains(">VOID</span>"))
        XCTAssertTrue(doc.html.contains("This invoice was voided on"), "the heading line")
        XCTAssertTrue(doc.html.contains("2026"), "with the day")
        XCTAssertTrue(doc.html.contains("Reason: Duplicate invoice"))
        XCTAssertTrue(doc.html.contains("Sign"), "the shared document is still all there")
        XCTAssertEqual(filename, "S-2101.pdf")

        guard case .paper(let plain, _) = try await r.invoice(orderId: "S-2102", language: "en") else {
            return XCTFail("expected paper")
        }
        XCTAssertFalse(plain.html.contains("inv-reversal"), "a standing invoice carries no stamp")

        guard case .paper(let ar, _) = try await r.invoice(orderId: "S-2101", language: "ar") else {
            return XCTFail("expected paper")
        }
        XCTAssertTrue(ar.html.contains("ملغاة"), "stamped in the paper's language")
        XCTAssertTrue(ar.html.contains("dir=\"rtl\""))
        XCTAssertNil(ar.html.range(of: "[\u{0660}-\u{0669}]", options: .regularExpression), "Western digits")
    }

    func testAFullyCreditedInvoiceIsStampedCreditedAndAPartialCreditIsNot() async throws {
        let r = try reader { store in
            self.addOrder(&store, ["id": .string("S-2201"), "status": .string("completed"), "project": .string("Sign"),
                                   "creditNotes": .array([.object(["id": .string("cn1"), "amount": .number(115)])]),
                                   "creditedAt": .string("2026-11-03T12:00:00.000Z")])
            self.addOrder(&store, ["id": .string("S-2202"), "status": .string("completed"), "project": .string("Half"),
                                   "creditNotes": .array([.object(["id": .string("cn2"), "amount": .number(50)])])])
        }
        guard case .paper(let doc, _) = try await r.invoice(orderId: "S-2201", language: "en") else {
            return XCTFail("expected paper")
        }
        XCTAssertTrue(doc.html.contains("data-stamp=\"credited\""))
        XCTAssertTrue(doc.html.contains(">CREDITED</span>"))
        XCTAssertTrue(doc.html.contains("This invoice was credited in full on"))
        guard case .paper(let half, _) = try await r.invoice(orderId: "S-2202", language: "en") else {
            return XCTFail("expected paper")
        }
        XCTAssertFalse(half.html.contains("inv-reversal"), "a partial credit stamps nothing (lib/invoice-reversal.js)")
    }

    func testTheRulesPlaceholderReasonIsNotPrinted() async throws {
        let r = try reader { store in
            self.addOrder(&store, ["id": .string("S-2301"), "status": .string("completed"), "project": .string("Sign"),
                                   "voidedAt": .string("2026-11-02T09:30:00.000Z"), "voidedReason": .string("Voided")])
        }
        guard case .paper(let doc, _) = try await r.invoice(orderId: "S-2301", language: "en") else {
            return XCTFail("expected paper")
        }
        XCTAssertTrue(doc.html.contains("data-stamp=\"void\""))
        XCTAssertFalse(doc.html.contains("inv-reversal-reason"), "lib/invoice-reversal.js's placeholder is not a reason")
    }

    func testTheStylesheetIsTheDesktops() throws {
        let bundled = InvoicePaper.stylesheet
        XCTAssertTrue(bundled.contains(".inv"), "renderer/invoice.css is bundled and readable")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../renderer/invoice.css").standardized
        XCTAssertEqual(bundled, try String(contentsOf: source, encoding: .utf8),
                       "ios/KhaytCompanion/Resources/invoice.css has drifted from renderer/invoice.css")
    }
}
