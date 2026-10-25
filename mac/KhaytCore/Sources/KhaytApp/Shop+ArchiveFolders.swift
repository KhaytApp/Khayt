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
                                          stop: ScanStop? = nil) async -> ArchiveScan {
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
                scan.failures.append(String(describing: error))
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
                guard !fresh.isEmpty else { continue }
                // The archive's own hash keys the cache: read once, here.
                let hash = lockedAll ? nil : await PinWork.run { (try? LibraryImport.contentHash(of: url)) ?? nil }
                let group = archiveGroup(url, under: root)
                for member in fresh {
                    if stopped() { break }
                    var id = Shop.uid("PF")
                    while !ids.insert(id).inserted { id = Shop.uid("PF") }
                    let ref = LibraryImport.ArchiveRef(path: path, member: member, hash: hash)
                    if lockedAll || member.encrypted || hash == nil {
                        held.append(LibraryImport.prepareLocked(ref, libraryRoot: libraryRoot, group: group, id: id))
                        scan.locked += 1
                        continue
                    }
                    let copy: Result<URL, Error> = await PinWork.run {
                        Result { try ArchiveMembers.materialise(member, of: url, archiveHash: hash ?? "", cache: cache) }
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
        if scan.added > 0 { lines.append(words.callIt("mac.arc_scanned", ["n": .number(Double(scan.added))])) }
        if scan.locked > 0 { lines.append(words.callIt("mac.arc_locked_n", ["n": .number(Double(scan.locked))])) }
        if scan.online > 0 { lines.append(words.callIt("mac.arc_online_n", ["n": .number(Double(scan.online))])) }
        if !scan.refused.isEmpty {
            lines.append(words.callIt("mac.arc_refused_n", ["n": .number(Double(scan.refused.count))]))
        }
        return lines
    }
}
