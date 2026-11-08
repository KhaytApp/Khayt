import Foundation
import KhaytCore

/// The shop's papers besides the invoice — a job's packing slip, delivery
/// note and work order, and a customer's account statement — from the book
/// the phone keeps. The Mac's `Shop+Papers.swift` on the shop floor.
///
/// ── WHAT DECIDES WHAT ─────────────────────────────────────────────────────
///
/// `lib/shop-documents.js`, through KhaytCore (`KhaytEngine.shopPaperHtml`
/// and `statementHtml`), handed the same inputs the Mac hands it: the shop's
/// settings, customers, machines, shelf and currencies, the shop's name, the
/// day, and the papers filed against the job's product. So the slip a phone
/// shares is the slip the Mac or the PC prints for the same job. The paper is
/// drawn in the invoice's WebKit paper (`InvoicePaper`) and shared as the
/// same A4 PDF.
///
/// Showing a paper writes nothing.
///
/// ── A STATEMENT FROM PART OF THE BOOK ─────────────────────────────────────
///
/// A phone carries every open job and the newest finished ones
/// (`BookScope.workingSet`), so a statement made from that can leave older
/// work and payments off. It used to be refused; Turki decided (Nov 2026)
/// that it is made anyway and SAYS so: the page warns before it is shared
/// (`PaperBuild.paper`'s `partial`), and the statement itself carries a line
/// that some older records may be missing. From a whole book: no warning.
enum PaperSubject: Hashable {
    /// A packing slip, delivery note or work order for one job.
    case job(KhaytEngine.ShopPaper, orderId: String)
    /// A customer's account statement.
    case statement(clientId: String)

    /// What the page is headed with.
    var title: String {
        switch self {
        case .job(let kind, _): return L10n.tr(Self.titleKey(kind))
        case .statement: return L10n.tr("paper.statement")
        }
    }

    static func titleKey(_ kind: KhaytEngine.ShopPaper) -> String {
        switch kind {
        case .packingSlip: return "paper.packing_slip"
        case .deliveryNote: return "paper.delivery_note"
        case .workOrder: return "paper.work_order"
        }
    }

    /// Whether the paper is a whole page with its own styles (the packing
    /// slip) rather than a document for the invoice's stylesheet — the Mac's
    /// `Shop.paperIsWholePage`.
    var isWholePage: Bool {
        if case .job(.packingSlip, _) = self { return true }
        return false
    }
}

enum PaperBuild {
    /// `partial`: made from a book that does not hold every job — see the
    /// note on `PaperSubject`. Only a statement is ever partial.
    case paper(InvoiceDocument, filename: String, wholePage: Bool, partial: Bool)
    case refused(PaperRefusal)
}

enum PaperRefusal: Equatable {
    /// Not in the phone's copy of the book.
    case missing
    /// A quote is not work yet: nothing to pack, deliver or make.
    case quote
    /// The shared document could not be built.
    case failed

    var message: String {
        switch self {
        case .missing: return L10n.tr("paper.refused.missing")
        case .quote: return L10n.tr("paper.refused.quote")
        case .failed: return L10n.tr("paper.refused.failed")
        }
    }
}

extension BookReader {

    /// One of the shop's papers, in `language` — or why there is none.
    func shopPaper(_ subject: PaperSubject, language: String, now: Date = Date()) async throws -> PaperBuild {
        let store = try wholeBook()
        func rows(_ key: String) -> [JSONValue] {
            if case .array(let r)? = store[key] { return r }
            return []
        }
        func byId(_ list: [JSONValue], _ id: String) -> [String: JSONValue]? {
            for case .object(let o) in list where o["id"] == .string(id) { return o }
            return nil
        }
        let orders = rows("printLog")
        let clients = rows("clients")
        let settings = Self.settings(store)
        let engine = try sharedEngine()
        let currencies: [String: JSONValue] = ((try? await engine.currencies()) ?? [:]).mapValues {
            .object(["symbol": .string($0.symbol), "label": .string($0.label), "pos": .string($0.pos)])
        }
        let shopName = await Self.shopName(settings, engine: engine, language: language)
        func inputs(docs: [JSONValue] = []) -> KhaytEngine.PaperInputs {
            KhaytEngine.PaperInputs(settings: settings, clients: clients, machines: rows("machines"),
                                    inventory: rows("inventory"), currencies: currencies,
                                    language: language, shopName: shopName,
                                    today: BookWriter.localDay(now), docs: docs)
        }

        switch subject {
        case .job(let kind, let orderId):
            guard let order = byId(orders, orderId) else { return .refused(.missing) }
            if let refusal = Self.paperRefusal(order) { return .refused(refusal) }
            // The papers filed against the job's product: the delivery note
            // lists the ones that go in the box, the work order all of them.
            let docs: [JSONValue] = OrderDocs.forOrder(.object(order), products: rows("products")).map {
                .object(["name": .string($0.name), "packWithOrder": .bool($0.packWithOrder)])
            }
            guard let html = try? await engine.shopPaperHtml(kind, order: .object(order), inputs(docs: docs)) else {
                return .refused(.failed)
            }
            return .paper(InvoiceDocument(html: html, arabicNumerals: false, selector: ""),
                          filename: Self.paperFilename(kind, reference: Self.reference(order)),
                          wholePage: subject.isWholePage, partial: false)
        case .statement(let clientId):
            guard let client = byId(clients, clientId) else { return .refused(.missing) }
            let partial = !holdsAll("printLog")
            guard let made = try? await engine.statementHtml(client: .object(client), orders: orders, inputs()) else {
                return .refused(.failed)
            }
            let html = partial ? Self.partialStatementNote(language: language) + made : made
            let name = (Self.text(client["name"]).flatMap { $0.isEmpty ? nil : $0 })
                ?? (Self.text(client["nameEn"]).flatMap { $0.isEmpty ? nil : $0 })
                ?? (Self.text(client["nameAr"]).flatMap { $0.isEmpty ? nil : $0 }) ?? clientId
            return .paper(InvoiceDocument(html: html, arabicNumerals: false, selector: ""),
                          filename: "statement-" + Self.safeFilePart(name) + ".pdf", wholePage: false,
                          partial: partial)
        }
    }

    /// The line printed at the head of a statement made from part of the
    /// book, in the statement's language: the customer reading it is told
    /// that older records may be missing.
    nonisolated static func partialStatementNote(language: String) -> String {
        let dir = language == "ar" ? "rtl" : "ltr"
        let text = PaperHTML.escape(L10n.tr("paper.statement.partial.printed", language: language))
        return "<div class=\"statement-partial\" role=\"note\" dir=\"\(dir)\" style=\"border:1px solid #b45309; "
            + "background:#fffbeb; color:#92400e; -webkit-print-color-adjust:exact; print-color-adjust:exact; "
            + "border-radius:6px; padding:8px 12px; margin:0 0 12px; font-size:12.5px; font-weight:600; "
            + "line-height:1.45;\">\(text)</div>"
    }

    /// A quote has nothing to pack, deliver or make yet. A cancelled job's
    /// papers are still the Mac's to give (its menus offer them), so they are
    /// not refused here — but the job page does not offer them either.
    nonisolated static func paperRefusal(_ order: [String: JSONValue]) -> PaperRefusal? {
        text(order["status"]) == "quote" ? .quote : nil
    }

    /// The number a person reads: the job number, else its id.
    nonisolated static func reference(_ order: [String: JSONValue]) -> String {
        if let n = text(order["jobNumber"]), !n.isEmpty { return n }
        return text(order["id"]) ?? ""
    }

    /// The file a paper is shared under, as the Mac's Save as PDF names it.
    nonisolated static func paperFilename(_ kind: KhaytEngine.ShopPaper, reference: String) -> String {
        let lead: String
        switch kind {
        case .packingSlip: lead = "packing-slip"
        case .deliveryNote: lead = "delivery-note"
        case .workOrder: lead = "work-order"
        }
        return lead + "-" + safeFilePart(reference) + ".pdf"
    }

    /// A name with the characters a file name cannot hold taken out.
    nonisolated static func safeFilePart(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "khayt" : cleaned
    }
}

extension KhaytAPIClient {

    /// One of the shop's papers, built from the book this phone keeps — or why not.
    func shopPaper(_ subject: PaperSubject) async -> PaperBuild {
        guard let reader, holdsBook else { return .refused(.missing) }
        return (try? await reader.shopPaper(subject, language: L10n.contentLanguage)) ?? .refused(.failed)
    }
}
