import Foundation
import AppKit
import KhaytCore

/// WhatsApp updates to customers, with no account.
///
/// ── WHAT THIS IS ──────────────────────────────────────────────────────────
///
/// Saudi customers expect WhatsApp, not email. When a job reaches a moment the
/// customer cares about — received, ready, shipped, delivered — the job offers
/// "Send on WhatsApp". That opens WhatsApp on the customer's number with the
/// message already typed, in the customer's language, from the shop's own
/// template for that moment or Khayt's default words. A person presses send.
///
/// The RULES — the number, the milestone, the language, the words, the log
/// line — are `lib/whatsapp-message.js`, so the desktop can offer the same
/// button with the same words. This file is only what a Mac does with them:
/// open a URL, and write the log.
///
/// Automatic sending needs a WhatsApp Business provider and approved
/// templates, and is not here: see docs/handoffs/whatsapp-business-api.md.
extension Shop {

    /// The customer record a job points at, raw and typed.
    func clientRecord(for job: Order) -> (client: Client, row: JSONValue)? {
        guard let id = job.clientId, !id.isEmpty,
              let client = clients.first(where: { $0.id == id }),
              let row = clientRows.first(where: { Self.recordId($0) == id }) else { return nil }
        return (client, row)
    }

    /// What only this app can format. The currency goes as its CODE, not
    /// `Money.mark`: the new riyal sign is a character a customer's phone may
    /// not have yet, and a box where the currency should be is worse than SAR.
    private func whatsAppValues(for job: Order) -> [String: String] {
        ["price": Money.figure(job.price), "currency": currency, "due": job.dueDate ?? ""]
    }

    /// The update for a job, at its own milestone and the customer's language
    /// unless told otherwise. Nil only when the engine is not up.
    func whatsAppUpdate(for job: Order, milestone: String? = nil,
                        lang: String? = nil) async -> WhatsAppUpdate? {
        guard let engine, let order = orderRow(job.id) else { return nil }
        let templates = messageTemplates.map(\.row)
        return try? await engine.whatsAppUpdate(
            order: order, client: clientRecord(for: job)?.row, settings: settingsDict,
            templates: templates, milestone: milestone, lang: lang,
            shopLang: words.language, values: whatsAppValues(for: job))
    }

    /// What the job's inspector offers: the milestone it is at, and when that
    /// update was last opened in WhatsApp (nil when it has not been). Nil when
    /// the job owes the customer no update — a quote, a cancelled job.
    struct WhatsAppOffer: Equatable, Sendable {
        var milestone: String
        var sentAt: String?
    }

    func whatsAppOffer(for job: Order) async -> WhatsAppOffer? {
        guard let engine, let order = orderRow(job.id),
              let milestone = (try? await engine.whatsAppMilestone(order: order)) ?? nil
        else { return nil }
        let log = clientRecord(for: job)?.client.commLog.map { JSONValue.object($0.raw) } ?? []
        let sent = (try? await engine.whatsAppSentAt(commLog: log, orderId: job.id,
                                                     milestone: milestone)) ?? nil
        return WhatsAppOffer(milestone: milestone, sentAt: sent)
    }

    /// The number a job's customer would be written to, or why not.
    func whatsAppRecipient(for job: Order) async -> WhatsAppChat {
        guard clientRecord(for: job) != nil else { return Self.refusedChat("no_customer") }
        return await whatsAppRecipient(phone: customerPhone(for: job))
    }

    func whatsAppRecipient(phone: String) async -> WhatsAppChat {
        guard !phone.trimmingCharacters(in: .whitespaces).isEmpty else {
            return Self.refusedChat("no_phone")
        }
        guard let engine else { return Self.refusedChat("no_phone") }
        return (try? await engine.whatsAppChat(phone: phone, text: "")) ?? Self.refusedChat("no_phone")
    }

    private static func refusedChat(_ reason: String) -> WhatsAppChat {
        WhatsAppChat(ok: false, reason: reason, e164: "", digits: "", link: "")
    }

    /// Open WhatsApp on the job's customer with this text typed in, and write
    /// it to the customer's log. Returns what to tell the shop, or nil when
    /// WhatsApp was opened.
    ///
    /// The link is built AGAIN from the text as it stands, not taken from the
    /// update: the shop may have changed the message in the box.
    ///
    /// The log line is written when WhatsApp is OPENED, because that is the
    /// last thing this app can see. Its note is the message itself, so a shop
    /// that did not press send in WhatsApp can see what it meant to say.
    func sendWhatsApp(for job: Order, text: String, milestone: String?,
                      lang: String?) async -> String? {
        guard let engine else { return words.callIt("mac.move_no_engine") }
        guard let record = clientRecord(for: job) else {
            return whatsAppReason("no_customer")
        }
        guard let chat = try? await engine.whatsAppChat(phone: record.client.phone, text: text),
              chat.ok, let url = URL(string: chat.link) else {
            return whatsAppReason((try? await engine.whatsAppChat(
                phone: record.client.phone, text: ""))?.reason ?? "no_phone")
        }
        NSWorkspace.shared.open(url)
        if case .object(let raw)? = try? await engine.whatsAppCommEntry(
            id: Self.uid("CMM"), at: Date(), text: text, orderId: job.id,
            milestone: milestone, lang: lang) {
            await addCommunication(CommEntry(raw: raw), to: record.client.id)
        }
        return nil
    }

    /// Open a WhatsApp chat with a customer, nothing typed. Nothing is
    /// logged: nothing has been said yet.
    func openWhatsAppChat(with client: Client) async -> String? {
        let chat = await whatsAppRecipient(phone: client.phone)
        guard chat.ok, let url = URL(string: chat.link) else { return whatsAppReason(chat.reason) }
        NSWorkspace.shared.open(url)
        return nil
    }

    /// Why a number cannot be used, in the shop's words.
    func whatsAppReason(_ reason: String) -> String {
        switch reason {
        case "", "empty", "no_phone": return words.callIt("mac.no_phone_for_whatsapp")
        default: return words.callIt("mac.wa_reason_" + reason,
                                     fallback: words.callIt("mac.no_phone_for_whatsapp"))
        }
    }

    /// A milestone in the shop's words.
    func whatsAppMilestoneName(_ milestone: String) -> String {
        words.callIt("mac.wa_m_" + milestone, fallback: milestone)
    }
}
