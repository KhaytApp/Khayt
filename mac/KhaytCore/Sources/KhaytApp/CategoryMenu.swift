import SwiftUI

/// Saying what models ARE, and tagging them.
///
/// ── WHY THIS EXISTS ───────────────────────────────────────────────────────
///
/// The library could be narrowed by category and by tag and neither could be
/// SET from this Mac. `GroupMenu` files a model into a project; nothing wrote
/// `category`, and nothing but an import ever wrote `tags`. So the chips that
/// answer "show me the wall art" would have stayed empty on a real book for
/// ever — a hundred and fifty-two models here, none of them carrying either —
/// and the only way to fill them was to open the other app. That is a gap to
/// close, not a difference to write down.
///
/// ── THE THREE AXES ARE NOT THE SAME QUESTION ──────────────────────────────
///
/// A GROUP is the set a model belongs to: the seven Saudi Kings, offerable as
/// one collection, and a folder in the grid. A CATEGORY is what a thing IS:
/// wall art, a functional part, a dental model — many models, no folder, and
/// the answer to a question asked when you do not yet know what you want. TAGS
/// are everything neither covers, several per model.
///
/// Which is why this is a second menu beside the first rather than a second
/// entry inside it.
struct CategoryMenu: View {
    @Bindable var shop: Shop
    @State private var naming = false
    @State private var tagging = false
    @State private var typed = ""
    @State private var typedTags = ""

    private var count: Int { shop.fileSelection.count }

    var body: some View {
        Menu {
            if count == 0 {
                Text(shop.words.callIt("mac.pick_a_model"))
            } else {
                ForEach(shop.categoriesInUse, id: \.self) { category in
                    Button {
                        Task { await shop.fileSelection(underCategory: category) }
                    } label: {
                        // A tick against the one they are all already in, so the
                        // menu says where they are as well as offering to move
                        // them — the same as the group menu's.
                        if allAlreadyIn(category) { Label(category, systemImage: "checkmark") }
                        else { Text(category) }
                    }
                }
                if !shop.categoriesInUse.isEmpty { Divider() }
                Button(shop.words.callIt("mac.new_category")) { typed = ""; naming = true }
                if shop.selectedFiles.contains(where: { !($0.category ?? "").isEmpty }) {
                    Button(shop.words.callIt("mac.remove_from_category")) {
                        Task { await shop.fileSelection(underCategory: "") }
                    }
                }
                Divider()
                Button(shop.words.callIt("mac.tags") + "\u{2026}") {
                    typedTags = shop.tagsOnSelection.joined(separator: ", ")
                    tagging = true
                }
            }
        } label: {
            Label(count > 1
                  ? shop.words.callIt("mac.category_n_models", ["n": .number(Double(count))])
                  : shop.words.callIt("mac.category"),
                  systemImage: "tag")
        }
        .disabled(!shop.canWrite || count == 0)
        .help(shop.canWrite
              ? shop.words.callIt("mac.category_why")
              : shop.words.callIt("mac.group_locked"))
        .popover(isPresented: $naming, arrowEdge: .bottom) {
            NameIt(words: shop.words, typed: $typed,
                   title: shop.words.callIt("mac.name_this_category"),
                   example: shop.words.callIt("mac.category_example"),
                   note: shop.words.callIt("mac.group_name_kept"),
                   confirm: shop.words.callIt("mac.file_it")) { name in
                naming = false
                let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !wanted.isEmpty else { return }
                Task { await shop.fileSelection(underCategory: wanted) }
            }
        }
        .popover(isPresented: $tagging, arrowEdge: .bottom) {
            NameIt(words: shop.words, typed: $typedTags,
                   title: shop.words.callIt("mac.tags"),
                   example: shop.words.callIt("mac.tag_example"),
                   // Two sentences, because two things are surprising: a tag
                   // already in use keeps its spelling, and what is typed here
                   // REPLACES what every selected model carried.
                   note: shop.words.callIt("mac.group_name_kept") + " "
                       + shop.words.callIt("mac.tags_replaced"),
                   confirm: shop.words.callIt("mac.file_it")) { line in
                tagging = false
                Task { await shop.tagSelection(line) }
            }
        }
    }

    private func allAlreadyIn(_ category: String) -> Bool {
        let chosen = shop.selectedFiles
        return !chosen.isEmpty
            && chosen.allSatisfy { ($0.category ?? "").lowercased() == category.lowercased() }
    }
}

/// One typed line, with a title, an example and a sentence saying what happens.
///
/// `GroupMenu` has its own copy of this shape — deliberately left alone rather
/// than folded in here, because that one is reached from a different menu and
/// changing it is a change to a screen this work was not asked to touch. If a
/// third appears, they should all become this.
struct NameIt: View {
    let words: Words
    @Binding var typed: String
    let title: String
    let example: String
    let note: String
    let confirm: String
    let done: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            TextField(example, text: $typed)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .focused($focused)
                .onSubmit { done(typed) }
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(confirm) { done(typed) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .onAppear { focused = true }
    }
}
