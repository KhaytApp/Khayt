import SwiftUI
import KhaytCore

/// Drafting a message to a customer about one job.
///
/// ── IT DRAFTS. IT DOES NOT SEND ───────────────────────────────────────────
///
/// The message comes back for the shop to read, change and send itself. That
/// is partly because this app cannot email — but it would be the right shape
/// even if it could: a message written about somebody's order, in the shop's
/// name, is not something to put on the wire before a person has read it.
///
/// So the draft lands in an editable box with Copy under it, and the shop sends
/// it through whatever it actually uses, which in this market is usually
/// WhatsApp.
///
/// ── AND WHAT TRAVELS IS THE DISCLOSURE'S LIST, EXACTLY ────────────────────
///
/// This is the one feature that sends another person's data, and the settings
/// screen names what: the customer's name, the order reference, project, status
/// and due date, and the amount and outstanding balance. The customer record is
/// right here and also holds an email address, a phone number and an address.
/// None of those is passed. See `AiClient.draftReply`.
struct DraftMessageSheet: View {
    let shop: Shop
    let job: Order

    @State private var intent = "status_update"
    @State private var note = ""
    @State private var drafted = ""
    @State private var problem: String?
    @State private var working = false
    @State private var intents: [KhaytEngine.ReplyIntent] = []
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shop.words.callIt("mac.draft_a_message")).font(.headline)
                Text(job.client.isEmpty
                     ? job.project
                     : "\(job.project) · \(job.client)")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }

            Picker(shop.words.callIt("mac.what_about"), selection: $intent) {
                ForEach(intents) { one in
                    // The rule's own words where the shop's locale has them,
                    // and the rule's English where it does not.
                    Text(shop.words.callIt("ai.reply_intent_" + one.id, fallback: one.label))
                        .tag(one.id)
                }
            }

            // Only for the intent that exists to carry it. A free-text box on
            // every intent invites a shop to type the message it was asking to
            // have written.
            if intent == "custom" {
                TextField(shop.words.callIt("mac.what_to_say"), text: $note, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...4)
            }

            HStack {
                Button(drafted.isEmpty
                       ? shop.words.callIt("mac.draft_it")
                       : shop.words.callIt("mac.draft_again")) {
                    Task { await draft() }
                }
                .disabled(working)
                if working {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }

            if !drafted.isEmpty {
                // EDITABLE. It is the shop's message, in the shop's name, and
                // a draft nobody can change is a draft nobody should send.
                TextEditor(text: $drafted)
                    .font(.body)
                    .frame(height: 150)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                HStack {
                    Button(shop.words.callIt("mac.copy_message")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(drafted, forType: .string)
                        copied = true
                    }
                    if copied {
                        Text(shop.words.callIt("mac.copied")).font(.caption)
                            .foregroundStyle(Khayt.done)
                    }
                    Spacer()
                }
                Text(shop.words.callIt("mac.draft_not_sent"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let problem {
                Text(problem).font(.callout).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(shop.words.callIt("common.close")) { shop.draftingFor = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 460)
        .task { intents = (try? await shop.engine?.replyIntents()) ?? [] }
    }

    private func draft() async {
        working = true
        problem = nil
        copied = false
        defer { working = false }
        switch await shop.draftMessage(for: job, intent: intent, note: note) {
        case .drafted(let text): drafted = text
        case .refused(let why): problem = why
        }
    }
}
