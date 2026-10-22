import Foundation
import KhaytCore

/// Where each model's bytes are, on THIS Mac: here only, here and online, or
/// online only — kept in `library-sync.json` beside the library's folder.
///
/// ── WHY A FILE OF ITS OWN, AND NOT THE BOOK ──────────────────────────────
///
/// It is a fact about this device's disk. The book syncs to the other Mac,
/// the phone and the cloud, and "online only" written there would tell a Mac
/// that has the file that it does not. So it is per device, beside the
/// library root, and nothing else reads it.
///
/// ── WHY AN INDEX AT ALL ──────────────────────────────────────────────────
///
/// The state lived only in sidecars — `<model>.cloud` (moved out, by either
/// app) and `<model>.online` (put in the bucket by the shop, never here) —
/// found by listing a model's folder on every question. A tile cannot do
/// that: 6,600 models on a NAS is 6,600 directory listings per draw. Here a
/// tile's badge, the Show menu's two filters and their counts are dictionary
/// reads.
///
/// ── THE SIDECARS STAY, AND STAY THE TRUTH ────────────────────────────────
///
/// This is written wherever this app writes or removes one, and filled from
/// them on first launch (`migrate`). They are not deleted: the Electron app
/// reads and writes them, Bring Back is driven by them, and a model the other
/// app moved out is still found by `Shop.isInCloudOnly`'s listing. Models new
/// to the book since the last look are read from their folders once
/// (`reconcile`), so an import, a link or a bucket adoption needs no hook.
///
/// Thread-safe: the store passes run off the main actor.
final class LibrarySyncIndex: @unchecked Sendable {

    enum State: String, Codable, Sendable {
        /// On this Mac, with no copy online that this Mac has proved.
        case local
        /// On this Mac, and proved to be online too (`ensureInBucket`).
        case backedUp
        /// Not on this Mac: in the bucket, or in a cloud drive's folder the
        /// drive has not downloaded.
        case online
    }

    struct Entry: Codable, Equatable, Sendable {
        var state: State
        /// "Keep on this Mac": Free up space never moves it out.
        var keep: Bool?
        var at: String?
    }

    struct Disk: Codable, Equatable, Sendable {
        var v = 1
        /// The library folder this describes. A library moved elsewhere is
        /// read afresh rather than trusted.
        var root: String
        /// When the sidecars were read into it.
        var migratedAt: String?
        var models: [String: Entry] = [:]
    }

    nonisolated static let fileName = "library-sync.json"

    /// Beside the library's folder: for the built-in vault, beside the book.
    nonisolated static func location(primary: String) -> URL {
        URL(fileURLWithPath: primary).deletingLastPathComponent().appending(path: fileName)
    }

    let url: URL
    private let lock = NSLock()
    private var disk: Disk

    private init(url: URL, disk: Disk) {
        self.url = url
        self.disk = disk
    }

    var root: String { lock.withLock { disk.root } }
    var migratedAt: String? { lock.withLock { disk.migratedAt } }
    var count: Int { lock.withLock { disk.models.count } }

    func entry(_ id: String) -> Entry? { lock.withLock { disk.models[id] } }
    func state(_ id: String) -> State? { entry(id)?.state }
    func isKept(_ id: String) -> Bool { entry(id)?.keep == true }
    var ids: Set<String> { lock.withLock { Set(disk.models.keys) } }

    /// The index for this library, from disk — or nil when there is none, it
    /// cannot be read, or it describes another folder: then `migrate`.
    nonisolated static func open(primary: String) -> LibrarySyncIndex? {
        let url = location(primary: primary)
        guard let data = try? Data(contentsOf: url),
              let disk = try? JSONDecoder().decode(Disk.self, from: data),
              disk.v == 1, disk.root == primary else { return nil }
        return LibrarySyncIndex(url: url, disk: disk)
    }

    /// A first index, read from the sidecars under every root, and written.
    ///
    /// `ids` is the book's model ids. A model with a `.cloud` sidecar and no
    /// file is online; with the file still there too (a crash between writing
    /// the sidecar and removing the file) it is backed up; an `.online`
    /// marker is online; a linked model its drive has not downloaded is
    /// online. Everything else starts as local: nothing on disk says this Mac
    /// ever proved a copy online.
    nonisolated static func migrate(primary: String, roots: [String], models: [Probe],
                                    now: Date = Date()) -> LibrarySyncIndex {
        var disk = Disk(root: primary, migratedAt: StoreWriter.iso(now))
        let at = StoreWriter.iso(now)
        for (id, state) in states(roots: roots, models: models) {
            disk.models[id] = Entry(state: state, keep: nil, at: at)
        }
        let index = LibrarySyncIndex(url: location(primary: primary), disk: disk)
        index.save()
        return index
    }

    /// What `migrate` and `reconcile` need of a model, read on the main actor
    /// and handed off.
    struct Probe: Sendable {
        let id: String
        /// For a linked model, its own file.
        let externalPath: String?
    }

    /// Each model's state, read from its folder's sidecars (or, for a linked
    /// model, its drive). One listing per model folder, off the main actor.
    nonisolated static func states(roots: [String], models: [Probe]) -> [String: State] {
        let fm = FileManager.default
        var out: [String: State] = [:]
        for model in models {
            if let path = model.externalPath, !path.isEmpty {
                let url = URL(fileURLWithPath: path)
                out[model.id] = fm.fileExists(atPath: path) && LinkedCloud.isOnlineOnly(url) ? .online : .local
                continue
            }
            guard let dir = LibraryLocation.directory(for: model.id, roots: roots) else {
                out[model.id] = .local
                continue
            }
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            out[model.id] = state(of: names)
        }
        return out
    }

    /// The state one folder's file names say.
    nonisolated static func state(of names: [String]) -> State {
        let set = Set(names)
        // `<model>.online.cloud` is the desktop moving a MARKER out: the
        // model was never here either way (`LibraryA65ReviewTests`).
        if names.contains(where: { $0.hasSuffix(Shop.onlineExt) || $0.hasSuffix(Shop.onlineExt + ".cloud") }) {
            return .online
        }
        let sidecars = names.filter { $0.hasSuffix(".cloud") }
        guard !sidecars.isEmpty else { return .local }
        // Each moved model either still here beside its sidecar, or not.
        let stillHere = sidecars.allSatisfy { set.contains(String($0.dropLast(".cloud".count))) }
        return stillHere ? .backedUp : .online
    }

    // MARK: - Changing it

    /// Record states, and write the file once for all of them.
    func set(_ changes: [String: State], now: Date = Date()) {
        guard !changes.isEmpty else { return }
        let at = StoreWriter.iso(now)
        let changed: Bool = lock.withLock {
            var any = false
            for (id, state) in changes {
                var e = disk.models[id] ?? Entry(state: state, keep: nil, at: at)
                if e.state != state || disk.models[id] == nil {
                    e.state = state
                    e.at = at
                    disk.models[id] = e
                    any = true
                }
            }
            return any
        }
        if changed { save() }
    }

    func set(_ id: String, _ state: State, now: Date = Date()) { set([id: state], now: now) }

    /// "Keep on this Mac", on or off.
    func setKeep(_ id: String, _ keep: Bool) {
        lock.withLock {
            var e = disk.models[id] ?? Entry(state: .local, keep: nil, at: StoreWriter.iso(Date()))
            e.keep = keep ? true : nil
            disk.models[id] = e
        }
        save()
    }

    /// Models gone from the book.
    func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let changed: Bool = lock.withLock {
            let before = disk.models.count
            for id in ids { disk.models[id] = nil }
            return disk.models.count != before
        }
        if changed { save() }
    }

    /// Bring the index level with the book: models it has never seen are read
    /// from their folders, models no longer in the book are dropped. Returns
    /// whether anything changed. Off the main actor; one listing per NEW model.
    @discardableResult
    func reconcile(roots: [String], models: [Probe]) -> Bool {
        let known = ids
        let inBook = Set(models.map(\.id))
        let fresh = models.filter { !known.contains($0.id) }
        let gone = known.subtracting(inBook)
        guard !fresh.isEmpty || !gone.isEmpty else { return false }
        let found = Self.states(roots: roots, models: fresh)
        let at = StoreWriter.iso(Date())
        lock.withLock {
            for id in gone { disk.models[id] = nil }
            for (id, state) in found { disk.models[id] = Entry(state: state, keep: nil, at: at) }
        }
        save()
        return true
    }

    /// Atomically, and quietly: a write that fails leaves the sidecars, which
    /// are the truth, and an index rebuilt from them next launch.
    private func save() {
        let snapshot = lock.withLock { disk }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Everything in it, for a test.
    var snapshot: Disk { lock.withLock { disk } }
}

/// What the Show menu can narrow the library to by where the bytes are.
enum LibraryStorageFilter: String, Hashable, Sendable {
    /// Not on this Mac.
    case onlineOnly
    /// On this Mac and nowhere else this Mac knows of.
    case thisMacOnly

    func matches(_ state: LibrarySyncIndex.State?) -> Bool {
        switch self {
        case .onlineOnly: return state == .online
        case .thisMacOnly: return (state ?? .local) == .local
        }
    }
}
