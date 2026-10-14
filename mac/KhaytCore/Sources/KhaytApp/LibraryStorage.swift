import Foundation
import KhaytCore

/// Model files sitting in the library's storage that the library does not know
/// about — found, and added.
///
/// Asked for by the shop (Oct 2026): "library should read the storage for any
/// 3d files and add them to the library and add a photo if that file has a
/// photo". A shop whose library lives in iCloud Drive or on a NAS drops files
/// into that folder from the Finder, from another Mac, from a phone, and the
/// library never saw them: only an import wrote a record.
///
/// ── FOUR PLACES, FOUR WAYS IN ─────────────────────────────────────────────
///
/// * THE PRIMARY FOLDER — adopted IN PLACE, the way a linked folder is: the
///   record points at the file (`externalPath`), nothing is copied, moved,
///   renamed or deleted.
/// * PAST LOCATIONS — COPIED into the primary folder, as an import that keeps
///   its original. In place would be wrong here: a past location is what the
///   other app's "move stranded files" walks and relocates WHOLE
///   (`printLibStrandedFiles` in main.js), and a record pointing into one
///   would lose its file to the next move. The original is never touched.
/// * THE MIRROR — never read. It is a copy of the primary folder written
///   after every write; everything in it is either already in the library or
///   on its way there, and adopting from it would point records at a backup.
/// * THE BUCKET — added as CLOUD-ONLY records, nothing downloaded: see
///   `adoptFromBucket`. Google Drive is not listed at all — see there for why.
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
/// * ANYTHING THIS APP HAS ADOPTED BEFORE (`settings.printLibrary.adopted`).
///   A delete in either app removes the record and leaves the shop's file
///   where it is — so a path in that list with no record now is a model some
///   app deleted, and it stays deleted. The list syncs with the book, so the
///   other app needs to know nothing about it. `notAdopted`, written by this
///   app's own delete before the list existed, is still honoured.
/// * A file already found to be a duplicate, unchanged since
///   (`settings.printLibrary.seenDuplicates`, path + size + mtime) — so a
///   loose copy of a model is not hashed again on every launch.
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
        /// True when the shop pressed Stop — see `ScanStop`.
        var stopped = false

        mutating func fold(_ other: StorageReport) {
            added += other.added; duplicates += other.duplicates; photos += other.photos
            failures += other.failures; capped = capped || other.capped; addedIds += other.addedIds
            stopped = stopped || other.stopped
        }
    }

    /// How far one pass looks, so a NAS with half a million files cannot hold
    /// a book's load hostage. A capped pass says so; the next one continues,
    /// because what it added is known by then.
    nonisolated static let storageVisitCap = 100_000
    nonisolated static let storageAdoptCap = 500
    /// Records made from a bucket in one pass, and the photos fetched for them.
    nonisolated static let bucketAdoptCap = 200
    nonisolated static let bucketPhotoCap = 50

    // MARK: - The ledger

    /// What this app has already looked at in the storage, kept in the book.
    struct StorageLedger: Equatable, Sendable {
        /// Paths (and `bucket:<name>/<key>`s) adopted, in the order they were.
        var adopted: [String] = []
        /// `path|size|mtime` (or `bucket:…|size|etag`) of files found to be
        /// duplicates.
        var seenDuplicates: [String] = []
        /// Older: paths this app's delete remembered (`deleteLibraryFiles`).
        var notAdopted: [String] = []

        /// Each list is bounded: a list that grows for ever is a book that
        /// grows for ever. The newest are kept.
        nonisolated static let cap = 5000

        nonisolated static func read(_ settings: [String: JSONValue]) -> StorageLedger {
            guard case .object(let l)? = settings["printLibrary"] else { return StorageLedger() }
            func list(_ k: String) -> [String] {
                guard case .array(let a)? = l[k] else { return [] }
                return a.compactMap { if case .string(let s) = $0 { s } else { nil } }
            }
            return StorageLedger(adopted: list("adopted"), seenDuplicates: list("seenDuplicates"),
                                 notAdopted: list("notAdopted"))
        }

        /// Paths never to adopt again.
        var skipped: Set<String> { Set(adopted).union(notAdopted) }
        /// The signatures of known duplicates.
        var duplicateSet: Set<String> { Set(seenDuplicates) }

        nonisolated static func merged(_ old: [String], adding new: [String]) -> [String] {
            var seen = Set(old)
            var out = old
            for n in new where seen.insert(n).inserted { out.append(n) }
            return Array(out.suffix(cap))
        }

        /// Into `settings.printLibrary`, touching only these two keys.
        func write(into settings: inout [String: JSONValue]) {
            var library: [String: JSONValue] = [:]
            if case .object(let l)? = settings["printLibrary"] { library = l }
            library["adopted"] = .array(adopted.map(JSONValue.string))
            library["seenDuplicates"] = .array(seenDuplicates.map(JSONValue.string))
            settings["printLibrary"] = .object(library)
        }
    }

    /// `path|size|mtime` — what makes a duplicate "the same file as last time".
    nonisolated static func signature(_ url: URL) -> String? {
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = v.fileSize, let m = v.contentModificationDate else { return nil }
        return "\(canonical(url))|\(size)|\(Int64(m.timeIntervalSince1970 * 1000))"
    }

    /// One spelling of a path, whatever symlink it was reached through.
    nonisolated static func canonical(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The ledger written back after a pass: what it adopted and found to be
    /// duplicates added, and entries whose file is gone pruned — only where
    /// the folder they were in can be seen, so an unmounted NAS keeps its list.
    nonisolated static func ledgerAfter(_ ledger: StorageLedger, adopted: [String], duplicates: [String],
                                        visibleRoots: [String]) -> StorageLedger {
        let fm = FileManager.default
        func gone(_ path: String) -> Bool {
            guard !path.hasPrefix("bucket:") else { return false }
            guard visibleRoots.contains(where: { LibraryMove.under(path, $0) }) else { return false }
            return !fm.fileExists(atPath: path)
        }
        var next = ledger
        next.adopted = StorageLedger.merged(ledger.adopted.filter { !gone($0) }, adding: adopted)
        let stale = ledger.seenDuplicates.filter { sig in
            guard !sig.hasPrefix("bucket:"), let path = sig.split(separator: "|").first.map(String.init) else { return false }
            guard visibleRoots.contains(where: { LibraryMove.under(path, $0) }) else { return false }
            return signature(URL(fileURLWithPath: path)) != sig
        }
        next.seenDuplicates = StorageLedger.merged(ledger.seenDuplicates.filter { !stale.contains($0) },
                                                   adding: duplicates)
        return next
    }

    /// A pass's ledger, written over the one ON DISK NOW rather than the one
    /// the pass started from: whatever another writer (the other app, a sync,
    /// the other pass) added since `read` is kept. Run inside the write
    /// chain. A pass that wrote `next` whole put back the ledger it had read,
    /// minus anything added during a bucket listing (Oct 2026 review).
    nonisolated static func ledgerMerged(_ next: StorageLedger, over read: StorageLedger,
                                         into current: StorageLedger) -> StorageLedger {
        var out = current
        let wasAdopted = Set(read.adopted), wasSeen = Set(read.seenDuplicates)
        out.adopted = StorageLedger.merged(next.adopted, adding: current.adopted.filter { !wasAdopted.contains($0) })
        out.seenDuplicates = StorageLedger.merged(next.seenDuplicates,
                                                  adding: current.seenDuplicates.filter { !wasSeen.contains($0) })
        return out
    }

    /// Files the shop deleted from the library after they were adopted
    /// (the older list — see `StorageLedger`).
    var notAdopted: Set<String> { Set(StorageLedger.read(settingsDict).notAdopted) }

    /// A folder at the root that is Khayt's own, whether or not a record still
    /// names it.
    nonisolated static func isKhaytFolder(_ name: String, recordDirs: Set<String>) -> Bool {
        recordDirs.contains(name) || name.hasPrefix("PF-") || name == "unsorted"
            || name == GroupPictures.folderName
    }

    // MARK: - Walking a folder

    /// The untracked model files under a library root, grouped and with their
    /// photos. Reads only.
    ///
    /// - Parameters:
    ///   - rows: the book's `printFiles`, raw — so a record this build cannot
    ///     decode still owns its folder.
    ///   - ignored: paths never to adopt (the ledger's, `notAdopted`).
    ///   - seen: signatures of files already found to be duplicates.
    ///   - excluding: folders never walked into wherever they sit — the
    ///     mirror, the linked folders and the other roots, when one is nested
    ///     inside this root.
    nonisolated static func untrackedInStorage(_ root: URL, rows: [JSONValue], ignored: Set<String>,
                                               seen: Set<String> = [],
                                               excluding: [String] = [],
                                               visitCap: Int = storageVisitCap,
                                               adoptCap: Int = storageAdoptCap,
                                               stop: ScanStop? = nil)
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
                known.insert(canonical(url))
            }
        }
        known.formUnion(ignored)
        func isKnown(_ url: URL) -> Bool {
            if known.contains(url.standardizedFileURL.path) || known.contains(canonical(url)) { return true }
            if !seen.isEmpty, let sig = signature(url), seen.contains(sig) { return true }
            return false
        }
        func isModel(_ url: URL) -> Bool {
            LibraryImport.kinds.contains(url.pathExtension.lowercased()) && LibraryImport.isRegularFile(url)
        }
        let fences = Set(excluding.flatMap { p -> [String] in
            let u = URL(fileURLWithPath: p)
            return [u.standardizedFileURL.path, canonical(u)]
        })
        func fenced(_ dir: URL) -> Bool {
            !fences.isEmpty && (fences.contains(dir.standardizedFileURL.path) || fences.contains(canonical(dir)))
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
            if capped || stop?.isStopped == true { break }
            guard let v = try? entry.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
            if v.isDirectory == true {
                let name = entry.lastPathComponent
                guard !isKhaytFolder(name, recordDirs: recordDirs), name != ".Trash",
                      !fenced(entry) else { continue }
                // Every model under it, known ones too: "a folder of one model"
                // and its grouping are judged over the whole folder, so a second
                // file dropped beside an adopted one is grouped the same way.
                var all: [URL] = []
                let walker = fm.enumerator(at: entry,
                                           includingPropertiesForKeys: LibraryImport.fileKeys + [.isDirectoryKey],
                                           options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let next = walker?.nextObject() as? URL {
                    visited += 1
                    if visited > visitCap { capped = true; break }
                    if visited % 256 == 0, stop?.isStopped == true { break }
                    // KHAYT'S OWN FOLDERS AT ANY DEPTH, not only at the top: a
                    // record folder copied into a shop folder (or the mirror,
                    // nested here) holds versions and converted copies whose
                    // bytes no record has — each would be adopted as a new
                    // model (Oct 2026 review).
                    if (try? next.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        if isKhaytFolder(next.lastPathComponent, recordDirs: recordDirs) || fenced(next) {
                            walker?.skipDescendants()
                        }
                        continue
                    }
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

    /// The past locations a pass copies from: every root but the primary,
    /// the mirror (a copy of the primary — see the type's note), and the
    /// built-in vault when it is not the primary, nested ones dropped as
    /// `LibraryMove.sources` drops them.
    nonisolated static func pastLocations(_ roots: LibraryLocation.Roots, builtIn: String) -> [String] {
        LibraryMove.sources(roots: roots.roots, primary: roots.primary, mirror: roots.mirror)
            .filter { URL(fileURLWithPath: $0).standardizedFileURL.path
                        != URL(fileURLWithPath: builtIn).standardizedFileURL.path }
    }

    /// The book as it is on disk now — rows and settings.
    nonisolated static func readBook(_ storeURL: URL) -> [String: JSONValue]? {
        guard let data = try? Data(contentsOf: storeURL) else { return nil }
        return try? JSONValue.decode([String: JSONValue].self, from: data)
    }

    // MARK: - Local folders

    /// One pass over the library's folders: the primary adopted in place,
    /// each past location copied in. Reads the book itself, so the ledger and
    /// the records it judges by are the ones on disk now.
    ///
    /// The seam the tests drive against a temp directory and a temp book, as
    /// `LibraryImport.add` is. The walks run on a dispatch queue (`PinWork`),
    /// never blocking a cooperative-pool thread.
    static func adoptFromStorage(root: URL, past: [URL] = [], excluding: [String] = [],
                                 storeURL: URL, engine: KhaytEngine,
                                 owns: @escaping @Sendable () -> Bool,
                                 whoHasIt: @escaping @Sendable () -> String?,
                                 stop: ScanStop? = nil,
                                 isOnline: (@Sendable (URL) -> Bool)? = nil,
                                 progress: @escaping (Int, Int, URL) -> Void) async -> StorageReport {
        // lock: callers — rescanStorage
        // The book read, and what is worked out from it, on a dispatch queue:
        // 16 MB decoded on the main actor held the window for over a second.
        guard let start = await PinWork.run({ () -> StorageStart? in
            guard let book = readBook(storeURL) else { return nil }
            return StorageStart(book)
        }) else { return StorageReport() }
        let rows = start.rows, ledger = start.ledger
        let skipped = ledger.skipped, seen = ledger.duplicateSet

        var report = StorageReport()
        var adopted: [String] = [], duplicates: [String] = []
        let names = start.names
        var hashes = start.hashes
        // The primary in place; each past location by copy.
        // Online-only files in the primary (an iCloud Drive library with
        // Optimise Storage on) are known by name and size — see `LinkedCloud`.
        let nameSizes = start.nameSizes
        for (where_, inPlace) in [(root, true)] + past.map({ ($0, false) }) {
            if stop?.isStopped == true || Task.isCancelled { report.stopped = true; break }
            guard FileManager.default.fileExists(atPath: where_.path) else { continue }
            // Every other root is a fence for this one's walk: the primary is
            // never walked again from a past location around it, and nothing
            // nested here (the mirror, a linked folder) is walked as part of it.
            let fence = excluding + ([root] + past).filter { $0 != where_ }.map(\.path)
            let found = await PinWork.run {
                Shop.untrackedInStorage(where_, rows: rows, ignored: skipped, seen: seen, excluding: fence, stop: stop)
            }
            report.capped = report.capped || found.capped
            guard !found.files.isEmpty else { continue }
            let done = await LibraryImport.addMany(
                found.files, storeURL: storeURL, libraryRoot: root,
                knownHashes: hashes, nameOfExisting: { names[$0] },
                engine: engine, keepOriginal: true, inPlace: inPlace,
                knownNameSizes: nameSizes, isOnline: isOnline,
                owns: owns, whoHasIt: whoHasIt,
                shouldStop: { stop?.isStopped == true || Task.isCancelled },
                progress: progress)
            report.stopped = report.stopped || done.stopped
            report.added += done.moved
            report.duplicates += done.duplicates
            report.photos += done.photos
            report.failures += done.failures
            report.addedIds += done.addedIds
            adopted += done.addedURLs.map(canonical)
            duplicates += done.duplicateURLs.compactMap(signature)
            // What came in this pass is known to the next location's walk.
            if let fresh = await PinWork.run({ readBook(storeURL).map(StorageStart.init) }) {
                hashes.formUnion(fresh.hashes)
            }
        }
        let visible = ([root] + past).filter { FileManager.default.fileExists(atPath: $0.path) }.map(canonical)
        let next = ledgerAfter(ledger, adopted: adopted, duplicates: duplicates, visibleRoots: visible)
        if next != ledger {
            // lock: callers — rescanStorage
            try? await StoreWriter.updateOffMain(storeURL: storeURL, owns: owns, whoHasIt: whoHasIt) { book in
                var settings = Shop.settings(book)
                Shop.ledgerMerged(next, over: ledger, into: StorageLedger.read(settings)).write(into: &settings)
                book["settings"] = .object(settings)
            }
        }
        return report
    }

    /// What the storage pass needs from the book before it walks, worked out
    /// off the main actor.
    struct StorageStart: Sendable {
        let rows: [JSONValue]
        let ledger: StorageLedger
        var hashes: Set<String> = []
        var names: [String: String] = [:]
        var nameSizes: Set<String> = []

        nonisolated init(_ book: [String: JSONValue]) {
            rows = Shop.rows(book, "printFiles")
            ledger = StorageLedger.read(Shop.settings(book))
            for case .object(let o) in rows {
                if case .string(let h)? = o["contentHash"] {
                    hashes.insert(h)
                    if names[h] == nil, case .string(let n)? = o["name"] { names[h] = n }
                }
                guard case .object(let sf)? = o["sourceFile"], case .number(let size)? = sf["size"], size > 0,
                      case .string(let name)? = o["originalName"] ?? sf["originalName"] else { continue }
                nameSizes.insert(LibraryImport.nameSize(Int(size), name))
            }
        }
    }

    // MARK: - The bucket

    /// The marker a CLOUD-ONLY model leaves in its folder in place of the file:
    /// where the object is and what it measured in the listing. Not a `.cloud`
    /// sidecar on purpose — a sidecar must carry the SHA-256 of bytes this Mac
    /// once held (`parseSidecar` in lib/print-library-tier.js refuses one
    /// without), and a model the shop put in the bucket by hand has never been
    /// here to be hashed. The other app reads no `.online` file; to it the
    /// model shows as not on this computer, which is true.
    nonisolated static let onlineExt = ".online"

    struct OnlineMarker: Codable, Equatable, Sendable {
        var v = 1
        var key: String
        var size: Int
        var etag: String
        var bucket: String
        var provider: String
        var at: String
    }

    nonisolated static func onlineMarker(for model: URL) -> URL {
        model.deletingLastPathComponent().appending(path: model.lastPathComponent + onlineExt)
    }

    /// The object keys a book already knows: those its sidecars and markers
    /// name, under the library's own folder.
    nonisolated static func keysNamedOnDisk(_ root: URL) -> Set<String> {
        keysNamedOnDisk(roots: [root.path], except: [])
    }

    /// The same over every root, leaving out the record folders in `except`
    /// — what the models NOT being deleted still name.
    nonisolated static func keysNamedOnDisk(roots: [String], except: Set<String>) -> Set<String> {
        var out: Set<String> = []
        for f in roots.flatMap({ CloudLibrary.libraryFiles(root: $0, includingMarkers: true) })
        where (f.filename.hasSuffix(".cloud") || f.filename.hasSuffix(onlineExt)) && !except.contains(f.id ?? "") {
            guard let data = FileManager.default.contents(atPath: f.fullPath),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let key = o["key"] as? String else { continue }
            out.insert(key)
        }
        return out
    }

    /// The image keys that are a bucket model's photo — `ModelPhoto`'s rules
    /// over a listing instead of a folder: its own name beside it or in a
    /// gallery folder, else, when its folder holds one model, any picture there.
    nonisolated static func photoKeys(for model: String, among keys: [String], models: [String]) -> [String] {
        func dir(_ k: String) -> String { (k as NSString).deletingLastPathComponent }
        func stem(_ k: String) -> String { ((k as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased() }
        func isImage(_ k: String) -> Bool { ModelPhoto.kinds.contains((k as NSString).pathExtension.lowercased()) }
        let d = dir(model)
        var homes = [d]
        if !d.isEmpty, ImportGrouping.meaningful((d as NSString).lastPathComponent) == nil { homes.append(dir(d)) }
        let images = keys.filter(isImage).sorted()
        func gallery(_ home: String) -> [String] {
            images.filter { k in
                let parent = dir(k)
                return dir(parent) == home && ModelPhoto.galleries.contains((parent as NSString).lastPathComponent.lowercased())
            }
        }
        let own = stem(model)
        var picks = images.filter { dir($0) == d && stem($0) == own }
        for h in homes { picks += gallery(h).filter { stem($0) == own } }
        if picks.isEmpty {
            for h in homes where !h.isEmpty {
                let under = models.filter { $0.hasPrefix(h + "/") }.count
                guard under == 1 else { continue }
                picks = gallery(h) + images.filter { dir($0) == h }
                if !picks.isEmpty { break }
            }
        }
        var seen = Set<String>()
        return picks.filter { seen.insert($0).inserted }.prefix(ModelPhoto.keep).map { $0 }
    }

    /// Objects the shop put in the library's bucket by hand, added as
    /// CLOUD-ONLY records — nothing downloaded.
    ///
    /// The shop asked for exactly this (Oct 2026): "should not download from
    /// an online drive, it should add it to the library and show that it's
    /// online with an option to download". Each becomes a record with a
    /// `.online` marker in its folder, which `isInCloudOnly` reads, so the
    /// library shows it as in the cloud and offers Bring Back — which fetches
    /// it, checks it against the size and ETag the listing gave, and only then
    /// measures, hashes and pictures it (`fillDownloaded`).
    ///
    /// ── WHAT A KEY IS ─────────────────────────────────────────────────────
    ///
    /// * `[prefix]/print-files/<record>/…` — the library's own copies. Owned.
    /// * `[prefix]/print-files/<PF-…|unsorted|_khayt-check>/…` with no record —
    ///   a deleted model's backup (a delete never removes the bucket's copy),
    ///   or the settings pane's test probe. Skipped, as an orphaned folder is.
    /// * A key a sidecar or marker on this Mac names — owned.
    /// * Anything else of a model's kind — the shop's own. Adopted once: its
    ///   `bucket:<name>/<key>` goes in the ledger, so a delete keeps it out.
    ///
    /// A duplicate is caught BEFORE anything is fetched where it can be: an
    /// object whose size and ETag equal one of the library's own copies is
    /// the same bytes. A plain MD5 ETag only — a multipart one names how it
    /// was uploaded as much as what it holds.
    ///
    /// ── GOOGLE DRIVE IS NOT LISTED ────────────────────────────────────────
    ///
    /// Both apps ask Drive for `drive.file` (`DriveClient.scope`), which lets
    /// an app "create new Drive files, or modify existing files, that you open
    /// with an app or that the user shares with an app while using the Google
    /// Picker API or the app's file picker"
    /// (developers.google.com/workspace/drive/api/guides/api-specific-auth).
    /// Neither app has a Drive picker, so every file it can see is one it put
    /// there — a record's copy. A file the shop drops into Drive by hand is
    /// invisible to it, and there is nothing to adopt.
    static func adoptFromBucket(_ c: S3Config, provider: String, root: URL,
                                storeURL: URL, fetch: @escaping S3.Fetch,
                                owns: @escaping @Sendable () -> Bool,
                                whoHasIt: @escaping @Sendable () -> String?,
                                stop: ScanStop? = nil,
                                progress: (Int, Int, String) -> Void) async throws -> StorageReport {
        // lock: callers — rescanStorage
        // Read off the main actor, as the local pass reads it (`StorageStart`).
        guard let start = await PinWork.run({ readBook(storeURL).map(StorageStart.init) }) else {
            return StorageReport()
        }
        let rows = start.rows
        let ledger = start.ledger
        let base = c.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let listPrefix = base.isEmpty ? "" : base + "/"
        let listed = try await S3.list(c, prefix: listPrefix, fetch: fetch)
        let complete = listed.count < 50_000
        func tag(_ k: String) -> String { "bucket:\(c.bucket)/\(k)" }

        var recordDirs: Set<String> = []
        for row in rows {
            if case .object(let o) = row, case .string(let id)? = o["id"] {
                recordDirs.insert(LibraryLocation.itemDirName(id))
            }
        }
        let named = await PinWork.run { Shop.keysNamedOnDisk(root) }
        var owned: [S3.Listed] = []
        var theirs: [S3.Listed] = []
        for item in listed {
            let rel = String(item.key.dropFirst(listPrefix.count))
            let parts = rel.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            // A hidden segment, or an EMPTY one (`a//b.stl`, a leading `/`):
            // `S3.request` drops empty segments, so Bring Back would fetch —
            // and Delete Completely would delete — `a/b.stl`, a different
            // object (Oct 2026 review).
            if parts.contains(where: { $0.hasPrefix(".") || $0.isEmpty }) { continue }
            if parts.first == "print-files", parts.count >= 3 {
                let dir = parts[1]
                if recordDirs.contains(dir) { owned.append(item) }
                // A record folder whose record is gone, or the probe: skipped.
                continue
            }
            if named.contains(item.key) { owned.append(item); continue }
            theirs.append(item)
        }
        let models = theirs.filter { LibraryImport.kinds.contains(($0.key as NSString).pathExtension.lowercased()) }
        let allKeys = theirs.map(\.key)
        let modelKeys = models.map(\.key)
        let skipped = ledger.skipped
        let seenDup = ledger.duplicateSet
        func plainEtag(_ e: String?) -> String? {
            guard let e = e?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")), !e.isEmpty, !e.contains("-")
            else { return nil }
            return e.lowercased()
        }
        var known = Set(owned.compactMap { o in plainEtag(o.etag).map { "\(o.size)|\($0)" } })

        var report = StorageReport()
        var adopted: [String] = []
        var duplicates: [String] = []
        var records: [[String: JSONValue]] = []
        var photosFetched = 0
        let fm = FileManager.default
        let fresh = models.filter { !skipped.contains(tag($0.key)) && $0.size > 0 }
        for (i, item) in fresh.enumerated() {
            // What was found before a Stop is written below, ledger and all.
            if stop?.isStopped == true || Task.isCancelled { report.stopped = true; break }
            if records.count >= bucketAdoptCap { report.capped = true; break }
            progress(i, fresh.count, (item.key as NSString).lastPathComponent)
            let signature = "\(tag(item.key))|\(item.size)|\(item.etag ?? "")"
            if seenDup.contains(signature) { continue }
            if let e = plainEtag(item.etag) {
                guard known.insert("\(item.size)|\(e)").inserted else {
                    report.duplicates += 1
                    duplicates.append(signature)
                    continue
                }
            }
            // The record and its folder, holding only the marker (and, below,
            // nothing else: a photo is inline in the record).
            let id = Shop.uid("PF")
            let dir = root.appending(path: LibraryLocation.itemDirName(id))
            let originalName = (item.key as NSString).lastPathComponent
            let ext = (originalName as NSString).pathExtension.lowercased()
            do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            catch { report.failures.append("\(originalName): \(error.localizedDescription)"); continue }
            let filename = LibraryImport.vaultFilename(in: dir, originalName: originalName, ext: ext)
            let marker = OnlineMarker(key: item.key, size: item.size, etag: item.etag ?? "", bucket: c.bucket,
                                      provider: provider, at: StoreWriter.iso(Date()))
            do {
                try JSONEncoder().encode(marker).write(to: onlineMarker(for: dir.appending(path: filename)),
                                                       options: .atomic)
            } catch {
                try? fm.removeItem(at: dir)
                report.failures.append("\(originalName): \(error.localizedDescription)"); continue
            }
            // Grouped by the folders the key sits in, as a folder import is.
            let rel = String(item.key.dropFirst(listPrefix.count))
            let fake = URL(fileURLWithPath: "/khayt-bucket").appending(path: rel)
            var group: String?, title: String?
            let parts = rel.split(separator: "/").map(String.init)
            if parts.count > 1 {
                let chosen = URL(fileURLWithPath: "/khayt-bucket").appending(path: parts[0])
                let siblings = modelKeys.filter { $0.hasPrefix(listPrefix + parts[0] + "/") }
                    .map { URL(fileURLWithPath: "/khayt-bucket").appending(path: String($0.dropFirst(listPrefix.count))) }
                let placed = ImportGrouping.placements(for: siblings, chosen: chosen)[fake]
                group = placed?.group; title = placed?.title
            }
            let name = title ?? (originalName as NSString).deletingPathExtension
            var record = LibraryImport.record(id: id, name: name, originalName: originalName,
                                              filename: filename, ext: ext, size: item.size,
                                              hash: nil, key: nil, colours: [], swapCount: 0,
                                              thumbFile: nil, group: group)
            // The photo: a small picture, fetched because it is NOT the model.
            for photoKey in photoKeys(for: item.key, among: allKeys, models: modelKeys)
            where photosFetched < bucketPhotoCap {
                guard let size = theirs.first(where: { $0.key == photoKey })?.size,
                      size <= ProductPhotos.maxSourceBytes,
                      let data = try? await S3.get(c, key: photoKey, fetch: fetch) else { continue }
                photosFetched += 1
                let ext = (photoKey as NSString).pathExtension
                // Decoded off the main actor, as every batch decode is.
                guard let uri = await PinWork.run({ () -> String? in
                    let tmp = FileManager.default.temporaryDirectory
                        .appending(path: "khayt-photo-\(UUID().uuidString)").appendingPathExtension(ext)
                    defer { try? FileManager.default.removeItem(at: tmp) }   // scratch
                    guard (try? data.write(to: tmp)) != nil else { return nil }
                    return try? LibraryPhoto.dataURI(of: tmp)
                }) else { continue }
                record["userPhoto"] = .string(uri)
                report.photos += 1
                break
            }
            // Looked for already, so the backfill does not look again.
            record["photoLookedFor"] = .string(StoreWriter.iso(Date()))
            records.append(record)
            adopted.append(tag(item.key))
            report.addedIds.append(id)
        }
        report.added = records.count

        // What the bucket no longer holds leaves the ledger — when the whole
        // listing came back, and only the bucket's own entries.
        let present = Set(listed.map { tag($0.key) })
        var next = ledger
        let mine = "bucket:\(c.bucket)/"
        next.adopted = StorageLedger.merged(ledger.adopted.filter { !complete || !$0.hasPrefix(mine) || present.contains($0) },
                                            adding: adopted)
        next.seenDuplicates = StorageLedger.merged(ledger.seenDuplicates.filter { sig in
            guard complete, sig.hasPrefix(mine) else { return true }
            return present.contains(String(sig.split(separator: "|").first ?? ""))
        }, adding: duplicates)
        guard !records.isEmpty || next != ledger else { return report }
        let newRecords = records, nextLedger = next
        do {
            // lock: callers — rescanStorage
            // One write, off the main actor.
            try await StoreWriter.updateOffMain(storeURL: storeURL, owns: owns, whoHasIt: whoHasIt) { book in
                var rows = Shop.rows(book, "printFiles")
                rows.insert(contentsOf: newRecords.map(JSONValue.object), at: 0)
                book["printFiles"] = .array(rows)
                var settings = Shop.settings(book)
                Shop.ledgerMerged(nextLedger, over: ledger, into: StorageLedger.read(settings)).write(into: &settings)
                book["settings"] = .object(settings)
            }
        } catch {
            // The book refused: the markers have no records to belong to.
            for case .string(let id)? in records.map({ $0["id"] }) {
                try? fm.removeItem(at: root.appending(path: LibraryLocation.itemDirName(id)))
            }
            report.failures.append(String(describing: error))
            report.added = 0; report.addedIds = []; report.photos = 0
        }
        return report
    }

    /// A cloud-only model's bytes, brought down and checked against what the
    /// listing said: the size, and the ETag where it is a plain MD5. Written
    /// beside the marker and the marker removed — the record then has a file.
    static func bringDown(_ marker: URL, config c: S3Config, engine: KhaytEngine,
                          fetch: @escaping S3.Fetch) async throws -> URL {
        // lock: system — fetches a model the shop asked for, into its own folder; removes only its marker and half-written .part.
        let data = try Data(contentsOf: marker)
        let m = try JSONDecoder().decode(OnlineMarker.self, from: data)
        guard let bytes = try await S3.get(c, key: m.key, fetch: fetch) else { throw CloudLibrary.Failure.notThere }
        guard bytes.count == m.size else { throw CloudLibrary.Failure.wrongSize(there: bytes.count, here: m.size) }
        let md5 = CloudLibrary.md5(bytes)
        if try await engine.etagVerdict(etag: m.etag, md5: md5) == "mismatch" { throw CloudLibrary.Failure.hashMismatch }
        let model = marker.deletingLastPathComponent()
            .appending(path: String(marker.lastPathComponent.dropLast(onlineExt.count)))
        let part = model.deletingLastPathComponent()
            .appending(path: model.lastPathComponent + ".part-\(ProcessInfo.processInfo.processIdentifier)")
        try bytes.write(to: part, options: .atomic)
        if rename(part.path, model.path) != 0 {
            try? FileManager.default.removeItem(at: part)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try? FileManager.default.removeItem(at: marker)
        return model
    }

    /// What a model's own bytes say, written onto a record that had none —
    /// a cloud-only model just brought down. The hash, the measurements, the
    /// colours, the slicer's figures, the picture. Nothing the shop wrote is
    /// replaced: a name, a group, a photo, figures already there stay.
    ///
    /// Returns the title of a record that already holds these bytes, when one
    /// does: the duplicate the listing could not catch, caught now.
    ///
    /// `pictures` is where a drawn or embedded preview is written: the
    /// model's own folder for a bucket model, and the record's VAULT folder
    /// for a linked one — a linked model's folder is the shop's, and nothing
    /// of this app's is ever written into it. Also used for a linked model
    /// indexed online only, once it is on this Mac (`Shop.fillNowLocal`).
    @discardableResult
    static func fillDownloaded(id: String, file: URL, pictures: URL? = nil, storeURL: URL, engine: KhaytEngine,
                               owns: @escaping @Sendable () -> Bool,
                               whoHasIt: @escaping @Sendable () -> String?) async throws -> String? {
        // lock: callers — bringDownOnline, fillNowLocal, bringDownLinked
        let ext = file.pathExtension.lowercased()
        let hash = await LibraryImport.offMain { try? LibraryImport.contentHash(of: file) } ?? nil
        // NOT READ, NOTHING WRITTEN. A drive that is offline, or refuses the
        // download, fails the read — and writing anyway took `indexedOnline`
        // off a record whose bytes were never seen, so `fillNowLocal` never
        // looked at it again and it stayed unmeasured and unhashed for good
        // (alpha.66 review). Said instead, and tried again next time.
        guard let hash else {
            throw LibraryImport.Failure.failed("could not read \(file.lastPathComponent)")
        }
        let a = await LibraryImport.analyse(file, ext: ext, dir: pictures ?? file.deletingLastPathComponent(),
                                            engine: engine, analyseRisk: false)
        let key = a.key, reader = a.reader, colours = a.colours, swapCount = a.swapCount
        let thumbFile = a.thumbFile, parsed = a.parsed, size = a.size
        let designer = a.provenance?.designer
        let licence = a.provenance.flatMap { ModelLicence.fromFile($0.licence)?.id }
        // Off the main actor: the whole book is read and written for one record.
        return try await StoreWriter.updateOffMain(storeURL: storeURL, owns: owns, whoHasIt: whoHasIt) { book in
            var duplicateOf: String?
            var rows = Shop.rows(book, "printFiles")
            for (i, row) in rows.enumerated() {
                guard case .object(var o) = row else { continue }
                if Shop.recordId(row) != id {
                    if case .string(hash)? = o["contentHash"], case .string(let n)? = o["name"] { duplicateOf = n }
                    continue
                }
                func empty(_ k: String) -> Bool {
                    switch o[k] { case nil, .null?: true; case .string(let s)?: s.isEmpty
                                  case .array(let x)?: x.isEmpty; case .object(let x)?: x.isEmpty; default: false }
                }
                o["contentHash"] = .string(hash)
                if let key { o["geometryKey"] = .string(key) }
                if let reader { o["geometryReader"] = .number(Double(reader)) }
                if empty("colors") { o["colors"] = .array(colours); o["swapCount"] = .number(Double(swapCount)) }
                if empty("thumbFile"), let thumbFile { o["thumbFile"] = .string(thumbFile); o["thumbSource"] = .string("embedded") }
                if empty("parsed") { o["parsed"] = .object(parsed) }
                if empty("source"), let designer { o["source"] = .string(designer) }
                if empty("licence"), let licence { o["licence"] = .string(licence) }
                if case .object(var sf)? = o["sourceFile"] { sf["size"] = .number(Double(size)); o["sourceFile"] = .object(sf) }
                // Read now: no longer a record of what the drive listed.
                o.removeValue(forKey: "indexedOnline")
                rows[i] = .object(o)
            }
            book["printFiles"] = .array(rows)
            return duplicateOf
        }
    }

    // MARK: - Photos for models already in the library

    /// Records the photo backfill should look at: no photo, never looked for.
    nonisolated static func photoDue(_ o: [String: JSONValue]) -> Bool {
        switch o["userPhoto"] {
        case .string(let s)? where !s.isEmpty: return false
        default: break
        }
        if let mark = o["photoLookedFor"], mark != .null { return false }
        return true
    }

    /// Where a record's model sits on this Mac, and the folder its photo rules
    /// are judged within. Nil when the model is not here (in the cloud, on an
    /// unplugged drive): it is looked at once it is.
    nonisolated static func photoPlace(_ o: [String: JSONValue], roots: [String], linked: [String])
        -> (model: URL, boundary: URL?, vault: Bool)? {
        let fm = FileManager.default
        if case .string(let p)? = o["externalPath"], !p.isEmpty {
            guard fm.fileExists(atPath: p) else { return nil }
            let model = URL(fileURLWithPath: p)
            if let l = linked.first(where: { LibraryMove.under(p, $0) }) {
                return (model, URL(fileURLWithPath: l), false)
            }
            // Under a library root: the top-level folder it is in, as the
            // adoption walk judged it; loose at the root, its own name only.
            for r in roots where LibraryMove.under(p, r) {
                let rel = URL(fileURLWithPath: canonical(model)).pathComponents
                    .dropFirst(URL(fileURLWithPath: canonical(URL(fileURLWithPath: r))).pathComponents.count)
                guard rel.count > 1, let top = rel.first else { return (model, nil, false) }
                return (model, URL(fileURLWithPath: canonical(URL(fileURLWithPath: r))).appending(path: top), false)
            }
            return (model, nil, false)
        }
        guard case .string(let id)? = o["id"], case .object(let sf)? = o["sourceFile"],
              case .string(let filename)? = sf["filename"], !filename.isEmpty,
              let dir = LibraryLocation.directory(for: id, roots: roots) else { return nil }
        let model = dir.appending(path: filename)
        guard fm.fileExists(atPath: model.path) else { return nil }
        return (model, dir, true)
    }

    /// Every model under a folder, for "a folder of one model". Bounded.
    nonisolated static func modelsIn(_ dir: URL, cap: Int = 5000) -> [URL] {
        var out: [URL] = []
        var seen = 0
        let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: LibraryImport.fileKeys,
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let next = walker?.nextObject() as? URL {
            seen += 1
            if seen > cap { break }
            if LibraryImport.kinds.contains(next.pathExtension.lowercased()), LibraryImport.isRegularFile(next) {
                out.append(next)
            }
        }
        return out
    }

    /// Look ONCE for the photo of every model already in the library that has
    /// none, and mark each one looked at (`photoLookedFor`) whether or not one
    /// was found — so a photo the shop later takes off never comes back.
    ///
    /// ── THE MARK IS A FIELD ON THE RECORD ─────────────────────────────────
    ///
    /// Checked first: neither app rewrites a library record from a list of
    /// fields it knows. The other app edits records in place
    /// (`Object.assign(rec, …)` throughout renderer/printfiles.js) and sync
    /// merges whole records, so an unknown field rides along — `externalPath`
    /// has done exactly that since the linked folders shipped.
    ///
    /// Written with `recordingDeletes: false`, which skips the automatic rev
    /// stamp: a record that only gained the mark has not been EDITED, and
    /// stamping every model in the library would push the whole library to
    /// the cloud as edits nobody made. A record that gained a photo is
    /// stamped by hand, because that is a change worth syncing. The cost: on
    /// another Mac the unstamped mark may be lost to a merge, and that Mac
    /// looks once more — finding what this one found.
    static func backfillPhotos(storeURL: URL, roots: [String], linked: [String],
                               owns: @escaping @Sendable () -> Bool,
                               whoHasIt: @escaping @Sendable () -> String?,
                               cap: Int = 2000,
                               isOnline: (@Sendable (URL) -> Bool)? = nil) async -> Int {
        let isOnline: @Sendable (URL) -> Bool = isOnline ?? { LinkedCloud.isOnlineOnly($0) }
        // lock: callers — rescanStorage
        // Read, and every record looked at, on a dispatch queue: a stat per
        // model (thousands of them, on a cloud drive) and the 16 MB book
        // decoded used to hold the window at every launch.
        let due = await PinWork.run { () -> [PhotoDue] in
            guard let book = readBook(storeURL) else { return [] }
            var due: [PhotoDue] = []
            for case .object(let o) in Shop.rows(book, "printFiles") where photoDue(o) {
                guard case .string(let id)? = o["id"] else { continue }
                if due.count >= cap { break }
                guard let place = photoPlace(o, roots: roots, linked: linked) else { continue }
                // A model the cloud has not downloaded is looked at once it is
                // here, as one on an unplugged drive is — left unmarked.
                if isOnline(place.model) { continue }
                var thumb: String?
                if case .string(let t)? = o["thumbFile"] { thumb = t }
                due.append(PhotoDue(id: id, model: place.model, boundary: place.boundary, vault: place.vault,
                                    thumb: thumb))
            }
            return due
        }
        guard !due.isEmpty else { return 0 }
        let looked = due
        // The walk AND the decoding, on a dispatch queue: up to `cap`
        // pictures decoded here once ran on the main actor and froze the
        // window on load (Oct 2026 review).
        let photos: [String: String] = await PinWork.run {
            var out: [String: String] = [:]
            var under: [String: [URL]] = [:]
            for item in looked {
                var every = [item.model]
                if let b = item.boundary {
                    let key = b.standardizedFileURL.path
                    if under[key] == nil { under[key] = Shop.modelsIn(b) }
                    every = under[key] ?? every
                }
                var found = ModelPhoto.candidates(for: [item.model], everyModel: every,
                                                  boundary: item.boundary)[item.model] ?? []
                // A vault folder holds the pictures the APP made: never a photo.
                if item.vault {
                    found = found.filter {
                        let n = $0.lastPathComponent.lowercased()
                        return !n.hasPrefix("thumb") && n != (item.thumb ?? "").lowercased()
                    }
                }
                // Never a picture the cloud would have to download to decode.
                found = found.filter { !isOnline($0) }
                if let uri = LibraryImport.firstPhoto(found) { out[item.id] = uri }
            }
            return out
        }
        let ids = Set(looked.map(\.id))
        let mark = JSONValue.string(StoreWriter.iso(Date()))
        do {
            return try await StoreWriter.updateOffMain(storeURL: storeURL, owns: owns, whoHasIt: whoHasIt,
                                                       recordingDeletes: false) { book in
                var rows = Shop.rows(book, "printFiles")
                var set = 0
                for (i, row) in rows.enumerated() {
                    guard let id = Shop.recordId(row), ids.contains(id),
                          case .object(var o) = row, photoDue(o) else { continue }
                    o["photoLookedFor"] = mark
                    if let uri = photos[id] {
                        o["userPhoto"] = .string(uri)
                        StoreWriter.stamp(&o)
                        set += 1
                    }
                    rows[i] = .object(o)
                }
                book["printFiles"] = .array(rows)
                return set
            }
        } catch { return 0 }
    }

    /// A record the photo backfill will look for a photo for.
    struct PhotoDue: Sendable {
        let id: String
        let model: URL
        let boundary: URL?
        let vault: Bool
        let thumb: String?
    }

    // MARK: - The pass

    /// Look through the library's storage for models it does not know, and
    /// for the photos of the ones it does.
    ///
    /// `byPerson: false` is the once-per-book pass on load (`rescanStorageIfDue`),
    /// which adopts into the library the shop already chose, whoever is at the
    /// Mac. A person pressing Rescan Storage adds to the library: inventory/create.
    func rescanStorage(byPerson: Bool = true) async {
        if byPerson { guard permitted("inventory", "create") else { return } }
        // lock: system — when !byPerson: adopting files already in the
        // library's own storage, once per book on load.
        guard let build = source.build, StoreLock.weOwnIt(build), let roots = libraryRoots, let engine,
              !libraryMoveBusy else { return }
        let root = URL(fileURLWithPath: roots.primary)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        if byPerson { clearLastOutcome() }
        libraryMoveBusy = true
        let stop = ScanStop()
        libraryScanStop = stop
        defer { libraryMoveBusy = false; libraryMoveProgress = nil; libraryScanStop = nil }
        let owns: @Sendable () -> Bool = { StoreLock.weOwnIt(build) }
        let who: @Sendable () -> String? = { StoreLock.describe(StoreLock.verdict(for: build)) }
        let past = Self.pastLocations(roots, builtIn: LibraryLocation.defaultRoot(for: build))
            .map { URL(fileURLWithPath: $0) }
        // Reloaded at the end only if the pass wrote — see `rescanLinkedFolders`.
        var bookAt = Self.bookStamp(build.storeURL)
        let drawn = ScanProgress()
        var report = await Self.adoptFromStorage(
            root: root, past: past, excluding: roots.roots.filter { $0 != roots.primary } + [roots.mirror].compactMap { $0 } + linkedFolders,
            storeURL: build.storeURL, engine: engine,
            owns: owns, whoHasIt: who, stop: stop, isOnline: linkedIsOnline,
            progress: { [weak self] done, total, url in
                guard drawn.due(done, of: total) else { return }
                self?.libraryMoveProgress = (done, total, url.lastPathComponent)
            })
        // The bucket, when the library's remote is one. Drive: see
        // `adoptFromBucket` for why there is nothing there to find.
        if !report.stopped, let config = await cloudConfig(), case .bucket(let c) = config.remote {
            do {
                report.fold(try await Self.adoptFromBucket(
                    c, provider: config.provider, root: root, storeURL: build.storeURL,
                    fetch: CloudLibrary.fetch, owns: owns, whoHasIt: who, stop: stop,
                    progress: { [weak self] done, total, name in
                        guard drawn.due(done, of: total) else { return }
                        self?.libraryMoveProgress = (done, total, name)
                    }))
            } catch {
                report.failures.append(cloudSay(error))
            }
        }
        if !report.stopped, !stop.isStopped {
            report.photos += await Self.backfillPhotos(storeURL: build.storeURL, roots: roots.roots,
                                                       linked: linkedFolders, owns: owns, whoHasIt: who,
                                                       isOnline: linkedIsOnline)
        }
        await reloadIfWritten(since: &bookAt)
        if !report.addedIds.isEmpty {
            let ids = report.addedIds
            Task { [weak self] in await self?.backUpToCloud(ids: ids) }
        }
        // Stopped: said either way, with what got in before it — whoever
        // pressed Stop is waiting to hear that it did.
        if report.stopped || stop.isStopped {
            importNote = words.callIt("mac.scan_stopped", ["n": .number(Double(report.added))])
            return
        }
        // The load-time pass speaks only when it found something; a person
        // who pressed the button is always answered.
        guard byPerson || report.added > 0 || report.photos > 0 else { return }
        var note = report.added + report.duplicates + report.photos == 0
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
    ///
    /// A shop that pressed Stop on the linked pass stopped the LOOKING, not
    /// one folder of it: this pass does not then start by itself behind it.
    /// Rescan in Settings still runs it whenever the shop asks.
    func rescanStorageIfDue() {
        guard case .store(let build) = source, !storageScannedBooks.contains(build.rawValue) else { return }
        storageScannedBooks.insert(build.rawValue)
        let linked = linkedScan
        storageScan = Task { [weak self] in
            await linked?.value
            guard let self, !Task.isCancelled, !self.libraryScanStoppedBooks.contains(build.rawValue) else { return }
            await self.rescanStorage(byPerson: false)
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
        return Array(out.suffix(StorageLedger.cap))
    }
}
