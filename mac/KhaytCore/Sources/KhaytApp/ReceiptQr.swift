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
    /// screenshot. A PDF is drawn page by page at 2× so a small printed code
    /// still has the pixels to decode; a receipt is a page or two, and more
    /// than ten pages is not a receipt.
    static func payloads(in url: URL) -> [String] {
        var images: [CGImage] = []
        if url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(url: url) else { return [] }
            for i in 0..<min(doc.pageCount, 10) {
                guard let page = doc.page(at: i) else { continue }
                let box = page.bounds(for: .mediaBox)
                let size = NSSize(width: box.width * 2, height: box.height * 2)
                let picture = page.thumbnail(of: size, for: .mediaBox)
                if let cg = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) { images.append(cg) }
            }
        } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            images.append(cg)
        }
        var seen = Set<String>()
        return images.flatMap(payloads(in:)).filter { seen.insert($0).inserted }
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

    /// `found` is for a photograph of the sheet with codes already read.
    init(shop: Shop, found: [Found] = []) {
        self.shop = shop
        _found = State(initialValue: found)
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
            ForEach(found) { item in
                ReceiptFoundRow(shop: shop, item: item) { draft in
                    shop.fileFromReceipt(draft)
                    dismiss()
                }
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

    var body: some View {
        let words = shop.words
        VStack(alignment: .leading, spacing: 4) {
            if let draft = item.draft {
                // The seller's own name, in its own direction: an Arabic name
                // inside an English sheet (or the other way round) is isolated
                // so it does not drag the figures beside it out of order.
                Text(Figure.isolated(draft.supplier?.name ?? sellerName(draft)))
                    .font(.body.weight(.semibold))
                Text(Money.text(draft.draft.amount, shop.currency)
                     + (draft.draft.vatAmount > 0
                        ? " · " + words.callIt("mac.receipt_vat", ["vat": .string(Money.text(draft.draft.vatAmount, shop.currency))])
                        : "")
                     + " · " + Figure.isolated(draft.draft.date))
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                // Named as the book names them, matched by VAT number or name.
                if draft.supplier != nil {
                    Text(words.callIt("mac.receipt_supplier"))
                        .font(.caption).foregroundStyle(.secondary)
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
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The seller as the receipt names it: the note is `seller · VAT …`.
    private func sellerName(_ draft: KhaytEngine.ReceiptDraft) -> String {
        draft.draft.note.components(separatedBy: " · VAT ").first ?? draft.draft.note
    }
}
