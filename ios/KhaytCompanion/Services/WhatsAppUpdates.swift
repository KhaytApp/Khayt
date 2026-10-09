import Foundation
import KhaytCore

/// WhatsApp updates to customers, from the phone — the Mac's "Send on WhatsApp"
/// (`KhaytApp/WhatsApp.swift`) on the shop floor.
///
/// The RULES are all `lib/whatsapp-message.js`, through KhaytCore: which
/// milestone a job is at, the customer's language, the shop's template or
/// Khayt's default words, the number made ready for `wa.me` (or refused with a
/// reason), and the line written to the customer's log. This file only reads
/// the book, opens a link, and writes that line.
///
/// No account and no API: WhatsApp opens with the message typed, and a person
/// presses send there. The log line is written when WhatsApp OPENS, because
/// that is the last thing the phone can see — the Mac does the same.
///
/// ── THE SHOP'S OWN TEMPLATES ──────────────────────────────────────────────
///
/// They are the book's `waTemplates`, which the phone's working set
/// (`BookScope.workingSet`) does not carry yet. Read when present; until then
/// the update is Khayt's default words in the customer's language, which the
/// sheet says and lets the shop edit.
extension KhaytAPIClient {

    struct WhatsAppOffer: Equatable {
        var milestone: String
        /// When this milestone's update was last opened in WhatsApp, ISO; nil if never.
        var sentAt: String?
    }

    private struct Rows {
        var order: [String: JSONValue]
        var client: [String: JSONValue]?
        var settings: [String: JSONValue]
        var templates: [JSONValue]
    }

    private func rows(for orderId: String) -> Rows? {
        guard let book, book.exists, let store = try? book.read(),
              case .array(let orders)? = store["printLog"],
              case .object(let order)? = orders.first(where: {
                  if case .object(let o) = $0, o["id"] == .string(orderId) { return true }
                  return false
              }) else { return nil }
        var client: [String: JSONValue]?
        if case .string(let cid)? = order["clientId"], !cid.isEmpty, case .array(let clients)? = store["clients"],
           case .object(let c)? = clients.first(where: {
               if case .object(let o) = $0, o["id"] == .string(cid) { return true }
               return false
           }) { client = c }
        var settings: [String: JSONValue] = [:]
        if case .object(let s)? = store["settings"] { settings = s }
        var templates: [JSONValue] = []
        if case .array(let t)? = store["waTemplates"] { templates = t }
        return Rows(order: order, client: client, settings: settings, templates: templates)
    }

    /// What only this app formats — the Mac's own split: the price as a figure,
    /// the currency as its CODE (the riyal sign may not exist on a customer's
    /// phone yet), the due date as the book has it.
    private func values(_ r: Rows) -> [String: String] {
        var price = 0.0
        if case .number(let n)? = r.order["price"] { price = n }
        var currency = ""
        if case .string(let c)? = r.settings["currency"] { currency = c }
        var due = ""
        if case .string(let d)? = r.order["dueDate"] { due = d }
        return ["price": Money.figure(price), "currency": currency, "due": due]
    }

    /// The milestone a job owes its customer, and whether it was already sent.
    /// Nil for a quote or a cancelled job, or without a book.
    func whatsAppOffer(orderId: String) async -> WhatsAppOffer? {
        guard let r = rows(for: orderId), let reader, let engine = try? await reader.sharedEngine(),
              let milestone = (try? await engine.whatsAppMilestone(order: .object(r.order))) ?? nil else { return nil }
        var log: [JSONValue] = []
        if case .array(let l)? = r.client?["commLog"] { log = l }
        let sent = (try? await engine.whatsAppSentAt(commLog: log, orderId: orderId, milestone: milestone)) ?? nil
        return WhatsAppOffer(milestone: milestone, sentAt: sent)
    }

    /// The update's text and recipient, by the shared rule. `lang` nil is the
    /// customer's own language.
    func whatsAppUpdate(orderId: String, lang: String? = nil) async -> WhatsAppUpdate? {
        guard let r = rows(for: orderId), let reader, let engine = try? await reader.sharedEngine() else { return nil }
        return try? await engine.whatsAppUpdate(
            order: .object(r.order), client: r.client.map(JSONValue.object), settings: r.settings,
            templates: r.templates, milestone: nil, lang: lang,
            shopLang: L10n.usesArabicLayout ? "ar" : "en", values: values(r))
    }

    /// The `wa.me` link for this text — built AGAIN from the text as it stands,
    /// since the shop may have edited it — or the reason there is none.
    func whatsAppLink(orderId: String, text: String) async -> (url: URL?, reason: String) {
        guard let r = rows(for: orderId) else { return (nil, "no_customer") }
        guard let client = r.client else { return (nil, "no_customer") }
        var phone = ""
        if case .string(let p)? = client["phone"] { phone = p }
        guard !phone.trimmingCharacters(in: .whitespaces).isEmpty else { return (nil, "no_phone") }
        guard let reader, let engine = try? await reader.sharedEngine(),
              let chat = try? await engine.whatsAppChat(phone: phone, text: text) else { return (nil, "no_phone") }
        guard chat.ok, let url = URL(string: chat.link) else { return (nil, chat.reason) }
        return (url, "")
    }

    /// WhatsApp has opened with this text: write it to the customer's log, in
    /// the shared shape, so both apps list it and the job stops offering an
    /// update it has sent.
    func logWhatsApp(orderId: String, text: String, milestone: String?, lang: String?, now: Date = Date()) async {
        guard let book, let r = rows(for: orderId), case .string(let cid)? = r.client?["id"],
              let reader, let engine = try? await reader.sharedEngine(),
              let entry = try? await engine.whatsAppCommEntry(id: BookWriter.lanId("CMM", now: now), at: now, text: text,
                                                              orderId: orderId, milestone: milestone, lang: lang)
        else { return }
        try? BookWriter(book: book).addCommEntry(clientId: cid, entry: entry)
        await refreshPendingCount()
        await deliverPending()
    }
}
