import SwiftUI
import AppKit
import KhaytCore

/// Sending a customer a WhatsApp update, or one of the shop's saved messages.
///
/// ── WHY THIS EXISTS BESIDE THE DRAFTER ────────────────────────────────────
///
/// This app already had one way to write to a customer: `DraftMessageSheet`,
/// which asks a model to compose something. That needs a key, a connection,
/// and a shop that has agreed to send a customer's details to a service — and
/// most shops have none of those. Meanwhile the book already holds messages the
/// shop wrote itself, in its own words, with its own placeholders.
///
/// ── THE MILESTONE UPDATES ─────────────────────────────────────────────────
///
/// First on the list are the four moments a customer cares about — received,
/// ready, shipped, delivered — in the CUSTOMER's language, from the shop's
/// template for that moment or Khayt's default words. The sheet opens on the
/// one the job is at. All of it is `lib/whatsapp-message.js`; this is the
/// screen.
///
/// ── AND IT STILL DOES NOT SEND BY ITSELF ──────────────────────────────────
///
/// The button hands the finished text to WhatsApp with the customer's number
/// already in it, normalised to the international form `wa.me` needs — a
/// local `05…` number opens WhatsApp on a chat with nobody. WhatsApp is what
/// opens, and a person presses send there. A message about somebody's order,
/// in the shop's name, is not something to put on the wire without a person
/// reading it — the same rule the drafter keeps, for the same reason.
struct MessageSheet: View {
    let shop: Shop
    let job: Order

    /// `m:<milestone>` for an update, `t:<template id>` for a saved message.
    @State private var choice = ""
    @State private var lang = "ar"
    @State private var milestones: [String] = []
    @State private var text = ""
    /// What the box held when it was last filled. The shop has edited the
    /// message when the two differ — worked out, not flagged by `onChange`,
    /// which also fires for the fill itself.
    @State private var filled = ""
    /// What `filled` was filled FROM, so a cancelled replace can go back.
    @State private var shownChoice = ""
    @State private var shownLang = "ar"
    @State private var reverting = false
    @State private var confirmReplace = false
    @State private var isDefault = false
    @State private var recipient: WhatsAppChat?
    @State private var problem: String?
    @State private var copied = false
    @State private var sending = false
    @State private var ready = false

    /// Saved messages for any time. A template for a milestone is not listed
    /// here: it is what that milestone's update says.
    private var saved: [MessageTemplate] { shop.messageTemplates.filter { $0.milestone.isEmpty } }
    private var edited: Bool { text != filled }
    private var milestone: String? {
        choice.hasPrefix("m:") ? String(choice.dropFirst(2)) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shop.words.callIt("mac.send_on_whatsapp")).font(.headline)
                Text(job.client.isEmpty ? job.project : "\(job.project) · \(job.client)")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }

            HStack(spacing: 12) {
                // A menu, so the saved messages are not rows in the sheet.
                Picker(shop.words.callIt("mac.message_template"), selection: $choice) {
                    ForEach(milestones, id: \.self) { m in Text(shop.whatsAppMilestoneName(m)).tag("m:" + m) }
                    Section(shop.words.callIt("mac.wa_saved_messages")) {
                        ForEach(saved) { one in Text(one.name).tag("t:" + one.id) }
                    }
                }
                if milestone != nil {
                    // The customer's language is chosen for the shop; this is
                    // the override for the customer it got wrong.
                    Picker(shop.words.callIt("mac.wa_language"), selection: $lang) {
                        Text(shop.words.callIt("mac.wa_lang_ar")).tag("ar")
                        Text(shop.words.callIt("mac.wa_lang_en")).tag("en")
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            .onChange(of: choice) { _, _ in changed() }
            .onChange(of: lang) { _, _ in changed() }

            if saved.isEmpty && milestones.isEmpty {
                // An empty picker over an empty box is a screen that looks
                // broken. The templates are written in Settings, and saying so
                // is the difference between a dead end and a next step.
                Label(shop.words.callIt("wa.no_templates"), systemImage: "text.bubble")
                    .font(.callout).foregroundStyle(.secondary)
            }

            TextEditor(text: $text)
                .font(.body)
                // A floor so an empty message is still a box worth typing in,
                // and a ceiling so a shop with a long template does not get a
                // sheet taller than its screen — a sheet cannot be moved, so
                // one that overflows hides its own buttons.
                .frame(minHeight: 120, maxHeight: 240)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                // The message's own direction, not the app's: an Arabic
                // message typed into a left-aligned box puts the cursor on the
                // wrong side.
                .environment(\.layoutDirection,
                             milestone != nil && lang == "ar" ? .rightToLeft : .leftToRight)

            if milestone != nil, isDefault, !edited {
                Text(shop.words.callIt("mac.wa_default_words"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            recipientLine

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(Khayt.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(shop.words.callIt(copied ? "mac.copied" : "mac.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }
                Spacer()
                Button(shop.words.callIt("common.close")) { shop.messagingFor = nil }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("mac.send_on_whatsapp")) { Task { await send() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(recipient?.ok != true || sending
                              || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 540)
        .confirmationDialog(shop.words.callIt("mac.replace_edited_message"),
                            isPresented: $confirmReplace) {
            Button(shop.words.callIt("mac.replace"), role: .destructive) {
                Task { await refill() }
            }
            Button(shop.words.callIt("common.cancel"), role: .cancel) { revert() }
        }
        .task { await start() }
    }

    /// Who it goes to, or — said plainly rather than by a disabled button
    /// with no explanation — why it cannot go: the fix is on the customer
    /// record, and a shop staring at a greyed-out button has not been told.
    @ViewBuilder
    private var recipientLine: some View {
        if let recipient {
            if recipient.ok {
                VStack(alignment: .leading, spacing: 2) {
                    // Isolated left-to-right, or an Arabic line moves the `+`
                    // to the wrong end of the number.
                    Label(shop.words.callIt("mac.wa_to", ["number": .string("\u{2066}" + recipient.e164 + "\u{2069}")]),
                          systemImage: "phone")
                        .font(.callout)
                    if shop.clientRecord(for: job) != nil {
                        Text(shop.words.callIt("mac.wa_logged_note"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Label(shop.whatsAppReason(recipient.reason), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func start() async {
        guard !ready else { return }
        milestones = (try? await shop.engine?.whatsAppMilestones()) ?? []
        recipient = await shop.whatsAppRecipient(for: job)
        let update = await shop.whatsAppUpdate(for: job)
        if let update { lang = update.lang }
        if let update, !update.milestone.isEmpty {
            choice = "m:" + update.milestone
        } else if let first = saved.first {
            choice = "t:" + first.id
        }
        await refill()
        ready = true
    }

    /// The picker or the language moved. Ask before throwing an edit away.
    private func changed() {
        guard ready else { return }
        if reverting { reverting = false; return }
        if edited { confirmReplace = true } else { Task { await refill() } }
    }

    /// The shop kept its edit: put the pickers back on what the box says.
    private func revert() {
        if choice != shownChoice { reverting = true; choice = shownChoice }
        else if lang != shownLang { reverting = true; lang = shownLang }
    }

    private func refill() async {
        if let milestone {
            let update = await shop.whatsAppUpdate(for: job, milestone: milestone, lang: lang)
            text = update?.text ?? ""
            isDefault = update?.isDefault ?? false
        } else if choice.hasPrefix("t:"),
                  let template = saved.first(where: { "t:" + $0.id == choice }) {
            text = shop.fillMessage(template, for: job)
            isDefault = false
        }
        filled = text
        shownChoice = choice
        shownLang = lang
        copied = false
        problem = nil
    }

    private func send() async {
        sending = true
        defer { sending = false }
        problem = await shop.sendWhatsApp(for: job, text: text, milestone: milestone,
                                          lang: milestone == nil ? nil : lang)
        if problem == nil { shop.messagingFor = nil }
    }
}
