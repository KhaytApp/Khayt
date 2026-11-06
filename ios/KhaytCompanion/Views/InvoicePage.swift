import SwiftUI
import UIKit
import WebKit
import KhaytCore

/// A job's invoice on the phone: the paper the Mac prints, shown, and handed
/// to the share sheet as an A4 PDF — WhatsApp, Mail, AirDrop or Print.
struct InvoicePage: View {
    @EnvironmentObject private var api: KhaytAPIClient
    let orderId: String
    /// The proforma rather than the invoice.
    var proforma = false

    var body: some View {
        PaperPage(title: L10n.tr(proforma ? "proforma.title" : "invoice.title"),
                  failure: InvoiceRefusal.failed.message) {
            switch await api.invoice(orderId: orderId, proforma: proforma) {
            case .refused(let why): return .refused(why.message)
            case .paper(let doc, let filename): return .paper(doc, filename: filename, wholePage: false)
            }
        }
    }
}

/// A packing slip, delivery note, work order or account statement
/// (`ShopPapers.swift`), on the same paper as the invoice.
struct ShopPaperPage: View {
    @EnvironmentObject private var api: KhaytAPIClient
    let subject: PaperSubject

    var body: some View {
        PaperPage(title: subject.title, failure: PaperRefusal.failed.message) {
            switch await api.shopPaper(subject) {
            case .refused(let why): return .refused(why.message)
            case .paper(let doc, let filename, let wholePage): return .paper(doc, filename: filename, wholePage: wholePage)
            }
        }
    }
}

/// One of the shop's papers, shown, and handed to the share sheet as an A4
/// PDF — the invoice's page, for every paper the phone makes.
struct PaperPage: View {
    enum Loaded {
        case paper(InvoiceDocument, filename: String, wholePage: Bool)
        case refused(String)
    }

    let title: String
    /// What to say when the PDF cannot be made.
    let failure: String
    let load: () async -> Loaded

    @StateObject private var paper = InvoicePaper()
    @State private var refusal: String?
    @State private var file: URL?
    @State private var making = false

    var body: some View {
        ZStack {
            KhaytDesign.ground.ignoresSafeArea()
            if let refusal {
                ContentUnavailableView(title, systemImage: "doc.text",
                                       description: Text(refusal))
            } else {
                InvoiceWebView(paper: paper)
                    .opacity(paper.drawn ? 1 : 0)
                if !paper.drawn { ProgressView() }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let file {
                    ShareLink(item: file) { Label(L10n.tr("invoice.share"), systemImage: "square.and.arrow.up") }
                } else if paper.drawn {
                    Button { Task { await makeFile() } } label: {
                        if making { ProgressView() } else { Label(L10n.tr("invoice.share"), systemImage: "square.and.arrow.up") }
                    }
                    .disabled(making)
                }
            }
        }
        .task { await show() }
    }

    private func show() async {
        switch await load() {
        case .refused(let why):
            refusal = why
        case .paper(let doc, let filename, let wholePage):
            paper.show(doc, filename: filename, wholePage: wholePage)
            // The PDF is made as soon as the paper is laid out, so the share
            // button is ready by the time a thumb reaches it.
            while !paper.drawn, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
            await makeFile()
        }
    }

    private func makeFile() async {
        guard file == nil, !making else { return }
        making = true
        defer { making = false }
        file = paper.pdfFile()
        if file == nil { refusal = failure }
    }
}

/// The document in a WebView, and the PDF made from it.
///
/// The paper is html — the same html Khayt prints — so it is drawn by WebKit
/// rather than laid out a second time. Page scripts are OFF, as on the Mac:
/// an escaping slip in some future field is then visible text on the paper,
/// never code running. The Arabic-digit pass is the app asking WebKit to run
/// it, which works with page scripts off.
@MainActor
final class InvoicePaper: NSObject, ObservableObject, WKNavigationDelegate {

    let webView: WKWebView
    @Published private(set) var drawn = false
    private var document: InvoiceDocument?
    private var filename = "invoice.pdf"

    override init() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.isOpaque = false
    }

    /// `wholePage`: the document is a page of its own, styles and all — the
    /// packing slip (`lib/shop-documents.js`) — and is drawn as it is rather
    /// than inside the invoice's stylesheet, as the Mac draws it.
    func show(_ doc: InvoiceDocument, filename: String, wholePage: Bool = false) {
        document = doc
        self.filename = filename
        drawn = false
        webView.loadHTMLString(wholePage ? doc.html : Self.page(doc), baseURL: nil)
    }

    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
        // The digits first, and only then `drawn`: the PDF waits on it, and a
        // PDF made before the pass would carry 0–9.
        guard let document, document.arabicNumerals else { drawn = true; return }
        Task { @MainActor in
            _ = try? await view.evaluateJavaScript(Self.digitPass(document.selector))
            drawn = true
        }
    }

    /// Nothing but the document itself may load: a link, a `<meta refresh>`
    /// or a redirect inside a shop's own invoice must not put a remote page
    /// on the phone.
    func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = action.request.url
        let isDocument = url == nil || url?.absoluteString == "about:blank"
        decisionHandler(!drawn && isDocument ? .allow : .cancel)
    }

    /// The paper as an A4 PDF in a folder of its own, named as the Mac names
    /// it. Printed rather than photographed, so the print half of
    /// `invoice.css` — the page size, the margins, black on white — applies.
    func pdfFile() -> URL? {
        let data = Self.pdf(from: webView.viewPrintFormatter())
        guard !data.isEmpty else { return nil }
        do {
            let dir = FileManager.default.temporaryDirectory.appending(path: "khayt-paper-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appending(path: filename)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// A4 in points, with the margins `@page` asks for.
    nonisolated static let a4 = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)

    static func pdf(from formatter: UIPrintFormatter) -> Data {
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        renderer.setValue(a4, forKey: "paperRect")
        renderer.setValue(a4.insetBy(dx: 36, dy: 36), forKey: "printableRect")
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, a4, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        for page in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: page, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }

    /// Rewrite the document's digits to Arabic-Indic — text nodes only, so
    /// the markup inside each element (the address paragraphs, the currency
    /// span, the `<bdi>` around a phone number) survives. The Mac's pass.
    nonisolated static func digitPass(_ selector: String) -> String {
        let quoted = (try? String(data: JSONEncoder().encode(selector), encoding: .utf8)) ?? "\"\""
        return """
        (function () {
          var A = '\u{0660}\u{0661}\u{0662}\u{0663}\u{0664}\u{0665}\u{0666}\u{0667}\u{0668}\u{0669}';
          document.querySelectorAll(\(quoted)).forEach(function (el) {
            var walk = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
            for (var n = walk.nextNode(); n; n = walk.nextNode()) {
              n.nodeValue = n.nodeValue.replace(/[0-9]/g, function (d) { return A[+d]; });
            }
          });
        })();
        """
    }

    /// `renderer/invoice.css`, bundled — the stylesheet the desktop prints with.
    nonisolated static let stylesheet: String = {
        guard let url = Bundle.main.url(forResource: "invoice", withExtension: "css"),
              let css = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return css
    }()

    /// The document in the page it is printed on, as the Mac wraps it — laid
    /// out at the paper's width and shown scaled to the phone, as a PDF
    /// preview is, rather than reflowed into a column the paper never has.
    nonisolated static func page(_ doc: InvoiceDocument) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=860">
        <style>\(stylesheet)</style>
        <style>
        @media print {
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
            font-family: -apple-system, "SF Pro Text", "Tajawal", "Cairo", Arial, sans-serif;
            box-sizing: border-box;
            font-size: 12px;
            line-height: 1.55;
          }
        }
        </style>
        </head><body><div id="invoice-print-area">\(doc.html)</div></body></html>
        """
    }
}

struct InvoiceWebView: UIViewRepresentable {
    let paper: InvoicePaper
    func makeUIView(context: Context) -> WKWebView { paper.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
