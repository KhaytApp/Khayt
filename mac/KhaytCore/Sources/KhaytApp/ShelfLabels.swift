import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import WebKit
import KhaytCore

/// A printable sheet of QR labels for the shelf.
///
/// ── WHY THIS IS NOT A NEW FEATURE ──────────────────────────────────────────
///
/// `lib/labels.js` has built this sheet for a long time and the Electron app
/// prints from it; the Mac app simply could not reach the module. That is the
/// third rule in a row found this way — the shelf's runway and its dryness were
/// the other two — so the work here is a bridge, not an invention, and a label
/// printed from this app is byte-for-byte the sheet the other app prints.
///
/// The one part that cannot be shared is the QR image itself: drawing one is a
/// platform job. Electron asks its hub; this asks CoreImage, which has had a
/// QR generator built in since 2013 and needs nothing added to the bundle.
enum ShelfLabels {

    /// What a scanner reads off a spool label.
    ///
    /// The same string the Electron app encodes, deliberately: a shop that
    /// labels half its rack from one app and half from the other must be able
    /// to scan both with the same phone. `renderer/labels.js` writes
    /// `KHAYT-SPOOL:<id>` and so does this.
    static func code(for spoolId: String) -> String { "KHAYT-SPOOL:" + spoolId }

    /// A QR code as a PNG data URL, or nil when the payload cannot be encoded.
    ///
    /// `CIQRCodeGenerator` emits roughly one pixel per module — a 25-module
    /// code is a 25pt image — so it is scaled up before rasterising. Scaling
    /// AFTER rasterising would resample a tiny bitmap and give a scanner soft
    /// edges to guess at; a transform on the CIImage keeps every module square.
    ///
    /// `.medium` correction, matching the Electron side. A label on a spool in
    /// a workshop gets handled, so some redundancy is worth the density.
    static func qr(_ text: String, side: CGFloat = 240) -> String? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let small = filter.outputImage else { return nil }
        let scale = side / max(small.extent.width, 1)
        let big = small.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cg = context.createCGImage(big, from: big.extent) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    /// One spool's label, in the shape `lib/labels.js` expects.
    ///
    /// Quantity in the item's OWN unit — a bottle of resin is millilitres and a
    /// stack of ply is sheets, and a label that says "340 g" of resin sends
    /// somebody to the wrong shelf. The same mistake the cards made until the
    /// units work.
    @MainActor
    static func entry(for spool: Spool, shop: Shop) -> JSONValue {
        let unit = shop.unit(of: spool)
        var lines: [JSONValue] = []
        if let variant = spool.colourVariant, !variant.isEmpty { lines.append(.string(variant)) }
        if let w = spool.weight { lines.append(.string(Quantity.say(w, unit, shop.words))) }
        var fields: [String: JSONValue] = [
            "title": .string(spool.material.isEmpty ? spool.id : spool.material),
            "lines": .array(lines),
            "sub": .string(spool.id),
        ]
        if let img = qr(code(for: spool.id)) { fields["qr"] = .string(img) }
        return .object(fields)
    }
}

/// The sheet, laid out and printed by WebKit.
///
/// Deliberately the same machinery as `InvoicePaper`: a `WKWebView` given the
/// shared CSS and the shared HTML, printed through `printOperation` rather than
/// photographed. A print operation renders at the paper's size, which is why an
/// invoice saved from a narrow sheet stopped coming out as one endless strip —
/// and a sheet of labels has the same problem for the same reason.
@MainActor
final class LabelPaper: NSObject, ObservableObject, WKNavigationDelegate {
    let webView = WKWebView()
    @Published private(set) var drawn = false

    init(html: String) {
        super.init()
        webView.navigationDelegate = self
        webView.loadHTMLString(Self.page(html), baseURL: nil)
    }

    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) { drawn = true }

    /// The shared stylesheet, and the `#label-print-area` id its rules hang off.
    ///
    /// `invoice.css` carries the label rules as well as the invoice ones and is
    /// already copied into this bundle by `mac/sync-js.sh`, so the labels are
    /// styled by the same file that styles them in the other app. A second
    /// stylesheet here would drift within a release.
    static func page(_ inner: String) -> String {
        let css = AppResources.bundle.url(forResource: "invoice", withExtension: "css")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        \(css)
        /* On paper the renderer relies on a body class to reveal this area.
           There is no app chrome here to hide, so the area is simply visible. */
        body { margin: 0; background: #fff; color: #111;
               font: 13px -apple-system, system-ui, sans-serif; }
        #label-print-area { display: block; padding: 12mm; }
        @page { size: A4; margin: 0; }
        </style></head><body><div id="label-print-area">\(inner)</div></body></html>
        """
    }

    func printSheet() {
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.view?.frame = NSRect(x: 0, y: 0, width: 595, height: 842)   // A4 points
        operation.run()
    }
}

/// A built label sheet, waiting to be looked at.
///
/// `Identifiable` so it drives a `.sheet(item:)` like every other question this
/// window asks. The count is carried so the sheet can say how many labels are
/// about to be printed BEFORE the print panel opens — "print 40 labels" is a
/// different decision from "print".
struct LabelSheetRequest: Identifiable {
    let id = UUID()
    let html: String
    let count: Int
}

/// The sheet a shop looks at before it prints.
struct LabelSheet: View {
    @Bindable var shop: Shop
    let request: LabelSheetRequest
    @StateObject private var paper: LabelPaper

    init(shop: Shop, request: LabelSheetRequest) {
        self.shop = shop
        self.request = request
        _paper = StateObject(wrappedValue: LabelPaper(html: request.html))
    }

    var body: some View {
        VStack(spacing: 0) {
            LabelPaperView(paper: paper)
                .frame(minWidth: 520, minHeight: 560)
            Divider()
            HStack {
                Text(shop.words.counting(request.count, "mac.labels_count"))
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.pendingLabels = nil }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("mac.print")) { paper.printSheet() }
                    .keyboardShortcut(.defaultAction)
                    // The button waits for WebKit to lay the page out. Printing
                    // before that gives a blank sheet, which is a sheet of
                    // labels a shop has already stuck to its spools.
                    .disabled(!paper.drawn)
            }
            .padding(12)
        }
    }
}

struct LabelPaperView: NSViewRepresentable {
    let paper: LabelPaper
    func makeNSView(context: Context) -> WKWebView { paper.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
