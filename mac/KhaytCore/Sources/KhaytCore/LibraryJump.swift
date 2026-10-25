import Foundation

/// ⌘J, "Jump to in Library": the rules, with no shop in them.
///
/// ── ONE MATCHER, ⌘K'S ─────────────────────────────────────────────────────
///
/// The palette searches a `GoToIndex` — the same folded keys, the same
/// "whole key, start of key, start of a word, anywhere, every word" scores
/// and the same narrowing of a longer query — so typing "dent" ranks the
/// same way in ⌘K and ⌘J. What is the library's own is here: which things it
/// lists (models, folders, compressed files shown as folders, tags, saved
/// searches), the order equal matches fall in, and what each key does.
///
/// ── EQUAL MATCHES: RECENT FIRST, THEN MOST PRINTED ────────────────────────
///
/// `GoToIndex` breaks a tie by where an entry sits in the index, so the index
/// is built in this prior's order: the day something was last used (printed,
/// or added when it never has been) newest first, then how many times it has
/// been printed, then its kind (a model before a folder), then its title. Of
/// two models called "Dental model set", the one printed this week is the one
/// a shop is looking for.
public enum LibraryJump {

    /// The kinds ⌘J lists.
    public static let kinds: Set<GoToIndex.Kind> = [.model, .folder, .archive, .tag, .search]

    /// How many rows the palette shows.
    public static let limit = 8

    /// One thing the palette can jump to, before it is folded.
    public struct Candidate: Sendable, Equatable {
        public var kind: GoToIndex.Kind
        public var id: String
        public var title: String
        public var subtitle: String
        public var fields: [String]
        /// The last day it was used, `YYYY-MM-DD` (an ISO instant is cut to
        /// its first ten characters by the caller); empty when unknown.
        public var lastActive: String
        /// Times printed — for a folder or a tag, every model in it together.
        public var prints: Int

        public init(kind: GoToIndex.Kind, id: String, title: String, subtitle: String = "",
                    fields: [String], lastActive: String = "", prints: Int = 0) {
            self.kind = kind
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.fields = fields
            self.lastActive = lastActive
            self.prints = prints
        }
    }

    /// The order equal matches fall in — see "EQUAL MATCHES".
    public static func before(_ a: Candidate, _ b: Candidate) -> Bool {
        if a.lastActive != b.lastActive { return a.lastActive > b.lastActive }
        if a.prints != b.prints { return a.prints > b.prints }
        if a.kind != b.kind { return order(a.kind) < order(b.kind) }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }

    static func order(_ kind: GoToIndex.Kind) -> Int {
        switch kind {
        case .model: 0
        case .folder: 1
        case .archive: 2
        case .search: 3
        case .tag: 4
        default: 5
        }
    }

    /// The index, in the prior's order. Only ⌘J's kinds; anything else
    /// handed in is dropped.
    public static func index(_ candidates: [Candidate]) -> GoToIndex {
        let sorted = candidates.filter { kinds.contains($0.kind) }.sorted(by: before)
        return GoToIndex(sorted.map {
            GoToIndex.Entry(kind: $0.kind, id: $0.id, title: $0.title, subtitle: $0.subtitle, fields: $0.fields)
        })
    }

    /// What the palette lists with nothing typed: the models used most
    /// recently — the index is already in that order.
    public static func recent(_ index: GoToIndex, limit: Int = limit) -> [GoToIndex.Entry] {
        Array(index.entries.lazy.filter { $0.kind == .model }.prefix(limit))
    }

    /// The last day of an instant or a day, `YYYY-MM-DD`, or "" — sortable
    /// as text.
    public static func day(_ stamp: String?) -> String {
        guard let stamp, stamp.count >= 10 else { return "" }
        let day = String(stamp.prefix(10))
        // Only digits and dashes in the shape of a day: anything else would
        // sort as though it were one.
        let shape = day.enumerated().allSatisfy { i, c in (i == 4 || i == 7) ? c == "-" : c.isASCII && c.isNumber }
        return shape ? day : ""
    }

    // MARK: - What a key does

    /// ↩ opens, ⌘↩ quotes, ⌥↩ starts a job.
    public enum Action: String, Sendable, CaseIterable {
        case open, quote, newJob
    }

    /// The action a Return with these modifiers asks for. ⌘ wins over ⌥ when
    /// both are held: a quote is the one that writes nothing until it is
    /// saved.
    public static func action(command: Bool, option: Bool) -> Action {
        command ? .quote : (option ? .newJob : .open)
    }

    /// May `action` run on a row of this kind? Opening always may (the
    /// palette lists only what the library shows); a quote or a job only for
    /// a model, and only for someone the Quote and New Job menu items are
    /// enabled for (`canMoveJobs`).
    public static func allows(_ action: Action, on kind: GoToIndex.Kind, canMoveJobs: Bool) -> Bool {
        switch action {
        case .open: true
        case .quote, .newJob: kind == .model && canMoveJobs
        }
    }
}
