import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import KhaytCore

/// A job's invoice, from the book the phone keeps — the Mac's `Invoice.swift`
/// on the shop floor.
///
/// The document is `lib/invoice-document.js` through KhaytCore
/// (`KhaytEngine.invoiceHtml`), so the phone cannot hand a customer a
/// different paper from the one the Mac or the PC prints for the same job.
/// What is assembled here is what the Mac assembles: the tax split by the
/// shop's own rule, the ZATCA QR's pixels (the PAYLOAD is shared), and the
/// shop's name and fields.
///
/// ── THE PHONE NEVER NUMBERS AN INVOICE ─────────────────────────────────────
///
/// An accepted quote is owed an invoice number, and `ensureInvoiceNumber`
/// takes it from a counter in the settings — a read-modify-write that is only
/// safe inside the store's own write on the newest book. The phone's copy can
/// be stale, and sync merges whole records, so two devices numbering offline
/// would print one number twice. A job still owed a number is refused here
/// with where to go; the Mac or the PC numbers it the first time it draws the
/// invoice, and the phone prints that number from then on.
enum InvoiceBuild {
    case paper(InvoiceDocument, filename: String)
    case refused(InvoiceRefusal)
}

enum InvoiceRefusal: Equatable {
    /// Not in the phone's copy of the book.
    case missing
    /// Still a quote, or one waiting for the customer: not an invoice yet.
    case quote
    /// A cancelled job is never invoiced.
    case cancelled
    /// An accepted quote the Mac or the PC has not numbered yet.
    case notNumbered
    /// The shared document could not be built.
    case failed

    var message: String {
        switch self {
        case .missing: return L10n.tr("invoice.refused.missing")
        case .quote: return L10n.tr("invoice.refused.quote")
        case .cancelled: return L10n.tr("invoice.refused.cancelled")
        case .notNumbered: return L10n.tr("invoice.refused.not_numbered")
        case .failed: return L10n.tr("invoice.refused.failed")
        }
    }
}

extension BookReader {

    /// The invoice for `orderId`, in `language` — or why there is none.
    func invoice(orderId: String, language: String) async throws -> InvoiceBuild {
        let store = try wholeBook()
        var orders: [JSONValue] = []
        if case .array(let rows)? = store["printLog"] { orders = rows }
        guard let row = orders.first(where: {
            if case .object(let o) = $0, o["id"] == .string(orderId) { return true }
            return false
        }), case .object(let order) = row else { return .refused(.missing) }

        if let refusal = Self.invoiceRefusal(order) { return .refused(refusal) }

        var settings = Self.settings(store)
        let engine = try sharedEngine()
        // The counter is the Mac's — see the type's note.
        if try await engine.invoiceNumberOwed(order: row, settings: settings) { return .refused(.notNumbered) }
        let number = try await engine.documentNumber(order: row, settings: settings)

        let price = Self.number(order["price"])
        let profile = try? await engine.taxProfile(settings: settings)
        let registered = profile?.isRegistered == true
        let split: TaxSplit? = registered ? try? await engine.computeTax(price, profile: profile!) : nil

        // THE MOMENT, not the day: ZATCA's tag 3 is the invoice's date and
        // time, so the order's own stamp when it has one, as the Mac passes it.
        var stamp = Self.text(order["date"])
        if let ts = Self.text(order["timestamp"]), !ts.isEmpty { stamp = ts }

        let sellerName = await Self.shopName(settings, engine: engine, language: language)
        let fields = Self.documentFields(settings)

        // The loyalty badge is worked out from what the customer has spent,
        // and a phone holding the newest 200 jobs would understate it. No
        // badge is honest; a lower one printed on a customer's paper is not.
        if !holdsAll("printLog") { settings["loyaltyEnabled"] = .bool(false) }

        var clients: [JSONValue] = []
        if case .array(let c)? = store["clients"] { clients = c }

        let subtotal = split?.subtotal ?? price
        let taxTotal = split?.taxTotal ?? 0
        var qrSvg = ""
        var qrProblem: String?
        if case .bool(true)? = settings["enableZatca"] {
            let words = (try? await engine.translations(language: language)) ?? [:]
            let refusal = (try? await engine.zatcaReadiness(settings: settings, sellerName: sellerName)).flatMap { $0 }
            if let refusal {
                qrProblem = Self.zatcaRefusal(refusal, words: words)
            } else if let payload = try? await engine.zatcaPayload(
                sellerName: sellerName, vatNumber: Self.text(settings["vat"]) ?? "", timestamp: stamp ?? "",
                total: Self.amount(subtotal + taxTotal), vatAmount: Self.amount(taxTotal)),
                let image = Self.qrImage(payload) {
                qrSvg = "<img src=\"\(image)\" width=\"120\" height=\"120\" alt=\"ZATCA\">"
            } else {
                qrProblem = words["inv.qr_failed"] ?? "inv.qr_failed"
            }
        }

        // The Subtotal row is the ITEMS, so the document reconciles its own
        // table against what they came to before rush, shipping and discount.
        let summary = try? await engine.invoiceSummary(order: row, settings: settings)
        let money: [String: JSONValue] = [
            "qrSvg": .string(qrSvg),
            "qrProblem": qrProblem.map(JSONValue.string) ?? .null,
            "payQrSvg": .string(""),
            "total": .string(Self.amount(subtotal + taxTotal)),
            "vatAmount": .string(Self.amount(taxTotal)),
            "subtotal": .string(Self.amount(subtotal)),
            "subtotalShown": .string(Self.amount(summary?.itemsSubtotal ?? price)),
            "vatRate": .number(registered ? profile!.totalPercent : 0),
            "shipping": .number(0),
        ]
        let currencies = ((try? await engine.currencies()) ?? [:]).mapValues {
            JSONValue.object(["symbol": .string($0.symbol), "label": .string($0.label), "pos": .string($0.pos)])
        }
        guard let doc = try? await engine.invoiceHtml(
            order: row, settings: settings, clients: clients, currencies: currencies,
            language: language, money: money, sellerFields: fields, orders: orders) else {
            return .refused(.failed)
        }
        return .paper(doc, filename: Self.invoiceFilename(number: number, project: Self.text(order["project"])))
    }

    /// The rules that hold before any engine is asked: a cancelled job and a
    /// quote still waiting for the customer are not invoices. "Waiting" is
    /// `lib/order-new.js`'s `awaitingApproval`: in the quote column, or on
    /// hold with its quote attached and no yes recorded.
    nonisolated static func invoiceRefusal(_ order: [String: JSONValue]) -> InvoiceRefusal? {
        let status = text(order["status"]) ?? ""
        if status == "cancelled" { return .cancelled }
        if status == "quote" { return .quote }
        if status == "on_hold", truthy(order["hasQuote"]),
           !truthy(order["quoteAcceptedAt"]), !truthy(order["clientApprovedAt"]) { return .quote }
        return nil
    }

    /// JavaScript's truthiness, for the fields the rule above reads.
    nonisolated static func truthy(_ v: JSONValue?) -> Bool {
        switch v {
        case .bool(let b)?: return b
        case .string(let s)?: return !s.isEmpty
        case .number(let n)?: return n != 0 && !n.isNaN
        case .array?, .object?: return true
        default: return false
        }
    }

    /// The name the paper prints, as the Mac's `Shop.shopName(from:)` reads it.
    static func shopName(_ settings: [String: JSONValue], engine: KhaytEngine, language: String) async -> String {
        if let name = try? await engine.shopText("biz", settings: settings, language: language), !name.isEmpty {
            return name
        }
        for key in ["bizEn", "bizAr"] {
            if let v = text(settings[key]), !v.isEmpty { return v }
        }
        return ""
    }

    /// Every field the document asks the shop for, as the Mac's
    /// `shopDocumentFields` resolves them: English first, then Arabic.
    nonisolated static func documentFields(_ settings: [String: JSONValue]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for base in ["biz", "addr", "tagline", "footer"] {
            let value = ["\(base)En", "\(base)Ar"].lazy.compactMap { text(settings[$0]) }.first { !$0.isEmpty }
            out[base] = .string(value ?? "")
        }
        return out
    }

    /// Named as the Mac's invoice sheet names it — the name is what the
    /// customer sees on the attachment.
    nonisolated static func invoiceFilename(number: String, project: String?) -> String {
        let base = number.isEmpty ? (project ?? L10n.tr("invoice.title")) : number
        let cleaned = base.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "invoice" : cleaned) + ".pdf"
    }

    /// Which ZATCA fields are missing, in the shared catalogue's words.
    nonisolated static func zatcaRefusal(_ reason: StatusGate.Reason, words: [String: String]) -> String {
        guard case .array(let missing)? = reason.params["missing"] else { return words["inv.qr_failed"] ?? "inv.qr_failed" }
        return missing.compactMap { if case .string(let key) = $0 { return words[key] ?? key } else { return nil } }
            .joined(separator: " · ")
    }

    /// Two decimals, the way an invoice states money.
    nonisolated static func amount(_ n: Double) -> String {
        String(format: "%.2f", n.isFinite ? n : 0)
    }

    nonisolated static func number(_ v: JSONValue?) -> Double {
        switch v {
        case .number(let n)?: return n.isFinite ? n : 0
        case .string(let s)?: return Double(s.trimmingCharacters(in: .whitespaces)) ?? 0
        default: return 0
        }
    }

    nonisolated static func text(_ v: JSONValue?) -> String? {
        if case .string(let s)? = v { return s }
        return nil
    }

    /// The QR, as a data URL — CoreImage, `M` correction, scaled before it is
    /// rasterised, exactly as the Mac draws it.
    nonisolated static func qrImage(_ payload: String) -> String? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent),
              let png = UIImage(cgImage: cg).pngData() else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}
