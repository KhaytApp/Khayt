import Foundation
import KhaytCore

/// "Send with Pay Link" on the invoice sheet: the invoice's amount owed and the
/// shop's own pay link, to the customer, the way a payment reminder goes.
///
/// Nothing here decides money. The amount asked for and the link with that
/// amount in it are `lib/payment-reminder.js` (`reminderPlan`); the words are
/// `reminderText`, the shop's `tpl-payment` or Khayt's default; the WhatsApp
/// chat and its log line are `sendWhatsApp`. This file only chooses the way
/// out: WhatsApp when the customer has a number, else the share picker with
/// the PDF and the same text.
///
/// It does NOT count as a reminder (`markReminder`): handing over the invoice
/// is not chasing it, and counting it would spend one of the three reminders
/// Today is allowed before the shop has asked for anything.
extension Shop {

    /// Whether a job is one the sheet may ask money for: real work (never a
    /// quote, which is chased by its own follow-up; never cancelled work)
    /// with something still owed. The inspector's "Send reminder" rule.
    static func owesForPayLink(_ job: Order) -> Bool {
        job.status != "quote" && job.status != "cancelled" && !job.isSettled
    }

    /// Whether a plan has something to send: an amount, and a link to pay it.
    static func offersPayLink(_ plan: KhaytEngine.ReminderPlan?) -> Bool {
        guard let plan else { return false }
        return plan.amount > 0.005 && !plan.payLink.isEmpty
    }

    /// The reminder plan for job `id` when the sheet should offer Send with
    /// Pay Link — the job owes money AND the shop has a pay link — else nil.
    func payLinkPlan(for id: Order.ID) async -> KhaytEngine.ReminderPlan? {
        guard let engine, let job = orders.first(where: { $0.id == id }),
              Self.owesForPayLink(job), let row = orderRow(id) else { return nil }
        let plan = try? await engine.reminderPlan(order: row, owed: job.owedInOwnCurrency,
                                                  settings: settingsDict,
                                                  client: clientRecord(for: job)?.row)
        return Self.offersPayLink(plan) ? plan : nil
    }

    /// Send it. WhatsApp when the customer has a usable number (text only:
    /// a chat link cannot carry a file); otherwise the share picker with the
    /// invoice PDF and the same text. Returns what to tell the shop, or nil.
    func sendWithPayLink(_ id: Order.ID, plan: KhaytEngine.ReminderPlan,
                         pdf: @MainActor () async -> URL?) async -> String? {
        guard let job = orders.first(where: { $0.id == id }) else { return words.callIt("mac.move_gone") }
        let text = await reminderText(for: job, plan: plan)
        if await whatsAppRecipient(for: job).ok {
            return await sendWhatsApp(for: job, text: text, milestone: nil, lang: nil)
        }
        var items: [Any] = []
        if let url = await pdf() { items.append(url) }
        items.append(text)
        Self.presentSharePicker(items)
        return nil
    }
}
