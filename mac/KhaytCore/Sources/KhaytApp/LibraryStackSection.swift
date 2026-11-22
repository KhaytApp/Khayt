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
                memberList(members, cover: members.first?.id)
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
                Text(w.counting(others.count, "mac.stk_suggest")
                    .replacingOccurrences(of: "{why}", with: w.callIt(Shop.stackReasonKey(suggestion.reason))))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                memberList(others, cover: nil)
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

    /// The members, by title: the stack's cover (the one on top, which
    /// "Show on Top of Stack" changes) marked with a stack, THIS model in
    /// bold. Not a radio list — each row is a plain button that shows that
    /// member in the inspector.
    private func memberList(_ members: [LibraryFile], cover: LibraryFile.ID?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(members.prefix(12)) { m in
                Button { shop.fileSelection = [m.id] } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.stack.fill")
                            .font(.caption2)
                            .foregroundStyle(Khayt.brand)
                            .opacity(m.id == cover ? 1 : 0)
                            .accessibilityHidden(true)
                        Text(m.title)
                            .font(m.id == file.id ? .caption.weight(.semibold) : .caption)
                            .foregroundStyle(m.id == file.id ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(m.id == file.id)
                .help(m.id == cover ? m.title + " — " + shop.words.callIt("mac.stk_cover") : m.title)
            }
            if members.count > 12 {
                Text(shop.words.callIt("mac.stk_more", ["n": .string(shop.words.numeral(members.count - 12))]))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
