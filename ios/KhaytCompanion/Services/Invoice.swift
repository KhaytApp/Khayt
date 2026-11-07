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
    /// A proforma is for priced work accepted and not yet finished.
    case noProforma

    var message: String {
        switch self {
        case .missing: return L10n.tr("invoice.refused.missing")
        case .quote: return L10n.tr("invoice.refused.quote")
        case .cancelled: return L10n.tr("invoice.refused.cancelled")
        case .notNumbered: return L10n.tr("invoice.refused.not_numbered")
        case .failed: return L10n.tr("invoice.refused.failed")
        case .noProforma: return L10n.tr("proforma.refused")
        }
    }
}

extension BookReader {

    /// The invoice for `orderId`, in `language` — or why there is none.
    ///
    /// `proforma`: the same paper as a request for payment before the work is
    /// invoiced (`proforma` in `lib/invoice-document.js`, as the Mac's
    /// `Invoice.html(for:shop:proforma:)`): titled and watermarked as one, no
    /// ZATCA QR, the job's own id for a number — and never numbered, so the
    /// phone's no-numbering rule is not in its way.
    func invoice(orderId: String, language: String, proforma: Bool = false) async throws -> InvoiceBuild {
        let store = try wholeBook()
        var orders: [JSONValue] = []
        if case .array(let rows)? = store["printLog"] { orders = rows }
        guard let row = orders.first(where: {
            if case .object(let o) = $0, o["id"] == .string(orderId) { return true }
            return false
        }), case .object(let order) = row else { return .refused(.missing) }

        if proforma {
            guard Self.offersProforma(order) else { return .refused(.noProforma) }
        } else if let refusal = Self.invoiceRefusal(order) { return .refused(refusal) }

        var settings = Self.settings(store)
        let engine = try sharedEngine()
        // The counter is the Mac's — see the type's note.
        let number: String
        if proforma {
            // The number a person reads, as lib/invoice-document.js prints it:
            // the job number, not the id's random tag.
            number = Self.text(order["jobNumber"]).flatMap { $0.isEmpty ? nil : $0 } ?? orderId
        } else {
            if try await engine.invoiceNumberOwed(order: row, settings: settings) { return .refused(.notNumbered) }
            number = try await engine.documentNumber(order: row, settings: settings)
        }

        let price = Self.number(order["price"])
        let profile = try? await engine.taxProfile(settings: settings)
        let registered = profile?.isRegistered == true
        let split: TaxSplit? = registered ? try? await engine.computeTax(price, profile: profile!) : nil

        // THE MOMENT, not the day: ZATCA's tag 3 is the invoice's date and
        // time, so the order's own stamp when it has one, as the Mac passes it.
        var stamp = Self.text(order["date"])
        if let ts = Self.text(order["timestamp"]), !ts.isEmpty { stamp = ts }

        let sellerName = await Self.shopName(settings, engine: engine, language: language)
        let fields = ShopFields.document(settings)

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
        if !proforma, case .bool(true)? = settings["enableZatca"] {
            let words = (try? await engine.translations(language: language)) ?? [:]
            let refusal = (try? await engine.zatcaReadiness(settings: settings, sellerName: sellerName)).flatMap { $0 }
            // Tags 4 and 5 are RIYALS. A job saved in a client's currency is
            // converted at the rate stored on it when it was saved; with no
            // rate there is no honest figure and no QR (`qrAmounts`, shared
            // with the desktop and the Mac).
            let riyals = try? await engine.zatcaAmounts(
                order: row, settings: settings, total: subtotal + taxTotal, vatAmount: taxTotal)
            if let refusal {
                qrProblem = Self.zatcaRefusal(refusal, words: words)
            } else if case .refused(let why)? = riyals {
                qrProblem = Self.zatcaRefusal(why, words: words)
            } else if case .amounts(let total, let vat)? = riyals,
                let payload = try? await engine.zatcaPayload(
                sellerName: sellerName, vatNumber: Self.text(settings["vat"]) ?? "", timestamp: stamp ?? "",
                total: Self.amount(total), vatAmount: Self.amount(vat)),
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
            "proforma": .bool(proforma),
        ]
        let currencies = ((try? await engine.currencies()) ?? [:]).mapValues {
            JSONValue.object(["symbol": .string($0.symbol), "label": .string($0.label), "pos": .string($0.pos)])
        }
        guard let doc = try? await engine.invoiceHtml(
            order: row, settings: settings, clients: clients, currencies: currencies,
            language: language, money: money, sellerFields: fields, orders: orders) else {
            return .refused(.failed)
        }
        // A voided or fully credited invoice is printed stamped as one — see
        // `InvoiceStamp`. The shared document has no such stamp of its own.
        let paper = InvoiceStamp.of(order).map {
            InvoiceDocument(html: $0.wrap(doc.html, language: language),
                            arabicNumerals: doc.arabicNumerals, selector: doc.selector)
        } ?? doc
        return .paper(paper, filename: Self.invoiceFilename(number: proforma ? "Proforma-" + number : number,
                                                            project: Self.text(order["project"])))
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

    /// Whether a job has a proforma to give — the Mac's `Shop.offersProforma`:
    /// priced, accepted and not yet finished. A quote already is the paper for
    /// asking; a finished job gets its invoice.
    nonisolated static func offersProforma(_ order: [String: JSONValue]) -> Bool {
        guard number(order["price"]) > 0 else { return false }
        return offersProforma(status: text(order["status"]) ?? "")
    }

    nonisolated static func offersProforma(status: String) -> Bool {
        ["pending", "on_hold", "printing", "post", "qc"].contains(status)
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
        return ShopFields.value("biz", settings)
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

/// The stamp on an invoice that has been taken back — Turki's decision
/// (Nov 2026): a voided invoice must never print or share as a normal one.
///
/// ── WHERE THE RECORDS COME FROM ───────────────────────────────────────────
///
/// `lib/invoice-reversal.js` writes them on every computer: a void stamps
/// `voidedAt` (and `voidedReason`); a credit note that brings the credited
/// total up to the price stamps `creditedAt`. A partial credit stamps
/// nothing, so it prints no stamp here either.
///
/// ── WHY IT IS DRAWN HERE ──────────────────────────────────────────────────
///
/// `lib/invoice-document.js` — the paper all three apps print — has no void
/// or credited stamp (it has a PAID one and the proforma's watermark), and
/// neither the desktop nor the Mac marks a voided invoice in any other way.
/// The phone wraps the shared document rather than changing it, so the other
/// two apps' papers are untouched until the owner decides they match; the
/// styles are inline, as the proforma's watermark is, because
/// `invoice.css` is the desktop's file, byte for byte.
enum InvoiceStamp: Equatable {
    /// `voidedAt`: the invoice was cancelled outright.
    case voided(at: String, reason: String?)
    /// `creditedAt`: credit notes cover the whole price.
    case credited(at: String)

    /// The stamp `order` carries, if any. A void wins over a credit: it is
    /// the stronger statement, and a job can hold both.
    static func of(_ order: [String: JSONValue]) -> InvoiceStamp? {
        if let at = stampText(order["voidedAt"]) {
            var reason = stampText(order["voidedReason"])
            // The rule's own placeholder when nobody typed a reason.
            if reason == "Voided" { reason = nil }
            return .voided(at: at, reason: reason)
        }
        if let at = stampText(order["creditedAt"]) { return .credited(at: at) }
        return nil
    }

    private static func stampText(_ v: JSONValue?) -> String? {
        switch v {
        case .string(let s)?:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        case .number(let ms)? where ms > 0:
            return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: ms / 1000))
        default: return nil
        }
    }

    /// The big word across the paper.
    func word(language: String) -> String {
        switch self {
        case .voided: return L10n.tr("invoice.stamp.void", language: language)
        case .credited: return L10n.tr("invoice.stamp.credited", language: language)
        }
    }

    /// The line at the head of the paper: what happened, and when.
    func line(language: String) -> String {
        let locale = L10n.latinDigits(Locale(identifier: language))
        switch self {
        case .voided(let at, _):
            return String(format: L10n.tr("invoice.stamp.void.line", language: language), locale: locale,
                          Self.day(at, language: language))
        case .credited(let at):
            return String(format: L10n.tr("invoice.stamp.credited.line", language: language), locale: locale,
                          Self.day(at, language: language))
        }
    }

    /// The day a stamp was made, as a person reads it: the stamp is an ISO
    /// moment, shown as the LOCAL day in the paper's language, Western digits.
    static func day(_ stamp: String, language: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let date = iso.date(from: stamp) ?? plain.date(from: stamp) else { return String(stamp.prefix(10)) }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = L10n.latinDigits(Locale(identifier: language))
        f.dateStyle = .long
        f.timeStyle = .none
        return f.string(from: date)
    }

    /// `html` — the shared document — with the stamp: a heading line above
    /// it and the word across it, diagonally, on screen and on the PDF.
    func wrap(_ html: String, language: String) -> String {
        let dir = language == "ar" ? "rtl" : "ltr"
        let red = "#b91c1c"
        var reasonHtml = ""
        if case .voided(_, let reason?) = self {
            let format = L10n.tr("invoice.stamp.void.reason", language: language)
            let text = String(format: format, locale: L10n.latinDigits(Locale(identifier: language)), reason)
            reasonHtml = "<div style=\"font-weight:500; font-size:12.5px; margin-top:3px;\">\(Self.escape(text))</div>"
        }
        let kind: String
        switch self {
        case .voided: kind = "void"
        case .credited: kind = "credited"
        }
        let word = Self.escape(word(language: language))
        return """
        <div class="khayt-reversal" data-stamp="\(kind)" style="position:relative;">\
        <div class="reversal-banner" role="note" dir="\(dir)" style="border:2px solid \(red); color:\(red); \
        background:#fef2f2; -webkit-print-color-adjust:exact; print-color-adjust:exact; border-radius:6px; \
        padding:10px 14px; margin:0 0 14px; font-size:14px; font-weight:700; line-height:1.45;">\
        <span style="letter-spacing:2px; margin-inline-end:8px;">\(word)</span> \(Self.escape(line(language: language)))\(reasonHtml)</div>\
        <div class="reversal-watermark" aria-hidden="true" style="position:absolute; inset:0; display:flex; \
        align-items:center; justify-content:center; pointer-events:none; z-index:5; overflow:hidden;">\
        <span style="transform:rotate(-30deg); font-size:120px; font-weight:900; letter-spacing:10px; \
        color:rgba(185,28,28,0.22); border:8px solid rgba(185,28,28,0.22); border-radius:18px; padding:0 28px; \
        white-space:nowrap;">\(word)</span></div>\
        \(html)</div>
        """
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
