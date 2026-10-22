import Foundation
import CryptoKit
import KhaytCore

/// Where each model's files are, on THIS Mac: here only, here and backed up
/// online, or online only — kept in the app's own support folder, beside the
/// book, one file per library folder.
///
/// ── WHY A FILE OF ITS OWN, AND NOT THE BOOK ──────────────────────────────
///
/// It is a fact about this device's disk. The book syncs to the other Mac,
/// the phone and the cloud, and "online only" written there would tell a Mac
/// that has the file that it does not. So it lives in Application Support,
/// which nothing syncs or shares — never beside a library folder that may be
/// on a NAS or a cloud drive another Mac also reads. Keyed by a hash of the
/// library folder's path, so two libraries never share an index.
///
/// ── WHY AN INDEX AT ALL ──────────────────────────────────────────────────
///
/// The state lived only in sidecars — `<file>.cloud` (moved out, by either
/// app) and `<file>.online` (put in the bucket by the shop, never here) —
/// found by listing a model's folder on every question. A tile cannot do
/// that: 6,600 models on a NAS is 6,600 directory listings per draw. Here a
/// tile's badge, the Show menu's two filters and their counts are dictionary
/// reads.
///
/// ── PER FILE, AND "BACKED UP" ONLY WHILE IT IS PROVABLY TRUE ─────────────
///
/// A pack is several files in one folder, and one of them moved out does not
/// make the model online only: each file has its own entry, and a model is
/// online only when none of its files is here. "Backed up" is stamped with
/// WHERE (`remote`, the provider and bucket/prefix or Drive folder) and the
/// file as it was then (size, mtime). Read against another remote, or none,
/// it is "on this Mac only"; a file changed since reads the same, checked on
/// every load (`reconcile`).
///
/// ── THE SIDECARS STAY, AND STAY THE TRUTH ────────────────────────────────
///
/// This is written wherever this app writes or removes one, and filled from
/// them on first launch (`migrate`). They are not deleted: the Electron app
/// reads and writes them, Bring Back is driven by them, and the disk wins
/// over the index wherever a file is looked at (`Shop.isInCloudOnly`).
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

    /// One file of a model.
    struct FileEntry: Codable, Equatable, Sendable {
        var state: State
        /// For `.backedUp`: which remote proved it (`CloudLibrary.remoteIdentity`).
        var remote: String?
        /// For `.backedUp`: the file as it was when it was proved.
        var size: Int?
        var mtimeMs: Double?
        var at: String?
    }

    struct Entry: Codable, Equatable, Sendable {
        /// By file name, in the model's folder (a linked model: its own file).
        var files: [String: FileEntry] = [:]
        /// "Keep on this Mac": Free up space never moves it out.
        var keep: Bool?
    }

    struct Disk: Codable, Equatable, Sendable {
        var v = 2
        /// The library folder this describes.
        var root: String
        /// When the sidecars were read into it.
        var migratedAt: String?
        var models: [String: Entry] = [:]
    }

    /// `library-sync-<hash of the root>.json`.
    nonisolated static func fileName(root: String) -> String {
        let digest = SHA256.hash(data: Data(root.utf8)).map { String(format: "%02x", $0) }.joined()
        return "library-sync-" + digest.prefix(16) + ".json"
    }

    /// In `folder` — the book's own support folder.
    nonisolated static func location(primary: String, folder: URL) -> URL {
        folder.appending(path: fileName(root: primary))
    }

    /// Where the first build of this wrote it: beside the library folder.
    nonisolated static func legacyLocation(primary: String) -> URL {
        URL(fileURLWithPath: primary).deletingLastPathComponent().appending(path: "library-sync.json")
    }

    let url: URL
    private let lock = NSLock()
    /// Held for a whole save — the snapshot AND the write — so an older
    /// snapshot can never land after a newer one.
    private let saving = NSLock()
    private var disk: Disk

    private init(url: URL, disk: Disk) {
        self.url = url
        self.disk = disk
    }

    var root: String { lock.withLock { disk.root } }
    var migratedAt: String? { lock.withLock { disk.migratedAt } }
    var count: Int { lock.withLock { disk.models.count } }
    var ids: Set<String> { lock.withLock { Set(disk.models.keys) } }

    func entry(_ id: String) -> Entry? { lock.withLock { disk.models[id] } }
    func isKept(_ id: String) -> Bool { entry(id)?.keep == true }

    /// The model's state, against the remote in use now (nil: none).
    ///
    /// Online only when none of its files is here; backed up when every file
    /// here was proved on THIS remote; on this Mac only otherwise. Nil when
    /// nothing is known about it.
    func state(_ id: String, remote: String?) -> State? {
        guard let files = entry(id)?.files, !files.isEmpty else { return nil }
        return Self.modelState(files.values, remote: remote)
    }

    nonisolated static func modelState<S: Sequence>(_ files: S, remote: String?) -> State
    where S.Element == FileEntry {
        var here = 0, proved = 0, online = 0
        for f in files {
            switch f.state {
            case .online: online += 1
            case .local: here += 1
            case .backedUp:
                here += 1
                if let remote, f.remote == remote { proved += 1 }
            }
        }
        if here == 0 { return online > 0 ? .online : .local }
        return proved == here ? .backedUp : .local
    }

    /// The index for this library, from `folder` — or nil when there is none,
    /// it cannot be read, or it describes another folder: then `migrate`.
    nonisolated static func open(primary: String, folder: URL) -> LibrarySyncIndex? {
        let url = location(primary: primary, folder: folder)
        guard let data = try? Data(contentsOf: url),
              let disk = try? JSONDecoder().decode(Disk.self, from: data),
              disk.v == 2, disk.root == primary else { return nil }
        return LibrarySyncIndex(url: url, disk: disk)
    }

    /// The keep choices of an index the first build wrote beside the library
    /// folder, and that file removed — it was in a place another Mac may
    /// share. Its states are not carried over: they are read again from the
    /// sidecars, per file, which the old file did not record.
    nonisolated static func takeLegacy(primary: String) -> Set<String> {
        let url = legacyLocation(primary: primary)
        guard let data = try? Data(contentsOf: url) else { return [] }
        defer { try? FileManager.default.removeItem(at: url) }
        struct Old: Decodable {
            struct E: Decodable { var keep: Bool? }
            var root: String
            var models: [String: E]
        }
        guard let old = try? JSONDecoder().decode(Old.self, from: data), old.root == primary else { return [] }
        return Set(old.models.filter { $0.value.keep == true }.keys)
    }

    /// A first index, read from the sidecars under every root, and written.
    nonisolated static func migrate(primary: String, folder: URL, roots: [String], models: [Probe],
                                    keep: Set<String> = [], now: Date = Date()) -> LibrarySyncIndex {
        let at = StoreWriter.iso(now)
        var disk = Disk(root: primary, migratedAt: at)
        for model in models {
            var entry = Entry(files: files(of: model, roots: roots, at: at))
            if keep.contains(model.id) { entry.keep = true }
            disk.models[model.id] = entry
        }
        let index = LibrarySyncIndex(url: location(primary: primary, folder: folder), disk: disk)
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

    /// A model's files as its folder (or, linked, its drive) says now. One
    /// listing; never a read of a file's bytes.
    nonisolated static func files(of model: Probe, roots: [String], at: String) -> [String: FileEntry] {
        let fm = FileManager.default
        if let path = model.externalPath, !path.isEmpty {
            guard fm.fileExists(atPath: path) else { return [:] }
            let online = LinkedCloud.isOnlineOnly(URL(fileURLWithPath: path))
            return [(path as NSString).lastPathComponent: FileEntry(state: online ? .online : .local, at: at)]
        }
        guard let dir = LibraryLocation.directory(for: model.id, roots: roots) else { return [:] }
        return files(of: (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [], at: at)
    }

    /// The files one folder's names say.
    ///
    /// A model file here is here — a sidecar beside it is a crash between
    /// writing the sidecar and removing the file, and proves no remote, so it
    /// reads as on this Mac only. A sidecar or marker with no file beside it
    /// is that file online. `<file>.online.cloud` is the desktop moving a
    /// MARKER out: the file was never here either way.
    nonisolated static func files(of names: [String], at: String? = nil) -> [String: FileEntry] {
        let present = Set(names)
        var out: [String: FileEntry] = [:]
        for name in names {
            var base: String?
            if name.hasSuffix(Shop.onlineExt + ".cloud") {
                base = String(name.dropLast((Shop.onlineExt + ".cloud").count))
            } else if name.hasSuffix(".cloud") {
                base = String(name.dropLast(".cloud".count))
            } else if name.hasSuffix(Shop.onlineExt) {
                base = String(name.dropLast(Shop.onlineExt.count))
            }
            if let base {
                if !present.contains(base) { out[base] = FileEntry(state: .online, at: at) }
                continue
            }
            let ext = (name as NSString).pathExtension.lowercased()
            guard LibraryImport.kinds.contains(ext), !name.contains(".part-") else { continue }
            out[name] = FileEntry(state: .local, at: at)
        }
        return out
    }

    // MARK: - Changing it

    /// Record files' states, by model, and write the file ONCE for all of
    /// them. A model's other files are left as they were.
    func record(_ changes: [String: [String: FileEntry]]) {
        guard !changes.isEmpty else { return }
        lock.withLock {
            for (id, files) in changes {
                var e = disk.models[id] ?? Entry()
                for (name, file) in files { e.files[name] = file }
                disk.models[id] = e
            }
        }
        save()
    }

    /// Replace what is known of models' files with what their folders say.
    func replaceFiles(_ found: [String: [String: FileEntry]]) {
        guard !found.isEmpty else { return }
        lock.withLock {
            for (id, files) in found {
                var e = disk.models[id] ?? Entry()
                e.files = files
                disk.models[id] = e
            }
        }
        save()
    }

    /// "Keep on this Mac", on or off.
    func setKeep(_ ids: Set<String>, _ keep: Bool) {
        guard !ids.isEmpty else { return }
        lock.withLock {
            for id in ids {
                var e = disk.models[id] ?? Entry()
                e.keep = keep ? true : nil
                disk.models[id] = e
            }
        }
        save()
    }

    func setKeep(_ id: String, _ keep: Bool) { setKeep([id], keep) }

    /// Bring the index level with the book and the disk: models it has never
    /// seen are read from their folders, models no longer in the book are
    /// dropped, and every "backed up" file is checked against its size and
    /// mtime (a stat, never a read) — one edited since is on this Mac only.
    /// Returns whether anything changed. Off the main actor.
    @discardableResult
    func reconcile(roots: [String], models: [Probe], now: Date = Date()) -> Bool {
        let at = StoreWriter.iso(now)
        let current = lock.withLock { disk.models }
        let inBook = Set(models.map(\.id))
        let gone = Set(current.keys).subtracting(inBook)
        var fresh: [String: [String: FileEntry]] = [:]
        var stale: [String: [String: FileEntry]] = [:]
        for model in models {
            guard let known = current[model.id] else {
                fresh[model.id] = Self.files(of: model, roots: roots, at: at)
                continue
            }
            for (name, file) in known.files where file.state == .backedUp {
                guard let url = Self.url(of: name, model: model, roots: roots),
                      Self.stillAsProved(file, url) else {
                    stale[model.id, default: [:]][name] = FileEntry(state: .local, at: at)
                    continue
                }
            }
        }
        guard !fresh.isEmpty || !gone.isEmpty || !stale.isEmpty else { return false }
        lock.withLock {
            for id in gone { disk.models[id] = nil }
            for (id, files) in fresh { disk.models[id] = Entry(files: files, keep: disk.models[id]?.keep) }
            for (id, files) in stale {
                for (name, file) in files { disk.models[id]?.files[name] = file }
            }
        }
        save()
        return true
    }

    nonisolated static func url(of name: String, model: Probe, roots: [String]) -> URL? {
        if let path = model.externalPath, !path.isEmpty { return URL(fileURLWithPath: path) }
        return LibraryLocation.directory(for: model.id, roots: roots)?.appending(path: name)
    }

    /// The size and mtime a file has now.
    nonisolated static func stamp(_ url: URL) -> (size: Int, mtimeMs: Double)? {
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = v.fileSize, let m = v.contentModificationDate else { return nil }
        return (size, (m.timeIntervalSince1970 * 1000).rounded())
    }

    /// Is the file still the bytes that were proved online?
    nonisolated static func stillAsProved(_ file: FileEntry, _ url: URL) -> Bool {
        guard let now = stamp(url) else { return false }
        return file.size == now.size && file.mtimeMs == now.mtimeMs
    }

    /// A file proved online by `remote`, as it is now.
    nonisolated static func backedUp(_ url: URL, remote: String?, at: Date = Date()) -> FileEntry {
        let s = stamp(url)
        return FileEntry(state: remote == nil || s == nil ? .local : .backedUp, remote: remote,
                         size: s?.size, mtimeMs: s?.mtimeMs, at: StoreWriter.iso(at))
    }

    /// Serialised as a whole: the snapshot is taken inside the save lock, so
    /// whichever save runs last writes the newest state. Quietly: a write that
    /// fails leaves the sidecars, which are the truth, and an index read from
    /// them again.
    private func save() {
        saving.withLock {
            let snapshot = lock.withLock { disk }
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
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
