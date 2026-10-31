import Foundation
import KhaytCore

/// ── COMPRESSED FILES AS FOLDERS ─────────────────────────────────────────
///
/// A ZIP, RAR, 7-Zip or tar sitting in a LINKED folder appears in the library
/// as a folder named after it, its models as tiles — measured, pictured and
/// priced like any linked model — and the shop never unpacks it. Meshory
/// does this; model sites hand packs over as zips, and a shop that keeps its
/// downloads as they came had a hole in its library wherever one sat.
///
/// THE RECORD. One per model member, a linked record like any other:
/// `externalPath` is the ARCHIVE (so unlinking the folder, the "deleted, do
/// not index again" list and the folder label all just work), and
/// `archiveMember` names the member as the archive lists it. `archiveHash` is
/// the archive's SHA-256 when it was indexed, and keys the cache.
///
/// THE BYTES. Nothing reads the archive as a model. Measuring, previewing,
/// opening, quoting or starting a job asks `modelFile`, which hands out the
/// member extracted to the cache (`ArchiveMembers.Cache`, 4 GB in
/// ~/Library/Caches, least recently used let go first) — extracted once, when
/// it is indexed, and again on demand (`materialise`) after the cache lets it
/// go. The archive is never rewritten: deleting a member deletes its record
/// and remembers its key; the archive and its other members are untouched.
///
/// ONLINE-ONLY. An archive its drive has not downloaded is listed as
/// nothing: listing a RAR is reading it, reading it is downloading it, and a
/// pack of a gigabyte is not something to fetch unasked. It is counted in
/// the scan's sentence instead, and indexed once it is on this Mac.
extension Shop {

    // MARK: - The member's bytes

    /// A member's extracted copy, when the cache has it and the archive is
    /// still where it was. Never extracts (`materialise` does).
    nonisolated static func archiveCopy(of file: LibraryFile,
                                        cache: ArchiveMembers.Cache = .shared) -> URL? {
        guard let path = file.archivePath, let member = file.archiveEntry, !member.encrypted,
              let hash = file.archiveHash, !hash.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return cache.cached(key: ArchiveFolder.cacheKey(archiveHash: hash, member: member.path),
                            leaf: ArchiveFolder.cacheLeaf(member), touching: false)
    }

    /// The member extracted to the cache — now, if the cache had let it go —
    /// off the main actor. Nil for a locked member, an archive that is gone
    /// or still online, or one that will not give the member up.
    @discardableResult
    func materialise(_ file: LibraryFile) async -> URL? {
        guard file.inArchive, !file.isLocked, let path = file.archivePath, let member = file.archiveEntry,
              let hash = file.archiveHash, !hash.isEmpty else { return nil }
        if let here = Self.archiveCopy(of: file) {
            ArchiveMembers.Cache.shared.touch(ArchiveFolder.cacheKey(archiveHash: hash, member: member.path))
            return here
        }
        let url = URL(fileURLWithPath: path)
        let isOnline = linkedIsOnline
        guard !archiveExtracting.contains(file.id) else { return nil }
        archiveExtracting.insert(file.id)
        defer { archiveExtracting.remove(file.id) }
        let got = await PinWork.run { () -> URL? in
            guard FileManager.default.fileExists(atPath: path), !isOnline(url) else { return nil }
            return try? ArchiveMembers.materialise(member, of: url, archiveHash: hash)
        }
        archiveCacheRevision &+= 1
        return got
    }

    /// Bring Back for a member: its archive read whole (which is what makes a
    /// drive fetch it), then the member extracted.
    func bringDownArchive(_ file: LibraryFile) async {
        guard let path = file.archivePath else { return }
        _ = await PinWork.run { (try? LibraryImport.contentHash(of: URL(fileURLWithPath: path))) ?? nil }
        await materialise(file)
    }

    /// What Show in Finder shows for a model: a member's ARCHIVE, never the
    /// cache's copy (which the shop did not put anywhere).
    func revealable(_ file: LibraryFile) -> URL? {
        if let path = file.archivePath {
            return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        return modelFile(for: file)
    }

    // MARK: - Folders that are archives

    /// The archive's file name, for a group whose every model came out of
    /// that one archive — how its folder tile knows to look like one. Worked
    /// out once per change to the library.
    func archiveName(ofGroup path: String) -> String? {
        if let memo = archiveGroupMemo, memo.revision == filesRevision { return memo.names[path] }
        var names: [String: String] = [:]
        var mixed: Set<String> = []
        for file in files where !file.isArchived {
            guard let group = file.groupName, !mixed.contains(group) else { continue }
            guard let archive = file.archivePath else { mixed.insert(group); names[group] = nil; continue }
            let name = (archive as NSString).lastPathComponent
            if let was = names[group], was != name { mixed.insert(group); names[group] = nil; continue }
            names[group] = name
        }
        archiveGroupMemo = (filesRevision, names)
        return names[path]
    }

    /// The models of the archive a group is, in the library's order.
    func archiveMembers(ofGroup path: String) -> [LibraryFile] {
        files.filter { !$0.isArchived && $0.inArchive && $0.groupName == path }
    }

    /// "Remove from Library…" on an archive's folder tile: exactly its
    /// models put on the grid (drawn flat, as Library Health's Show does, so
    /// none is folded inside a tile), then the library's own delete question
    /// with the exact count — `askToDeleteFromLibrary`, which refuses if any
    /// is not on screen (27 Sep 2026). The archive itself is never touched.
    @discardableResult
    func askToRemoveArchive(ofGroup path: String) -> [LibraryFile] {
        guard permitted("inventory", "delete") else { return [] }
        let chosen = archiveMembers(ofGroup: path)
        guard !chosen.isEmpty else { return [] }
        clearLibraryFilter()
        search = ""
        shelf = .library(nil)
        libraryFlat = true
        libraryHealthFocus = LibraryHealthFocus(kind: .missing, ids: chosen.map(\.id),
                                                label: archiveName(ofGroup: path) ?? Shop.groupLeaf(path))
        libraryHealthOpen = false
        fileSelection = []
        return askToDeleteFromLibrary(chosen)
    }

    // MARK: - Indexing

    /// What one pass over the linked folders' archives did.
    struct ArchiveScan: Equatable, Sendable {
        var added = 0
        var locked = 0
        /// Archives an online drive has not downloaded: listed as nothing.
        var online = 0
        /// Archives not opened, each with the reason, for the sentence.
        var refused: [String] = []
        var failures: [String] = []
        var addedIds: [String] = []
        /// Members of a changed archive read again under its new hash, and
        /// members it no longer holds.
        var refreshed = 0
        var gone = 0
    }

    /// What the book holds about one archive already indexed: the hash its
    /// members were indexed under, and the archive's size and time then.
    struct IndexedArchive: Sendable, Equatable {
        var hash: String?
        var bytes: Int?
        var modified: Double?
        /// When the first member was indexed (epoch ms) — for records made
        /// before the size and time were kept.
        var indexedAt: Double?
        /// Each member's record id and its name in the archive.
        var members: [(id: String, member: String)] = []

        static func == (a: Self, b: Self) -> Bool {
            a.hash == b.hash && a.bytes == b.bytes && a.modified == b.modified && a.indexedAt == b.indexedAt
                && a.members.map(\.id) == b.members.map(\.id) && a.members.map(\.member) == b.members.map(\.member)
        }
    }

    /// The archives the book's members came from, by standardised path.
    /// Locked members (no hash) are left out: nothing of theirs is cached.
    nonisolated static func indexedArchives(_ files: [LibraryFile]) -> [String: IndexedArchive] {
        var out: [String: IndexedArchive] = [:]
        for f in files where f.inArchive && !f.isLocked {
            guard let path = f.archivePath, let member = f.archiveMember, let hash = f.archiveHash else { continue }
            let key = URL(fileURLWithPath: path).standardizedFileURL.path
            var a = out[key] ?? IndexedArchive(hash: hash, bytes: f.archiveBytes.map { Int($0) }, modified: f.archiveModified)
            let at = f.createdAt?.date.map { $0.timeIntervalSince1970 * 1000 }
            if let at { a.indexedAt = min(a.indexedAt ?? at, at) }
            a.members.append((f.id, member))
            out[key] = a
        }
        return out
    }

    /// The archive's size and modification time (epoch ms) on disk now.
    nonisolated static func archiveStamp(_ url: URL) -> (bytes: Int, modified: Double?) {
        let at = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil
        return (ArchiveMembers.size(of: url), at.map { ($0.timeIntervalSince1970 * 1000).rounded() })
    }

    /// Whether an indexed archive may have changed since: its size or time
    /// differ from the ones kept, or — for records made before they were
    /// kept — it was modified after its members were indexed.
    nonisolated static func mayHaveChanged(_ was: IndexedArchive, bytes: Int, modified: Double?) -> Bool {
        if let b = was.bytes, b != bytes { return true }
        if let m = was.modified { return modified != nil && modified != m }
        guard let modified, let at = was.indexedAt else { return true }
        return modified > at
    }

    /// Index the model members of every archive the linked walk found, that
    /// the book does not already hold (by `memberKey`, or remembered as
    /// deleted). Each member is extracted to the cache and read through the
    /// import's own `prepare`, so it is measured and pictured exactly as a
    /// loose model would be; a locked member is listed and not opened.
    /// Written a batch at a time, through the store's chain.
    static func indexArchives(_ found: [(root: URL, archives: [URL])], known: Set<String>,
                                          storeURL: URL, libraryRoot: URL, engine: KhaytEngine,
                                          isOnline: @escaping @Sendable (URL) -> Bool,
                                          cache: ArchiveMembers.Cache = .shared,
                                          limits: ArchiveFolder.Limits = .init(),
                                          owns: @escaping @Sendable () -> Bool,
                                          whoHasIt: @escaping @Sendable () -> String?,
                                          stop: ScanStop? = nil,
                                          indexed: [String: IndexedArchive] = [:]) async -> ArchiveScan {
        // lock: callers — rescanLinkedFolders, archiveRows
        var scan = ArchiveScan()
        var held: [LibraryImport.Prepared] = []
        var ids = Set<String>()
        func stopped() -> Bool { stop?.isStopped == true || Task.isCancelled }
        func writeHeld() async {
            // lock: callers — indexArchives
            guard !held.isEmpty else { return }
            do {
                try await LibraryImport.write(held, storeURL: storeURL, owns: owns, whoHasIt: whoHasIt)
                scan.added += held.count
                scan.addedIds += held.map(\.added.id)
            } catch {
                for p in held { try? FileManager.default.removeItem(at: p.dir) }
                scan.failures.append(ErrorText.plain(error))
            }
            held = []
        }
        for (root, archives) in found {
            for url in archives {
                if stopped() { break }
                let name = url.lastPathComponent
                let path = url.standardizedFileURL.path
                if isOnline(url) { scan.online += 1; continue }
                let listed: Result<[ArchiveFolder.Member], Error> = await PinWork.run {
                    Result { try ArchiveMembers.list(url) }
                }
                let members: [ArchiveFolder.Member]
                switch listed {
                case .success(let m): members = m
                case .failure(ArchiveMembers.Failure.locked):
                    // Locked to the listing itself (a 7-Zip with its names
                    // encrypted): nothing to show but that it is locked.
                    scan.locked += 1; continue
                case .failure(let e): scan.refused.append("\(name): \(e)"); continue
                }
                let bytes = ArchiveMembers.size(of: url)
                let verdict = ArchiveFolder.judge(members, archiveBytes: bytes,
                                                  modelKinds: LibraryImport.kinds, limits: limits)
                let models: [ArchiveFolder.Member]
                var lockedAll = false
                switch verdict {
                case .open(let m): models = m
                case .locked(let m): models = m; lockedAll = true
                case .noModels: continue
                case .refused(let why): scan.refused.append("\(name): \(why)"); continue
                }
                let fresh = models.filter { !known.contains(ArchiveFolder.memberKey(archive: path, member: $0.path)) }
                let stamp = archiveStamp(url)
                // A CHANGED ARCHIVE — a newer pack saved over the old one —
                // is a new hash: its members are read again under it, and
                // one it no longer holds is marked gone. Without this the
                // records kept the old hash, so the cache handed out the OLD
                // bytes, and once it let them go the member never opened again.
                var hash: String?
                var hashed = false
                if !lockedAll, let was = indexed[path], was.hash != nil,
                   mayHaveChanged(was, bytes: stamp.bytes, modified: stamp.modified) {
                    hash = await PinWork.run { (try? LibraryImport.contentHash(of: url)) ?? nil }
                    hashed = true
                    if let hash {
                        await refreshChanged(was, archive: url, now: hash, stamp: stamp, models: models,
                                             storeURL: storeURL, engine: engine, cache: cache,
                                             owns: owns, whoHasIt: whoHasIt, scan: &scan)
                    }
                }
                guard !fresh.isEmpty else { continue }
                // The archive's own hash keys the cache: read once, here.
                if !hashed, !lockedAll { hash = await PinWork.run { (try? LibraryImport.contentHash(of: url)) ?? nil } }
                let archiveHash = hash
                let group = archiveGroup(url, under: root)
                for member in fresh {
                    if stopped() { break }
                    var id = Shop.uid("PF")
                    while !ids.insert(id).inserted { id = Shop.uid("PF") }
                    var ref = LibraryImport.ArchiveRef(path: path, member: member, hash: hash)
                    ref.bytes = stamp.bytes
                    ref.modified = stamp.modified
                    if lockedAll || member.encrypted || hash == nil {
                        held.append(LibraryImport.prepareLocked(ref, libraryRoot: libraryRoot, group: group, id: id))
                        scan.locked += 1
                        continue
                    }
                    let copy: Result<URL, Error> = await PinWork.run {
                        Result { try ArchiveMembers.materialise(member, of: url, archiveHash: archiveHash ?? "", cache: cache) }
                    }
                    do {
                        let file = try copy.get()
                        // Every member, a copy of a model already here
                        // included: the archive is shown as it is, and
                        // Library Health lists the same file twice.
                        let made = try await LibraryImport.prepare(file, libraryRoot: libraryRoot, knownHashes: [],
                                                                   nameOfExisting: { _ in nil }, engine: engine,
                                                                   inPlace: true, group: group, id: id, archive: ref)
                        held.append(made)
                    } catch ArchiveMembers.Failure.locked {
                        held.append(LibraryImport.prepareLocked(ref, libraryRoot: libraryRoot, group: group, id: id))
                        scan.locked += 1
                    } catch {
                        scan.failures.append("\(name) › \(member.leaf): \(error)")
                    }
                    if held.count >= LibraryImport.writeBatch { await writeHeld() }
                }
            }
        }
        await writeHeld()
        return scan
    }

    /// An indexed archive whose bytes may have changed, hashed again: under a
    /// NEW hash, each member it still holds is extracted and read again
    /// (`readDownloaded` / `applyDownloaded`, as Measure does — the shop's
    /// own fields are never replaced) and re-keyed; a member it no longer
    /// holds is marked `archiveGone`. Under the SAME hash only the size and
    /// time are kept, so the next scan does not read it again. One write.
    static func refreshChanged(_ was: IndexedArchive, archive url: URL, now hash: String,
                               stamp: (bytes: Int, modified: Double?), models: [ArchiveFolder.Member],
                               storeURL: URL, engine: KhaytEngine, cache: ArchiveMembers.Cache,
                               owns: @escaping @Sendable () -> Bool,
                               whoHasIt: @escaping @Sendable () -> String?,
                               scan: inout ArchiveScan) async {
        // lock: callers — indexArchives
        let changed = hash != was.hash
        var reads: [String: DownloadedRead] = [:]
        var present: Set<String> = []
        if changed {
            let byPath = Dictionary(models.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            for (id, name) in was.members {
                guard let member = byPath[name] else { continue }
                present.insert(id)
                let copy: Result<URL, Error> = await PinWork.run {
                    Result { try ArchiveMembers.materialise(member, of: url, archiveHash: hash, cache: cache) }
                }
                guard let file = try? copy.get() else { continue }
                if let read = try? await readDownloaded(file: file, pictures: nil, engine: engine) { reads[id] = read }
            }
        } else {
            present = Set(was.members.map(\.id))
        }
        let ids = Set(was.members.map(\.id))
        let held = present, filled = reads
        do {
            try await StoreWriter.updateOffMain(storeURL: storeURL, owns: owns, whoHasIt: whoHasIt) { book in
                var rows = Shop.rows(book, "printFiles")
                for (i, row) in rows.enumerated() {
                    guard case .object(var o) = row, let id = Shop.recordId(row), ids.contains(id) else { continue }
                    o["archiveBytes"] = .number(Double(stamp.bytes))
                    if let m = stamp.modified { o["archiveModified"] = .number(m) }
                    if held.contains(id) {
                        o["archiveHash"] = .string(hash)
                        o.removeValue(forKey: "archiveGone")
                    } else {
                        o["archiveGone"] = .bool(true)
                    }
                    rows[i] = .object(o)
                }
                book["printFiles"] = .array(rows)
                if !filled.isEmpty { _ = Shop.applyDownloaded(filled, to: &book) }
            }
            if changed { scan.refreshed += present.count; scan.gone += ids.count - present.count }
        } catch {
            scan.failures.append("\(url.lastPathComponent): \(error)")
        }
    }

    /// The group an archive's models are filed in: the folders it sits in
    /// below the linked folder, by the same rule as a loose model's
    /// (`ImportGrouping.levels`, the linked folder's own name left out), and
    /// then the archive's own name as a person would spell it. Always a
    /// folder, even for one model: it is the archive, drawn as a folder.
    nonisolated static func archiveGroup(_ archive: URL, under root: URL) -> String {
        let parent = ImportGrouping.levels(for: archive, chosen: root, includeChosen: false)
        let base = ArchiveFolder.baseName(of: archive.lastPathComponent)
        let named = ImportGrouping.display(ImportGrouping.meaningful(base) ?? base)
        return ImportGrouping.fitting(parent + [named])
    }

    /// The scan's sentence about archives, or nil when there were none.
    func archiveScanLines(_ scan: ArchiveScan) -> [String] {
        var lines: [String] = []
        if scan.added > 0 { lines.append(words.counting(scan.added, "mac.arc_scanned")) }
        if scan.locked > 0 { lines.append(words.callIt("mac.arc_locked_n", ["n": .number(Double(scan.locked))])) }
        if scan.online > 0 { lines.append(words.counting(scan.online, "mac.arc_online_n")) }
        if !scan.refused.isEmpty {
            lines.append(words.callIt("mac.arc_refused_n", ["n": .number(Double(scan.refused.count))]))
        }
        return lines
    }
}
