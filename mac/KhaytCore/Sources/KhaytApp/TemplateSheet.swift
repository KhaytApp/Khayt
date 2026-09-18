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

    private var isNew: Bool { template.id.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(shop.words.callIt(isNew ? "wa.new_tpl" : "wa.edit_tpl")).font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text(shop.words.callIt("wa.tpl_name")).font(.callout)
                TextField(shop.words.callIt("wa.tpl_name_ph"), text: $name)
                    .textFieldStyle(.roundedBorder)
            }

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
                    shop.saveTemplate(id: isNew ? nil : template.id, name: name, body: message)
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
        }
    }
}
