import KhaytCore
import XCTest
@testable import KhaytCompanion

/// The shop's papers and a quote's Revise / history / follow-up on the
/// phone: the Mac's `lib/shop-documents.js` and `lib/quote-revision.js`
/// through the phone's engine, from and into the book the phone keeps.
@MainActor
final class ShopPapersAndQuotesTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("papers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    /// The sample shop, changed by `edit`, as a book.
    private func book(scope: BookScope.Taken? = SampleShop.scope(),
                      _ edit: (inout [String: JSONValue]) -> Void = { _ in }) throws -> CompanionBook {
        var store = SampleShop.book()
        edit(&store)
        let folder = dir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let book = CompanionBook(directory: folder)
        try book.replace(with: store, scope: scope)
        return book
    }

    private func order(_ book: CompanionBook, _ id: String) throws -> [String: JSONValue] {
        guard case .array(let rows)? = try book.read()["printLog"] else { throw XCTSkip("no printLog") }
        for case .object(let o) in rows where o["id"] == .string(id) { return o }
        XCTFail("no order \(id)")
        return [:]
    }

    private func paper(_ build: PaperBuild, file: StaticString = #filePath, line: UInt = #line)
        -> (html: String, filename: String, wholePage: Bool, partial: Bool)? {
        guard case .paper(let doc, let filename, let wholePage, let partial) = build else {
            XCTFail("expected a paper, got \(build)", file: file, line: line)
            return nil
        }
        return (doc.html, filename, wholePage, partial)
    }

    // MARK: - Papers

    func testEachJobPaperIsTheSharedModulesWithTheJobsOwnFacts() async throws {
        let reader = BookReader(book: try book())
        // S-1046: Acme Robotics' enclosure lid, in post-processing, 95.
        let slipBuild = try await reader.shopPaper(.job(.packingSlip, orderId: "S-1046"), language: "en")
        let slip = try XCTUnwrap(paper(slipBuild))
        XCTAssertTrue(slip.html.hasPrefix("<!DOCTYPE html>"), "the slip is a whole page of its own")
        XCTAssertTrue(slip.wholePage)
        XCTAssertTrue(slip.html.contains("Acme Robotics"), "ships to the job's customer")
        XCTAssertTrue(slip.html.contains("S-1046"), "the job's reference")
        XCTAssertEqual(slip.filename, "packing-slip-S-1046.pdf")

        let built = try await reader.shopPaper(.job(.deliveryNote, orderId: "S-1046"), language: "en")
        let note = try XCTUnwrap(paper(built))
        XCTAssertFalse(note.wholePage, "drawn in the invoice's stylesheet")
        XCTAssertTrue(note.html.contains("Delivery Note"))
        // "Deliver to" is the invoice's rule since #2276: the linked customer
        // (not the job's description), with their number under it.
        XCTAssertTrue(note.html.contains("Acme Robotics"), "addressed to the linked customer")
        XCTAssertTrue(note.html.contains("+15555550101"), "Acme Robotics' number")
        XCTAssertTrue(note.html.contains("S-1046"))
        XCTAssertTrue(note.html.contains("Sample Print Shop"), "the shop's name")
        XCTAssertEqual(note.filename, "delivery-note-S-1046.pdf")

        let floorBuild = try await reader.shopPaper(.job(.workOrder, orderId: "S-1046"), language: "en")
        let floor = try XCTUnwrap(paper(floorBuild))
        XCTAssertTrue(floor.html.contains("Work Order"))
        XCTAssertTrue(floor.html.contains("WO-S-1046"))
        XCTAssertTrue(floor.html.contains("Enclosure lid"))
        XCTAssertFalse(floor.html.contains("95.00"), "no price on the floor's sheet")
        XCTAssertEqual(floor.filename, "work-order-S-1046.pdf")
    }

    func testAPaperCarriesTheJobNumberNotTheRawId() async throws {
        let b = try book { store in
            guard case .array(var rows)? = store["printLog"] else { return }
            rows.append(.object(["id": .string("ORD-mz81k2-QX7"), "jobNumber": .string("KH-0042"),
                                 "status": .string("completed"), "project": .string("Name plate"),
                                 "client": .string("Maya Chen"), "clientId": .string("C-3"),
                                 "date": .string("2026-10-30"), "price": .number(25), "paidAmount": .number(0),
                                 "parts": .array([.object(["qty": .number(1)])]), "rev": .number(1)]))
            store["printLog"] = .array(rows)
        }
        let built = try await BookReader(book: b)
            .shopPaper(.job(.deliveryNote, orderId: "ORD-mz81k2-QX7"), language: "en")
        let note = try XCTUnwrap(paper(built))
        XCTAssertTrue(note.html.contains("KH-0042"))
        XCTAssertTrue(note.html.contains("+15555550142"), "Maya Chen's number")
        XCTAssertEqual(note.filename, "delivery-note-KH-0042.pdf")
    }

    func testAnArabicShopsPapersReadRightToLeft() async throws {
        let reader = BookReader(book: try book())
        let built = try await reader.shopPaper(.job(.deliveryNote, orderId: "S-1046"), language: "ar")
        let note = try XCTUnwrap(paper(built))
        XCTAssertTrue(note.html.contains("dir=\"rtl\""))
        XCTAssertTrue(note.html.contains("إشعار تسليم"))
    }

    func testAQuoteHasNoPapersAndAMissingJobSaysSo() async throws {
        let reader = BookReader(book: try book())
        guard case .refused(let why) = try await reader.shopPaper(.job(.packingSlip, orderId: "S-1048"), language: "en")
        else { return XCTFail("a quote has nothing to pack") }
        XCTAssertEqual(why, .quote)
        guard case .refused(let gone) = try await reader.shopPaper(.job(.workOrder, orderId: "NOPE"), language: "en")
        else { return XCTFail("expected a refusal") }
        XCTAssertEqual(gone, .missing)
    }

    func testTheStatementListsTheCustomersJobsAndNobodyElses() async throws {
        let reader = BookReader(book: try book())
        let built = try await reader.shopPaper(.statement(clientId: "C-3"), language: "en")
        let statement = try XCTUnwrap(paper(built))
        XCTAssertTrue(statement.html.contains("Account Statement"))
        XCTAssertTrue(statement.html.contains("Maya Chen"), "the customer's name")
        XCTAssertTrue(statement.html.contains("S-1038"), "her finished planter")
        XCTAssertTrue(statement.html.contains("S-1044"), "her phone stand")
        XCTAssertFalse(statement.html.contains("S-1041"), "Acme's drone arms are not on her statement")
        XCTAssertEqual(statement.filename, "statement-Maya Chen.pdf")
        XCTAssertFalse(statement.wholePage)
    }

    func testAStatementFromPartOfTheBookIsMadeAndSaysSo() async throws {
        let full = SampleShop.scope()
        var held = full.collections
        held["printLog"] = .init(whole: false, sent: 9, available: 3_140)
        let partial = BookScope.Taken(collections: held, omitted: full.omitted, takenAt: full.takenAt)
        let reader = BookReader(book: try book(scope: partial))
        let built = try await reader.shopPaper(.statement(clientId: "C-3"), language: "en")
        let statement = try XCTUnwrap(paper(built), "Turki, Nov 2026: made anyway, never refused")
        XCTAssertTrue(statement.partial, "the page warns before it is shared")
        XCTAssertTrue(statement.html.contains("Account Statement"))
        XCTAssertTrue(statement.html.contains("Maya Chen"))
        XCTAssertTrue(statement.html.hasPrefix("<div class=\"statement-partial\""), "the line heads the paper")
        XCTAssertTrue(statement.html.contains(L10n.tr("paper.statement.partial.printed", language: "en")))
        XCTAssertTrue(statement.html.contains("may be missing"), "said plainly on the paper itself")
        let arBuild = try await reader.shopPaper(.statement(clientId: "C-3"), language: "ar")
        let arabic = try XCTUnwrap(paper(arBuild))
        XCTAssertTrue(arabic.html.contains(L10n.tr("paper.statement.partial.printed", language: "ar")),
                      "in the statement's own language")
        XCTAssertTrue(arabic.html.contains("dir=\"rtl\""))
        // A job's own papers need only the job, and are never partial.
        let noteBuild = try await reader.shopPaper(.job(.deliveryNote, orderId: "S-1046"), language: "en")
        let note = try XCTUnwrap(paper(noteBuild))
        XCTAssertFalse(note.partial)
        XCTAssertFalse(note.html.contains("statement-partial"))
    }

    func testAStatementFromTheWholeBookCarriesNoWarning() async throws {
        let reader = BookReader(book: try book())
        let built = try await reader.shopPaper(.statement(clientId: "C-3"), language: "en")
        let statement = try XCTUnwrap(paper(built))
        XCTAssertFalse(statement.partial)
        XCTAssertFalse(statement.html.contains("statement-partial"))
    }

    func testAPhoneWithoutABookMakesNoPaper() async {
        let api = KhaytAPIClient(settings: ConnectionSettings(), withBook: false)
        guard case .refused(let why) = await api.shopPaper(.job(.packingSlip, orderId: "S-1046")) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(why, .missing)
    }

    // MARK: - Revise

    func testRevisingAQuoteKeepsItsVersionAndMakesTheChangeInOneWrite() async throws {
        let b = try book()
        let engine = try await BookReader(book: b).sharedEngine()
        let writer = BookWriter(book: b)
        let before = try order(b, "S-1048")

        let wrote = try await writer.reviseQuote(orderId: "S-1048",
                                                 fields: ["price": .number(300), "notes": .string("Thicker walls")],
                                                 engine: engine)
        XCTAssertTrue(wrote)
        let after = try order(b, "S-1048")
        XCTAssertEqual(after["quoteVersion"], .number(2))
        guard case .array(let kept)? = after["quoteRevisions"], case .object(let first)? = kept.first else {
            return XCTFail("the quote as it was is kept")
        }
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(first["version"], .number(1))
        XCTAssertEqual(first["price"], .number(340), "the price it was")
        XCTAssertEqual(after["price"], .number(300), "the price it is now")
        XCTAssertEqual(after["notes"], .string("Thicker walls"))
        XCTAssertEqual(after["status"], .string("quote"), "still a quote")
        XCTAssertNotEqual(after["rev"], before["rev"], "stamped, so the change travels")

        try await writer.reviseQuote(orderId: "S-1048", fields: ["price": .number(280)], engine: engine)
        let again = try order(b, "S-1048")
        XCTAssertEqual(again["quoteVersion"], .number(3))
        guard case .array(let twice)? = again["quoteRevisions"] else { return XCTFail() }
        XCTAssertEqual(twice.count, 2)
        let history = try await engine.quoteRevisions(order: .object(again))
        XCTAssertEqual(history.map(\.version), [2, 1], "newest first")
        XCTAssertEqual(history.map(\.price), [300, 340])
    }

    func testARevisionThatChangesNothingWritesNothing() async throws {
        let b = try book()
        let engine = try await BookReader(book: b).sharedEngine()
        let before = try order(b, "S-1048")
        let wrote = try await BookWriter(book: b).reviseQuote(orderId: "S-1048", fields: ["price": .number(340)],
                                                             engine: engine)
        XCTAssertFalse(wrote)
        XCTAssertEqual(try order(b, "S-1048"), before, "no version kept for a sheet opened and closed")
    }

    func testOnlyAQuoteIsRevisedOrFollowedUp() async throws {
        let b = try book()
        let engine = try await BookReader(book: b).sharedEngine()
        let writer = BookWriter(book: b)
        do {
            try await writer.reviseQuote(orderId: "S-1046", fields: ["price": .number(1)], engine: engine)
            XCTFail("an accepted job is edited, not revised")
        } catch let refusal as BookWriter.Refusal {
            XCTAssertEqual(refusal, .notAQuote)
        }
        do {
            try await writer.recordFollowUp(orderId: "S-1046", engine: engine)
            XCTFail("only a quote is followed up")
        } catch let refusal as BookWriter.Refusal {
            XCTAssertEqual(refusal, .notAQuote)
        }
    }

    func testTheReviseSheetSendsOnlyWhatMoved() {
        let edit = KhaytAPIClient.OrderEditState(dueDate: "2026-11-20", priorityLevel: "normal", price: 340)
        let quote = KhaytAPIClient.QuoteState(version: 1, followUpCount: 0, followUpSentAt: nil,
                                              price: 340, notes: "ABS", revisions: [],
                                              invoiceNotes: "Ships in a week", discountPct: 10, shippingCost: 0)
        func fields(due: String? = "2026-11-20", level: String = "normal", price: Double? = 340,
                    discount: String = "10", shipping: String = "", notes: String = "ABS",
                    printed: String = "Ships in a week") -> [String: JSONValue] {
            EditOrderSheet.reviseFields(start: edit, quote: quote, due: due, level: level, price: price,
                                        discount: discount, shipping: shipping, notes: notes, invoiceNotes: printed)
        }
        XCTAssertTrue(fields().isEmpty, "a sheet opened and saved unchanged sends nothing")
        let moved = fields(due: nil, level: "urgent", price: 300, discount: "", shipping: "25",
                           notes: "ABS, black", printed: "Ships in 3 days")
        XCTAssertEqual(moved["dueDate"], .null)
        XCTAssertEqual(moved["priorityLevel"], .string("urgent"))
        XCTAssertEqual(moved["price"], .number(300))
        XCTAssertEqual(moved["discountPct"], .number(0), "an emptied discount box is no discount")
        XCTAssertEqual(moved["shippingCost"], .number(25))
        XCTAssertEqual(moved["notes"], .string("ABS, black"))
        XCTAssertEqual(moved["invoiceNotes"], .string("Ships in 3 days"))
        XCTAssertNil(fields(price: nil)["price"], "an unreadable price leaves the price alone")
        XCTAssertNil(fields(discount: "abc")["discountPct"], "an unreadable discount leaves it alone")
        XCTAssertEqual(EditOrderSheet.plain(10), "10")
        XCTAssertEqual(EditOrderSheet.plain(0), "")
        XCTAssertEqual(EditOrderSheet.plain(12.5), "12.50")
    }

    func testRevisingCoversEveryFieldTheEditorWritesAndKeepsTheVersion() async throws {
        let b = try book()
        let engine = try await BookReader(book: b).sharedEngine()
        let fields: [String: JSONValue] = [
            "dueDate": .string("2026-12-01"), "priorityLevel": .string("urgent"),
            "discountPct": .number(10), "shippingCost": .number(20),
            "notes": .string("Thicker walls"), "invoiceNotes": .string("Ships in 3 days"),
        ]
        let wrote = try await BookWriter(book: b).reviseQuote(orderId: "S-1048", fields: fields, engine: engine)
        XCTAssertTrue(wrote)
        let after = try order(b, "S-1048")
        XCTAssertEqual(after["quoteVersion"], .number(2), "a version kept, as Revise always has")
        guard case .array(let kept)? = after["quoteRevisions"], case .object(let first)? = kept.first else {
            return XCTFail("the quote as it was is kept")
        }
        XCTAssertEqual(first["price"], .number(340))
        XCTAssertEqual(after["status"], .string("quote"), "still a quote, so the customer is asked again")
        XCTAssertEqual(after["dueDate"], .string("2026-12-01"))
        XCTAssertEqual(after["priorityLevel"], .string("urgent"))
        XCTAssertEqual(after["priority"], .bool(true), "the priority is a pair")
        XCTAssertEqual(after["discountPct"], .number(10))
        XCTAssertEqual(after["shippingCost"], .number(20))
        XCTAssertEqual(after["notes"], .string("Thicker walls"))
        XCTAssertEqual(after["invoiceNotes"], .string("Ships in 3 days"))
        guard case .array(let edits)? = after["editHistory"], !edits.isEmpty else {
            return XCTFail("the tracked fields are written in the job's history")
        }
    }

    // MARK: - Follow-up

    func testAFollowUpIsStampedInTheBook() async throws {
        let b = try book()
        let engine = try await BookReader(book: b).sharedEngine()
        let writer = BookWriter(book: b)
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        try await writer.recordFollowUp(orderId: "S-1049", engine: engine, now: now)
        var o = try order(b, "S-1049")
        XCTAssertEqual(o["followUpCount"], .number(1))
        XCTAssertEqual(o["followUpSentAt"], .string(StoreWriter.iso(now)))
        try await writer.recordFollowUp(orderId: "S-1049", engine: engine, now: now.addingTimeInterval(86_400))
        o = try order(b, "S-1049")
        XCTAssertEqual(o["followUpCount"], .number(2), "counted on from what the book holds")
        XCTAssertEqual(o["status"], .string("quote"))
    }

    func testTheFollowUpMessageNamesTheReferenceNotTheId() async throws {
        let engine = try await BookReader(book: try book()).sharedEngine()
        let words = try await engine.translations(language: "en")
        let template = try XCTUnwrap(words["quote.followup_msg"])
        let quote: [String: JSONValue] = [
            "id": .string("ORD-mz81k2-QX7"), "jobNumber": .string("KH-0042"), "status": .string("quote"),
            "project": .string("Prototype housing"), "client": .string("Acme"), "price": .number(340),
            "quoteExpiresAt": .string("2026-11-12"),
        ]
        let text = KhaytAPIClient.followUpMessage(template: template, order: quote,
                                                  customerName: "Acme Robotics", currency: "SAR")
        XCTAssertTrue(text.contains("Acme Robotics"))
        XCTAssertTrue(text.contains("KH-0042"))
        XCTAssertFalse(text.contains("ORD-mz81k2-QX7"), "never the raw id")
        XCTAssertTrue(text.contains("Prototype housing"))
        XCTAssertTrue(text.contains("340.00 SAR"))
        XCTAssertTrue(text.contains("2026-11-12"))
        XCTAssertFalse(text.contains("{"), "every placeholder filled")
    }

    func testAPhoneWithoutABookSaysItCannotReviseOrFollowUp() async {
        let api = KhaytAPIClient(settings: ConnectionSettings(), withBook: false)
        do {
            try await api.reviseQuote(orderId: "S-1048", fields: ["price": .number(1)])
            XCTFail("no LAN route takes a revision")
        } catch {
            XCTAssertEqual(error.localizedDescription, L10n.tr("quote.needs_book"))
        }
        do {
            _ = try await api.followUpQuote(orderId: "S-1048")
            XCTFail("no LAN route takes a follow-up")
        } catch {
            XCTAssertEqual(error.localizedDescription, L10n.tr("quote.needs_book"))
        }
    }
}
