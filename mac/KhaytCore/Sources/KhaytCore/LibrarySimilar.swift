import Foundation

/// "Find similar": the models most like one model, ranked.
///
/// ── THE ORDER ─────────────────────────────────────────────────────────────
///
/// 1. The same bytes (`contentHash`) — the same file.
/// 2. The same `geometryKey` — the same triangle count, volume and box. A
///    strong hint, never proof: a part MIRRORED left-to-right keeps all three,
///    so a left arm and a right arm match here (`khayt-library-model`). Every
///    match of this kind carries `mirrorCaveat`, and the screen says so, as
///    Library Health does.
/// 3. Everything else, by a score: how close the bounding box is (its three
///    sides sorted, so a part lying down matches itself standing up), the
///    volume and the triangle count, plus the same group, shared tags and the
///    same name once variant words are off (`LibraryStacks.stem`).
///
/// A model with no measured mesh can still find others by group, tags and
/// name. Archived models are never offered. Pure: the app hands it the
/// facts and puts the answer on the grid as a focus through the one matcher.
public enum LibrarySimilar {

    public struct Model: Sendable, Equatable {
        public var id: String
        public var title: String
        public var group: String?
        public var tags: [String]
        public var contentHash: String?
        public var geometryKey: String?
        public var archived: Bool

        public init(id: String, title: String, group: String? = nil, tags: [String] = [],
                    contentHash: String? = nil, geometryKey: String? = nil, archived: Bool = false) {
            self.id = id; self.title = title; self.group = group; self.tags = tags
            self.contentHash = contentHash; self.geometryKey = geometryKey; self.archived = archived
        }

        /// `triangles:volume:XxYxZ`, unpacked; nil when nothing was measured.
        var shape: (tris: Double, volume: Double, sides: [Double])? {
            guard let key = geometryKey else { return nil }
            let p = key.split(separator: ":", omittingEmptySubsequences: false)
            guard p.count == 3, let t = Double(p[0]), t > 0, let v = Double(p[1]) else { return nil }
            let d = p[2].split(separator: "x").compactMap { Double($0) }
            guard d.count == 3, d.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
            return (t, v, d.sorted())
        }
    }

    public enum Why: String, Sendable, Equatable {
        case sameFile, sameShape, near
    }

    public struct Match: Sendable, Equatable {
        public var id: String
        public var why: Why
        /// 0…1; 1 for the same file or shape.
        public var score: Double
        /// A same-shape match may be a mirrored twin, not the same part.
        public var mirrorCaveat: Bool { why == .sameShape }
    }

    /// The lowest score worth showing among the `near` ones.
    public static let threshold = 0.45
    /// How many are shown at most.
    public static let limit = 30

    /// The models most like `target`, best first. The target itself is not
    /// in the list.
    public static func ranked(_ target: Model, among all: [Model], limit: Int = limit) -> [Match] {
        let mine = target.shape
        let myTags = Set(target.tags.map { $0.lowercased() })
        let myStem = LibraryStacks.stem(target.title)
        let myGroup = (target.group ?? "").lowercased()
        var out: [Match] = []
        for m in all where m.id != target.id && !m.archived {
            if let h = target.contentHash, !h.isEmpty, m.contentHash == h {
                out.append(Match(id: m.id, why: .sameFile, score: 1)); continue
            }
            if mine != nil, let k = target.geometryKey, m.geometryKey == k {
                out.append(Match(id: m.id, why: .sameShape, score: 1)); continue
            }
            let group = (m.group ?? "").lowercased()
            let sameGroup = !myGroup.isEmpty && group == myGroup
            let theirTags = Set(m.tags.map { $0.lowercased() })
            let union = myTags.union(theirTags)
            let tagShare = union.isEmpty ? 0 : Double(myTags.intersection(theirTags).count) / Double(union.count)
            let sameStem = myStem.count >= 3 && LibraryStacks.stem(m.title) == myStem
            // What the shop said about them: the group, the tags, the name.
            let said = (sameGroup ? 0.4 : 0) + 0.3 * tagShare + (sameStem ? 0.3 : 0)
            let normalised: Double
            if let a = mine, let b = m.shape {
                // The shape: each sorted side's closeness, the volume, the
                // triangle count — most of the score when both are measured.
                let sides = zip(a.sides, b.sides).map { closeness($0, $1) }.reduce(0, +) / 3
                let shape = 0.6 * sides + 0.25 * closeness(a.volume, b.volume) + 0.15 * closeness(a.tris, b.tris)
                normalised = 0.8 * shape + 0.2 * said
            } else {
                // With no shapes to compare, the name, group and tags alone.
                normalised = said
            }
            guard normalised >= threshold else { continue }
            out.append(Match(id: m.id, why: .near, score: min(1, normalised)))
        }
        func rank(_ w: Why) -> Int { w == .sameFile ? 0 : (w == .sameShape ? 1 : 2) }
        let titles = Dictionary(all.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        return Array(out.sorted { a, b in
            if rank(a.why) != rank(b.why) { return rank(a.why) < rank(b.why) }
            if a.score != b.score { return a.score > b.score }
            return (titles[a.id] ?? "").localizedStandardCompare(titles[b.id] ?? "") == .orderedAscending
        }.prefix(max(0, limit)))
    }

    /// 1 when equal, falling to 0 as one becomes twice the other (or more).
    static func closeness(_ a: Double, _ b: Double) -> Double {
        guard a.isFinite, b.isFinite else { return 0 }
        let hi = max(abs(a), abs(b)), lo = min(abs(a), abs(b))
        guard hi > 0 else { return 1 }
        return max(0, 1 - (hi - lo) / hi * 2)
    }
}
