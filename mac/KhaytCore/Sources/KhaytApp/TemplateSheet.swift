import SwiftUI
import KhaytCore

/// Writing the messages a shop sends its customers.
///
/// ── WHY THIS EXISTS ───────────────────────────────────────────────────────
///
/// `MessageSheet` has always read `waTemplates` and this Mac could not write
/// one. A shop whose book carries none opened the sheet to an empty picker and
/// an empty box, with nothing on screen to say why or what to do — and the only
/// way to make a template was to open the other app. The templates ARE how a
/// shop talks to its customers, so that is a gap to close.
///
/// The placeholders are named on screen rather than documented elsewhere,
/// because a template that says `{{clientname}}` looks right while it is being
/// typed and sends the literal text to a customer.
struct TemplateSheet: View {
    @Bindable var shop: Shop
    /// The one being edited. A template with an empty id is a new one.
    let template: MessageTemplate

    @State private var name = ""
    /// Not `body` — that is the view.
    @State private var message = ""
    @State private var loaded = false
    /// The WhatsApp milestone this template speaks for, or empty.
    @State private var milestone = ""
    @State private var lang = ""
    @State private var milestones: [String] = []
    /// The default words last put in the box, so they can be swapped for
    /// another milestone's without asking — they are not the shop's edit.
    @State private var defaults = ""

    private var isNew: Bool { template.id.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shop.words.callIt(isNew ? "wa.new_tpl" : "wa.edit_tpl")).font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text(shop.words.callIt("wa.tpl_name")).font(.callout)
                TextField(shop.words.callIt("wa.tpl_name_ph"), text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            // ── WHEN IT IS SENT ───────────────────────────────────────────
            //
            // A template for a milestone replaces Khayt's default words for
            // that WhatsApp update — for customers in its language, or for all
            // of them when it has none. Choosing one with an empty box starts
            // from the default words, so a shop edits rather than writes.
            HStack(spacing: 12) {
                Picker(shop.words.callIt("mac.wa_milestone"), selection: $milestone) {
                    Text(shop.words.callIt("mac.wa_milestone_none")).tag("")
                    ForEach(milestones, id: \.self) { m in
                        Text(shop.whatsAppMilestoneName(m)).tag(m)
                    }
                }
                .fixedSize()
                if !milestone.isEmpty {
                    Picker(shop.words.callIt("mac.wa_language"), selection: $lang) {
                        Text(shop.words.callIt("mac.wa_any_language")).tag("")
                        Text(shop.words.callIt("mac.wa_lang_ar")).tag("ar")
                        Text(shop.words.callIt("mac.wa_lang_en")).tag("en")
                    }
                    .fixedSize()
                }
            }
            .onChange(of: milestone) { _, _ in startFromDefault() }
            .onChange(of: lang) { _, _ in startFromDefault() }

            VStack(alignment: .leading, spacing: 4) {
                Text(shop.words.callIt("wa.tpl_body")).font(.callout)
                TextEditor(text: $message)
                    .font(.body)
                    // A sheet cannot be moved, so a tall one hides its own
                    // buttons. Floor and ceiling both.
                    .frame(minHeight: 110, maxHeight: 220)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(shop.words.callIt("wa.tpl_hint")).font(.caption)
                    .foregroundStyle(.secondary)
                // From the rule, not a list typed here: a placeholder this app
                // offers that `WaTemplate.fill` does not replace would reach a
                // customer as its own text.
                Text(WaTemplate.placeholders.map { "{{\($0)}}" }.joined(separator: " · "))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let problem = shop.writeProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                if !isNew {
                    Button(shop.words.callIt("common.delete"), role: .destructive) {
                        shop.deleteTemplate(template.id)
                        if shop.writeProblem == nil { shop.editingTemplate = nil }
                    }
                }
                Spacer()
                Button(shop.words.callIt("common.cancel")) { shop.editingTemplate = nil }
                    .keyboardShortcut(.cancelAction)
                Button(shop.words.callIt("common.save")) {
                    shop.saveTemplate(id: isNew ? nil : template.id, name: name, body: message,
                                      milestone: milestone, lang: milestone.isEmpty ? "" : lang)
                    if shop.writeProblem == nil { shop.editingTemplate = nil }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                          || message.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 520)
        .task {
            guard !loaded else { return }
            loaded = true
            name = template.name
            message = template.body
            milestone = template.milestone
            lang = template.lang
            milestones = (try? await shop.engine?.whatsAppMilestones()) ?? []
        }
    }

    /// Put the default words in the box — only when the shop has not written
    /// anything of its own there, so changing the milestone never throws an
    /// edit away.
    private func startFromDefault() {
        guard loaded, message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || message == defaults else { return }
        guard !milestone.isEmpty else { return }
        let wanted = lang.isEmpty ? (shop.words.language == "en" ? "en" : "ar") : lang
        Task {
            let words = (try? await shop.engine?.whatsAppDefaultBody(milestone: milestone, lang: wanted)) ?? ""
            message = words
            defaults = words
        }
    }
}
