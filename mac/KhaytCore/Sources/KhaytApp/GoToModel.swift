import Foundation
import Observation
import KhaytCore

/// ⌘K's state: the query, what it answers, the cursor. `GoToPalette` draws
/// it; the tests drive it with no window at all.
///
/// ── ONE ANSWER, TAGGED WITH ITS QUERY ───────────────────────────────────────
///
/// The palette once kept the headings and the rows as two things the view
/// lined up by position: an array of groups, and rows identified by their
/// place in the flat list (`.id(0)`, `.id(1)`…) inside a `LazyVStack`. Going
/// from the nothing-typed list (every screen) to the answer for "dent", the
/// lazy stack kept the rows it already had under ids 0…8 and drew the new
/// HEADINGS over the OLD ROWS — "Library" above Dashboard and Jobs,
/// "Catalogue" above Board, "Jobs" above Library and the rest, which is
/// exactly the shape of the real answer (two models, one product, five
/// jobs…) laid over the first nine screens. Dental model set was in the
/// answer and never drawn.
///
/// So an answer is one value: the query it answers, and its `Section`s, each
/// carrying its own title and its own rows, every row identified by what it
/// IS (`kind` and record id), never by where it sits.
///
/// ── NOTHING OLD REPLACES SOMETHING NEW ──────────────────────────────────────
///
/// A search reads the query, the index and the last answer, goes off the main
/// actor, and on its return is applied only if the query and the index are
/// still the ones it started from. An older search finishing late is
/// dropped. The book's index arriving re-runs whatever is in the field NOW,
/// so a query typed before the index existed is answered once it does — and
/// until then the palette says it is still loading instead of "nothing
/// matches".
@MainActor @Observable
final class GoToModel {

    /// One row: what it opens, and where it sits in the list ↑/↓ walk.
    struct Row: Identifiable, Equatable {
        /// What the row is — never where it is. `kind|id`, because a job and
        /// a customer may share an id string.
        let id: String
        let entry: GoToIndex.Entry
        /// Its place in the flat list the cursor walks.
        let index: Int
    }

    /// One heading and the rows under it — together, so they cannot drift.
    struct Section: Identifiable, Equatable {
        var id: String { kind.rawValue }
        let kind: GoToIndex.Kind
        let title: String
        let rows: [Row]
    }

    /// What the palette shows for one query.
    struct Answer: Equatable {
        /// The query, as typed, that this answers.
        let query: String
        let sections: [Section]
        /// The book's index was not ready: the screens answered alone and the
        /// book's rows are still to come.
        let loading: Bool

        static let empty = Answer(query: "", sections: [], loading: false)
    }

    /// How many rows a group shows.
    nonisolated static let perGroup = 8

    @ObservationIgnored let shop: Shop

    /// What is in the field.
    var query = ""
    private(set) var answer = Answer.empty
    var cursor = 0

    /// The book's index, once it is ready.
    private(set) var book: GoToIndex?
    /// Which index `book` is; bumped when a new one arrives, so a search
    /// begun over the old one is not applied, and its answer is not narrowed
    /// from.
    @ObservationIgnored private var generation = 0
    /// The book's last answer — what a longer query narrows from — and which
    /// index it came from.
    @ObservationIgnored private var last: (generation: Int, result: GoToIndex.Result)?
    /// The screens and commands, built on first use: `goToScreens` reads the
    /// shop's state as it is when the palette opens.
    @ObservationIgnored private var screensIndex: GoToIndex?

    init(shop: Shop) { self.shop = shop }

    var sections: [Section] { answer.sections }
    var rows: [Row] { answer.sections.flatMap(\.rows) }
    var loading: Bool { answer.loading }

    private var screens: GoToIndex {
        if let screensIndex { return screensIndex }
        let built = shop.goToScreens()
        screensIndex = built
        return built
    }

    // MARK: - Searching

    /// Build (or fetch) the book's index, then answer what is in the field
    /// now — which may be far more than was there when this began.
    func load() async {
        if book == nil { apply(query, book: nil, kinds: shop.goToKinds) }
        let index = await shop.goToIndex()
        book = index
        generation += 1
        last = nil
        await search()
    }

    /// Answer the query in the field. An answer that arrives after the field
    /// or the index has moved on is dropped.
    func search() async {
        let q = query
        let kinds = shop.goToKinds
        guard let book else {
            apply(q, book: nil, kinds: kinds)
            return
        }
        let started = generation
        let previous = last?.generation == started ? last?.result : nil
        let found = await Task.detached(priority: .userInitiated) {
            book.search(q, kinds: kinds, perGroup: Self.perGroup, narrowing: previous)
        }.value
        guard q == query, started == generation, kinds == shop.goToKinds else { return }
        last = (started, found)
        apply(q, book: found, kinds: kinds)
    }

    private func apply(_ q: String, book: GoToIndex.Result?, kinds: Set<GoToIndex.Kind>) {
        let next = Self.answer(q, screens: screens, book: book, kinds: kinds,
                               bookReady: self.book != nil, perGroup: Self.perGroup,
                               title: { self.shop.words.callIt("mac.goto_group_" + $0.rawValue) })
        if next != answer { cursor = 0 }
        answer = next
    }

    /// What the palette lists for a query: with nothing typed, every screen
    /// and command; otherwise the screens' matches and the book's together,
    /// by the same matcher. `loading` when something was typed that the book
    /// may yet answer.
    static func answer(_ q: String, screens: GoToIndex, book: GoToIndex.Result?,
                                   kinds: Set<GoToIndex.Kind>, bookReady: Bool, perGroup: Int,
                                   title: (GoToIndex.Kind) -> String) -> Answer {
        guard !kinds.isEmpty else { return Answer(query: q, sections: [], loading: false) }
        let typed = !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let groups: [GoToIndex.Group]
        if !typed {
            if kinds.contains(.screen), !screens.entries.isEmpty {
                groups = [GoToIndex.Group(kind: .screen,
                                          hits: screens.entries.enumerated().map { GoToIndex.Hit(entry: $1, score: 0, position: $0) })]
            } else {
                groups = []
            }
        } else {
            let mine = screens.search(q, kinds: kinds, perGroup: perGroup)
            groups = GoToIndex.merged([mine] + (book.map { [$0] } ?? []))
        }
        // One section per kind, each row once: should two indexes ever answer
        // the same kind, its rows join one heading rather than making a second
        // with the same identity. Numbered afterwards, in the order drawn.
        var kindsInOrder: [GoToIndex.Kind] = []
        var entries: [GoToIndex.Kind: [GoToIndex.Entry]] = [:]
        var seen = Set<String>()
        for group in groups {
            for hit in group.hits where seen.insert(group.kind.rawValue + "|" + hit.entry.id).inserted {
                if entries[group.kind] == nil { kindsInOrder.append(group.kind) }
                entries[group.kind, default: []].append(hit.entry)
            }
        }
        var at = 0
        let sections = kindsInOrder.map { kind in
            Section(kind: kind, title: title(kind), rows: entries[kind, default: []].map { entry in
                defer { at += 1 }
                return Row(id: kind.rawValue + "|" + entry.id, entry: entry, index: at)
            })
        }
        let bookKinds = kinds.subtracting([.screen])
        return Answer(query: q, sections: sections, loading: typed && !bookReady && !bookKinds.isEmpty)
    }

    // MARK: - The cursor

    func move(_ by: Int) {
        let count = rows.count
        guard count > 0 else { return }
        cursor = min(max(0, cursor + by), count - 1)
    }

    var selected: Row? {
        let all = rows
        return all.indices.contains(cursor) ? all[cursor] : nil
    }

    func open(_ row: Row? = nil) {
        guard let row = row ?? selected else { return }
        shop.goTo(row.entry)
    }
}
