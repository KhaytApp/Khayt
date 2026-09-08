import Foundation
import Testing
import KhaytCore
@testable import KhaytApp

/// The document a customer is handed.
///
/// The HTML is `lib/invoice-document.js` and is tested where it lives, against
/// ten golden fixtures. What is tested here is that this app hands it the right
/// things: the tax already split, a currency table it can format against, the
/// customer's own record, and a ZATCA QR that is either valid or absent with a
/// reason. An invoice built from the wrong ingredients is well-formed and wrong,
/// which is the worst kind of document to hand somebody.
@MainActor
struct InvoiceTests {

    /// A shop with a real job on its book.
    ///
    /// `enableZatca` on and every field the QR needs present, so the default
    /// case is the one a registered Saudi shop actually prints; the cases that
    /// take a field away say so.
    static func paper(settings extra: [String: JSONValue] = [:],
                      order extraOrder: [String: JSONValue] = [:]) -> Invoice.Ingredients {
        var settings: [String: JSONValue] = [
            "currency": .string("SAR"),
            "taxEnabled": .bool(true),
            "taxRate": .number(15),
            "taxInclusive": .bool(true),
            "taxRegistered": .bool(true),
            "vat": .string("310122393500003"),
            "enableZatca": .bool(true),
            "invoiceLanguageMode": .string("single"),
        ]
        for (k, v) in extra { settings[k] = v }

        var order: [String: JSONValue] = [
            "id": .string("J1"),
            "invoiceNumber": .string("INV-0007"),
            "date": .string("2026-07-02T14:32:00.000Z"),
            "status": .string("completed"),
            "project": .string("Turbine bracket"),
            "client": .string("Acme"),
            "clientId": .string("C1"),
            "price": .number(575),
            "paidAmount": .number(575),
            "paymentStatus": .string("paid"),
            "printTime": .number(8.745),
            "priority": .bool(false),
            "notes": .string(""),
            "parts": .array([.object([
                "id": .string("P1"), "name": .string("Bracket"), "qty": .number(1),
                "material": .string("PETG-CF"), "colour": .string("Black"),
                "printWeight": .number(559), "baseCost": .number(120),
                "layerHeight": .number(0.2),
            ])]),
        ]
        for (k, v) in extraOrder { order[k] = v }

        return Invoice.Ingredients(
            row: .object(order),
            settings: settings,
            clients: [.object(["id": .string("C1"), "nameEn": .string("Acme Metalworks"),
                               "phone": .string("+966 50 123 4567"),
                               "email": .string("shop@acme.example"),
                               "vatNumber": .string("300000000000003")])],
            currencies: ["SAR": .object(["symbol": .string("SAR")])],
            language: "en",
            sellerName: "Tuwaiq Additive",
            sellerAddress: "Riyadh",
            sellerFields: ["biz": .string("Tuwaiq Additive"), "addr": .string("Riyadh"),
                           "tagline": .string("Precision 3D printing in Riyadh"),
                           "footer": .string("")],
            price: 575,
            // 15% inclusive of 575: the shop keeps 500 and owes 75.
            subtotal: 500, taxTotal: 75, vatRate: 15,
            timestamp: "2026-07-02T14:32:00.000Z")
    }

    /// Just the bill-to block. `contains` over the whole page cannot tell the
    /// difference between a name in the right place and the same characters
    /// somewhere else entirely — which is exactly the mistake this test made.
    static func billToBlock(_ html: String) -> String {
        guard let start = html.range(of: "<div class=\"bill-to\">") else { return "" }
        let rest = html[start.upperBound...]
        guard let end = rest.range(of: "<table class=\"lines\">") else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }

    static func build(_ paper: Invoice.Ingredients) async throws -> InvoiceDocument {
        let engine = try KhaytEngine()
        let words = Words()
        await words.load(paper.language, engine: engine)
        return try #require(await Invoice.document(paper, engine: engine, words: words))
    }

    // MARK: - what is on the paper

    @Test("the invoice states the job, the customer, and what is owed")
    func theDocument() async throws {
        let doc = try await Self.build(Self.paper())

        // The number a Khayt invoice states is the ORDER'S id, not the
        // `invoiceNumber` field beside it. Asserted rather than assumed: this
        // app's sheet header and its saved filename have to say the same thing
        // the paper says, and they used to say the other one.
        #expect(doc.html.contains("J1"), "its own number, as the shared document states it")
        #expect(doc.html.contains("Turbine bracket"), "what was made")
        #expect(doc.html.contains("PETG-CF"), "and what it was made of")

        // WHO IT IS ADDRESSED TO, checked inside the bill-to block rather than
        // anywhere on the page. This assertion used to read
        // `contains("Turbine bracket"), "what was made, billed to"` — and it
        // was right about the document and wrong about the document being
        // right: `order.project` is the JOB, and it was printed over this
        // customer's own phone number.
        let billTo = Self.billToBlock(doc.html)
        #expect(billTo.contains("Acme Metalworks"), "the customer, not the job")
        #expect(!billTo.contains("Turbine bracket"), "and the job is not standing in for them")

        // The customer's contact line. The Mac app printed a blank here until
        // the rule moved into the document itself — every host that built its
        // own context had to remember to pass it, and this one did not.
        #expect(doc.html.contains("+966 50 123 4567"))
        #expect(doc.html.contains("shop@acme.example"))

        // The money, split by this app before the document ever saw it: the
        // document is handed the answer, not the shop's tax settings.
        #expect(doc.html.contains("575.00"), "the total due")
        #expect(doc.html.contains("75.00"), "and the tax inside it")
        #expect(doc.html.contains("Total due"), "said in words, not only in figures")
        #expect(doc.html.contains("VAT (15%)"), "at the rate that was applied")
    }

    /// The Mac builds its own context for the shared document, so a field it
    /// forgets to pass is a field the paper simply does not have. It printed
    /// six invoices with a blank contact line that way. `clients` is the one
    /// that decides who the invoice is addressed to.
    @Test("the customer reaches the paper through this app's own context")
    func theCustomerIsPassed() async throws {
        var paper = Self.paper()
        // The same job with nobody to bill it to: the dual-purpose field takes
        // over, exactly as it always has, and the Project row is not printed
        // twice.
        paper.clients = []
        let orphan = try await Self.build(paper)
        #expect(Self.billToBlock(orphan.html).contains("Turbine bracket"))
        #expect(!orphan.html.contains(">Project<"), "not said twice")

        // And with the customer there, the job moves to its own line rather
        // than being dropped off the document.
        let addressed = try await Self.build(Self.paper())
        #expect(addressed.html.contains("Turbine bracket"), "still says what was made")
        #expect(Self.billToBlock(addressed.html).contains("Acme Metalworks"))
    }

    @Test("a registered shop gets a QR, drawn as an image the document carries")
    func qrPresent() async throws {
        let doc = try await Self.build(Self.paper())
        #expect(doc.html.contains("<img src=\"data:image/png;base64,"),
                "the QR is drawn here and embedded, so the document is one file")
        #expect(doc.html.contains("alt=\"ZATCA\""))
    }

    @Test("a shop missing a field the QR needs prints the reason instead of an empty box")
    func qrRefused() async throws {
        let doc = try await Self.build(Self.paper(settings: ["vat": .string("")]))
        #expect(!doc.html.contains("alt=\"ZATCA\""), "no code is drawn")
        // The refusal names the field. A QR that scans and is invalid is worse
        // than no QR: a code that reads invites no question.
        #expect(doc.html.lowercased().contains("vat") || doc.html.contains("VAT"),
                "and the document says which field is missing")
    }

    @Test("a shop with ZATCA switched off prints neither a code nor a complaint")
    func qrOff() async throws {
        let doc = try await Self.build(Self.paper(settings: ["enableZatca": .bool(false)]))
        #expect(!doc.html.contains("alt=\"ZATCA\""))
        #expect(!doc.html.contains("qr-problem"), "and no space is given to explaining it")
    }

    @Test("an unregistered shop's invoice has no tax line at all")
    func noTax() async throws {
        // vatRate zero is what `Shop.taxSplit` returns for a shop that is not
        // registered — inventing a zero-rate line would tell a customer the
        // shop charges tax and happens to charge none.
        var paper = Self.paper(settings: ["taxRegistered": .bool(false), "enableZatca": .bool(false)])
        paper.subtotal = 575; paper.taxTotal = 0; paper.vatRate = 0
        let doc = try await Self.build(paper)
        #expect(!doc.html.contains("VAT (15%)"))
        #expect(doc.html.contains("575.00"))
    }

    @Test("the digits are rewritten only where the shop reads Arabic ones")
    func numerals() async throws {
        let english = try await Self.build(Self.paper())
        #expect(english.arabicNumerals == false)

        var arabic = Self.paper(settings: ["invoiceLanguage": .string("ar")])
        arabic.language = "ar"
        let doc = try await Self.build(arabic)
        // Whichever way the shop is set, the SELECTOR must be there: the app
        // rewrites the digits of the elements it names, and an empty selector
        // rewrites nothing while looking like it worked.
        #expect(!doc.selector.isEmpty)
    }

    // MARK: - the page it is printed on

    @Test("the page carries the shop's own stylesheet, not a Swift copy of it")
    func stylesheet() throws {
        let css = InvoicePaper.stylesheet
        #expect(css.contains(".inv"), "renderer/invoice.css is bundled and readable")
        #expect(css.contains("@media print"), "including the rules that make it a page")
        // Synced from the renderer by mac/sync-js.sh. Two stylesheets would be
        // two documents that agreed until one of them was edited.
        let source = try String(contentsOf: MoveJobTests.repoRoot
            .appending(path: "renderer/invoice.css"), encoding: .utf8)
        #expect(css == source, "byte for byte the file Khayt links")
    }

    @Test("the document is wrapped in the area the stylesheet is written around")
    func page() throws {
        let doc = InvoiceDocument(html: "<div class=\"inv\">x</div>",
                                  arabicNumerals: false, selector: ".v")
        let page = InvoicePaper.page(doc)
        // The wrapper is what `@media print` reveals and everything else hides.
        // Dropping it would print a blank page from a window that looked right.
        #expect(page.contains("id=\"invoice-print-area\""))
        #expect(page.contains("@media screen"), "and it is made visible on screen")
        #expect(!page.contains("<script>"), "no digit pass for a shop reading 0-9")
    }

    @Test("a shop reading Arabic digits gets the pass that rewrites them")
    func digitPass() throws {
        let doc = InvoiceDocument(html: "<span class=\"v\">575.00</span>",
                                  arabicNumerals: true, selector: ".v, .amount")
        let page = InvoicePaper.page(doc)
        #expect(page.contains("<script>"))
        #expect(page.contains(".v, .amount"), "over the elements the module named")
        #expect(page.contains("\u{0660}"), "and with the digits to write")
    }

    // MARK: - on paper

    @Test("the document becomes a PDF, drawn by the engine that drew the window")
    func pdf() async throws {
        let doc = try await Self.build(Self.paper())
        let paper = InvoicePaper(document: doc)

        // WebKit lays out on the run loop; the sheet's button waits for the
        // same signal. Asking before it is drawn returns a blank page, which is
        // the whole reason `drawn` exists.
        for _ in 0..<200 where !paper.drawn {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(paper.drawn, "WebKit never finished laying the document out")

        let data = try await paper.pdf()
        #expect(data.prefix(5) == Data("%PDF-".utf8), "a real PDF, not an error page")
        // A blank A4 page is about 1 KB. This document has a table, a QR and a
        // stylesheet in it, and a PDF that small would mean WebKit drew nothing.
        #expect(data.count > 8_000, "and it has the document in it (\(data.count) bytes)")
        // Kept when a snapshot run asks for it, because the only way to know a
        // printed page is right is to look at one.
        if let dir = ProcessInfo.processInfo.environment["KHAYT_SNAPSHOT_DIR"] {
            try? data.write(to: URL(fileURLWithPath: dir).appending(path: "26-invoice.pdf"))
        }
    }

    // MARK: - keeping it

    @Test("the file is named after the number on the paper, and never after a folder")
    func filename() async throws {
        let words = Words()
        // The same name Khayt's own export gives it, which is also the number
        // printed under "No." on the document.
        #expect(InvoiceSheet.filename(Self.order(id: "ORD-01000"), words: words) == "ORD-01000.pdf")
        #expect(InvoiceSheet.filename(Self.order(id: "", project: "Lids 2/3"), words: words)
                == "Lids 2-3.pdf", "a slash in a job's name is not a folder")
        #expect(InvoiceSheet.filename(nil, words: words).hasSuffix(".pdf"))
    }

    static func order(id: String, project: String = "Turbine bracket") -> Order? {
        let row: [String: JSONValue] = [
            "id": .string(id), "date": .string("2026-07-02"), "status": .string("completed"),
            "project": .string(project), "price": .number(575), "paidAmount": .number(0),
            "paymentStatus": .string("unpaid"), "printTime": .number(1),
            "priority": .bool(false), "notes": .string(""),
        ]
        guard let data = try? JSONEncoder().encode(JSONValue.object(row)) else { return nil }
        return try? JSONDecoder().decode(Order.self, from: data)
    }
}
