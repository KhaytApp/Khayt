import SwiftUI
import KhaytCore

/// The inspector's Variants section: the stack this model is in, or the one
/// the library suggests for it, and Find Similar.
///
/// A suggestion is only ever offered — "Stack them" is the shop's choice. A
/// suggestion made on shape alone says what Library Health says about it: a
/// mirrored part has the same shape figures as its twin.
struct StackSection: View {
    let shop: Shop
    let file: LibraryFile

    var body: some View {
        let w = shop.words
        VStack(alignment: .leading, spacing: 10) {
            if let s = shop.stackOf(file) {
                let members = shop.stackMembers(s)
                Text(w.callIt("mac.stk_in_stack", ["variants": .string(w.counting(members.count, "mac.stk_n_variants"))]))
                    .font(.callout)
                memberList(members)
                FlowLayout(spacing: 8) {
                    Button(w.callIt(shop.isStackOpen(s) ? "mac.stk_hide" : "mac.stk_show")) { shop.toggleStackOpen(s) }
                    if members.first?.id != file.id {
                        Button(w.callIt("mac.stk_make_cover")) { shop.makeStackCover(file.id) }
                            .disabled(!shop.canWrite)
                    }
                    Button(w.callIt("mac.stk_remove")) { shop.removeFromStack([file.id]) }
                        .disabled(!shop.canWrite)
                    Button(w.callIt("mac.stk_unstack")) { shop.unstack(s) }
                        .disabled(!shop.canWrite)
                }
                .controlSize(.small)
            } else if let suggestion = shop.stackSuggestion(for: file) {
                let others = suggestion.ids.filter { $0 != file.id }.compactMap(shop.libraryFile(id:))
                Text(w.callIt("mac.stk_suggest", ["variants": .string(w.counting(others.count, "mac.stk_n_variants")),
                                                  "why": .string(w.callIt(Shop.stackReasonKey(suggestion.reason)))]))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                memberList(others)
                if suggestion.reason == .sameShape {
                    Label(w.callIt("mac.lh_mirror_note"), systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(w.callIt("mac.stk_accept", ["variants": .string(w.counting(others.count, "mac.stk_n_variants"))])) {
                    shop.acceptStackSuggestion(suggestion, cover: file.id)
                }
                .controlSize(.small)
                .disabled(!shop.canWrite)
            } else {
                Text(w.callIt("mac.stk_none")).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Button { shop.findSimilar(to: file) } label: {
                Label(w.callIt("mac.sim_find"), systemImage: "square.on.square.dashed")
            }
            .controlSize(.small)
            .help(w.callIt("mac.sim_help"))
        }
    }

    /// The members, by title — the cover marked.
    private func memberList(_ members: [LibraryFile]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(members.prefix(12)) { m in
                HStack(spacing: 6) {
                    Image(systemName: m.id == file.id ? "circle.inset.filled" : "circle")
                        .font(.caption2)
                        .foregroundStyle(m.id == file.id ? AnyShapeStyle(Khayt.brand) : AnyShapeStyle(.tertiary))
                        .accessibilityHidden(true)
                    Text(m.title).font(.caption).lineLimit(1).truncationMode(.middle)
                }
                .help(m.title)
            }
            if members.count > 12 {
                Text(shop.words.callIt("mac.stk_more", ["n": .string(shop.words.numeral(members.count - 12))]))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
