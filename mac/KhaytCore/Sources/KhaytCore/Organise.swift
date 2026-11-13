import Foundation

/// Counting what a library is filed under, without leaving Swift.
///
/// ── WHY THE COUNT IS HERE AND THE REST IS NOT ─────────────────────────────
///
/// `lib/organise.js` still owns filing (`assign`, `unify`): one rule for the
/// name a model is put under, shared with the other app. Only `counts` is
/// ported, because of what asking for it cost. The Mac handed JavaScript the
/// WHOLE library to count its categories, twice on every reload and again on
/// the first letters of a Library search. On a shop with 14,695 models that is
/// 24 MB turned into JSON text and parsed back each time, about 0.57 s per
/// call in the shipped app, for a rule that itself takes 6 ms
/// (`mac-measurements-nov11`). Tags were already counted here (`Tags.counts`);
/// this is the same step for groups and categories.
///
/// ── A PORT, NOT A SECOND OPINION ──────────────────────────────────────────
///
/// Everything below is what the JavaScript does, including the parts nobody
/// would choose: a record that is the number `0` is filed under "0", a name is
/// cut at 60 UTF-16 units rather than 60 letters, and two spellings count as
/// one name only if JavaScript's own lower-casing says so. The book already
/// holds the answers that rule gave. `OrganiseCountsParityTests` runs the real
/// `lib/organise.js` beside this on generated records and fails when they part.
///
/// That includes the two ways the old call FAILED, and with it the whole
/// count (the callers show no chips then): see `Unreadable`.
///
/// One thing is Foundation's and not JavaScript's: the order of two names
/// with the SAME count is `localizedCompare`, as in `Tags.counts`. It agrees
/// with `localeCompare` on the names shops type; it is not the same code, and
/// the two are known to part on a lone final sigma ("ς" against "Σ").
public enum Organise {

    /// Longest a name may be, in UTF-16 units (`String.prototype.slice`).
    public static let max = 60

    public enum Field: String, Sendable, CaseIterable {
        case group
        case category
    }

    /// The two records the JavaScript could not count, and still cannot.
    ///
    /// Neither is a decision made here. Each is what happened when the
    /// library was handed to `lib/organise.js`: the call threw, the callers
    /// swallowed it, and the Library showed no category chips at all. A port
    /// that quietly counted these would be a port that disagrees with the
    /// other app about the same book.
    public enum Unreadable: Error, Equatable {
        /// The name is an object with a field called `toString` (or a list
        /// holding one). `String(value)` throws a TypeError on it.
        case notText
        /// The 60-unit cut fell through the middle of a character outside the
        /// basic plane (an emoji). JavaScript keeps the first half; the answer
        /// could not be read back from JSON with half a character in it.
        case halfCharacter
    }

    public struct Count: Sendable, Equatable {
        /// The spelling used MOST; the first one seen wins a tie.
        public let label: String
        public let count: Int
        public init(label: String, count: Int) {
            self.label = label
            self.count = count
        }
    }

    // MARK: - JavaScript's idea of a space and of lower case

    /// What `\s` and `trim()` call white space: ECMAScript's WhiteSpace and
    /// LineTerminator. Not `CharacterSet.whitespacesAndNewlines`, which leaves
    /// out the byte-order mark (U+FEFF) and takes in U+0085, so a name pasted
    /// with either would be one name here and another there.
    static func isSpace(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680,
             0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    /// `String(raw == null ? '' : raw).replace(/\s+/g, ' ').trim().slice(0, MAX).trim()`.
    /// Never nil; "" means "not set".
    public static func normalise(_ raw: JSONValue?) throws -> String {
        let text = try self.text(raw)
        // Runs of space become one space and the ends are trimmed, in one
        // pass: a run is only written once something follows it.
        var out = String.UnicodeScalarView()
        var units = 0
        var gap = false
        for u in text.unicodeScalars {
            if isSpace(u) { gap = true; continue }
            if gap, units > 0 {
                // The cut falls on the space, which the last trim drops.
                if units == max { return String(out) }
                out.append(" ")
                units += 1
            }
            gap = false
            let width = u.value > 0xFFFF ? 2 : 1
            if units + width > max {
                if units == max {
                    // Cut cleanly. A space left at the very end goes, as the
                    // second `trim()` takes it.
                    if out.last == " " { out.removeLast() }
                } else {
                    // `slice` counts UTF-16 units, so it cuts a character
                    // outside the basic plane (an emoji) in half and keeps
                    // the first half.
                    throw Unreadable.halfCharacter
                }
                return String(out)
            }
            out.append(u)
            units += width
        }
        return String(out)
    }

    /// `String(value)`, with the one case where it throws.
    ///
    /// An object is "[object Object]" unless it has a field of its own named
    /// `toString`: nothing that came out of JSON is a function, so the
    /// conversion finds a `toString` it cannot call, then a `valueOf` that
    /// hands the object back, and gives up with a TypeError. A list joins
    /// its items the same way, so one such item inside it throws too.
    static func text(_ value: JSONValue?) throws -> String {
        switch value {
        case .object(let o):
            if o["toString"] != nil { throw Unreadable.notText }
            return "[object Object]"
        case .array(let items):
            return try items.map { item -> String in
                if case .null = item { return "" }
                return try text(item)
            }.joined(separator: ",")
        default:
            return JSSemantics.text(value)
        }
    }

    /// `toLowerCase()`: the language-independent mapping, which is Unicode's
    /// per-letter lower case plus ONE rule that looks at the neighbours: a
    /// capital sigma at the end of a word becomes the final form "ς", not "σ".
    /// Swift's `lowercased()` has no such rule, and without it "ΟΔΟΣ" and
    /// "οδος" would be one category in the other app and two here.
    static func lower(_ text: String) -> String {
        if text.utf8.allSatisfy({ $0 < 0x80 }) { return text.lowercased() }
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        for (i, u) in scalars.enumerated() {
            if u.value == 0x03A3 {
                out.append(finalSigma(scalars, at: i) ? "\u{03C2}" : "\u{03C3}")
            } else {
                out.append(contentsOf: u.properties.lowercaseMapping.unicodeScalars)
            }
        }
        return String(out)
    }

    /// Unicode's Final_Sigma: a cased letter comes before (skipping marks and
    /// the like), and no cased letter comes after (skipping the same).
    private static func finalSigma(_ scalars: [Unicode.Scalar], at i: Int) -> Bool {
        var before = false
        var j = i - 1
        while j >= 0 {
            let p = scalars[j].properties
            if p.isCaseIgnorable { j -= 1; continue }
            before = p.isCased
            break
        }
        guard before else { return false }
        var k = i + 1
        while k < scalars.count {
            let p = scalars[k].properties
            if p.isCaseIgnorable { k += 1; continue }
            return !p.isCased
        }
        return true
    }

    /// `String(s == null ? '' : s).trim().toLowerCase()`: what makes two
    /// spellings the same name.
    public static func key(_ name: String) -> String {
        var scalars = name.unicodeScalars[...]
        while let first = scalars.first, isSpace(first) { scalars.removeFirst() }
        while let last = scalars.last, isSpace(last) { scalars.removeLast() }
        return lower(String(scalars))
    }

    // MARK: - Reading a record

    /// What the JavaScript reads off a row that is not an object.
    ///
    /// `rec && rec.category`: a row that is `0`, `false` or `""` is handed on
    /// AS ITSELF, so the number `0` in a list of models is filed under "0".
    /// Any other non-object has no such property and is not filed.
    private static func falsy(_ record: JSONValue?) -> JSONValue? {
        guard let record, !JSSemantics.truthy(record) else { return nil }
        return record
    }

    /// What a thing IS. `normalise(rec && rec.category)`.
    public static func categoryOf(_ record: JSONValue?) throws -> String {
        if case .object(let r)? = record { return try normalise(r["category"]) }
        return try normalise(falsy(record))
    }

    /// The set a thing belongs to. `folder` wins when it is a string, even an
    /// empty one: it is the field an older build writes, and that is a sync
    /// decision (`lib/organise.js`), not an accident.
    public static func groupOf(_ record: JSONValue?) throws -> String {
        if case .object(let r)? = record {
            if case .string? = r["folder"] { return try normalise(r["folder"]) }
            return try normalise(r["group"])
        }
        return try normalise(falsy(record))
    }

    // MARK: - Counting

    /// A string compared the way JavaScript compares one: unit for unit.
    /// Swift calls "é" and "e" + accent equal; a JavaScript `Map` does not,
    /// and they are two spellings there.
    private struct Exact: Hashable {
        let text: String
        static func == (a: Exact, b: Exact) -> Bool { a.text.utf8.elementsEqual(b.text.utf8) }
        func hash(into hasher: inout Hasher) {
            for byte in text.utf8 { hasher.combine(byte) }
        }
    }

    /// Distinct names across records, most-used first, folded by case.
    ///
    /// The label is the spelling used most and the count is every spelling's
    /// together, so a shop that typed "Busts" and "busts" sees one chip with
    /// the real number on it.
    public static func counts(_ records: [JSONValue], field: Field) throws -> [Count] {
        // Insertion order is kept on purpose, as a `Map` keeps it: it decides
        // which spelling wins a tie and which name comes first when the
        // counts and the collation both call two names equal.
        var order: [Exact] = []
        var spellings: [Exact: [(text: String, count: Int)]] = [:]
        var slot: [Exact: Int] = [:]           // spelling -> where it sits in its key's list
        // The same few names thousands of times over: the key of a spelling
        // is worked out once.
        var keyOf: [Exact: Exact] = [:]

        for record in records {
            let name = field == .category ? try categoryOf(record) : try groupOf(record)
            if name.isEmpty { continue }
            let spelling = Exact(text: name)
            let kk: Exact
            if let known = keyOf[spelling] { kk = known } else {
                kk = Exact(text: key(name))
                keyOf[spelling] = kk
            }
            if let at = slot[spelling] {
                spellings[kk]![at].count += 1
            } else {
                if spellings[kk] == nil { spellings[kk] = []; order.append(kk) }
                slot[spelling] = spellings[kk]!.count
                spellings[kk]!.append((name, 1))
            }
        }

        var rows: [Count] = []
        rows.reserveCapacity(order.count)
        for kk in order {
            var total = 0, best = "", bestN = -1
            for (text, n) in spellings[kk] ?? [] {
                total += n
                // Strict, so the FIRST spelling seen wins a tie.
                if n > bestN { bestN = n; best = text }
            }
            rows.append(Count(label: best, count: total))
        }

        // `b[1] - a[1] || a[0].localeCompare(b[0])`. The same collation
        // `Tags.counts` uses for the same line of JavaScript. The index is the
        // last word because JavaScript's sort is stable and Swift's is not.
        return rows.enumerated().sorted { lhs, rhs in
            if lhs.element.count != rhs.element.count { return lhs.element.count > rhs.element.count }
            let byName = lhs.element.label.localizedCompare(rhs.element.label)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
