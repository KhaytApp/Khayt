import Foundation
import KhaytCore

/// A quote's Revise, its history, and the follow-up — the Mac's
/// `Shop+Quotes.swift` on the go, in the same fields:
///
/// * Revise keeps what the quote says now in `quoteRevisions[]` and moves
///   `quoteVersion` on one (`lib/quote-revision.js`), with the change made in
///   the same write (`BookWriter.reviseQuote`).
/// * The history is `KhaytQuoteRevision.history`, newest first.
/// * A follow-up is recorded as `followUpSentAt` and `followUpCount`
///   (`lib/quote-followup.js` `markFollowUpPatch`) BEFORE WhatsApp opens with
///   the shop's own words for it (`quote.followup_msg`), then written to the
///   customer's log as every WhatsApp message the phone opens is.
///
/// All three are the book's: no LAN route takes them, so a phone that keeps
/// no book says it cannot, as `addSupplier` does.
extension KhaytAPIClient {

    /// What the quote tools show: the version, the follow-ups so far, what
    /// the Revise sheet starts from, and the kept versions.
    struct QuoteState: Equatable {
        var version: Int
        var followUpCount: Int
        var followUpSentAt: String?
        var price: Double
        var notes: String
        var revisions: [KhaytEngine.QuoteRevision]
    }

    private func quoteRow(_ orderId: String) -> JSONValue? {
        guard let book, book.exists, let store = try? book.read(),
              case .array(let rows)? = store["printLog"] else { return nil }
        return rows.first {
            if case .object(let o) = $0, o["id"] == .string(orderId) { return true }
            return false
        }
    }

    /// The quote as its tools show it. Nil without a book, or when the job is
    /// no longer a quote.
    func quoteState(orderId: String) async -> QuoteState? {
        guard let row = quoteRow(orderId), case .object(let o) = row, o["status"] == .string("quote"),
              let reader, let engine = try? await reader.sharedEngine() else { return nil }
        func number(_ v: JSONValue?) -> Double {
            if case .number(let n)? = v, n.isFinite { return n }
            return 0
        }
        var sentAt: String?
        if case .string(let s)? = o["followUpSentAt"], !s.isEmpty { sentAt = s }
        var notes = ""
        if case .string(let s)? = o["notes"] { notes = s }
        return QuoteState(version: max(1, Int(number(o["quoteVersion"]))),
                          followUpCount: max(0, Int(number(o["followUpCount"]))),
                          followUpSentAt: sentAt, price: number(o["price"]), notes: notes,
                          revisions: (try? await engine.quoteRevisions(order: row)) ?? [])
    }

    /// Only what moved: a key left out is left alone by the rule.
    nonisolated static func revisionFields(start: QuoteState, price: Double?, notes: String) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        if let price, price >= 0, abs(price - start.price) > 0.004 { out["price"] = .number(price) }
        if notes != start.notes { out["notes"] = .string(notes) }
        return out
    }

    /// Revise a quote from the book (`BookWriter.reviseQuote`), and send it on.
    /// Returns whether anything changed.
    @discardableResult
    func reviseQuote(orderId: String, fields: [String: JSONValue], now: Date = Date()) async throws -> Bool {
        guard let book, book.exists, let reader else { throw KhaytAPIError.server(L10n.tr("quote.needs_book")) }
        let wrote = try await BookWriter(book: book).reviseQuote(orderId: orderId, fields: fields,
                                                                 engine: reader.sharedEngine(), now: now)
        if wrote {
            await refreshPendingCount()
            await deliverPending()
        }
        return wrote
    }

    /// The follow-up's words: `quote.followup_msg`, the shop's own catalogue,
    /// in the shop's language — the Mac's `followUpText`, with the job's
    /// readable reference for `{id}` and the currency as its code, as the
    /// phone's WhatsApp updates write money for a customer's phone.
    func followUpText(orderId: String) async -> String? {
        guard let row = quoteRow(orderId), case .object(let o) = row, let reader,
              let engine = try? await reader.sharedEngine(),
              let template = (try? await engine.translations(language: L10n.contentLanguage))?["quote.followup_msg"]
        else { return nil }
        let code = (try? await reader.orderCurrency(orderId: orderId)) ?? nil
        return Self.followUpMessage(template: template, order: o,
                                    customerName: customer(orderId: orderId)?.displayName, currency: code)
    }

    /// The template filled in: the customer, the job's READABLE reference
    /// (never its raw id), the project, the total with the currency's code,
    /// and the last day as the book has it.
    nonisolated static func followUpMessage(template: String, order o: [String: JSONValue],
                                            customerName: String?, currency: String?) -> String {
        func text(_ v: JSONValue?) -> String {
            if case .string(let s)? = v { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
            return ""
        }
        let reference = BookReader.reference(o)
        let project = text(o["project"]).isEmpty ? reference : text(o["project"])
        let name = customerName.flatMap { $0.isEmpty ? nil : $0 } ?? (text(o["client"]).isEmpty ? project : text(o["client"]))
        var price = 0.0
        if case .number(let n)? = o["price"], n.isFinite { price = n }
        let total = [Money.figure(price), currency ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        let values = ["name": name, "id": reference, "project": project, "total": total,
                      "expires": text(o["quoteExpiresAt"])]
        var out = template
        for (key, value) in values { out = out.replacingOccurrences(of: "{\(key)}", with: value) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Follow up on a quote: the words, the chat, and the follow-up RECORDED
    /// — in that order, so nothing is written for a customer with no number
    /// and WhatsApp never opens for a follow-up the book did not take.
    /// Returns the link to open and the text, for the customer's log.
    func followUpQuote(orderId: String, now: Date = Date()) async throws -> (url: URL, text: String) {
        guard let book, book.exists, let reader else { throw KhaytAPIError.server(L10n.tr("quote.needs_book")) }
        guard let text = await followUpText(orderId: orderId) else {
            throw KhaytAPIError.server(L10n.tr("quote.not_a_quote"))
        }
        let link = await whatsAppLink(orderId: orderId, text: text)
        guard let url = link.url else {
            throw KhaytAPIError.server(WhatsAppSheet.reason(link.reason))
        }
        try await BookWriter(book: book).recordFollowUp(orderId: orderId, engine: reader.sharedEngine(), now: now)
        await refreshPendingCount()
        await deliverPending()
        return (url, text)
    }
}
