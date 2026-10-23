import SwiftUI
import KhaytCore

/// The job's WhatsApp line in the inspector, with the divider above it.
///
/// When the job has reached a moment the customer cares about and the update
/// for it has not been opened in WhatsApp yet, it says so and offers the
/// button prominently — that is the "offer" at a milestone, worked out from
/// the job and the customer's log rather than from whichever screen happened
/// to make the move, so a job moved on the phone, by a carrier's webhook or in
/// the other app is offered the same update. Once sent, it says when, and the
/// button stays for a second message.
///
/// A job with no milestone (a quote, a cancelled job) and a book with no saved
/// messages has nothing to offer, and draws nothing — not even the divider.
struct WhatsAppJobRow: View {
    let shop: Shop
    let job: Order

    @State private var offer: Shop.WhatsAppOffer?
    /// The update as WhatsApp Business would send it now, when it can.
    @State private var business: WhatsAppCloudMessage?
    @State private var sending = false

    /// A new line in the log, a move, a shipment — any of them can change the
    /// answer, so the look is keyed on all of it.
    private var key: String {
        let client = shop.clientRecord(for: job)?.client
        let log = client?.commLog.count ?? 0
        return [job.id, job.status, job.shippedAt ?? "", job.deliveredAt ?? "",
                job.clientId ?? "", String(log), client?.phone ?? "",
                client?.whatsAppConsent?.at ?? ""].joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if offer != nil || !shop.messageTemplates.isEmpty {
                Divider()
            }
            if let offer, offer.sentAt == nil {
                Text(shop.words.callIt("mac.wa_update_due",
                                       ["m": .string(shop.whatsAppMilestoneName(offer.milestone))]))
                    .font(.callout.weight(.medium))
                if let business, business.send {
                    // The shop's approved template, sent for it — the same
                    // send a move makes, for a job that reached this step
                    // somewhere the move could not send it (a failed send, the
                    // phone, the other app).
                    HStack {
                        Button(shop.words.callIt("mac.wab_send_now")) {
                            sending = true
                            Task {
                                if let problem = await shop.sendWhatsAppBusiness(business, jobId: job.id) {
                                    shop.moveProblem = problem
                                }
                                sending = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(sending)
                        Button(shop.words.callIt("mac.wab_write_myself")) { shop.messagingFor = job }
                            .buttonStyle(.link)
                            .font(.callout)
                    }
                } else {
                    Button(shop.words.callIt("mac.send_on_whatsapp")) { shop.messagingFor = job }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            } else {
                if let offer, let at = offer.sentAt {
                    Text(shop.words.callIt("mac.wa_update_sent", [
                        "m": .string(shop.whatsAppMilestoneName(offer.milestone)),
                        "day": .string(Calendar.localDay(ofInstant: at)),
                    ]))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                // Also for a quote when the book has saved messages: the sheet
                // lists them.
                if offer != nil || !shop.messageTemplates.isEmpty {
                    Button(shop.words.callIt("mac.send_on_whatsapp")) { shop.messagingFor = job }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
        }
        .task(id: key + "|" + shop.settingsValue.hashValue.description) {
            offer = await shop.whatsAppOffer(for: job)
            business = shop.whatsAppBusinessAccount() == nil ? nil
                : await shop.whatsAppBusinessMessage(before: nil, jobId: job.id, now: true)
        }
    }
}
