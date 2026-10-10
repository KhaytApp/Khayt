import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import Vision
import KhaytCore

// MARK: - A supplier's receipt, read off its QR
//
// Every Saudi tax invoice carries a ZATCA QR: the seller, their VAT number,
// the moment, the total and the VAT. Read off the code, the expense is the
// exact figures — the input VAT to the halala, with no OCR and no typing. What
// the code says is `lib/zatca-qr.js`'s to decide (`decodeTLV`, and the draft in
// `receiptToExpenseDraft`); this file finds the code in a picture and hands
// the person a filled-in expense to check. It never files one by itself: a
// receipt does not say what the money was for, so the category is theirs.

enum ReceiptQr {

    /// Every QR payload Vision finds in an image or a PDF, in reading order,
    /// deduplicated. Empty when there is none or the file cannot be read.
    ///
    /// `VNDetectBarcodesRequest` limited to `.qr` — Apple's barcode detector,
    /// which reads a code at an angle and in a photograph, not only a crisp
    /// screenshot. A PDF is drawn page by page at up to 2× so a small printed
    /// code still has the pixels to decode; a receipt is a page or two, and
    /// more than ten pages is not a receipt.
    ///
    /// ONE PAGE AT A TIME, AND NEVER HUGE. A PDF's page box is whatever the
    /// file says: a 14 400-point MediaBox drawn at 2× was a 28 800-pixel
    /// square, ten of them held at once before Vision saw the first (alpha.63
    /// review). Each page is now drawn at most `maxSide` pixels on its long
    /// side (`renderScale`), read, and let go before the next.
    static func payloads(in url: URL) -> [String] {
        var found: [String] = []
        if url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(url: url) else { return [] }
            for i in 0..<min(doc.pageCount, 10) {
                autoreleasepool {
                    guard let page = doc.page(at: i) else { return }
                    let box = page.bounds(for: .mediaBox)
                    guard let scale = renderScale(for: box) else { return }
                    let size = NSSize(width: (box.width * scale).rounded(), height: (box.height * scale).rounded())
                    let picture = page.thumbnail(of: size, for: .mediaBox)
                    if let cg = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        found += payloads(in: cg)
                    }
                }
            }
        } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  // Upright, and never decoded absurdly large: a phone photo of
                  // a receipt carries its turn as a tag (ProductPhotos.upright).
                  let cg = ProductPhotos.upright(source) {
            found = payloads(in: cg)
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    /// The longest side a page is drawn at, in pixels.
    static let maxSide: CGFloat = 4096

    /// How much a page of this box is scaled to be read: 2×, or less so the
    /// long side stays within `maxSide`. Nil for a box no receipt has — empty,
    /// not a number, or more than 200 inches (PDF's own largest page) on a
    /// side — which is skipped rather than drawn.
    static func renderScale(for box: CGRect) -> CGFloat? {
        let w = box.width, h = box.height
        guard w.isFinite, h.isFinite, w >= 1, h >= 1, w <= 14_400, h <= 14_400 else { return nil }
        return min(2, maxSide / max(w, h))
    }

    static func payloads(in image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? [])
            // Top of the page first: Vision's origin is bottom-left.
            .sorted { $0.boundingBox.minY > $1.boundingBox.minY }
            .compactMap(\.payloadStringValue)
            .filter { !$0.isEmpty }
    }
}

extension Shop {

    /// "Add from receipt…": the person picks the receipt, the shop asks the
    /// lock first — this ends in an expense, invoicing/create, the same gate
    /// as `addExpense`, asked before anything is opened rather than after a
    /// receipt was read for nothing.
    func startReadingReceipt() {
        guard permitted("invoicing", "create") else { return }
        // The sheets hang off the Expenses screen, so the menu command takes
        // the person there first — and the expense they file is then in view.
        if !showingExpenses { shelf = .expenses }
        readingReceipt = true
    }

    /// Hand a read receipt to the expense sheet, filled in for review.
    func fileFromReceipt(_ draft: KhaytEngine.ReceiptDraft) {
        guard permitted("invoicing", "create") else { return }
        receiptPrefill = draft
        readingReceipt = false
        addingExpense = true
    }
}

/// Pick the receipt — a photo, a screenshot, a scanned PDF, or the code's
/// text pasted — then choose among its codes, if it has more than one.
struct ReceiptReaderSheet: View {
    let shop: Shop
    @Environment(\.dismiss) private var dismiss

    /// What was found: a read receipt with its draft, or why a code was not one.
    struct Found: Identifiable {
        let id = UUID()
        let text: String
        let draft: KhaytEngine.ReceiptDraft?
        let reason: String?
    }

    @State private var found: [Found]
    @State private var pasted = ""
    @State private var problem: String?
    @State private var busy = false
    /// The height of the screen the sheet is on. A sheet cannot be moved, so
    /// one taller than the screen hides its own Cancel button.
    let screenHeight: CGFloat

    /// `found` is for a photograph of the sheet with codes already read, and
    /// `screenHeight` for one taken as a small screen would show it.
    init(shop: Shop, found: [Found] = [], screenHeight: CGFloat? = nil) {
        self.shop = shop
        _found = State(initialValue: found)
        self.screenHeight = screenHeight ?? NSScreen.main?.visibleFrame.height ?? 800
    }

    /// The most the list of codes may take: what the screen leaves once the
    /// rest of the sheet (about 300 points) and the window's own margins are
    /// drawn, never less than one card and never more than four.
    static func listLimit(screenHeight: CGFloat) -> CGFloat {
        min(440, max(110, screenHeight - 380))
    }

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 14) {
            Text(words.callIt("mac.receipt_title")).font(.headline)
            Text(words.callIt("mac.receipt_hint"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(words.callIt("mac.receipt_open") + "\u{2026}") { Task { await openFile() } }
                    .disabled(busy)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(words.callIt("mac.receipt_paste")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("", text: $pasted)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .environment(\.layoutDirection, .leftToRight)
                        .onSubmit { Task { await read([pasted]) } }
                    Button(words.callIt("mac.receipt_read")) { Task { await read([pasted]) } }
                        .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                }
            }

            if let problem {
                Text(problem).font(.callout).foregroundStyle(Khayt.late)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Every code a receipt has, in a list that scrolls once it is
            // taller than the screen allows — the Cancel under it stays in
            // view however many codes a page carries (alpha.63 review).
            if !found.isEmpty {
                ViewThatFits(in: .vertical) {
                    cards
                    ScrollView { cards }
                }
                .frame(maxHeight: Self.listLimit(screenHeight: screenHeight))
            }

            HStack {
                Spacer()
                Button(words.callIt("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(found) { item in
                ReceiptFoundRow(shop: shop, item: item, use: { draft in
                    shop.fileFromReceipt(draft)
                    dismiss()
                }, addSupplier: { seller in
                    await addSupplier(seller)
                })
            }
        }
    }

    /// The seller, added as a supplier with its VAT number — through the one
    /// supplier write path, so the staff lock asks, and the sample shop says
    /// it cannot be changed. Then the codes are read again: the card now
    /// names the supplier as the book does.
    private func addSupplier(_ seller: KhaytEngine.ReceiptDraft.NewSupplier) async {
        problem = nil
        var supplier = Supplier.blank()
        supplier.name = seller.name
        supplier.vat = seller.vatNumber
        await shop.saveSupplier(supplier)
        if let said = shop.moveProblem { problem = said; return }
        await read(found.map(\.text))
    }

    private func openFile() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        defer { busy = false }
        // Vision and PDF drawing are blocking work: on a dispatch queue, never
        // the main actor or the cooperative pool (memory: swift pool starvation).
        let codes: [String] = await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: ReceiptQr.payloads(in: url)) }
        }
        guard !codes.isEmpty else {
            found = []
            problem = shop.words.callIt("mac.receipt_none_found")
            return
        }
        await read(codes)
    }

    private func read(_ codes: [String]) async {
        problem = nil
        guard let engine = shop.engine else { problem = shop.words.callIt("mac.move_no_engine"); return }
        var out: [Found] = []
        for code in codes {
            let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let read = try? await engine.readReceiptQr(text)
            if let read, read.ok {
                let draft = try? await engine.receiptDraft(text, suppliers: shop.supplierRows,
                                                          expenses: shop.expenseRows,
                                                          reclaimsTax: shop.reclaimsTax)
                out.append(Found(text: text, draft: draft, reason: nil))
            } else {
                out.append(Found(text: text, draft: nil, reason: read?.reason ?? "not_base64"))
            }
        }
        // One readable code and nothing else: straight to the sheet would skip
        // the duplicate check's sentence, so it is still shown — one row.
        found = out
        if out.allSatisfy({ $0.draft == nil }) {
            problem = shop.words.callIt("mac.receipt_unreadable")
        }
    }
}

/// One code from the receipt: what it says, and the way on — or why not.
struct ReceiptFoundRow: View {
    let shop: Shop
    let item: ReceiptReaderSheet.Found
    let use: (KhaytEngine.ReceiptDraft) -> Void
    var addSupplier: (KhaytEngine.ReceiptDraft.NewSupplier) async -> Void = { _ in }
    @State private var adding = false

    /// A caption whose figure alone is monospaced: an Arabic label set in a
    /// monospaced face is letter-spaced apart.
    static func caption(_ whole: String, mono figure: String) -> Text {
        var text = AttributedString(whole)
        text.font = .caption
        if !figure.isEmpty, let at = text.range(of: figure) { text[at].font = .system(.caption, design: .monospaced) }
        return Text(text)
    }

    /// The start of a code that is not a receipt's, so the person can tell
    /// which code on the page it was.
    static func codeStart(_ text: String) -> String {
        let flat = text.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) && !(0x200E...0x206F).contains($0.value) }
            .map(String.init).joined()
        return flat.count > 24 ? String(flat.prefix(24)) + "\u{2026}" : flat
    }

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 4) {
            if let draft = item.draft {
                // The seller's own name, in its own direction: an Arabic name
                // inside an English sheet (or the other way round) is isolated
                // so it does not drag the figures beside it out of order.
                Text(Figure.isolated(draft.supplier?.name ?? draft.sellerName))
                    .font(.body.weight(.semibold))
                Text(Money.text(draft.draft.amount, shop.currency)
                     + (draft.draft.vatAmount > 0
                        ? " · " + words.callIt("mac.receipt_vat", ["vat": .string(Money.text(draft.draft.vatAmount, shop.currency))])
                        : "")
                     + " · " + Figure.isolated(draft.draft.date))
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                // The seller's VAT number, which is how a receipt is matched
                // to a supplier: digits, left to right in either language.
                Self.caption(words.callIt("mac.receipt_vat_number", ["vat": .string(Figure.isolated(draft.vatNumber))]),
                             mono: draft.vatNumber)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                // Named as the book names them, matched by VAT number or name.
                if draft.supplier != nil {
                    Text(words.callIt("mac.receipt_supplier"))
                        .font(.caption).foregroundStyle(.secondary)
                } else if let seller = draft.newSupplier {
                    // Not in the book: one click adds them, number and all,
                    // so the next receipt from them is matched.
                    HStack(spacing: 8) {
                        Text(words.callIt("mac.receipt_new_supplier"))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(words.callIt("mac.receipt_add_supplier")) {
                            adding = true
                            Task {
                                await addSupplier(seller)
                                adding = false
                            }
                        }
                        .controlSize(.small)
                        .disabled(adding)
                    }
                }
                if draft.duplicateOf != nil {
                    // Flagged, and not offered: the same receipt filed twice
                    // is the same money counted twice in the books.
                    Text(words.callIt("mac.receipt_duplicate"))
                        .font(.callout).foregroundStyle(Khayt.attention)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Button(words.callIt("mac.receipt_use")) { use(draft) }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Text(words.callIt("mac.receipt_reason." + (item.reason ?? "not_base64")))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                let start = Self.codeStart(item.text)
                Self.caption(words.callIt("mac.receipt_code", ["code": .string(Figure.isolated(start))]), mono: start)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
