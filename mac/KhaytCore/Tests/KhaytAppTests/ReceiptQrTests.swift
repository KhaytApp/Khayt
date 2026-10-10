import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import PDFKit
import SwiftUI
import Testing
import KhaytCore
@testable import KhaytApp

/// Reading a supplier's receipt off its QR: Vision finds the code, the shared
/// rule reads it, and the shop gets a filled-in expense to check — never a
/// filed one.
@MainActor
struct ReceiptQrTests {

    static let VAT = "310122393500003"   // the sample book's Tuwaiq Filament Supply

    static func payload(_ seller: String = "Tuwaiq Filament Supply", total: String = "115.00",
                        vat: String = "15.00") async throws -> String {
        try await KhaytEngine().zatcaPayload(sellerName: seller, vatNumber: VAT,
                                             timestamp: "2026-10-09T14:30:00Z", total: total, vatAmount: vat)
    }

    /// A QR code drawn by Core Image, on a white page, `codes` stacked.
    static func picture(_ codes: [String]) throws -> CGImage {
        let context = CIContext()
        let side = 360, gap = 40
        let height = codes.count * (side + gap) + gap
        let space = CGColorSpaceCreateDeviceRGB()
        let canvas = try #require(CGContext(data: nil, width: side + 2 * gap, height: height, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: space,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(.white)
        canvas.fill(CGRect(x: 0, y: 0, width: side + 2 * gap, height: height))
        for (i, text) in codes.enumerated() {
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(text.utf8)
            filter.correctionLevel = "M"
            let raw = try #require(filter.outputImage)
            let scaled = raw.transformed(by: CGAffineTransform(scaleX: CGFloat(side) / raw.extent.width,
                                                               y: CGFloat(side) / raw.extent.height))
            let cg = try #require(context.createCGImage(scaled, from: scaled.extent))
            // Top of the page first, in Core Graphics' bottom-left coordinates.
            let y = height - (i + 1) * (side + gap)
            canvas.interpolationQuality = .none
            canvas.draw(cg, in: CGRect(x: gap, y: y, width: side, height: side))
        }
        return try #require(canvas.makeImage())
    }

    @Test("Vision reads a ZATCA QR drawn by Core Image, byte for byte")
    func visionReadsTheCode() async throws {
        let qr = try await Self.payload()
        let found = ReceiptQr.payloads(in: try Self.picture([qr]))
        #expect(found == [qr])
        let read = try await KhaytEngine().readReceiptQr(try #require(found.first))
        #expect(read.ok && read.receipt?.total == 115)
    }

    @Test("a receipt with two codes on it gives both, top first, for the person to pick")
    func severalCodes() async throws {
        let qr = try await Self.payload()
        let link = "https://example.com/pay/12345"
        #expect(ReceiptQr.payloads(in: try Self.picture([link, qr])) == [link, qr])
    }

    @Test("a PNG and a PDF of the receipt are both read from disk")
    func filesOnDisk() async throws {
        let qr = try await Self.payload()
        let image = try Self.picture([qr])
        let dir = FileManager.default.temporaryDirectory.appending(path: "receipt-qr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let png = dir.appending(path: "receipt.png")
        let rep = NSBitmapImageRep(cgImage: image)
        try #require(rep.representation(using: .png, properties: [:])).write(to: png)
        #expect(ReceiptQr.payloads(in: png) == [qr])

        let pdf = dir.appending(path: "receipt.pdf")
        let doc = PDFDocument()
        let page = try #require(PDFPage(image: NSImage(cgImage: image, size: NSSize(width: 220, height: 220))))
        doc.insert(page, at: 0)
        #expect(doc.write(to: pdf))
        #expect(ReceiptQr.payloads(in: pdf) == [qr])

        let blank = dir.appending(path: "nothing.png")
        try #require(NSBitmapImageRep(cgImage: try Self.picture([])).representation(using: .png, properties: [:]))
            .write(to: blank)
        #expect(ReceiptQr.payloads(in: blank).isEmpty)
    }

    @Test("the sample supplier is matched by its VAT number, the shop's mode decides the VAT, a repeat is caught")
    func draftAgainstTheBook() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        // A different name on the receipt than in the book: the VAT number wins.
        let qr = try await Self.payload("مؤسسة طويق لخيوط الطباعة")
        let draft = try #require(try await engine.receiptDraft(qr, suppliers: shop.supplierRows,
                                                              expenses: shop.expenseRows, reclaimsTax: true))
        #expect(draft.supplier?.name == "Tuwaiq Filament Supply")
        #expect(draft.draft.amount == 115 && draft.draft.vatAmount == 15)
        #expect(draft.draft.date == "2026-10-09" || draft.draft.date == "2026-10-10")
        #expect(draft.duplicateOf == nil)
        #expect(try await engine.receiptDraft(qr, suppliers: shop.supplierRows, expenses: shop.expenseRows,
                                              reclaimsTax: false)?.draft.vatAmount == 0)

        let filed = try #require(try await engine.newExpense([
            "amount": .number(draft.draft.amount), "vatAmount": .number(draft.draft.vatAmount),
            "category": .string("filament"), "note": .string(draft.draft.note),
            "receiptRef": .string(draft.draft.receiptRef),
        ], id: "EXP-r1", today: "2026-10-10").expense)
        let again = try await engine.receiptDraft(qr, suppliers: shop.supplierRows,
                                                  expenses: shop.expenseRows + [filed], reclaimsTax: true)
        #expect(again?.duplicateOf == "EXP-r1")
    }

    @Test("using a read receipt opens the expense sheet filled in, and saves nothing")
    func handsOverWithoutSaving() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let before = shop.expenseRows.count
        let draft = try #require(try await engine.receiptDraft(try await Self.payload(), suppliers: shop.supplierRows,
                                                              expenses: shop.expenseRows, reclaimsTax: true))
        shop.readingReceipt = true
        shop.fileFromReceipt(draft)
        #expect(shop.addingExpense)
        #expect(!shop.readingReceipt)
        #expect(shop.receiptPrefill == draft)
        #expect(shop.expenseRows.count == before, "nothing is filed until the person saves")
        shop.dismissEverySheet()
        #expect(shop.receiptPrefill == nil && !shop.addingExpense)
    }

    // MARK: alpha.63 review

    @Test("a PDF page is drawn at most 4096 px on its long side, and an absurd page box is skipped")
    func pdfScale() async throws {
        #expect(ReceiptQr.renderScale(for: CGRect(x: 0, y: 0, width: 595, height: 842)) == 2)
        #expect(ReceiptQr.renderScale(for: CGRect(x: 0, y: 0, width: 4096, height: 1000)) == 1)
        #expect(ReceiptQr.renderScale(for: CGRect(x: 0, y: 0, width: 14_400, height: 14_400))! * 14_400 <= 4096)
        #expect(ReceiptQr.renderScale(for: CGRect(x: 0, y: 0, width: 100_000, height: 100)) == nil)
        #expect(ReceiptQr.renderScale(for: CGRect(x: 0, y: 0, width: 0, height: 100)) == nil)
        #expect(ReceiptQr.renderScale(for: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)) == nil)

        // A receipt whose page claims a huge MediaBox is read — or skipped —
        // without drawing a 28 800-pixel square, and an ordinary page beside
        // it is still read.
        let qr = try await Self.payload()
        let image = try Self.picture([qr])
        let dir = FileManager.default.temporaryDirectory.appending(path: "receipt-qr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appending(path: "huge.pdf")
        let doc = PDFDocument()
        let huge = try #require(PDFPage(image: NSImage(cgImage: image, size: NSSize(width: 220, height: 220))))
        huge.setBounds(CGRect(x: 0, y: 0, width: 14_400, height: 14_400), for: .mediaBox)
        doc.insert(huge, at: 0)
        let absurd = try #require(PDFPage(image: NSImage(cgImage: image, size: NSSize(width: 220, height: 220))))
        absurd.setBounds(CGRect(x: 0, y: 0, width: 200_000, height: 200_000), for: .mediaBox)
        doc.insert(absurd, at: 1)
        let plain = try #require(PDFPage(image: NSImage(cgImage: image, size: NSSize(width: 220, height: 220))))
        doc.insert(plain, at: 2)
        #expect(doc.write(to: pdf))
        let started = Date()
        let found = ReceiptQr.payloads(in: pdf)
        #expect(found == [qr], Comment(rawValue: "\(found)"))
        #expect(Date().timeIntervalSince(started) < 20)
    }

    @Test("an unknown seller is offered as a supplier; added with its VAT number, the next read matches it")
    func newSupplierRoundTrip() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let qr = try await engine.zatcaPayload(sellerName: "Najd Bolts \u{202E}evil", vatNumber: "300000000000003",
                                               timestamp: "2026-10-09T14:30:00Z", total: "57.5", vatAmount: "7.5")
        let draft = try #require(try await engine.receiptDraft(qr, suppliers: shop.supplierRows,
                                                              expenses: shop.expenseRows, reclaimsTax: true))
        #expect(draft.supplier == nil)
        let seller = try #require(draft.newSupplier)
        #expect(seller.vatNumber == "300000000000003")
        #expect(draft.sellerName == "Najd Bolts evil", "the override was filed: \(draft.sellerName.unicodeScalars.map(\.value))")
        // What "Add as supplier" hands the one supplier write path.
        var supplier = Supplier.blank()
        supplier.name = seller.name
        supplier.vat = seller.vatNumber
        var record = supplier.edits
        record["id"] = .string("sup-new")
        #expect(record["vat"] == .string("300000000000003"))
        let again = try #require(try await engine.receiptDraft(qr, suppliers: shop.supplierRows + [.object(record)],
                                                              expenses: shop.expenseRows, reclaimsTax: true))
        #expect(again.supplier?.id == "sup-new")
        #expect(again.newSupplier == nil)
    }

    @Test("the prefilled expense: the note in the shop's language, no category chosen, Add closed until one is")
    func prefilledExpense() async throws {
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let draft = try #require(try await engine.receiptDraft(try await Self.payload("مؤسسة طويق لخيوط الطباعة"),
                                                              suppliers: shop.supplierRows,
                                                              expenses: shop.expenseRows, reclaimsTax: true))
        let en = try await ArabicDualTests.words("en")
        let ar = try await ArabicDualTests.words("ar")
        #expect(ExpenseSheet.receiptNote(draft, words: en) == "Tuwaiq Filament Supply · VAT no. \(Self.VAT)")
        #expect(ExpenseSheet.receiptNote(draft, words: ar) == "Tuwaiq Filament Supply · الرقم الضريبي \(Self.VAT)")
        #expect(ExpenseSheet.halala(115.004999) == 115)
        #expect(ExpenseSheet.halala(15.005001) == 15.01)
        shop.receiptPrefill = draft
        let sheet = ExpenseSheet(shop: shop)
        #expect(!sheet.canAdd, "a category was chosen for the person")
        shop.receiptPrefill = nil
        #expect(ExpenseSheet(shop: shop).canAdd == false, "a typed expense still needs its amount")
    }

    @Test("a code that is not a receipt is shown by its first 24 characters")
    func codeStart() {
        #expect(ReceiptFoundRow.codeStart("https://pay.example/1") == "https://pay.example/1")
        #expect(ReceiptFoundRow.codeStart("https://example.com/pay/1234567890") == "https://example.com/pay/\u{2026}")
        #expect(ReceiptFoundRow.codeStart("ab\u{202E}cd\ne") == "abcde")
    }

    @Test("the list of codes leaves room for Cancel on a small screen")
    func listLimit() async throws {
        #expect(ReceiptReaderSheet.listLimit(screenHeight: 600) == 220)
        #expect(ReceiptReaderSheet.listLimit(screenHeight: 400) == 110)
        #expect(ReceiptReaderSheet.listLimit(screenHeight: 1400) == 440)

        // Measured, not reasoned: eight codes on a 560-point screen and the
        // whole sheet, Cancel included, is shorter than the screen.
        let shop = Shop()
        await shop.load(.sample)
        let engine = try #require(shop.engine)
        let qr = try await Self.payload()
        let draft = try await engine.receiptDraft(qr, suppliers: [], expenses: [], reclaimsTax: true)
        let found = (0..<8).map { _ in ReceiptReaderSheet.Found(text: qr, draft: draft, reason: nil) }
        for screen in [560.0, 800.0] {
            let host = NSHostingView(rootView: ReceiptReaderSheet(shop: shop, found: found, screenHeight: screen))
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.height <= screen - 60,
                    "a \(Int(screen))-point screen gets a \(Int(host.fittingSize.height))-point sheet")
        }
    }
}
