import Foundation
import KhaytCore

/// Model files sitting in the library's OWN folder that the library does not
/// know about — adopted where they are.
///
/// Asked for by the shop (Oct 2026): "library should read the storage for any
/// 3d files and add them to the library". A shop whose library lives in iCloud
/// Drive or on a NAS drops files into that folder from the Finder, from another
/// Mac, from a phone, and the library never saw them: only an import wrote a
/// record, and nothing looked at the folder itself.
///
/// ── ADOPTED IN PLACE, THE WAY A LINKED FOLDER IS ─────────────────────────
///
/// The record points at the file (`externalPath`) and the vault folder holds
/// only its picture. Nothing is copied, moved, renamed or deleted — the same
/// `LibraryImport.addMany(… keepOriginal: true, inPlace: true)` the linked
/// folders use, deduplicated by content hash the way every import is.
///
/// ── WHAT IS NEVER ADOPTED ─────────────────────────────────────────────────
///
/// * Anything inside a RECORD's folder (`<root>/<itemDirName(id)>/`): the
///   model, its versions and converted copies (`lib/print-versions.js` keeps
///   them there), its thumbs, its guides, its `.cloud` sidecar.
/// * Anything inside a folder shaped like one (`PF-…`, `unsorted`) whose
///   record is gone. That is a model deleted on the other Mac of a synced book,
///   or one whose Trash failed — adopting it would bring a deleted model back.
/// * `group-pictures/`, hidden files, `.Trash`, symlinks, packages.
/// * Files the shop deleted from the library after they were adopted
///   (`settings.printLibrary.notAdopted`): deleting such a record leaves the
///   file where the shop put it, so without this it came back on next launch.
///
/// ── ONLY WHERE THE LIBRARY LIVES NOW ──────────────────────────────────────
///
/// The primary root, not the mirror and not past locations. The mirror is a
/// backup copy that is never read from; a past location is what the other app's
/// "move stranded files" walks and relocates WHOLE (`printLibStrandedFiles`),
/// so a record pointing into one would lose its file to the next move.
extension Shop {

    /// What one pass found and did, for the sentence afterwards.
    struct StorageReport: Equatable, Sendable {
        var added = 0
        var duplicates = 0
        var photos = 0
        var failures: [String] = []
        /// True when the walk stopped at its cap — there may be more.
        var capped = false
        var addedIds: [String] = []
    }

    /// How far one pass looks, so a NAS with half a million files cannot hold
    /// a book's load hostage. A capped pass says so; the next one continues,
    /// because what it added is known by then.
    nonisolated static let storageVisitCap = 100_000
    nonisolated static let storageAdoptCap = 500

    /// Files the shop deleted from the library after they were adopted.
    var notAdopted: Set<String> {
        guard case .object(let l)? = settingsDict["printLibrary"],
              case .array(let rows)? = l["notAdopted"] else { return [] }
        return Set(rows.compactMap { if case .string(let s) = $0 { s } else { nil } })
    }

    /// A folder at the root that is Khayt's own, whether or not a record still
    /// names it.
    nonisolated static func isKhaytFolder(_ name: String, recordDirs: Set<String>) -> Bool {
        recordDirs.contains(name) || name.hasPrefix("PF-") || name == "unsorted"
            || name == GroupPictures.folderName
    }

    /// The untracked model files under a library root, grouped and with their
    /// photos. Reads only.
    ///
    /// - Parameters:
    ///   - rows: the book's `printFiles`, raw — so a record this build cannot
    ///     decode still owns its folder.
    ///   - ignored: paths the shop deleted after adoption.
    nonisolated static func untrackedInStorage(_ root: URL, rows: [JSONValue], ignored: Set<String>,
                                               visitCap: Int = storageVisitCap,
                                               adoptCap: Int = storageAdoptCap)
        -> (files: [LibraryImport.Incoming], capped: Bool) {
        let fm = FileManager.default
        var recordDirs: Set<String> = []
        var known: Set<String> = []
        for row in rows {
            guard case .object(let o) = row else { continue }
            if case .string(let id)? = o["id"] { recordDirs.insert(LibraryLocation.itemDirName(id)) }
            if case .string(let p)? = o["externalPath"], !p.isEmpty {
                let url = URL(fileURLWithPath: p)
                known.insert(url.standardizedFileURL.path)
                known.insert(url.resolvingSymlinksInPath().standardizedFileURL.path)
            }
        }
        known.formUnion(ignored)
        func isKnown(_ url: URL) -> Bool {
            known.contains(url.standardizedFileURL.path)
                || known.contains(url.resolvingSymlinksInPath().standardizedFileURL.path)
        }
        func isModel(_ url: URL) -> Bool {
            LibraryImport.kinds.contains(url.pathExtension.lowercased()) && LibraryImport.isRegularFile(url)
        }

        // The root as it really is, so a root reached through a symlink is
        // walked, and every path found is spelled one way.
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        let top = ((try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: keys,
                                                options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var out: [LibraryImport.Incoming] = []
        var visited = 0
        var capped = false
        for entry in top {
            if capped { break }
            guard let v = try? entry.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
            if v.isDirectory == true {
                let name = entry.lastPathComponent
                guard !isKhaytFolder(name, recordDirs: recordDirs), name != ".Trash" else { continue }
                // Every model under it, known ones too: "a folder of one model"
                // and its grouping are judged over the whole folder, so a second
                // file dropped beside an adopted one is grouped the same way.
                var all: [URL] = []
                let walker = fm.enumerator(at: entry, includingPropertiesForKeys: LibraryImport.fileKeys,
                                           options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let next = walker?.nextObject() as? URL {
                    visited += 1
                    if visited > visitCap { capped = true; break }
                    if isModel(next) { all.append(next) }
                }
                let fresh = Set(all.filter { !isKnown($0) })
                guard !fresh.isEmpty else { continue }
                let photos = ModelPhoto.candidates(for: Array(fresh), everyModel: all, boundary: entry)
                for incoming in ImportGrouping.incoming(all, chosen: entry) where fresh.contains(incoming.url) {
                    var file = incoming
                    file.photos = photos[incoming.url] ?? []
                    out.append(file)
                }
            } else if v.isRegularFile == true {
                visited += 1
                guard isModel(entry), !isKnown(entry) else { continue }
                // Loose at the root: no group, and a photo only by its own
                // name — the root is the whole library, not one model's folder.
                var file = LibraryImport.Incoming(url: entry, group: nil)
                file.photos = ModelPhoto.candidates(for: [entry], everyModel: [entry], boundary: nil)[entry] ?? []
                out.append(file)
            }
        }
        out.sort { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        if out.count > adoptCap { out = Array(out.prefix(adoptCap)); capped = true }
        return (out, capped)
    }

    /// One pass over a library root: walk it, then adopt what is untracked.
    ///
    /// The seam the tests drive against a temp directory and a temp book, as
    /// `LibraryImport.add` is. The walk runs on a dispatch queue (`PinWork`),
    /// never blocking a cooperative-pool thread.
    static func adoptFromStorage(root: URL, rows: [JSONValue], ignored: Set<String>,
                                 storeURL: URL, engine: KhaytEngine,
                                 owns: @escaping () -> Bool,
                                 whoHasIt: @escaping () -> String?,
                                 progress: (Int, Int, URL) -> Void) async -> StorageReport {
        // lock: callers — rescanStorage
        let found = await PinWork.run { Shop.untrackedInStorage(root, rows: rows, ignored: ignored) }
        var report = StorageReport(capped: found.capped)
        guard !found.files.isEmpty else { return report }
        var names: [String: String] = [:]
        var hashes: Set<String> = []
        for row in rows {
            guard case .object(let o) = row, case .string(let h)? = o["contentHash"] else { continue }
            hashes.insert(h)
            if names[h] == nil, case .string(let n)? = o["name"] { names[h] = n }
        }
        let added = await LibraryImport.addMany(
            found.files, storeURL: storeURL, libraryRoot: root,
            knownHashes: hashes, nameOfExisting: { names[$0] },
            engine: engine, keepOriginal: true, inPlace: true,
            owns: owns, whoHasIt: whoHasIt, progress: progress)
        report.added = added.moved
        report.duplicates = added.duplicates
        report.photos = added.photos
        report.failures = added.failures
        report.addedIds = added.addedIds
        return report
    }

    /// Look through the library's own folder for models it does not know.
    ///
    /// `byPerson: false` is the once-per-book pass on load (`rescanStorageIfDue`),
    /// which adopts into the library the shop already chose, whoever is at the
    /// Mac. A person pressing Rescan Storage adds to the library: inventory/create.
    func rescanStorage(byPerson: Bool = true) async {
        if byPerson { guard permitted("inventory", "create") else { return } }
        // lock: system — when !byPerson: adopting files already in the
        // library's own folder, once per book on load.
        guard let build = source.build, StoreLock.weOwnIt(build), let roots = libraryRoots, let engine,
              !libraryMoveBusy else { return }
        let root = URL(fileURLWithPath: roots.primary)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        guard let raw = try? StoreReader(build: build).raw else { return }
        if byPerson { clearLastOutcome() }
        libraryMoveBusy = true
        defer { libraryMoveBusy = false; libraryMoveProgress = nil }
        let report = await Self.adoptFromStorage(
            root: root, rows: Self.rows(raw, "printFiles"), ignored: notAdopted,
            storeURL: build.storeURL, engine: engine,
            owns: { StoreLock.weOwnIt(build) },
            whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) },
            progress: { [weak self] done, total, url in
                self?.libraryMoveProgress = (done, total, url.lastPathComponent)
            })
        if report.added > 0 { await load(source) }
        if !report.addedIds.isEmpty {
            let ids = report.addedIds
            Task { [weak self] in await self?.backUpToCloud(ids: ids) }
        }
        // The load-time pass speaks only when it found something; a person
        // who pressed the button is always answered.
        guard byPerson || report.added > 0 else { return }
        var note = report.added + report.duplicates == 0
            ? words.callIt("mac.storage_nothing_new")
            : words.callIt("mac.storage_scanned", ["n": .number(Double(report.added)),
                                                    "same": .number(Double(report.duplicates)),
                                                    "photos": .number(Double(report.photos))])
        if report.capped { note += " " + words.callIt("mac.storage_capped") }
        importNote = note
        if !report.failures.isEmpty {
            importProblem = report.failures.prefix(3).joined(separator: "\n")
        }
    }

    /// The storage pass, once per book per launch — after the linked folders'
    /// pass, which holds the same busy flag.
    func rescanStorageIfDue() {
        guard case .store(let build) = source, !storageScannedBooks.contains(build.rawValue) else { return }
        storageScannedBooks.insert(build.rawValue)
        let linked = linkedScan
        Task { [weak self] in
            await linked?.value
            await self?.rescanStorage(byPerson: false)
        }
    }

    /// The paths to remember as "not to be adopted again", for records being
    /// deleted: those whose file is in a library root, held in place.
    nonisolated static func notAdoptedAfterDeleting(_ files: [LibraryFile], roots: [String],
                                                    already: [JSONValue]) -> [JSONValue] {
        var out = already
        var seen = Set(already.compactMap { if case .string(let s) = $0 { s } else { nil } })
        for file in files {
            guard let path = file.externalPath, !path.isEmpty,
                  roots.contains(where: { LibraryMove.under(path, $0) }) else { continue }
            let p = URL(fileURLWithPath: path).standardizedFileURL.path
            if seen.insert(p).inserted { out.append(.string(p)) }
        }
        // Bounded: a list that grows for ever is a book that grows for ever.
        return Array(out.suffix(5000))
    }
}
