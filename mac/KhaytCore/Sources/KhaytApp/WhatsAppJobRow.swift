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

    /// A new line in the log, a move, a shipment — any of them can change the
    /// answer, so the look is keyed on all of it.
    private var key: String {
        let log = shop.clientRecord(for: job)?.client.commLog.count ?? 0
        return [job.id, job.status, job.shippedAt ?? "", job.deliveredAt ?? "",
                job.clientId ?? "", String(log)].joined(separator: "|")
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
                Button(shop.words.callIt("mac.send_on_whatsapp")) { shop.messagingFor = job }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
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
        .task(id: key) {
            offer = await shop.whatsAppOffer(for: job)
        }
    }
}
