import SwiftUI
import KhaytCore

/// A one-page document from a shared rule — the box-form VAT return — shown
/// before it is printed. The same WebKit machinery as the End of Day Report
/// (`LabelPaper`, whole page), so it prints at the paper's size; the print
/// panel's PDF menu is the Mac's own Save as PDF.
struct PrintedPageSheet: View {
    @Bindable var shop: Shop
    let request: PrintedPageRequest
    @StateObject private var paper: LabelPaper

    init(shop: Shop, request: PrintedPageRequest) {
        self.shop = shop
        self.request = request
        _paper = StateObject(wrappedValue: LabelPaper(html: request.html, wholePage: true))
    }

    var body: some View {
        VStack(spacing: 0) {
            LabelPaperView(paper: paper)
                .frame(minWidth: 520, minHeight: 560)
            Divider()
            HStack {
                Text(request.title).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.pendingPrintedPage = nil }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("mac.print")) { paper.printSheet() }
                    .keyboardShortcut(.defaultAction)
                    // A page printed before WebKit has laid it out is blank.
                    .disabled(!paper.drawn)
            }
            .padding(12)
        }
    }
}
