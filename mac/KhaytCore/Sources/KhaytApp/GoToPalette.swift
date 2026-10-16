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

    @State private var query = ""
    /// The book's index, once it is ready. Until then the screens alone answer.
    @State private var book: GoToIndex?
    @State private var screens = GoToIndex([])
    /// The book's last answer — what a longer query narrows from.
    @State private var last: GoToIndex.Result?
    @State private var groups: [GoToIndex.Group] = []
    @State private var cursor = 0
    @FocusState private var fieldFocused: Bool

    /// How many rows a group shows.
    nonisolated static let perGroup = 8
    /// The pause before a search — long enough to fold a burst of keys into
    /// one, short enough that nobody waits for it.
    static let debounce: Duration = .milliseconds(60)

    private var rows: [GoToIndex.Entry] { groups.flatMap { $0.hits.map(\.entry) } }

    var body: some View {
        ZStack(alignment: .top) {
            // A click outside closes it, as it does Spotlight.
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { shop.goingTo = false }
                .accessibilityHidden(true)
            panel
                .padding(.top, 72)
                .padding(.horizontal, Space.xl)
        }
        .task {
            screens = shop.goToScreens()
            refresh()
            let index = await shop.goToIndex()
            book = index
            last = nil
            await search(query)
        }
        .task(id: query) {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await search(query)
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.md) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Role.text3)
                TextField(shop.words.callIt("mac.goto_prompt"), text: $query)
                    .textFieldStyle(.plain)
                    .font(TypeScale.title(15, weight: .regular))
                    .foregroundStyle(Role.text)
                    .focused($fieldFocused)
                    .onSubmit { open(at: cursor) }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.escape) { shop.goingTo = false; return .handled }
                    .accessibilityLabel(shop.words.callIt("mac.goto"))
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.md + 2)

            Divider().overlay(Role.line)

            results
                .frame(maxHeight: 380)

            Divider().overlay(Role.line)
            Text(shop.words.callIt("mac.goto_hint"))
                .font(TypeScale.label(10, weight: .regular))
                .foregroundStyle(Role.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.sm)
        }
        .frame(maxWidth: 580)
        .background(Role.sheet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Role.line2, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
        .onAppear { fieldFocused = true }
        .onExitCommand { shop.goingTo = false }
    }

    @ViewBuilder private var results: some View {
        if rows.isEmpty {
            Text(query.trimmingCharacters(in: .whitespaces).isEmpty ? "" : shop.words.callIt("mac.goto_none"))
                .font(TypeScale.body(12))
                .foregroundStyle(Role.text3)
                .frame(maxWidth: .infinity, minHeight: 44)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let starts = Self.starts(of: groups)
                        ForEach(Array(groups.enumerated()), id: \.element.kind) { g, group in
                            Text(shop.words.callIt("mac.goto_group_" + group.kind.rawValue))
                                .font(TypeScale.label(9.5))
                                .foregroundStyle(Role.text3)
                                .padding(.horizontal, Space.lg)
                                .padding(.top, Space.md)
                                .padding(.bottom, Space.xs)
                            ForEach(Array(group.hits.enumerated()), id: \.element.entry.id) { i, hit in
                                let at = starts[g] + i
                                row(hit.entry, selected: at == cursor)
                                    .id(at)
                                    .contentShape(Rectangle())
                                    .onTapGesture { open(at: at) }
                            }
                        }
                    }
                    .padding(.bottom, Space.sm)
                }
                .onChange(of: cursor) { _, now in proxy.scrollTo(now) }
            }
        }
    }

    private func row(_ entry: GoToIndex.Entry, selected: Bool) -> some View {
        HStack(spacing: Space.md) {
            Image(systemName: Self.symbol(for: entry))
                .frame(width: 18)
                .foregroundStyle(selected ? Role.accInk : Role.text2)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(TypeScale.row(12.5))
                    .foregroundStyle(Role.text)
                    .lineLimit(1)
                if !entry.subtitle.isEmpty {
                    Text(entry.subtitle)
                        .font(TypeScale.body(10.5))
                        .foregroundStyle(Role.text3)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
        .background(selected ? Role.accSoft : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Searching

    /// The screens alone, while the book's index is still being built — the
    /// palette answers at once, then fills in.
    private func refresh() {
        groups = Self.answer(query, screens: screens, book: nil, kinds: shop.goToKinds, perGroup: Self.perGroup)
        cursor = 0
    }

    private func search(_ q: String) async {
        let kinds = shop.goToKinds
        var bookResult: GoToIndex.Result?
        if let book {
            let previous = last
            let found = await Task.detached(priority: .userInitiated) {
                book.search(q, kinds: kinds, perGroup: Self.perGroup, narrowing: previous)
            }.value
            guard !Task.isCancelled, q == query else { return }
            last = found
            bookResult = found
        }
        groups = Self.answer(q, screens: screens, book: bookResult, kinds: kinds, perGroup: Self.perGroup)
        cursor = 0
    }

    /// What the palette lists for a query: with nothing typed, every screen
    /// and command; otherwise the screens' matches and the book's together.
    static func answer(_ q: String, screens: GoToIndex, book: GoToIndex.Result?,
                       kinds: Set<GoToIndex.Kind>, perGroup: Int) -> [GoToIndex.Group] {
        guard !kinds.isEmpty else { return [] }
        if q.trimmingCharacters(in: .whitespaces).isEmpty {
            guard kinds.contains(.screen), !screens.entries.isEmpty else { return [] }
            let hits = screens.entries.enumerated().map { GoToIndex.Hit(entry: $1, score: 0, position: $0) }
            return [GoToIndex.Group(kind: .screen, hits: hits)]
        }
        let mine = screens.search(q, kinds: kinds, perGroup: perGroup)
        return GoToIndex.merged([mine] + (book.map { [$0] } ?? []))
    }

    /// Where each group's first row sits in the flat list the cursor walks.
    static func starts(of groups: [GoToIndex.Group]) -> [Int] {
        var at = 0
        return groups.map { group in defer { at += group.hits.count }; return at }
    }

    private func move(_ by: Int) {
        let count = rows.count
        guard count > 0 else { return }
        cursor = min(max(0, cursor + by), count - 1)
    }

    private func open(at index: Int) {
        let all = rows
        guard all.indices.contains(index) else { return }
        shop.goTo(all[index])
    }

    static func symbol(for entry: GoToIndex.Entry) -> String {
        switch entry.kind {
        case .job: "doc.text"
        case .customer: "person"
        case .model: "cube"
        case .product: "tag"
        case .machine: "printer"
        case .screen: entry.id.hasPrefix("command:") ? "command" : "rectangle.stack"
        }
    }
}
