import Foundation

/// What is wrong with a library, in groups a shop can work through.
///
/// ── WHY A PURE RULE ───────────────────────────────────────────────────────
///
/// A library of thousands grows problems nobody can see from the grid: files
/// that went missing from the disk, models nobody measured, the same file
/// imported twice, a catalogue product whose model was deleted. Manyfold calls
/// its page for this "Troubleshoot". Khayt's is Library Health, and the
/// grouping lives HERE, in KhaytCore, so the iPhone can say the same thing
/// about the same book. The app hands it plain facts — where each model's
/// bytes are, what its slicer said, its key and its box — and gets the groups
/// back. Nothing here reads a disk or writes a record; every fix is the app's
/// own existing door.
///
/// ── DUPLICATES: CERTAIN, OR A LOOK ────────────────────────────────────────
///
/// `lib/model-identity.js` draws the line, and this keeps it:
///
///   SAME FILE   — the same `contentHash` (SHA-256 of the bytes). Certain.
///   LOOKS SAME  — the same `geometryKey` (`triangles:volume:XxYxZ`, which
///                 carries the bounding box) with DIFFERENT bytes: the mesh
///                 re-saved by another slicer, usually — but a part MIRRORED
///                 left-to-right has the same triangles, the same volume and
///                 the same box, so it has the same key and is not the same
///                 part. Those are shown to be looked at, never merged.
///
/// Nothing here merges anything, ever. The groups are lists.
public enum LibraryHealth {

    /// Where a model's bytes are, as the app found them.
    public enum Presence: String, Sendable, Equatable {
        /// On this Mac.
        case here
        /// Not on this Mac, but kept online (a bucket, or a drive's folder the
        /// drive has not downloaded).
        case online
        /// Neither: the record names a file this Mac cannot find.
        case missing
        /// Not asked — no library folder to look in (the sample book).
        case unknown
    }

    /// One model, as the rule needs it.
    public struct Model: Sendable, Equatable {
        public var id: String
        public var title: String
        public var presence: Presence
        public var contentHash: String?
        public var geometryKey: String?
        /// What the slicer (or the file's per-colour weights) said.
        public var slicedMinutes: Double?
        public var slicedGrams: Double?
        public var tags: [String]
        public var category: String?
        public var archived: Bool

        public init(id: String, title: String, presence: Presence, contentHash: String? = nil,
                    geometryKey: String? = nil, slicedMinutes: Double? = nil, slicedGrams: Double? = nil,
                    tags: [String] = [], category: String? = nil, archived: Bool = false) {
            self.id = id; self.title = title; self.presence = presence
            self.contentHash = contentHash; self.geometryKey = geometryKey
            self.slicedMinutes = slicedMinutes; self.slicedGrams = slicedGrams
            self.tags = tags; self.category = category; self.archived = archived
        }

        /// The mesh is measured: `geometryKey` with a triangle count and a
        /// box. A key with no triangles (an unreadable mesh) measures nothing.
        public var mesh: Mesh? { Mesh(key: geometryKey) }

        /// A time and a weight, from the slice or — failing it — from the
        /// measured mesh, which is what the app's estimate is made from.
        public var hasTime: Bool { (slicedMinutes ?? 0) > 0 || mesh != nil }
        public var hasWeight: Bool { (slicedGrams ?? 0) > 0 || mesh != nil }
        public var hasFigures: Bool { hasTime && hasWeight }
    }

    /// `triangles:volumeMm3:XxYxZ`, unpacked.
    public struct Mesh: Sendable, Equatable {
        public let triangles: Int
        public let x: Double, y: Double, z: Double

        public init?(key: String?) {
            guard let key, !key.isEmpty else { return nil }
            let parts = key.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, let tris = Int(parts[0]), tris > 0, Double(parts[1]) != nil else { return nil }
            let dims = parts[2].split(separator: "x").compactMap { Double($0) }
            guard dims.count == 3 else { return nil }
            triangles = tris; x = dims[0]; y = dims[1]; z = dims[2]
        }
    }

    /// A machine and its bed. `kind` is the machine kind's id (`fdm`,
    /// `resin`, `laser`, `uv`…); absent reads as `fdm`, as the app does.
    public struct Machine: Sendable, Equatable {
        public var id: String
        public var kind: String?
        public var bed: JSONValue?
        public init(id: String, kind: String? = nil, bed: JSONValue?) {
            self.id = id; self.kind = kind; self.bed = bed
        }
    }

    /// A catalogue product and the library models its parts print from.
    public struct Product: Sendable, Equatable {
        public var id: String
        public var name: String
        public var printFileIds: [String]
        public init(id: String, name: String, printFileIds: [String]) {
            self.id = id; self.name = name; self.printFileIds = printFileIds
        }
    }

    /// The machines a 3D model can go on. A laser bed or a UV flatbed holds
    /// a footprint and says nothing about printing a model.
    public static let modelKinds: Set<String> = ["fdm", "resin"]

    public enum Kind: String, Sendable, CaseIterable, Equatable {
        case missing
        case onlineUnmeasured
        case noFigures
        case sameFile
        case looksSame
        case tooBig
        case unorganised
        case orphanProducts
    }

    public struct Group: Sendable, Equatable {
        public let kind: Kind
        /// Every model in the group, in the library's order — for the
        /// duplicate kinds, every model in every cluster.
        public let modelIds: [String]
        /// For the duplicate kinds: the copies, a cluster each, oldest first
        /// as given. Empty for the rest.
        public let clusters: [[String]]
        /// For `orphanProducts`: the products.
        public let productIds: [String]

        public var count: Int { kind == .orphanProducts ? productIds.count : modelIds.count }
    }

    /// The groups with anything in them, in the order a shop should work
    /// through them: what is lost first, what is unpriced next, then what is
    /// tidy-up.
    public static func groups(models: [Model], machines: [Machine] = [],
                              products: [Product] = []) -> [Group] {
        let live = models.filter { !$0.archived }
        var out: [Group] = []
        func add(_ kind: Kind, _ ids: [String], clusters: [[String]] = [], products: [String] = []) {
            guard !ids.isEmpty || !products.isEmpty else { return }
            out.append(Group(kind: kind, modelIds: ids, clusters: clusters, productIds: products))
        }
        add(.missing, live.filter { $0.presence == .missing }.map(\.id))
        add(.onlineUnmeasured, live.filter { $0.presence == .online && !$0.hasFigures }.map(\.id))
        add(.noFigures, live.filter { $0.presence != .online && $0.presence != .missing && !$0.hasFigures }.map(\.id))
        let (same, looks) = duplicates(live)
        add(.sameFile, same.flatMap { $0 }, clusters: same)
        add(.looksSame, looks.flatMap { $0 }, clusters: looks)
        add(.tooBig, live.filter { tooBigForEveryMachine($0, machines) }.map(\.id))
        add(.unorganised, live.filter(isUnorganised).map(\.id))
        // EVERY record, archived too: a product whose model was put aside
        // still has its model. Only a model that is not in the book at all
        // is gone.
        let known = Set(models.map(\.id))
        add(.orphanProducts, [], products: products.filter { p in
            p.printFileIds.contains { !$0.isEmpty && !known.contains($0) }
        }.map(\.id))
        return out
    }

    /// Neither a tag nor a category — nothing a filter could find it by.
    public static func isUnorganised(_ m: Model) -> Bool {
        let tagged = m.tags.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let filed = !(m.category ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !tagged && !filed
    }

    /// Too big for every 3D printer that has a bed recorded. A model with no
    /// measured box, or a shop with no bed recorded, is not too big — unknown
    /// is not a refusal (`ModelReadiness`).
    public static func tooBigForEveryMachine(_ m: Model, _ machines: [Machine]) -> Bool {
        guard let mesh = m.mesh else { return false }
        let bounds = ModelReadiness.bounds(x: mesh.x, y: mesh.y, z: mesh.z)
        let states = machines
            .filter { modelKinds.contains(($0.kind ?? "fdm").lowercased()) }
            .compactMap { ModelReadiness.state(bounds: bounds, bed: $0.bed, spoolsReady: nil) }
        return !states.isEmpty && states.allSatisfy { $0 == .tooBig }
    }

    /// The two kinds of copy, each as clusters of ids in the order given.
    ///
    /// A geometry cluster counts only when its members hold at least two
    /// DIFFERENT files: two records of one file share a key too, and they
    /// are already the certain kind — shown once, not twice.
    public static func duplicates(_ models: [Model]) -> (sameFile: [[String]], looksSame: [[String]]) {
        var byHash: [String: [Model]] = [:], hashOrder: [String] = []
        var byKey: [String: [Model]] = [:], keyOrder: [String] = []
        for m in models {
            if let h = m.contentHash, !h.isEmpty {
                if byHash[h] == nil { hashOrder.append(h) }
                byHash[h, default: []].append(m)
            }
            if m.mesh != nil, let k = m.geometryKey {
                if byKey[k] == nil { keyOrder.append(k) }
                byKey[k, default: []].append(m)
            }
        }
        let same = hashOrder.compactMap { h -> [String]? in
            let ids = byHash[h]!.map(\.id)
            return Set(ids).count > 1 ? ids : nil
        }
        let looks = keyOrder.compactMap { k -> [String]? in
            let members = byKey[k]!
            guard Set(members.map(\.id)).count > 1 else { return nil }
            // Each record without a hash is its own file: nothing proves it
            // is the same bytes as anything.
            let files = Set(members.map { ($0.contentHash ?? "").isEmpty ? "id:" + $0.id : $0.contentHash! })
            return files.count > 1 ? members.map(\.id) : nil
        }
        return (same, looks)
    }
}
