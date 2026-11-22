import Foundation

/// Variants of one model, shown as one tile: "Dragon", "Dragon supportless",
/// "Dragon 150%".
///
/// ── IN THE BOOK: TWO FIELDS ON EACH MEMBER, NO CONTAINER ──────────────────
///
/// A stack is `stackId` (the same short string on every member) plus
/// `stackTop: true` on the one that wears the tile. There is no stack record:
/// sync merges whole records last-writer-wins with an older Electron build
/// that has never heard of stacks (`khayt-two-machines-one-old`), and a
/// container record that build cannot see would be deleted, duplicated or
/// orphaned by it. Two plain fields on records it already carries survive
/// untouched — Electron edits a record in place (`Object.assign`), so a field
/// it does not know rides along — and it simply shows each member as its own
/// model, which is what they are.
///
/// ── WHAT IS A STACK ON SCREEN ─────────────────────────────────────────────
///
/// A `stackId` that two or more models in the book carry. One left alone is
/// not a stack (its mate was deleted, or unstacked on the other machine) and
/// draws as the plain model it is; nothing has to be cleaned up for that.
///
/// ── FILTERS AND COUNTS ────────────────────────────────────────────────────
///
/// Nothing here filters. The library's one matcher (`Shop.libraryMatcher`)
/// decides which MODELS are shown, exactly as before, and every count — the
/// sidebar, the facets, the grid's own — is still a count of models. Stacking
/// is how the shown models are DRAWN (`collapse`): a stack shows when any of
/// its members is shown, as one tile whose badge counts the members shown.
/// So no number anywhere changes because models were stacked.
///
/// ── STACKING IS EXPLICIT ──────────────────────────────────────────────────
///
/// The shop selects tiles and chooses Stack, or accepts a SUGGESTION
/// (`suggestions`): the same group and the same name once the variant words
/// are taken off (`stem`), the same bytes, or the same shape figures — with
/// the mirror caveat Library Health gives, because a left and a right part
/// share a `geometryKey`. Nothing is ever stacked on its own.
public enum LibraryStacks {

    public static let idKey = "stackId"
    public static let topKey = "stackTop"
    /// A stack id as kept: the app writes `ST-` and eight hex digits; anything
    /// longer arriving by sync is cut rather than trusted.
    public static let idLength = 64

    /// One model, as the rules need it.
    public struct Member: Sendable, Equatable {
        public var id: String
        public var title: String
        public var group: String?
        public var stackId: String?
        public var stackTop: Bool
        public var contentHash: String?
        public var geometryKey: String?
        public var archived: Bool

        public init(id: String, title: String, group: String? = nil, stackId: String? = nil,
                    stackTop: Bool = false, contentHash: String? = nil, geometryKey: String? = nil,
                    archived: Bool = false) {
            self.id = id; self.title = title; self.group = group
            self.stackId = Self.clean(stackId); self.stackTop = stackTop
            self.contentHash = contentHash; self.geometryKey = geometryKey; self.archived = archived
        }

        /// A record's `stackId` as read: trimmed, empty is none, cut long.
        public static func clean(_ raw: String?) -> String? {
            let t = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : String(t.prefix(LibraryStacks.idLength))
        }
    }

    // MARK: - Who is in which stack

    /// Every stack in the book with two or more members, by id, members in
    /// book order. Archived models are left out: a put-aside variant is not
    /// one of the things the shop is choosing between, and the archived view
    /// draws each model alone.
    public static func index(_ all: [Member]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for m in all where !m.archived {
            if let s = m.stackId { out[s, default: []].append(m.id) }
        }
        return out.filter { $0.value.count >= 2 }
    }

    /// The member that wears a stack's tile among `ids`: the one marked
    /// `stackTop`, else the first. Two marked (two machines each chose one)
    /// is settled the same way on both: the first in `ids`.
    public static func cover(of ids: [String], tops: Set<String>) -> String? {
        ids.first(where: tops.contains) ?? ids.first
    }

    // MARK: - Drawing

    /// One tile of the grid, after stacking.
    public struct Tile: Sendable, Equatable {
        /// The model the tile shows (and the one a click selects).
        public var id: String
        /// The stack it stands for or belongs to; nil for a plain model.
        public var stackId: String?
        /// For a stack's tile: the members SHOWN (cover first), so the badge
        /// counts what the filters left. One for a plain model.
        public var shown: [String]
        /// How many members the stack has in the book.
        public var total: Int
        /// Drawn inside an open stack, after its cover.
        public var inside: Bool
        /// The stack is open: its members follow this tile.
        public var open: Bool

        public init(id: String, stackId: String? = nil, shown: [String]? = nil, total: Int = 1,
                    inside: Bool = false, open: Bool = false) {
            self.id = id; self.stackId = stackId; self.shown = shown ?? [id]
            self.total = total; self.inside = inside; self.open = open
        }

        public var isStack: Bool { stackId != nil && !inside }
    }

    /// The shown models, in the order they are drawn, as tiles.
    ///
    /// A stack takes the place of its FIRST shown member (so a sort still
    /// decides where it stands) and wears its cover — the `stackTop` member
    /// if that one is shown, else the first shown. An open stack (`expanded`)
    /// is its tile followed by every other shown member, inline. A stack with
    /// only one member shown is still its tile, with the badge saying so:
    /// the shop asked for the variants to stand together.
    public static func collapse(_ shown: [String], stackOf: [String: String], members: [String: [String]],
                                tops: Set<String>, expanded: Set<String>) -> [Tile] {
        var byStack: [String: [String]] = [:]
        for id in shown {
            if let s = stackOf[id], (members[s]?.count ?? 0) >= 2 { byStack[s, default: []].append(id) }
        }
        var out: [Tile] = []
        var drawn: Set<String> = []
        for id in shown {
            guard let s = stackOf[id], let held = byStack[s] else { out.append(Tile(id: id)); continue }
            guard drawn.insert(s).inserted else { continue }
            let top = cover(of: held, tops: tops) ?? id
            let ordered = [top] + held.filter { $0 != top }
            let total = members[s]?.count ?? held.count
            let open = expanded.contains(s)
            out.append(Tile(id: top, stackId: s, shown: ordered, total: total, open: open))
            if open {
                for member in ordered.dropFirst() {
                    out.append(Tile(id: member, stackId: s, total: total, inside: true))
                }
            }
        }
        return out
    }

    // MARK: - Writing

    /// What one record's two fields become. `stackId` nil removes both.
    public struct Patch: Sendable, Equatable {
        public var stackId: String?
        public var top: Bool
        public init(stackId: String?, top: Bool) { self.stackId = stackId; self.top = top }
    }

    /// Stack `ids` together, `cover` on top.
    ///
    /// If any chosen model is already in a stack, the FIRST such stack (in
    /// `ids` order) is the one they join, so stacking one more variant onto
    /// "Dragon" adds to it rather than making a second stack. Members of that
    /// stack that were not chosen stay in it. A chosen model leaving another
    /// stack leaves it; if that leaves one model behind, it is just a model
    /// (`index` ignores a stack of one), and its fields are cleared too so the
    /// book holds no stray half of a stack. Fewer than two models in the end
    /// is nothing to do (nil).
    public static func stacking(_ ids: [String], cover: String?, all: [Member],
                                newId: String) -> [String: Patch]? {
        var seen: Set<String> = []
        let chosen = ids.filter { seen.insert($0).inserted }
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let known = chosen.filter { byId[$0] != nil }
        let live = index(all)
        let joining = known.lazy.compactMap { byId[$0]?.stackId }.first { live[$0] != nil }
        let target = joining ?? newId
        let stayers = (joining.flatMap { live[$0] } ?? []).filter { !seen.contains($0) }
        let members = stayers + known
        guard Set(members).count >= 2 else { return nil }
        let top = cover.flatMap { c in members.contains(c) ? c : nil }
            ?? joining.flatMap { s in live[s].flatMap { ids in ids.first { byId[$0]?.stackTop == true } } }
            ?? known.first!
        var out: [String: Patch] = [:]
        for id in members { out[id] = Patch(stackId: target, top: id == top) }
        // The stacks the chosen ones left: a lone member left behind is cleared.
        for (s, held) in live where s != target {
            let left = held.filter { out[$0] == nil }
            if left.count < held.count, left.count == 1 { out[left[0]] = Patch(stackId: nil, top: false) }
        }
        // Only what actually changes.
        return out.filter { id, p in
            guard let m = byId[id] else { return false }
            return m.stackId != p.stackId || m.stackTop != p.top
        }
    }

    /// Take a whole stack apart: every member's two fields cleared.
    public static func unstacking(_ stackId: String, all: [Member]) -> [String: Patch]? {
        let held = all.filter { $0.stackId == stackId }
        guard !held.isEmpty else { return nil }
        return Dictionary(held.map { ($0.id, Patch(stackId: nil, top: false)) }, uniquingKeysWith: { a, _ in a })
    }

    /// Take some models out of their stacks. A stack left with one member is
    /// dissolved; one that loses its cover gets the next member on top.
    public static func removing(_ ids: Set<String>, all: [Member]) -> [String: Patch]? {
        var out: [String: Patch] = [:]
        let live = index(all)
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in ids where byId[id]?.stackId != nil { out[id] = Patch(stackId: nil, top: false) }
        guard !out.isEmpty else { return nil }
        for (s, held) in live {
            let left = held.filter { !ids.contains($0) }
            guard left.count < held.count else { continue }
            if left.count == 1 {
                out[left[0]] = Patch(stackId: nil, top: false)
            } else if !left.contains(where: { byId[$0]?.stackTop == true }), let first = left.first {
                out[first] = Patch(stackId: s, top: true)
            }
        }
        return out
    }

    /// Put another member on top.
    public static func choosingCover(_ id: String, all: [Member]) -> [String: Patch]? {
        guard let s = all.first(where: { $0.id == id })?.stackId, let held = index(all)[s] else { return nil }
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String: Patch] = [:]
        for m in held {
            let wanted = m == id
            if byId[m]?.stackTop != wanted { out[m] = Patch(stackId: s, top: wanted) }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Suggestions

    /// Why a set of models might be one stack.
    public enum Reason: String, Sendable, Equatable, CaseIterable {
        /// The same bytes (`contentHash`). Certain — but then they are the same
        /// file, which Library Health lists as a duplicate too.
        case sameFile
        /// The same group, and the same name once variant words are taken off.
        case sameName
        /// The same `geometryKey`. A mirrored part has the same key as its
        /// twin, so this is "the same size and shape", never "the same model".
        case sameShape
    }

    public struct Suggestion: Sendable, Equatable {
        public var ids: [String]
        public var reason: Reason
        /// The shared name, for `.sameName`.
        public var stem: String?
        /// The stack the suggestion would join, when one of them is in one.
        public var joins: String?
    }

    /// Sets of models that could be stacked, for the inspector to offer.
    ///
    /// Only sets that would CHANGE something: two models already in one
    /// stack are not suggested again, and a set must hold at least one model
    /// outside any stack or in a different one. Archived models never take
    /// part. Strongest reason first for any one model: the same file, then
    /// the same name in the same group, then the same shape.
    public static func suggestions(_ all: [Member]) -> [Suggestion] {
        let live = all.filter { !$0.archived }
        var out: [Suggestion] = []
        var claimed: Set<String> = []
        func offer(_ reason: Reason, _ groups: [String: [Member]], stem: (String) -> String? = { _ in nil }) {
            for key in groups.keys.sorted() {
                let held = groups[key]!.filter { !claimed.contains($0.id) }
                guard held.count >= 2 else { continue }
                let stacks = Set(held.map { $0.stackId ?? "\u{0}" + $0.id })
                guard stacks.count >= 2 else { continue }     // already one stack
                held.forEach { claimed.insert($0.id) }
                out.append(Suggestion(ids: held.map(\.id), reason: reason, stem: stem(key),
                                      joins: held.lazy.compactMap(\.stackId).first))
            }
        }
        offer(.sameFile, Dictionary(grouping: live.filter { !($0.contentHash ?? "").isEmpty }) { $0.contentHash! })
        offer(.sameName, Dictionary(grouping: live.compactMap { m -> (String, Member)? in
            let s = stem(m.title)
            guard s.count >= 3 else { return nil }
            return ((m.group ?? "").lowercased() + "\u{1}" + s, m)
        }, by: \.0).mapValues { $0.map(\.1) }, stem: { $0.components(separatedBy: "\u{1}").last })
        offer(.sameShape, Dictionary(grouping: live.filter { Self.measured($0.geometryKey) }) { $0.geometryKey! })
        return out
    }

    /// The suggestion that holds `id`, if any.
    public static func suggestion(for id: String, in all: [Member]) -> Suggestion? {
        suggestions(all).first { $0.ids.contains(id) }
    }

    /// A key that measured something: three parts, triangles above zero.
    static func measured(_ key: String?) -> Bool {
        guard let key else { return false }
        let p = key.split(separator: ":", omittingEmptySubsequences: false)
        return p.count == 3 && (Int(p[0]) ?? 0) > 0
    }

    /// Words that name a VARIANT of a model rather than the model: how it is
    /// supported, scaled, mirrored, hollowed or revised. Taken off a title to
    /// find the name variants share. Lower case, after splitting.
    public static let variantWords: Set<String> = [
        "support", "supports", "supported", "supportless", "supportfree", "unsupported", "presupported",
        "pre", "nosupport", "nosupports", "no", "free", "tree", "with", "without",
        "hollow", "hollowed", "solid", "scaled", "scale", "mirror", "mirrored", "left", "right",
        "lh", "rh", "copy", "final", "fixed", "repaired", "remix", "remixed", "new", "old", "alt",
        "small", "medium", "large", "big", "mini", "tiny", "huge", "xl", "half", "full", "size",
        "draft", "fine", "high", "low", "res", "lowres", "hires", "test", "print", "ready",
        "stl", "3mf", "obj", "step", "gcode",
    ]

    /// A title with its variant words, sizes, versions and copy numbers taken
    /// off, folded for case: "Dragon_150% (supportless) v2" → "dragon".
    public static func stem(_ title: String) -> String {
        var name = title
        for ext in [".stl", ".3mf", ".obj", ".step", ".stp", ".gcode"] where name.lowercased().hasSuffix(ext) {
            name = String(name.dropLast(ext.count))
        }
        let separators = CharacterSet(charactersIn: " _-.,()[]{}+/\\|·—–:;'\"")
            .union(.whitespacesAndNewlines)
        let words = name.lowercased().components(separatedBy: separators).filter { !$0.isEmpty }
        let kept = words.filter { !variantWords.contains($0) && !isFigure($0) }
        return kept.joined(separator: " ")
    }

    /// A size, scale, version or copy number: `150%`, `0.4mm`, `120mm`, `v2`,
    /// `v1`, `x2`, `2x`, `1`, `003`.
    static func isFigure(_ word: String) -> Bool {
        var w = Substring(word)
        if w.hasPrefix("v") || w.hasPrefix("x") || w.hasPrefix("r") { w = w.dropFirst() }
        for suffix in ["%", "mm", "cm", "m", "x", "pct"] where w.hasSuffix(suffix) && w.count > suffix.count {
            w = w.dropLast(suffix.count)
            break
        }
        guard !w.isEmpty else { return false }
        return w.allSatisfy { $0.isNumber || $0 == "." || $0 == "," }
    }
}
