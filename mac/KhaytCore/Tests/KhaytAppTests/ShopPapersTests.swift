import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The packing slip, delivery note, work order and account statement, and a
/// quote's Reject / Revise / history / follow-up — batch C of the Nov 2026
/// desktop parity list.
///
/// The papers and the revision rule are `lib/shop-documents.js` and
/// `lib/quote-revision.js` (held by Node tests, including that the desktop's
/// handlers call them); these pin that the Mac draws them from the same
/// module and writes the same fields the desktop writes.
@MainActor
struct ShopPapersTests {

    static let settings: [String: JSONValue] = [
        "currency": .string("SAR"),
        "postChecklist": .array([.object(["label": .string("Sand the seams")])]),
    ]

    static let client: JSONValue = .object([
        "id": .string("C1"), "nameEn": .string("Sara"), "name": .string("Sara"),
        "phone": .string("+966500000000"), "email": .string("sara@example.com"),
    ])

    static func job() -> [String: JSONValue] {
        [
            "id": .string("INV-7"), "jobNumber": .string("INV-7"), "clientId": .string("C1"),
            "date": .string("2026-10-01"), "status": .string("completed"),
            "project": .string("Lamp <shade>"), "price": .number(100), "paidAmount": .number(40),
            "machineId": .string("M1"), "notes": .string("Wrap well"),
            "trackingNumber": .string("TRK-1"), "courierName": .string("SMSA"),
            "parts": .array([.object([
                "name": .string("Shade"), "qty": .number(2), "printWeight": .number(10),
                "material": .string("PLA"), "colour": .string("Red"), "printTime": .number(1.5),
            ])]),
        ]
    }

    static func inputs(language: String = "en", docs: [JSONValue] = []) -> KhaytEngine.PaperInputs {
        KhaytEngine.PaperInputs(
            settings: settings, clients: [client],
            machines: [.object(["id": .string("M1"), "name": .string("X1C")])],
            language: language, shopName: "Atelier", today: "2026-11-05", docs: docs)
    }

    @Test("each job paper is the shared module's, escaped, with the job's own facts")
    func jobPapers() async throws {
        let engine = try KhaytEngine()
        let docs: [JSONValue] = [
            .object(["name": .string("Safety sheet"), "packWithOrder": .bool(true)]),
            .object(["name": .string("Setup sheet"), "packWithOrder": .bool(false)]),
        ]
        let slip = try await engine.shopPaperHtml(.packingSlip, order: .object(Self.job()), Self.inputs(docs: docs))
        #expect(slip.hasPrefix("<!DOCTYPE html>"), "a whole page of its own")
        #expect(slip.contains("<strong>Sara</strong>"), "ships to the linked customer")
        #expect(slip.contains("20g"), "quantity × grams")
        #expect(!slip.contains("<shade>"), "the project name is escaped")

        let note = try await engine.shopPaperHtml(.deliveryNote, order: .object(Self.job()), Self.inputs(docs: docs))
        #expect(note.contains("Delivery Note"), "in the shop's words")
        #expect(note.contains("TRK-1") && note.contains("SMSA"))
        #expect(note.contains("Safety sheet"))
        #expect(!note.contains("Setup sheet"), "a setup sheet does not go in the box")

        let floor = try await engine.shopPaperHtml(.workOrder, order: .object(Self.job()), Self.inputs(docs: docs))
        #expect(floor.contains("Work Order"))
        #expect(floor.contains("WO-INV-7"))
        #expect(floor.contains("X1C"), "the machine")
        #expect(floor.contains("Sand the seams"), "the shop's checklist")
        #expect(floor.contains("Setup sheet"), "the floor sees every document")
        #expect(!floor.contains("100.00"), "no price on the floor's sheet")
    }

    @Test("an Arabic shop's papers are in Arabic, right to left")
    func arabicPapers() async throws {
        let engine = try KhaytEngine()
        let slip = try await engine.shopPaperHtml(.packingSlip, order: .object(Self.job()), Self.inputs(language: "ar"))
        #expect(slip.contains("dir=\"rtl\""))
        let note = try await engine.shopPaperHtml(.deliveryNote, order: .object(Self.job()), Self.inputs(language: "ar"))
        #expect(note.contains("dir=\"rtl\""))
        // The title in Arabic first; the shop's second language may follow it.
        #expect(note.contains("<div class=\"title\">إشعار تسليم</div>"))
    }

    @Test("the statement adds up the customer's jobs in the shop's currency")
    func statement() async throws {
        let engine = try KhaytEngine()
        var other = Self.job()
        other["id"] = .string("X-1"); other["clientId"] = .string("C2"); other["price"] = .number(999)
        var older = Self.job()
        older["id"] = .string("INV-3"); older["jobNumber"] = .string("INV-3")
        older["date"] = .string("2026-09-01"); older["price"] = .number(50); older["paidAmount"] = .number(50)
        let html = try await engine.statementHtml(client: Self.client,
                                                  orders: [Self.job(), other, older].map(JSONValue.object),
                                                  Self.inputs())
        #expect(html.contains("Account Statement"))
        #expect(html.contains("150.00"), "charged across both of Sara's jobs")
        #expect(html.contains("90.00"), "paid")
        #expect(html.contains("60.00"), "still owed")
        #expect(!html.contains("999"), "another customer's job is not on it")
        let first = try #require(html.range(of: "INV-3")), second = try #require(html.range(of: "INV-7"))
        #expect(first.lowerBound < second.lowerBound, "oldest first")
    }

    @Test("Export all invoices takes the customer's finished work, oldest first")
    func invoicesToExport() async throws {
        let engine = try KhaytEngine()
        var quote = Self.job(); quote["id"] = .string("Q-1"); quote["status"] = .string("quote")
        var older = Self.job(); older["id"] = .string("INV-3"); older["date"] = .string("2026-09-01")
        older["status"] = .string("delivered")
        let ids = try await engine.invoicesToExport(clientId: "C1", orders: [Self.job(), quote, older].map(JSONValue.object))
        #expect(ids == ["INV-3", "INV-7"])
    }

    @Test("revise keeps the quote as it was, in the desktop's fields")
    func reviseFields() async throws {
        let engine = try KhaytEngine()
        var quote = Self.job()
        quote["status"] = .string("quote")
        let revised = try await engine.reviseQuote(order: .object(quote), now: Date(timeIntervalSince1970: 1_793_000_000))
        guard case .object(let o) = revised, case .array(let kept)? = o["quoteRevisions"],
              case .object(let row)? = kept.first else { Issue.record("no revision"); return }
        #expect(o["quoteVersion"] == .number(2))
        #expect(row["version"] == .number(1))
        #expect(row["price"] == .number(100))
        #expect(row["notes"] == .string("Wrap well"))
        let history = try await engine.quoteRevisions(order: revised)
        #expect(history.map(\.version) == [1])
        #expect(history.first?.partCount == 1)
        // A job that is not a quote is not revised.
        let job = try await engine.reviseQuote(order: .object(Self.job()))
        guard case .object(let j) = job else { return }
        #expect(j["quoteRevisions"] == nil)
    }

    @Test("a follow-up is recorded in followUpSentAt / followUpCount, and the rule then waits")
    func followUpFields() async throws {
        let engine = try KhaytEngine()
        let settings: [String: JSONValue] = ["quoteFollowUp": .object(["enabled": .bool(true)])]
        var quote = Self.job()
        quote["status"] = .string("quote")
        quote["quoteExpiresAt"] = .string(Calendar.book.dayString(Date().addingTimeInterval(86400)))
        #expect(try await engine.followUpDue(order: .object(quote), settings: settings))
        let marked = try await engine.markFollowUp(order: .object(quote))
        guard case .object(let o) = marked else { return }
        #expect(o["followUpCount"] == .number(1))
        #expect(o["followUpSentAt"] != nil)
        #expect(try await !engine.followUpDue(order: marked, settings: settings), "inside the cooldown")
    }

    @Test("every paper has its words in the shared catalogue")
    func paperTitles() async throws {
        let words = Words()
        await words.load("en", engine: try KhaytEngine())
        for kind in KhaytEngine.ShopPaper.allCases {
            let key = Shop.paperTitleKey(kind)
            #expect(words.callIt(key) != key, "\(key) is a word, not a key")
        }
        #expect(Shop.paperFilename(.workOrder, reference: "INV/7") == "work-order-INV-7.pdf")
    }
}

/// The ones that write a real book, in the serialised suite that owns the
/// temp support folder (`withPerfBook`).
extension LibraryEditPerfTests {

    static func quoteBook(_ quote: [String: JSONValue], followUp: Bool = true) -> [String: JSONValue] {
        var book = PerfBook.synthesize(models: 1)
        book["printLog"] = .array([.object(quote)])
        book["clients"] = .array([.object(["id": .string("C1"), "nameEn": .string("Sara"), "phone": .string("")])])
        book["settings"] = .object([
            "currency": .string("SAR"),
            "quoteFollowUp": .object(["enabled": .bool(followUp)]),
        ])
        return book
    }

    static func dueQuote() -> [String: JSONValue] {
        [
            "id": .string("Q1"), "date": .string("2026-10-01"), "status": .string("quote"),
            "project": .string("Lamp shade"), "client": .string("Sara"), "clientId": .string("C1"),
            "price": .number(200), "paidAmount": .number(0), "paymentStatus": .string("unpaid"),
            "printTime": .number(1), "priority": .bool(false), "notes": .string("first"), "rev": .number(1),
            "quoteExpiresAt": .string(Calendar.book.dayString(Date().addingTimeInterval(86400))),
        ]
    }

    @Test("Revise keeps a version on the book and opens the editor")
    func papers_reviseWritesAndOpensEditor() async throws {
        try await withPerfBook(Self.quoteBook(Self.dueQuote(), followUp: false)) { shop, url in
            await shop.reviseQuote("Q1")
            let disk = try DepositsAndRemindersTests.onDisk(url, "Q1")
            #expect(disk["quoteVersion"] == .number(2))
            guard case .array(let kept)? = disk["quoteRevisions"] else { Issue.record("not kept"); return }
            #expect(kept.count == 1)
            #expect(shop.pendingEdit?.id == "Q1", "the editor opens to change it")
            #expect(shop.hasQuoteRevisions("Q1"))
            #expect(shop.quoteVersion("Q1") == 2)
            #expect(await shop.quoteRevisions("Q1").map(\.version) == [1])
        }
    }

    @Test("Reject asks to delete a free quote, and refuses one that took money")
    func papers_rejectFollowsTheDeleteRule() async throws {
        try await withPerfBook(Self.quoteBook(Self.dueQuote(), followUp: false)) { shop, _ in
            shop.rejectQuote("Q1")
            #expect(shop.pendingJobDelete?.ids == ["Q1"], "asked first, with Undo after")
        }
        var paid = Self.dueQuote()
        paid["paidAmount"] = .number(50)
        paid["paymentStatus"] = .string("partial")
        try await withPerfBook(Self.quoteBook(paid, followUp: false)) { shop, url in
            shop.rejectQuote("Q1")
            #expect(shop.pendingJobDelete == nil, "a quote with a payment is not deleted")
            #expect(shop.moveProblem != nil, "and the shop is told why")
            let disk = try DepositsAndRemindersTests.onDisk(url, "Q1")
            #expect(disk["status"] == .string("quote"))
        }
    }

    @Test("the automatic follow-up records a due quote once, and never twice")
    func papers_autoFollowUpOnce() async throws {
        try await withPerfBook(Self.quoteBook(Self.dueQuote())) { shop, url in
            // The pass the load started: wait for its write.
            var count: JSONValue?
            for _ in 0..<100 {
                count = try DepositsAndRemindersTests.onDisk(url, "Q1")["followUpCount"]
                if count != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(count == .number(1), "recorded, though the customer has no number to message")
            #expect(try DepositsAndRemindersTests.onDisk(url, "Q1")["followUpSentAt"] != nil)
            // Again: the six-hour gate, and the shared rule's cooldown, each hold.
            shop.followUpQuotesIfDue()
            let again = await shop.recordFollowUps(["Q1"], onlyIfDue: true)
            #expect(again.isEmpty, "inside the cooldown")
            #expect(try DepositsAndRemindersTests.onDisk(url, "Q1")["followUpCount"] == .number(1))
            // The in-memory book catches up with the disk after the write
            // (the reload is its own hop); on a loaded runner that can lag.
            for _ in 0..<100 where !shop.quotesToChase.isEmpty {
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(shop.quotesToChase.isEmpty, "off Today for the cooldown")
        }
    }

    @Test("the follow-up is not sent when the shop has not switched it on")
    func papers_autoFollowUpOff() async throws {
        try await withPerfBook(Self.quoteBook(Self.dueQuote(), followUp: false)) { shop, url in
            shop.followUpQuotesIfDue()
            try await Task.sleep(for: .milliseconds(300))
            #expect(try DepositsAndRemindersTests.onDisk(url, "Q1")["followUpCount"] == nil)
        }
    }

    @Test("a follow-up by hand to a customer with no number says so and records nothing")
    func papers_followUpNeedsANumber() async throws {
        try await withPerfBook(Self.quoteBook(Self.dueQuote(), followUp: false)) { shop, url in
            await shop.sendQuoteFollowUp("Q1")
            #expect(shop.moveProblem == shop.words.callIt("quote.followup_no_phone"))
            let disk = try DepositsAndRemindersTests.onDisk(url, "Q1")
            #expect(disk["followUpCount"] == nil)
        }
    }

    @Test("an overdue invoice is flagged once a session, and nothing is written")
    func papers_overdueFlaggedOnce() async throws {
        try await withPerfBook(DepositsAndRemindersTests.book([DepositsAndRemindersTests.overdue()])) { shop, url in
            #expect(shop.flaggedInvoices.contains("J1"))
            shop.importNote = nil
            shop.flagOverdueInvoices(shop.invoicesToChase)
            #expect(shop.importNote == nil, "not flagged a second time")
            let disk = try DepositsAndRemindersTests.onDisk(url, "J1")
            #expect(disk["payReminderCount"] == nil, "flagging is not a sent reminder")
        }
    }

    @Test("a job's papers and a customer's statement draw from the book")
    func papers_drawFromTheBook() async throws {
        var job = Self.dueQuote()
        job["status"] = .string("completed")
        try await withPerfBook(Self.quoteBook(job, followUp: false)) { shop, _ in
            for kind in KhaytEngine.ShopPaper.allCases {
                shop.showPaper(kind, for: "Q1")
                guard let request = shop.pendingPaper else { Issue.record("not asked"); continue }
                guard case .paper(let doc, _) = await shop.paperDocument(request) else {
                    Issue.record("\(kind) refused"); continue
                }
                #expect(doc.html.contains("Lamp shade") || doc.html.contains("Sara"))
            }
            guard let sara = shop.shownCustomers.first(where: { $0.record?.id == "C1" }) else {
                Issue.record("no customer"); return
            }
            shop.showStatement(for: sara)
            guard let request = shop.pendingPaper, case .paper(let doc, _) = await shop.paperDocument(request) else {
                Issue.record("no statement"); return
            }
            #expect(doc.html.contains("Q1") && doc.html.contains("200.00"))
            #expect(await shop.invoicesToExport(for: sara) == ["Q1"])
        }
    }
}
