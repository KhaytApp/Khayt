import Observation
import SwiftUI

/// The choices under File ▸ Export Model Bundle…'s save panel: the price, the
/// group, and every file beside the model with a tick of its own.
///
/// Nothing here is ticked to begin with (beta.8 review). The panel promises
/// "never a customer's name", and the two things that most often carry one are
/// exactly these: a group called "Customers/Noura", and a quote or brief PDF
/// the shop dropped into the model's folder. So the shop sees each by name and
/// sends it on purpose, or it stays home.
struct BundleExportOptions: View {

    struct Paper: Identifiable, Equatable, Sendable {
        /// The member path it would have in the bundle (`settings/…`).
        let path: String
        /// The file's own name, as the shop knows it.
        let name: String
        var id: String { path }
    }

    @MainActor @Observable
    final class Model {
        let hasPrice: Bool
        let group: String?
        let papers: [Paper]
        var includePrice = false
        var includeGroup = false
        var ticked: Set<String> = []

        init(hasPrice: Bool, group: String?, papers: [Paper]) {
            self.hasPrice = hasPrice
            self.group = (group?.isEmpty ?? true) ? nil : group
            self.papers = papers
        }

        var choice: Shop.BundleChoice {
            Shop.BundleChoice(includePrice: hasPrice && includePrice, includeGroup: group != nil && includeGroup,
                              papers: ticked)
        }

        func binding(_ paper: Paper) -> Binding<Bool> {
            Binding(get: { self.ticked.contains(paper.path) },
                    set: { on in if on { self.ticked.insert(paper.path) } else { self.ticked.remove(paper.path) } })
        }
    }

    @Bindable var model: Model
    let words: Words

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(words.callIt("mac.mb_include_price"), isOn: $model.includePrice)
                .disabled(!model.hasPrice)
            if let group = model.group {
                Toggle(words.callIt("mac.mb_include_group", ["group": .string(group)]), isOn: $model.includeGroup)
            }
            if !model.papers.isEmpty {
                Text(words.callIt("mac.mb_papers"))
                    .font(.callout.weight(.medium))
                    .padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(model.papers) { paper in
                    Toggle(isOn: model.binding(paper)) { Text(verbatim: paper.name) }
                        .padding(.leading, 12)
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(12)
        .frame(minWidth: 360, alignment: .leading)
    }
}
