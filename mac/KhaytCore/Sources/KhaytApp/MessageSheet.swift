import SwiftUI
import AppKit
import KhaytCore

/// Sending a customer one of the shop's own saved messages.
///
/// ── WHY THIS EXISTS BESIDE THE DRAFTER ────────────────────────────────────
///
/// This app already had one way to write to a customer: `DraftMessageSheet`,
/// which asks a model to compose something. That needs a key, a connection,
/// and a shop that has agreed to send a customer's details to a service — and
/// most shops have none of those. Meanwhile the book already holds messages the
/// shop wrote itself, in its own words, with its own placeholders. This shop
/// has three. Nothing on this Mac could read them.
///
/// So: pick one, see it filled in, change anything, and send. No key, no
/// network, nothing leaves the Mac except the message the shop pressed send on.
///
/// ── AND IT STILL DOES NOT SEND BY ITSELF ──────────────────────────────────
///
/// The button hands the finished text to WhatsApp with the customer's number
/// already in it. WhatsApp is what opens, and a person presses send there. A
/// message about somebody's order, in the shop's name, is not something to put
/// on the wire without a person reading it — the same rule the drafter keeps,
/// for the same reason.
struct MessageSheet: View {
    let shop: Shop
    let job: Order

    @State private var chosen: String = ""
    @State private var text: String = ""
    @State private var copied = false
    /// Whether the shop has edited the text. Once it has, changing template
    /// must not silently throw the edit away.
    @State private var edited = false
    @State private var confirmReplace = false

    private var templates: [MessageTemplate] { shop.messageTemplates }
    private var phone: String { shop.customerPhone(for: job) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shop.words.callIt("mac.send_a_message")).font(.headline)
                Text(job.client.isEmpty ? job.project : "\(job.project) · \(job.client)")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }

            Picker(shop.words.callIt("mac.message_template"), selection: $chosen) {
                ForEach(templates) { one in Text(one.name).tag(one.id) }
            }
            .onChange(of: chosen) { _, id in
                guard edited else { refill(id); return }
                // The shop typed something. Ask before replacing it.
                confirmReplace = true
            }

            TextEditor(text: $text)
                .font(.body)
                // A floor so an empty message is still a box worth typing in,
                // and a ceiling so a shop with a long template does not get a
                // sheet taller than its screen — a sheet cannot be moved, so
                // one that overflows hides its own buttons.
                .frame(minHeight: 120, maxHeight: 260)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                .onChange(of: text) { _, _ in edited = true }

            if phone.isEmpty {
                // Said plainly rather than by a disabled button with no
                // explanation: the fix is on the customer record, and a shop
                // staring at a greyed-out button has not been told that.
                Label(shop.words.callIt("mac.no_phone_for_whatsapp"),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
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
                Button(shop.words.callIt("mac.open_whatsapp")) {
                    MessageSheet.openWhatsApp(phone: phone, message: text)
                    shop.messagingFor = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(phone.isEmpty || text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 520)
        .confirmationDialog(shop.words.callIt("mac.replace_edited_message"),
                            isPresented: $confirmReplace) {
            Button(shop.words.callIt("mac.replace"), role: .destructive) { refill(chosen) }
            Button(shop.words.callIt("common.cancel"), role: .cancel) {}
        }
        .task {
            guard chosen.isEmpty, let first = templates.first else { return }
            chosen = first.id
            refill(first.id)
        }
    }

    private func refill(_ id: String) {
        guard let template = templates.first(where: { $0.id == id }) else { return }
        text = shop.fillMessage(template, for: job)
        edited = false
        copied = false
    }

    /// Hand the message to WhatsApp with the number already in it.
    ///
    /// `wa.me` wants digits and nothing else — no `+`, no spaces, no dashes —
    /// and a number with any of those in it opens WhatsApp on a blank chat,
    /// which looks like the feature not working.
    static func openWhatsApp(phone: String, message: String) {
        let digits = phone.filter(\.isWholeNumber)
        guard !digits.isEmpty else { return }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "wa.me"
        parts.path = "/" + digits
        parts.queryItems = [URLQueryItem(name: "text", value: message)]
        guard let url = parts.url else { return }
        NSWorkspace.shared.open(url)
    }
}
