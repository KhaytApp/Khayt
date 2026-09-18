import Foundation

/// Keeping a shop's tags to one spelling each.
///
/// Tags are typed into a comma-separated box with nothing to guide them, so
/// "resin", "Resin" and " resin" are three tags. A filter keys on the exact
/// string, which means a shop that has drifted sees three chips for one idea
/// and each of them finds a third of its own files. Nothing errors; the library
/// just quietly stops being searchable, and the more files there are the worse
/// it gets.
///
/// ── THE RULE ───────────────────────────────────────────────────────────────
///
/// A tag that matches one already in use, ignoring case and surrounding space,
/// IS that tag and adopts its spelling. Anything else is new and is kept
/// exactly as typed — this normalises collisions, it does not impose a house
/// style. Lower-casing everything would turn "ABS" into "abs", and being
/// quietly rewritten is worse than being merged with what you meant.
public enum Tags {

    /// `String(s == null ? '' : s).trim().toLowerCase()`.
    ///
    /// Locale-independent lowering on both sides, which is what matters: the
    /// locale-aware pair would fold a Turkish "I" differently and a shop's own
    /// tags would stop matching themselves when the Mac changed language.
    public static func key(_ value: JSONValue?) -> String {
        JSSemantics.text(value).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func key(_ text: String) -> String { key(JSONValue.string(text)) }

    /// Reconcile typed tags against the ones a shop already uses.
    ///
    /// Trimmed, non-empty, de-duplicated case-insensitively, in the order they
    /// were given, each spelled the way the shop already spells it where that
    /// exists.
    public static func normalise(_ raw: JSONValue?, known: [JSONValue] = []) -> [String] {
        var canon: [String: String] = [:]
        var canonOrder: [String] = []
        for k in known {
            let kk = key(k)
            // FIRST spelling seen wins, so the answer does not depend on the
            // order a caller happened to collect the shop's tags in.
            guard !kk.isEmpty, canon[kk] == nil else { continue }
            canon[kk] = JSSemantics.text(k).trimmingCharacters(in: .whitespacesAndNewlines)
            canonOrder.append(kk)
        }

        let parts: [JSONValue]
        if case .array(let items)? = raw {
            parts = items
        } else {
            // `String(raw ?? '').split(',')` — one empty string for an empty
            // input, which the trim-and-skip below drops.
            parts = JSSemantics.text(raw).components(separatedBy: ",").map(JSONValue.string)
        }

        var out: [String] = []
        var seen: Set<String> = []
        for part in parts {
            let trimmed = JSSemantics.text(part).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let kk = key(part)
            if seen.contains(kk) { continue }   // "resin, Resin" is one tag
            seen.insert(kk)
            out.append(canon[kk] ?? trimmed)
        }
        return out
    }

    public static func normalise(_ typed: String, known: [String]) -> [String] {
        normalise(.string(typed), known: known.map(JSONValue.string))
    }

    public struct Count: Sendable, Equatable, Identifiable, Hashable {
        /// The spelling the shop uses MOST, which is the one they have settled
        /// on — not the first seen and not a lower-cased canonical form.
        public let label: String
        public let count: Int
        public var id: String { label }
    }

    /// Distinct tags across records, most-used first, folded by case.
    ///
    /// Counting the exact string showed a drifted shop one chip per spelling,
    /// each finding only its own share of the files. Folding here means the
    /// chip says what the shop means and its count is the real one.
    public static func counts(_ records: [JSONValue]) -> [Count] {
        // Insertion order is kept deliberately: it is the tie-break of last
        // resort below, and a Dictionary alone would make the answer depend on
        // hashing, which is seeded per process.
        var order: [String] = []
        var spellings: [String: [(text: String, count: Int)]] = [:]

        for record in records {
            guard case .object(let r) = record, let tags = iterable(r["tags"]) else { continue }
            // A record naming one tag twice in two spellings counts once.
            var once: Set<String> = []
            for tag in tags {
                let kk = key(tag)
                if kk.isEmpty || once.contains(kk) { continue }
                once.insert(kk)
                let text = JSSemantics.text(tag).trimmingCharacters(in: .whitespacesAndNewlines)
                if spellings[kk] == nil { spellings[kk] = []; order.append(kk) }
                if let i = spellings[kk]!.firstIndex(where: { $0.text == text }) {
                    spellings[kk]![i].count += 1
                } else {
                    spellings[kk]!.append((text, 1))
                }
            }
        }

        var rows: [Count] = []
        for kk in order {
            guard let seen = spellings[kk] else { continue }
            var total = 0, best = "", bestN = -1
            for (text, n) in seen {
                total += n
                // `n > bestN` is strict, so the FIRST spelling seen wins a tie
                // — the Map is in insertion order and so is this.
                if n > bestN { bestN = n; best = text }
            }
            rows.append(Count(label: best, count: total))
        }

        // `b[1] - a[1] || a[0].localeCompare(b[0])` — a locale-aware collation,
        // so "apple" sorts before "Banana" where comparing code points puts
        // every capital first. A shop's tags are often mixed case and often
        // Arabic, so the difference shows on a real book.
        //
        // The index is the last tie-break because Swift's sort is not stable
        // and JavaScript's has been since ES2019.
        return rows.enumerated().sorted { lhs, rhs in
            if lhs.element.count != rhs.element.count { return lhs.element.count > rhs.element.count }
            let byName = lhs.element.label.localizedCompare(rhs.element.label)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// `for (const tg of (r && r.tags) || [])` — and for-of over a STRING
    /// iterates its characters.
    ///
    /// A record whose `tags` was saved as `"resin"` rather than `["resin"]`
    /// therefore counts five tags, one per letter. That is not a good answer,
    /// but it is the answer the other app gives and the one already reflected
    /// in any book it wrote, so the port reproduces it rather than quietly
    /// deciding differently from the app it has to agree with.
    private static func iterable(_ value: JSONValue?) -> [JSONValue]? {
        switch value {
        case .array(let items): return items
        // `unicodeScalars`, not `Character`: for-of walks a string by CODE
        // POINT, while a Swift Character is a whole grapheme cluster — an "e"
        // with a combining accent is two steps there and one here.
        case .string(let s): return s.unicodeScalars.map { .string(String($0)) }
        // Anything else is not iterable and the original throws; `|| []` only
        // catches the falsey ones, which reach here as nil and are skipped.
        default: return nil
        }
    }

    /// Does this record carry that tag, whatever either side's spelling?
    ///
    /// Not `iterable`: the original calls `.some` here, which a string does not
    /// have, so a record with a string `tags` throws rather than being read
    /// letter by letter. A crash is not worth reproducing, so this answers
    /// false — the one deliberate divergence in the module.
    public static func has(_ record: JSONValue?, tag: JSONValue?) -> Bool {
        guard case .object(let r)? = record, case .array(let tags)? = r["tags"] else { return false }
        let wanted = key(tag)
        return tags.contains { key($0) == wanted }
    }
}
