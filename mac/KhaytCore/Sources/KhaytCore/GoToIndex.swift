import Foundation

/// What ⌘K searches: a light, folded copy of the book's names.
///
/// ── BUILT ONCE, SEARCHED PER KEYSTROKE ──────────────────────────────────────
///
/// A palette that walks the book's JSON on every key is fine on the sample's
/// forty jobs and unusable on a shop with ten thousand. So the names a person
/// would type — a job's number and invoice number, its customer and its parts,
/// a customer's phone, a model's file name — are folded ONCE, when the book
/// loads or changes, into one string per record. A keystroke then costs one
/// `contains` per record, and a keystroke that only extends the last query
/// (`ah` → `ahm`) looks only at what the last one matched: nothing that failed
/// to hold `ah` can hold `ahm`.
///
/// A value type, `Sendable`, with no reference to the shop — so the search
/// runs off the main actor and the window keeps drawing while it does.
///
/// ── HOW A MATCH RANKS ───────────────────────────────────────────────────────
///
/// Prefix before substring: typing "ah" should put Ahmad above Fahad. Each
/// record's keys are in priority order (a job's number before its parts), and
/// a hit is scored by how it matched and on which key:
///
///   the whole key           0   "ord-01002" for "ord-01002"
///   the start of the key    1   "ahmad" for "ah"
///   the start of a word     2   "noura ahmad" for "ah"
///   anywhere                3   "fahad" for "ah"
///   every word, somewhere   4   "ahmad saleh" for "sal ahm"
///
/// …then by key, then by the order the records were handed in — which the
/// caller makes "newest first" for jobs, so of two equal hits the recent one
/// wins. Folding is `SearchText.fold`: case, Latin diacritics, the Arabic
/// letter variants and Arabic-Indic digits all compare as one.
public struct GoToIndex: Sendable {

    /// Which kind of thing a row is, in the order the groups are listed when
    /// their best hits tie.
    public enum Kind: String, Sendable, CaseIterable, Comparable {
        case screen, job, customer, model, product, machine

        public static func < (a: Kind, b: Kind) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    /// One thing the palette can go to.
    public struct Entry: Sendable, Hashable, Identifiable {
        public let kind: Kind
        /// The record's own id — what the navigation selects.
        public let id: String
        public let title: String
        public let subtitle: String
        /// Folded, in priority order. See "HOW A MATCH RANKS".
        public let keys: [String]
        /// Every key in one string, for the one test each record gets per
        /// keystroke before it is scored. U+0001 cannot be typed, so a query
        /// never matches across two keys.
        let haystack: String

        public init(kind: Kind, id: String, title: String, subtitle: String = "", fields: [String]) {
            self.kind = kind
            self.id = id
            self.title = title
            self.subtitle = subtitle
            var seen = Set<String>()
            let folded = fields.lazy
                .map { SearchText.fold($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            self.keys = Array(folded)
            self.haystack = keys.joined(separator: "\u{1}")
        }
    }

    /// One row of an answer.
    public struct Hit: Sendable, Hashable {
        public init(entry: Entry, score: Int, position: Int) {
            self.entry = entry; self.score = score; self.position = position
        }
        public let entry: Entry
        /// Lower is better. See "HOW A MATCH RANKS".
        public let score: Int
        /// Where the entry sits in the index — the last tie-break.
        public let position: Int
    }

    /// One kind's rows, best first.
    public struct Group: Sendable {
        public let kind: Kind
        public let hits: [Hit]
        public init(kind: Kind, hits: [Hit]) { self.kind = kind; self.hits = hits }
    }

    /// An answer to one query.
    public struct Result: Sendable {
        /// The folded query this answers.
        public let query: String
        public let kinds: Set<Kind>
        /// Grouped, each group best first and at most `perGroup` long; the
        /// groups ordered by their best hit.
        public let groups: [Group]
        /// Every record that matched, not only the ones shown — what the next,
        /// longer query narrows from.
        public let matched: [Int]
        /// How many records this query looked at. The performance test's
        /// measure: bounded by the index, and by `matched` when narrowing.
        public let touched: Int

        public static let empty = Result(query: "", kinds: [], groups: [], matched: [], touched: 0)
    }

    public let entries: [Entry]

    public init(_ entries: [Entry]) { self.entries = entries }

    public var count: Int { entries.count }

    /// Search the index.
    ///
    /// - Parameters:
    ///   - kinds: what this person may see. A kind left out is never even
    ///     looked at — not filtered from the answer afterwards.
    ///   - perGroup: how many rows each group shows.
    ///   - previous: the last answer, when the new query only extends it.
    public func search(_ query: String, kinds: Set<Kind> = Set(Kind.allCases),
                       perGroup: Int = 8, narrowing previous: Result? = nil) -> Result {
        let q = SearchText.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !q.isEmpty, !kinds.isEmpty else { return Result(query: q, kinds: kinds, groups: [], matched: [], touched: 0) }
        let words = q.split(whereSeparator: { $0 == " " }).map(String.init)

        // What to look at: everything, or what the last query found.
        let candidates: AnySequence<Int>
        if let previous, !previous.query.isEmpty, previous.kinds == kinds,
           q.hasPrefix(previous.query) {
            candidates = AnySequence(previous.matched)
        } else {
            candidates = AnySequence(entries.indices)
        }

        var touched = 0
        var matched: [Int] = []
        var byKind: [Kind: [Hit]] = [:]
        for i in candidates {
            let entry = entries[i]
            guard kinds.contains(entry.kind) else { continue }
            touched += 1
            guard let score = Self.score(entry, q, words) else { continue }
            matched.append(i)
            byKind[entry.kind, default: []].append(Hit(entry: entry, score: score, position: i))
        }

        let groups = Self.ordered(byKind.map { Group(kind: $0, hits: Array(Self.best($1, perGroup))) })
        return Result(query: q, kinds: kinds, groups: groups, matched: matched, touched: touched)
    }

    /// Several answers as one list — the screens' and the book's, which are
    /// two indexes — with the groups ordered by their best hit, and the fixed
    /// order of `Kind` between equals.
    public static func merged(_ results: [Result]) -> [Group] {
        ordered(results.flatMap(\.groups))
    }

    static func ordered(_ groups: [Group]) -> [Group] {
        groups.filter { !$0.hits.isEmpty }.sorted { a, b in
            let sa = a.hits[0].score, sb = b.hits[0].score
            return sa != sb ? sa < sb : a.kind < b.kind
        }
    }

    /// The best `n`, in order. A full sort only when there are few — a query
    /// of one letter can match most of a 10k book, and only eight are drawn.
    static func best(_ hits: [Hit], _ n: Int) -> ArraySlice<Hit> {
        let before: (Hit, Hit) -> Bool = { a, b in
            a.score != b.score ? a.score < b.score : a.position < b.position
        }
        guard hits.count > n * 4 else { return hits.sorted(by: before).prefix(n) }
        var kept: [Hit] = []
        kept.reserveCapacity(n + 1)
        for hit in hits {
            if kept.count == n, let last = kept.last, !before(hit, last) { continue }
            let at = kept.firstIndex { before(hit, $0) } ?? kept.endIndex
            kept.insert(hit, at: at)
            if kept.count > n { kept.removeLast() }
        }
        return kept[...]
    }

    /// The score of a record for a folded query, or nil for no match.
    static func score(_ entry: Entry, _ q: String, _ words: [String]) -> Int? {
        if entry.haystack.contains(q) {
            var best = Int.max
            for (k, key) in entry.keys.enumerated() where key.contains(q) {
                let how: Int
                if key == q { how = 0 }
                else if key.hasPrefix(q) { how = 1 }
                else if startsAWord(key, q) { how = 2 }
                else { how = 3 }
                best = min(best, how * 8 + min(k, 7))
                if how == 0 { break }
            }
            if best != .max { return best }
        }
        // Several words, each somewhere: "saleh ahmad" for Ahmad Saleh.
        guard words.count > 1, words.allSatisfy({ entry.haystack.contains($0) }) else { return nil }
        return 4 * 8 + 7
    }

    /// Whether `q` begins a word inside `key` — after a space or punctuation.
    static func startsAWord(_ key: String, _ q: String) -> Bool {
        var rest = key[...]
        while let r = rest.firstRange(of: q) {
            if r.lowerBound == key.startIndex { return true }
            let before = key[key.index(before: r.lowerBound)]
            if before.isWhitespace || before.isPunctuation || before.isSymbol { return true }
            rest = key[key.index(after: r.lowerBound)...]
        }
        return false
    }
}
