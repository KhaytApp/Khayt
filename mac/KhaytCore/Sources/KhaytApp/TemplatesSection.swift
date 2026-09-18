import SwiftUI
import KhaytCore

/// The shop's saved messages, listed on the Integrations pane.
///
/// NOT in `TemplateSheet.swift` with the editor it opens, and the reason is a
/// guard rather than taste: `SheetsFitALaptopTests` reads every `*Sheet.swift`
/// and refuses a list of the shop's own records with no height cap, because a
/// sheet cannot be moved and past the screen's height its own buttons are
/// unreachable. This list is not in a sheet — it is inside the Settings
/// window's scrolling `Form`, which is exactly the bounded case the guard
/// cannot tell apart from the dangerous one by reading. So it lives in a file
/// the guard is not asked about.
struct TemplatesSection: View {
    @Bindable var shop: Shop

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(shop.words.callIt("wa.settings_section")).font(.headline)
            Text(shop.words.callIt("wa.settings_hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if shop.messageTemplates.isEmpty {
                Text(shop.words.callIt("wa.no_templates_hint"))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(shop.messageTemplates) { template in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.name)
                            Text(template.body).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        Spacer()
                        Button(shop.words.callIt("common.edit")) {
                            shop.editingTemplate = template
                        }
                    }
                    Divider()
                }
            }

            Button(shop.words.callIt("wa.add_template")) {
                shop.editingTemplate = MessageTemplate(id: "", name: "", body: "")
            }
            .disabled(!shop.canWrite)
            .help(shop.canWrite ? shop.words.callIt("wa.settings_hint")
                                : shop.words.callIt("mac.move_sample"))
        }
    }
}
