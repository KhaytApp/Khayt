import SwiftUI
import Observation
import KhaytCore

/// ⌘J's state: the query, the ranked rows, the cursor. `LibraryJumpPalette`
/// draws it; the tests drive it with no window at all.
///
/// The same discipline as ⌘K's `GoToModel`: nothing is read from the book
/// while typing — the index is built (or handed back) when the palette
/// opens — each keystroke is searched off the main actor after a short pause,
/// a longer query narrows the last one's matches, and an answer that comes
/// back after the field or the index moved on is dropped.
@MainActor @Observable
final class LibraryJumpModel {

    struct Row: Identifiable, Equatable {
        /// What the row is: `kind|id`, since a folder and a tag can share a
        /// name.
        let id: String
        let entry: GoToIndex.Entry
    }

    struct Answer: Equatable {
        let query: String
        let rows: [Row]
        /// Nothing typed: these are the most recently used models.
        let recent: Bool
        let loading: Bool

        static let empty = Answer(query: "", rows: [], recent: true, loading: true)
    }

    @ObservationIgnored let shop: Shop

    var query: String
    private(set) var answer = Answer.empty
    var cursor = 0

    private(set) var index: GoToIndex?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var last: (generation: Int, result: GoToIndex.Result)?

    init(shop: Shop, query: String = "") {
        self.shop = shop
        self.query = query
    }

    var rows: [Row] { answer.rows }

    // MARK: - Searching

    func load() async {
        let built = await shop.libraryJumpIndex()
        index = built
        generation += 1
        last = nil
        await search()
    }

    func search() async {
        let q = query
        let kinds = shop.libraryJumpKinds
        guard let index else {
            apply(Answer(query: q, rows: [], recent: q.isEmpty, loading: true))
            return
        }
        let started = generation
        let typed = !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard typed, !kinds.isEmpty else {
            let recent = kinds.contains(.model) ? LibraryJump.recent(index) : []
            apply(Answer(query: q, rows: recent.map(Self.row), recent: true, loading: false))
            return
        }
        let previous = last?.generation == started ? last?.result : nil
        let found = await Task.detached(priority: .userInitiated) {
            index.ranked(q, kinds: kinds, limit: LibraryJump.limit, narrowing: previous)
        }.value
        guard q == query, started == generation, kinds == shop.libraryJumpKinds else { return }
        last = (started, found.result)
        apply(Answer(query: q, rows: found.hits.map { Self.row($0.entry) }, recent: false, loading: false))
    }

    nonisolated static func row(_ entry: GoToIndex.Entry) -> Row {
        Row(id: entry.kind.rawValue + "|" + entry.id, entry: entry)
    }

    private func apply(_ next: Answer) {
        if next.rows.map(\.id) != answer.rows.map(\.id) { cursor = 0 }
        answer = next
    }

    // MARK: - The cursor and the keys

    func move(_ by: Int) {
        guard !rows.isEmpty else { return }
        cursor = min(max(0, cursor + by), rows.count - 1)
    }

    var selected: Row? { rows.indices.contains(cursor) ? rows[cursor] : nil }

    /// Return, with what was held: ⌘ for a quote, ⌥ for a job.
    func open(_ row: Row? = nil, modifiers: EventModifiers = []) {
        guard let row = row ?? selected else { return }
        let action = LibraryJump.action(command: modifiers.contains(.command), option: modifiers.contains(.option))
        shop.jump(to: row.entry, action)
    }
}

/// ⌘J — "Jump to in Library": one field, the library only.
///
/// ⌘K's palette with the library's rows: the same frame (`QuickPaletteFrame`)
/// and the same row (`QuickPaletteRow`), ranked best first across models,
/// folders, compressed files, tags and saved searches. ↩ opens (selects the
/// model in the grid and scrolls to it, or opens the folder or search),
/// ⌘↩ starts a quote from a model, ⌥↩ a job — each only where the menus'
/// Quote and New Job are enabled, and the foot line says only what works.
struct LibraryJumpPalette: View {
    @Bindable var shop: Shop
    @State private var model: LibraryJumpModel

    init(shop: Shop) {
        self.shop = shop
        _model = State(initialValue: LibraryJumpModel(shop: shop, query: shop.libraryJumpSeed))
    }

    var body: some View {
        QuickPaletteFrame(prompt: shop.words.callIt("mac.jump_prompt"),
                          label: shop.words.callIt("mac.jump"),
                          hint: shop.words.callIt(shop.canMoveJobs ? "mac.jump_hint" : "mac.jump_hint_open"),
                          query: $model.query,
                          close: { shop.jumping = false },
                          move: { model.move($0) },
                          submit: { model.open(modifiers: $0) }) {
            results
        }
        .task { await model.load() }
        .task(id: model.query) {
            try? await Task.sleep(for: GoToPalette.debounce)
            guard !Task.isCancelled else { return }
            await model.search()
        }
    }

    @ViewBuilder private var results: some View {
        let answer = model.answer
        if answer.rows.isEmpty {
            Text(answer.loading ? shop.words.callIt("mac.goto_loading")
                 : answer.recent ? "" : shop.words.callIt("mac.jump_none"))
                .font(TypeScale.body(12))
                .foregroundStyle(Role.text3)
                .frame(maxWidth: .infinity, minHeight: 44)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if answer.recent {
                            Text(shop.words.callIt("mac.jump_recent"))
                                .font(TypeScale.label(9.5))
                                .foregroundStyle(Role.text3)
                                .padding(.horizontal, Space.lg)
                                .padding(.top, Space.md)
                                .padding(.bottom, Space.xs)
                        }
                        ForEach(Array(answer.rows.enumerated()), id: \.element.id) { at, row in
                            QuickPaletteRow(symbol: GoToPalette.symbol(for: row.entry), title: row.entry.title,
                                            subtitle: row.entry.subtitle, selected: at == model.cursor)
                                .id(row.id)
                                .contentShape(Rectangle())
                                .onTapGesture { model.open(row) }
                        }
                    }
                    .padding(.vertical, Space.xs)
                }
                .onChange(of: model.cursor) { _, _ in
                    if let id = model.selected?.id { proxy.scrollTo(id) }
                }
            }
        }
    }
}
