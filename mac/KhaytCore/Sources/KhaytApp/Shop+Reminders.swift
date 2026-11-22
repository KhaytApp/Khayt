import Foundation
import KhaytCore

/// "Send reminder": a payment reminder to a job's customer, from Today's chase
/// list or the job's inspector, and recorded on the job once it has gone.
///
/// ── WHAT DECIDES WHAT ─────────────────────────────────────────────────────
///
/// `lib/payment-reminder.js`, shared with the other app: which invoices are due
/// (milestone proformas with a due date included), how much a reminder asks
/// for, which way it goes (`reminderChannel`: the shop's choice, else WhatsApp
/// when the customer has a number, else email), the shop's own pay link with
/// the amount in it, and the record a sent reminder leaves
/// (`markReminderPatch`) — which is what lets the cooldown and the
/// three-reminder cap work on this Mac, where nothing wrote it before.
///
/// The words are the shop's template `tpl-payment`, as the other app's 💰
/// reminder uses, or Khayt's own default; the figures are the job's own
/// currency (`whatsAppValues`).
extension Shop {

    /// Send a payment reminder for job `id` the way the shop sends them, and
    /// record it once sent. On screen: what was done, or why not.
    func sendPaymentReminder(_ id: Order.ID) async {
        moveProblem = nil
        guard permitted("orders", "edit") else { return }
        guard let engine, let job = orders.first(where: { $0.id == id }), let row = orderRow(id) else {
            moveProblem = words.callIt("mac.move_gone"); return
        }
        let settings = settingsDict
        let client = clientRecord(for: job)
        let plan: KhaytEngine.ReminderPlan
        do {
            plan = try await engine.reminderPlan(order: row, owed: job.owedInOwnCurrency,
                                                 settings: settings, client: client?.row)
        } catch {
            moveProblem = said(error); return
        }
        guard plan.amount > 0.005 else { moveProblem = words.callIt("inst.nothing_owed"); return }
        guard plan.channel != "none" else { moveProblem = words.callIt("mac.reminder_no_way"); return }

        let text = await reminderText(for: job, plan: plan)
        switch plan.channel {
        case "email":
            guard let mail = try? await engine.reminderEmail(
                settings: settings, client: client?.row, text: text,
                subject: words.callIt("pay.remind_subject", ["shop": .string(shopName)]),
                shopName: shopName),
                  await canEmailThrough(mail.provider) else {
                moveProblem = words.callIt("mac.reminder_no_way"); return
            }
            await post(mail)
            // `post` says a failure in `moveProblem`; a reminder that did not
            // go is not recorded as sent.
            if moveProblem != nil { return }
        default:
            if let why = await sendWhatsApp(for: job, text: text, milestone: nil, lang: nil) {
                moveProblem = why; return
            }
        }
        await recordReminderSent(id)
    }

    /// The reminder's words for a job: the shop's `tpl-payment`, else Khayt's
    /// default, with the amount ASKED FOR (the balance, or the milestones that
    /// are due) in the job's own currency, and the pay link after.
    func reminderText(for job: Order, plan: KhaytEngine.ReminderPlan) async -> String {
        let name = job.client.isEmpty ? job.project : job.client
        var values = whatsAppValues(for: job)
        // The amount asked for, in the JOB's currency — the one it is owed in
        // (as its code: see `whatsAppValues`).
        values["currency"] = job.currency.isEmpty ? currency : job.currency
        values["price"] = Money.figure(plan.amount)
        values["client"] = name
        values["id"] = job.id
        values["shop"] = shopName
        let template = messageTemplates.first { $0.id == "tpl-payment" }?.body
        let body = template ?? words.callIt("pay.remind_default", [
            "name": .string(name), "id": .string(job.id),
            "amount": .string(Money.figure(plan.amount) + " " + (values["currency"] ?? currency)),
        ])
        return (try? await engine?.reminderText(body: body, values: values, payLink: plan.payLink,
                                                payLabel: words.callIt("pay.remind_pay_here"))) ?? body
    }

    /// The sent reminder on the job (`payRemindedAt`, `payReminderCount`), so
    /// Today stops listing it for the cooldown and stops for good at the cap.
    func recordReminderSent(_ id: Order.ID, now: Date = Date()) async {
        let kept = moveNotices
        let wrote = await writeToOneOrder(id, named: words.callIt("mac.send_reminder"),
                                          as: .person("orders", "edit")) { order, engine, _ in
            OneOrderEdit(order: try await engine.markReminder(order: order, now: now),
                         activity: "\(id) → " + self.words.callIt("mac.send_reminder"))
        }
        if wrote {
            moveNotices = kept + [words.callIt("mac.reminder_sent", ["id": .string(id)])]
        }
    }
}
