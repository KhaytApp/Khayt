import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import KhaytCore

/// The invoice a customer is handed.
///
/// The document is `lib/invoice-document.js` — the same four hundred lines the
/// Electron window prints, so the two apps cannot hand out different papers for
/// the same job. This assembles what it needs and turns the result into a PDF.
///
/// WHAT IS ASSEMBLED HERE, and why each piece is not in the module:
///
/// * The money, through `KhaytTax` — whether a price includes the tax or the
///   tax is added on top is the shop's setting, and the document is handed the
///   answer rather than the question.
/// * The ZATCA QR, because drawing one needs a graphics framework. The
///   PAYLOAD is shared; only the pixels are native.
/// * The words, from `Words`, which is where this app's language lives.
@MainActor
enum Invoice {

    /// Everything the document needs, gathered from the shop.
    ///
    /// Gathering and building are separate on purpose: a test can hand this the
    /// awkward shop — no tax registration, a missing ZATCA field, a job with no
    /// parts — without opening a book to get one.
    static func html(for job: Order, shop: Shop) async -> InvoiceDocument? {
        guard let engine = shop.engine else { return nil }
        // The tax split, by the shop's own rule. A shop with no tax
        // registration has nothing to split: the whole price is what it keeps,
        // and the document prints no tax line.
        let money = await shop.taxSplit(job.price)
        let paper = Ingredients(
            row: shop.orderRow(job.id) ?? .object([:]),
            settings: shop.settingsDict,
            clients: shop.clientRows,
            currencies: currencyTable(shop),
            language: shop.words.language,
            sellerName: shop.shopName,
            sellerAddress: shop.shopAddress,
            sellerFields: shop.shopDocumentFields,
            price: job.price,
            subtotal: money?.subtotal ?? job.price,
            taxTotal: money?.taxTotal ?? 0,
            vatRate: await shop.taxPercent(),
            timestamp: job.date)
        return await document(paper, engine: engine, words: shop.words)
    }

    /// What the document is built from.
    ///
    /// `subtotal` and `taxTotal` are the shop's tax rule already applied —
    /// whether a price includes the tax or the tax is added on top is a setting,
    /// and the document is handed the answer rather than the question.
    struct Ingredients: Sendable {
        var row: JSONValue
        var settings: [String: JSONValue]
        var clients: [JSONValue]
        var currencies: [String: JSONValue]
        var language: String
        var sellerName: String
        var sellerAddress: String
        /// Every field the document asks the shop for — see
        /// `Shop.shopDocumentFields`. `sellerName` and `sellerAddress` stay
        /// because the ZATCA payload and the readiness check want them on their
        /// own, spelled as those rules spell them.
        var sellerFields: [String: JSONValue]
        /// What the job is priced at, before tax is split out of it.
        var price: Double
        var subtotal: Double
        var taxTotal: Double
        var vatRate: Double
        /// When the job was taken — the moment the QR is stamped with.
        var timestamp: String
    }

    /// The document itself.
    static func document(_ paper: Ingredients, engine: KhaytEngine,
                         words: Words) async -> InvoiceDocument? {
        // The QR, when the shop is registered AND every required field is
        // there. A refusal is passed to the document so it can say WHICH field
        // is missing, rather than printing an empty box.
        var qrSvg = ""
        var qrProblem: String?
        if case .bool(true)? = paper.settings["enableZatca"] {
            // `try?` on a call returning an optional gives an optional
            // optional; flattened once so "the call failed" and "the shop is
            // ready" are not the same value.
            let refusal = (try? await engine.zatcaReadiness(
                settings: paper.settings, sellerName: paper.sellerName)).flatMap { $0 }
            if let refusal {
                qrProblem = words.zatcaRefusal(refusal)
            } else if let payload = try? await engine.zatcaPayload(
                sellerName: paper.sellerName,
                vatNumber: Shop.plainString(paper.settings["vat"]) ?? "",
                timestamp: paper.timestamp,
                total: Self.amount(paper.subtotal + paper.taxTotal),
                vatAmount: Self.amount(paper.taxTotal)),
                let image = qrImage(payload) {
                qrSvg = "<img src=\"\(image)\" width=\"120\" height=\"120\" alt=\"ZATCA\">"
            } else {
                qrProblem = words.callIt("inv.qr_failed")
            }
        }

        let money: [String: JSONValue] = [
            "qrSvg": .string(qrSvg),
            "qrProblem": qrProblem.map(JSONValue.string) ?? .null,
            "payQrSvg": .string(""),
            "total": .string(Self.amount(paper.subtotal + paper.taxTotal)),
            "vatAmount": .string(Self.amount(paper.taxTotal)),
            "subtotal": .string(Self.amount(paper.subtotal)),
            // What the items came to before shipping was added — the figure the
            // document reconciles its own table against.
            "subtotalShown": .string(Self.amount(paper.price)),
            "vatRate": .number(paper.vatRate),
            "shipping": .number(0),
        ]
        return try? await engine.invoiceHtml(
            order: paper.row, settings: paper.settings, clients: paper.clients,
            currencies: paper.currencies, language: paper.language,
            money: money, sellerFields: paper.sellerFields)
    }

    /// The currency table the document formats against.
    static func currencyTable(_ shop: Shop) -> [String: JSONValue] {
        guard case .object(let table) = shop.currencyTable else { return [:] }
        return table
    }

    /// Two decimals, the way an invoice states money.
    static func amount(_ n: Double) -> String {
        String(format: "%.2f", n.isFinite ? n : 0)
    }

    /// The QR itself, as a data URL.
    ///
    /// CoreImage rather than a library: the payload is the shared rule and the
    /// pixels are the platform's. `M` correction is what ZATCA's own samples
    /// use — higher correction makes a denser code that a phone camera reads
    /// worse at the size an invoice prints it.
    static func qrImage(_ payload: String) -> String? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Scaled before rasterising: a 25-module code is 25 points across, and
        // an invoice printed from a 25-pixel image is a grey smudge.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}


import SwiftUI
import WebKit

/// An invoice on screen, and on paper.
///
/// A WebView because the document IS html — the same html Khayt prints — and
/// rendering it any other way would mean a second layout engine and a second
/// answer to what an invoice looks like.
///
/// `createPDF` is WebKit's own, so the file a customer receives is what the
/// window showed rather than a second run of the layout at a different size.
@MainActor
final class InvoicePaper: NSObject, ObservableObject, WKNavigationDelegate {

    let document: InvoiceDocument
    let webView: WKWebView
    /// False until WebKit says the document is laid out. Asking for a PDF
    /// before that returns a blank page, so the button waits.
    @Published private(set) var drawn = false
    /// What the last save did, in the shop's language. Shown under the paper.
    @Published var note: String?

    init(document: InvoiceDocument) {
        self.document = document
        self.webView = WKWebView()
        super.init()
        webView.navigationDelegate = self
        webView.loadHTMLString(Self.page(document), baseURL: nil)
    }

    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
        drawn = true
    }

    /// The document as a PDF, on A4, drawn by the engine that drew the window.
    ///
    /// A PRINT OPERATION, not `createPDF`. `createPDF` photographs the view at
    /// whatever size it happens to be, so an invoice saved from a narrow sheet
    /// came out as one endless 480-point-wide strip with the totals running off
    /// the edge — a picture of a window rather than a page. Printing renders in
    /// print media instead, which is the half of `renderer/invoice.css` written
    /// for paper: `@page { size: A4 }`, the margins, and the black-on-white the
    /// shop's colours give way to.
    func pdf() async throws -> Data {
        let info = NSPrintInfo()
        info.paperSize = Self.a4
        info.orientation = .portrait
        // Zero margins here, because the document sets its own in `@page`.
        // Adding AppKit's on top of the stylesheet's would indent every invoice
        // by two margins and lose the last line off the foot of the page.
        info.topMargin = 0; info.bottomMargin = 0
        info.leftMargin = 0; info.rightMargin = 0
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save

        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "khayt-invoice-\(UUID().uuidString).pdf")
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = file

        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        // The view has to be in a window to print. A sheet's web view already
        // is; one built to export without ever being shown is not, and prints
        // an empty page in silence.
        if webView.window == nil { Self.offscreen.contentView = webView }
        let host = webView.window ?? Self.offscreen

        // `runModal(for:…)`, NOT `run()`. WebKit's print operation is
        // asynchronous — the pages are laid out in the web process — and
        // `run()` waits for them on the very run loop they need, forever. The
        // documentation for `printOperation(with:)` says so in as many words;
        // it was read after the first attempt hung a test for ten minutes.
        let printed = Printed()
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            printed.done = done
            operation.runModal(for: host, delegate: printed,
                               didRun: #selector(Printed.printOperationDidRun(_:success:contextInfo:)),
                               contextInfo: nil)
        }

        defer { try? FileManager.default.removeItem(at: file) }
        return try Data(contentsOf: file)
    }

    /// The print operation's way of saying it finished: an Objective-C
    /// selector, on an object that holds the continuation waiting for it.
    private final class Printed: NSObject {
        var done: CheckedContinuation<Void, Error>?
        @objc func printOperationDidRun(_ op: NSPrintOperation, success: Bool,
                                        contextInfo: UnsafeMutableRawPointer?) {
            if success { done?.resume() } else { done?.resume(throwing: Failure.printFailed) }
            done = nil
        }
    }

    enum Failure: Error { case printFailed }

    /// A4 in points, which is what `NSPrintInfo` measures paper in.
    static let a4 = NSSize(width: 595.28, height: 841.89)

    /// A window for a document nobody is looking at.
    ///
    /// Off the screen deliberately: printing needs a window, and a real one
    /// would flash up in front of the shop on its way to a saved file.
    static let offscreen: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 620, height: 800),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        return w
    }()

    /// The invoice's own stylesheet — `renderer/invoice.css`, bundled.
    ///
    /// The same file the Electron window links, synced by `mac/sync-js.sh`
    /// alongside the shared modules. Rewriting these rules in Swift would make
    /// a second document that agreed with the first until one of them was
    /// edited.
    static let stylesheet: String = {
        guard let url = Bundle.module.url(forResource: "invoice", withExtension: "css"),
              let css = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return css
    }()

    /// The document, wrapped in the page it is printed on.
    ///
    /// `#invoice-print-area` is the wrapper the stylesheet is written around:
    /// in the Electron window it is hidden on screen and revealed for
    /// `window.print()`. Here the document IS the window, so the screen half is
    /// overridden and the print half left exactly as it is — which is also why
    /// the wrapper is kept rather than dropped. Whichever media WebKit renders
    /// in, the rules that apply are the shop's own.
    static func page(_ doc: InvoiceDocument) -> String {
        let numerals = doc.arabicNumerals ? """
        <script>
        // The one thing a stylesheet cannot do: rewrite the digits of elements
        // after they are laid out. The module said which elements.
        //
        // TEXT NODES, not `textContent`. Assigning `el.textContent` replaces
        // everything inside the element with one flat string — so it did not
        // only change the digits, it deleted the markup. `.biz-meta` holds the
        // address in its own paragraphs and the contact line in another, and
        // they came out as one run; `.amount` holds a span for the currency
        // and lost its styling; and the `<bdi>` that keeps a phone number the
        // right way round went with them, putting the number back to front for
        // exactly the shops that had asked for Arabic digits.
        (function () {
          var A = '\u{0660}\u{0661}\u{0662}\u{0663}\u{0664}\u{0665}\u{0666}\u{0667}\u{0668}\u{0669}';
          document.querySelectorAll('\(doc.selector)').forEach(function (el) {
            var walk = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
            for (var n = walk.nextNode(); n; n = walk.nextNode()) {
              n.nodeValue = n.nodeValue.replace(/[0-9]/g, function (d) { return A[+d]; });
            }
          });
        })();
        </script>
        """ : ""

        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>\(Self.stylesheet)</style>
        <style>
        @media print {
          /* The shared stylesheet lifts the document out of the window with
             `position: absolute; width: 100%`, to print it over an app that
             is hidden underneath. Here there is no app underneath, and WebKit
             measures that 100% against the whole sheet of paper rather than
             the area inside the margins — so the right margin was lost and
             the totals ran off the page. In flow, it is laid out where the
             margins say. */
          #invoice-print-area { position: static; width: auto; }
        }
        @media screen {
          html, body { margin: 0; background: #f2efe9; }
          #invoice-print-area {
            display: block;
            background: #fff;
            color: #1a1a1a;
            max-width: 820px;
            margin: 0 auto;
            padding: 28px 30px 40px;
            font-family: "SF Pro Text", "Segoe UI", "Tajawal", "Cairo", Arial, sans-serif;
            font-size: 12px;
            line-height: 1.55;
          }
        }
        </style>
        </head><body><div id="invoice-print-area">\(doc.html)</div>\(numerals)</body></html>
        """
    }
}

/// The paper itself, in a window.
struct InvoicePaperView: NSViewRepresentable {
    let paper: InvoicePaper
    func makeNSView(context: Context) -> WKWebView { paper.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
