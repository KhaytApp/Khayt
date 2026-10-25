import SwiftUI
import KhaytCore

/// ⌘K — "Go to…": one field, the whole book.
///
/// A small panel over the window, centred and near the top, the way Spotlight
/// and every editor's quick-open sit. Type, and it lists jobs, customers,
/// library models, catalogue products, machines and the app's own screens and
/// commands, grouped and best first. ↑/↓ move, ↩ opens, Esc closes.
///
/// ── WHAT EACH KEYSTROKE COSTS ───────────────────────────────────────────────
///
/// Nothing is read from the book while typing. The index is built when the
/// palette opens — or handed back from the last open if the book has not
/// changed since (`Shop.goToIndex`) — and each keystroke runs `GoToIndex.search`
/// over it, off the main actor, after a short pause so a fast typist does not
/// search five times for one word. A keystroke that extends the last query
/// searches only what the last one matched.
///
/// ── IN THE WINDOW, NOT A SHEET ──────────────────────────────────────────────
///
/// A sheet hangs from the title bar and greys out the window, which is the
/// wrong gesture for something opened, used and gone in two seconds. An
/// overlay inherits the window's mirroring (`Direction`) and its appearance,
/// so it is right-to-left in Arabic and dark in dark mode without a line of
/// its own saying so.
struct GoToPalette: View {
    @Bindable var shop: Shop
    /// The query, the answer and the cursor — see `GoToModel`, which the
    /// tests drive without this view.
    @State private var model: GoToModel

    init(shop: Shop) {
        self.shop = shop
        _model = State(initialValue: GoToModel(shop: shop))
    }

    /// The pause before a search — long enough to fold a burst of keys into
    /// one, short enough that nobody waits for it.
    static let debounce: Duration = .milliseconds(60)

    var body: some View {
        // The chrome is shared with ⌘J (`QuickPaletteFrame`); the rows and
        // what Return does are this palette's own.
        QuickPaletteFrame(prompt: shop.words.callIt("mac.goto_prompt"),
                          label: shop.words.callIt("mac.goto"),
                          hint: shop.words.callIt("mac.goto_hint"),
                          query: $model.query,
                          close: { shop.goingTo = false },
                          move: { model.move($0) },
                          submit: { _ in model.open() }) {
            results
        }
        // The index, once; then whatever is in the field by the time it is
        // ready is answered again (`GoToModel.load`).
        .task { await model.load() }
        .task(id: model.query) {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await model.search()
        }
    }

    /// The answer, drawn from one value: each section's heading with its own
    /// rows, every row identified by what it is. A plain `VStack` — at most
    /// six groups of eight, nothing a lazy stack would save, and no cache of
    /// rows for a new answer to be drawn under (see `GoToModel`).
    @ViewBuilder private var results: some View {
        let answer = model.answer
        if answer.sections.isEmpty {
            Text(answer.loading ? shop.words.callIt("mac.goto_loading")
                 : answer.query.trimmingCharacters(in: .whitespaces).isEmpty ? "" : shop.words.callIt("mac.goto_none"))
                .font(TypeScale.body(12))
                .foregroundStyle(Role.text3)
                .frame(maxWidth: .infinity, minHeight: 44)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(answer.sections) { section in
                            Text(section.title)
                                .font(TypeScale.label(9.5))
                                .foregroundStyle(Role.text3)
                                .padding(.horizontal, Space.lg)
                                .padding(.top, Space.md)
                                .padding(.bottom, Space.xs)
                            ForEach(section.rows) { item in
                                row(item.entry, selected: item.index == model.cursor)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.open(item) }
                            }
                        }
                        if answer.loading {
                            Text(shop.words.callIt("mac.goto_loading"))
                                .font(TypeScale.body(11))
                                .foregroundStyle(Role.text3)
                                .padding(.horizontal, Space.lg)
                                .padding(.vertical, Space.sm)
                        }
                    }
                    .padding(.bottom, Space.sm)
                }
                .onChange(of: model.cursor) { _, _ in
                    if let id = model.selected?.id { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func row(_ entry: GoToIndex.Entry, selected: Bool) -> some View {
        QuickPaletteRow(symbol: Self.symbol(for: entry), title: entry.title,
                        subtitle: entry.subtitle, selected: selected)
    }

    static func symbol(for entry: GoToIndex.Entry) -> String {
        switch entry.kind {
        case .job: "doc.text"
        case .customer: "person"
        case .model: "cube"
        case .product: "tag"
        case .machine: "printer"
        case .screen: entry.id.hasPrefix("command:") ? "command" : "rectangle.stack"
        case .folder: "folder"
        case .archive: "doc.zipper"
        case .tag: "number"
        case .search: "line.3.horizontal.decrease.circle"
        }
    }
}
