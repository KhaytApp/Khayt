import Foundation

/// Everything the library is narrowed by, as ONE value.
///
/// ── WHY ONE VALUE ─────────────────────────────────────────────────────────
///
/// The filter bar, the saved searches in the sidebar and the facet counts all
/// ask the same question — "which models?" — and the way three screens start
/// telling a shop three different answers is each keeping its own copy of the
/// question. So the bar reads and writes THIS (`Shop.libraryQuery`), a saved
/// search stores THIS, and the grid, a saved search's count and the facet
/// pools are all worked out by one matcher from it (`Shop.libraryMatcher`).
///
/// Portable on purpose: nothing here knows about SwiftUI or the Mac's own
/// types, so the iPhone can read a saved search from the same book and narrow
/// its own copy of the library the same way.
///
/// ── WHAT IS IN IT ─────────────────────────────────────────────────────────
///
/// - `text`: the search box as typed, `tag:` tokens and all (the Mac's
///   `LibrarySearch` parses it; a saved search keeps the words, not a parse).
/// - The Show axis (print next, duplicates, unfiled, never printed, archived,
///   storage, no print figures, sells in the catalogue), Ready on (one
///   machine, or any), Creator, Category and Tag.
/// - The ranges (`Ranges`): print time, filament, price, times printed and
///   the day a model was added. A model whose figure is NOT KNOWN never
///   matches a range — "under two hours" is not a claim about a model nobody
///   has timed.
/// - The order (`sort`, a `LibrarySort` raw value). Nil keeps whatever order
///   the screen already had.
///
/// ── IN THE BOOK ───────────────────────────────────────────────────────────
///
/// Written as a plain JSON object with only what is set (`json`), and read
/// back leniently (`init(json:)`): a field this build does not know is
/// ignored, a field it expects and does not find is off, and a value of the
/// wrong type is off rather than fatal. A query saved by a newer build opens
/// in an older one as the part of it that build understands.
public struct LibraryQuery: Codable, Equatable, Hashable, Sendable {

    /// Where the bytes are: not on this Mac, or on this Mac and nowhere else.
    public enum Storage: String, Codable, Hashable, Sendable, CaseIterable {
        case onlineOnly, thisMacOnly
    }

    /// The search box, as typed.
    public var text: String = ""

    // The Show axis.
    public var printNext = false
    public var duplicates = false
    public var unfiled = false
    public var neverPrinted = false
    public var archived = false
    public var storage: Storage?
    /// Neither a print time nor a weight is known — nothing to price from.
    public var noFigures = false
    /// A catalogue product is made from this model.
    public var inCatalogue = false
    /// Saved from a web page with the browser extension (`savedFromWebAt`).
    public var fromWeb = false

    // Ready on.
    /// One machine, by id.
    public var readyOn: String?
    /// Any machine that says what it has loaded.
    public var readyAnywhere = false

    public var creator: String?
    public var category: String?
    /// Models with no category at all.
    public var uncategorised = false
    public var tag: String?

    public var ranges = Ranges()

    /// A `LibrarySort` raw value; nil keeps the order the screen has.
    public var sort: String?

    public init() {}

    /// No filter, no range and no search — what the library opens on. The
    /// order is not a filter: a query that only sorts is still empty.
    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty && !filtersOn }

    /// Any axis or range narrowing (the search box aside).
    public var filtersOn: Bool {
        printNext || duplicates || unfiled || neverPrinted || archived || storage != nil
            || noFigures || inCatalogue || fromWeb || readyOn != nil || readyAnywhere
            || creator != nil || category != nil || uncategorised || tag != nil || ranges.isActive
    }

    /// The same question with no order — what a count depends on.
    public var unsorted: LibraryQuery {
        var me = self
        me.sort = nil
        return me
    }

    // MARK: Ranges

    /// A low and a high figure, either of them open. Both open is no range.
    public struct Bound: Codable, Equatable, Hashable, Sendable {
        public var min: Double?
        public var max: Double?

        public init(min: Double? = nil, max: Double? = nil) {
            self.min = min
            self.max = max
        }

        public var isActive: Bool { min != nil || max != nil }

        /// Does `value` fall inside? Unknown is never inside: a range is a
        /// claim about a figure, and a model with no figure has made none.
        /// A bound typed the wrong way round (min above max) is read as the
        /// range between the two, the way a shop meant it.
        public func contains(_ value: Double?) -> Bool {
            guard isActive else { return true }
            guard let value, value.isFinite else { return false }
            var lo = min, hi = max
            if let l = lo, let h = hi, l > h { lo = h; hi = l }
            if let lo, value < lo { return false }
            if let hi, value > hi { return false }
            return true
        }
    }

    /// Days in the book's calendar (`Calendar.book`), `YYYY-MM-DD`, either
    /// end open — or the last `lastDays` days, counted back from today, which
    /// is what a saved "added this month" has to mean next month too.
    public struct Days: Codable, Equatable, Hashable, Sendable {
        public var from: String?
        public var to: String?
        public var lastDays: Int?

        public init(from: String? = nil, to: String? = nil, lastDays: Int? = nil) {
            self.from = from
            self.to = to
            self.lastDays = lastDays
        }

        public var isActive: Bool { from != nil || to != nil || (lastDays ?? 0) > 0 }

        /// The first and last day this covers, as of `today` (`YYYY-MM-DD`).
        public func span(today: String) -> (from: String?, to: String?) {
            if let n = lastDays, n > 0 {
                guard let t = Self.date(today),
                      let start = Calendar.book.date(byAdding: .day, value: -(n - 1), to: t)
                else { return (nil, nil) }
                return (Calendar.book.dayString(start), today)
            }
            if let f = from, let t = to, f > t { return (t, f) }
            return (from, to)
        }

        /// Is `day` (`YYYY-MM-DD`) inside? Unknown never is.
        public func contains(_ day: String?, today: String) -> Bool {
            guard isActive else { return true }
            guard let day, day.count == 10 else { return false }
            let (from, to) = span(today: today)
            if let from, day < from { return false }
            if let to, day > to { return false }
            return true
        }

        /// Midday on a `YYYY-MM-DD` in the book's calendar — midday, so a
        /// daylight-saving shift can never push it onto the next day.
        static func date(_ day: String) -> Date? {
            let p = day.split(separator: "-").compactMap { Int($0) }
            guard p.count == 3 else { return nil }
            return Calendar.book.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))
        }
    }

    /// The five ranges.
    public struct Ranges: Codable, Equatable, Hashable, Sendable {
        /// Print time, in MINUTES (the slicer's own unit; the bar shows hours).
        public var minutes = Bound()
        public var grams = Bound()
        public var price = Bound()
        public var timesPrinted = Bound()
        public var added = Days()

        public init() {}

        public var isActive: Bool {
            minutes.isActive || grams.isActive || price.isActive || timesPrinted.isActive || added.isActive
        }

        /// How many of the five are set.
        public var activeCount: Int {
            [minutes.isActive, grams.isActive, price.isActive, timesPrinted.isActive, added.isActive]
                .count { $0 }
        }

        /// Does a model with these figures pass every range that is set?
        public func matches(_ f: Figures, today: String) -> Bool {
            minutes.contains(f.minutes) && grams.contains(f.grams) && price.contains(f.price)
                && timesPrinted.contains(f.timesPrinted.map(Double.init))
                && added.contains(f.addedDay, today: today)
        }
    }

    /// What one model's figures are, as far as they are known. Nil is
    /// unknown — and unknown never matches a range.
    public struct Figures: Equatable, Sendable {
        public var minutes: Double?
        public var grams: Double?
        public var price: Double?
        public var timesPrinted: Int?
        /// The book-calendar day it was added, `YYYY-MM-DD`.
        public var addedDay: String?

        public init(minutes: Double? = nil, grams: Double? = nil, price: Double? = nil,
                    timesPrinted: Int? = nil, addedDay: String? = nil) {
            self.minutes = minutes
            self.grams = grams
            self.price = price
            self.timesPrinted = timesPrinted
            self.addedDay = addedDay
        }
    }

    // MARK: In the book

    /// As the book holds it: only what is set.
    public var json: JSONValue {
        var o: [String: JSONValue] = [:]
        if !text.isEmpty { o["text"] = .string(text) }
        for (key, on) in [("printNext", printNext), ("duplicates", duplicates), ("unfiled", unfiled),
                          ("neverPrinted", neverPrinted), ("archived", archived), ("noFigures", noFigures),
                          ("inCatalogue", inCatalogue), ("fromWeb", fromWeb), ("readyAnywhere", readyAnywhere),
                          ("uncategorised", uncategorised)] where on {
            o[key] = .bool(true)
        }
        if let storage { o["storage"] = .string(storage.rawValue) }
        for (key, value) in [("readyOn", readyOn), ("creator", creator), ("category", category),
                             ("tag", tag), ("sort", sort)] {
            if let value, !value.isEmpty { o[key] = .string(value) }
        }
        var r: [String: JSONValue] = [:]
        for (key, bound) in [("minutes", ranges.minutes), ("grams", ranges.grams), ("price", ranges.price),
                             ("timesPrinted", ranges.timesPrinted)] where bound.isActive {
            var b: [String: JSONValue] = [:]
            if let v = bound.min { b["min"] = .number(v) }
            if let v = bound.max { b["max"] = .number(v) }
            r[key] = .object(b)
        }
        if ranges.added.isActive {
            var d: [String: JSONValue] = [:]
            if let v = ranges.added.from { d["from"] = .string(v) }
            if let v = ranges.added.to { d["to"] = .string(v) }
            if let v = ranges.added.lastDays, v > 0 { d["lastDays"] = .number(Double(v)) }
            r["added"] = .object(d)
        }
        if !r.isEmpty { o["ranges"] = .object(r) }
        return .object(o)
    }

    /// Read back leniently; nil only when it is not an object at all.
    public init?(json: JSONValue?) {
        guard case .object(let o)? = json else { return nil }
        func flag(_ k: String) -> Bool { if case .bool(true)? = o[k] { true } else { false } }
        func text(_ k: String) -> String? {
            guard case .string(let s)? = o[k] else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if case .string(let s)? = o["text"] { self.text = s }
        printNext = flag("printNext"); duplicates = flag("duplicates"); unfiled = flag("unfiled")
        neverPrinted = flag("neverPrinted"); archived = flag("archived"); noFigures = flag("noFigures")
        inCatalogue = flag("inCatalogue"); fromWeb = flag("fromWeb"); readyAnywhere = flag("readyAnywhere")
        uncategorised = flag("uncategorised")
        storage = text("storage").flatMap(Storage.init(rawValue:))
        readyOn = text("readyOn"); creator = text("creator"); category = text("category")
        tag = text("tag"); sort = text("sort")
        if case .object(let r)? = o["ranges"] {
            func bound(_ k: String) -> Bound {
                guard case .object(let b)? = r[k] else { return Bound() }
                func n(_ k: String) -> Double? {
                    if case .number(let v)? = b[k], v.isFinite { return v }
                    return nil
                }
                return Bound(min: n("min"), max: n("max"))
            }
            ranges.minutes = bound("minutes")
            ranges.grams = bound("grams")
            ranges.price = bound("price")
            ranges.timesPrinted = bound("timesPrinted")
            if case .object(let d)? = r["added"] {
                func day(_ k: String) -> String? {
                    guard case .string(let s)? = d[k], s.count >= 10 else { return nil }
                    return String(s.prefix(10))
                }
                var lastDays: Int?
                if case .number(let v)? = d["lastDays"], v.isFinite, v >= 1 { lastDays = Int(min(v, 36_500)) }
                ranges.added = Days(from: day("from"), to: day("to"), lastDays: lastDays)
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)
        guard let me = LibraryQuery(json: value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "a library query is an object"))
        }
        self = me
    }

    public func encode(to encoder: Encoder) throws { try json.encode(to: encoder) }
}

/// A library query a shop named and wants back — a smart folder.
///
/// On `settings.librarySavedSearches`, as `{id, name, query, createdAt}`. The
/// list rules live here so the two apps that could write it obey one set:
/// saving under a name already used REPLACES that search (a shop tweaking
/// "Ready for the market" should not end up with three of them), names are
/// trimmed and never empty, and the first of a repeated id wins on reading.
public struct LibrarySavedSearch: Codable, Equatable, Hashable, Sendable, Identifiable {
    public static let settingsKey = "librarySavedSearches"

    public var id: String
    public var name: String
    public var query: LibraryQuery
    public var createdAt: String

    public init(id: String, name: String, query: LibraryQuery, createdAt: String) {
        self.id = id
        self.name = name
        self.query = query
        self.createdAt = createdAt
    }

    public var json: JSONValue {
        .object(["id": .string(id), "name": .string(name), "query": query.json,
                 "createdAt": .string(createdAt)])
    }

    public init?(json: JSONValue?) {
        guard case .object(let o)? = json,
              case .string(let id)? = o["id"], !id.isEmpty,
              case .string(let rawName)? = o["name"] else { return nil }
        let name = Self.clean(rawName)
        guard !name.isEmpty else { return nil }
        self.id = id
        self.name = name
        self.query = LibraryQuery(json: o["query"]) ?? LibraryQuery()
        if case .string(let at)? = o["createdAt"] { createdAt = at } else { createdAt = "" }
    }

    /// A name as kept: trimmed, inner runs of space made one, and cut at 60
    /// characters — the sidebar is narrow and a pasted paragraph is not a name.
    public static func clean(_ typed: String) -> String {
        let words = typed.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        return String(words.joined(separator: " ").prefix(60))
    }

    /// What the settings hold, junk dropped, the first of a repeated id kept.
    public static func all(settings: [String: JSONValue]) -> [LibrarySavedSearch] {
        guard case .array(let rows)? = settings[settingsKey] else { return [] }
        var seen: Set<String> = []
        var out: [LibrarySavedSearch] = []
        for row in rows {
            guard let s = LibrarySavedSearch(json: row), seen.insert(s.id).inserted else { continue }
            out.append(s)
        }
        return out
    }

    public static func encode(_ list: [LibrarySavedSearch]) -> JSONValue { .array(list.map(\.json)) }

    // MARK: The list rules

    /// Keep `query` under `name`. The same name (folded for case) replaces
    /// that search's query in place and keeps its id; a new name is added at
    /// the end. Nil when the name is empty.
    public static func saving(_ name: String, _ query: LibraryQuery, into list: [LibrarySavedSearch],
                              id: String, at: String) -> [LibrarySavedSearch]? {
        let name = clean(name)
        guard !name.isEmpty else { return nil }
        var out = list
        if let i = out.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
            out[i].query = query
            out[i].name = name
            return out
        }
        out.append(LibrarySavedSearch(id: id, name: name, query: query, createdAt: at))
        return out
    }

    /// Rename one. Nil when the name is empty, or another search has it.
    public static func renaming(_ id: String, to name: String,
                                in list: [LibrarySavedSearch]) -> [LibrarySavedSearch]? {
        let name = clean(name)
        guard !name.isEmpty, let i = list.firstIndex(where: { $0.id == id }) else { return nil }
        guard !list.contains(where: { $0.id != id && $0.name.lowercased() == name.lowercased() })
        else { return nil }
        var out = list
        out[i].name = name
        return out
    }

    /// Replace one's query, keeping its name and place.
    public static func replacing(_ id: String, with query: LibraryQuery,
                                 in list: [LibrarySavedSearch]) -> [LibrarySavedSearch]? {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return nil }
        var out = list
        out[i].query = query
        return out
    }

    /// A copy just after the original, named by `copyName(name, n)` with the
    /// first `n` (2, 3, …) that no other search already has.
    public static func duplicating(_ id: String, in list: [LibrarySavedSearch], newId: String, at: String,
                                   copyName: (String, Int) -> String) -> [LibrarySavedSearch]? {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return nil }
        let taken = Set(list.map { $0.name.lowercased() })
        var n = 2
        var name = clean(copyName(list[i].name, n))
        while taken.contains(name.lowercased()), n < 1000 {
            n += 1
            name = clean(copyName(list[i].name, n))
        }
        var out = list
        out.insert(LibrarySavedSearch(id: newId, name: name, query: list[i].query, createdAt: at), at: i + 1)
        return out
    }

    public static func deleting(_ id: String, from list: [LibrarySavedSearch]) -> [LibrarySavedSearch]? {
        guard list.contains(where: { $0.id == id }) else { return nil }
        return list.filter { $0.id != id }
    }
}
