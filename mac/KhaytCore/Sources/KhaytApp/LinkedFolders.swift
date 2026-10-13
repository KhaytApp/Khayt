import Foundation
import KhaytCore

/// Folders the library INDEXES WHERE THEY ARE — a NAS, an external drive, a
/// Dropbox folder — instead of copying their models into the vault.
///
/// Asked for by the shop (Sep 2026) after looking at LayerMate, which works
/// this way. Kept in `settings.printLibrary.linked` (a list of paths).
///
/// ── THE FILES ARE THE SHOP'S, AND STAY WHERE THEY ARE ──────────────────
///
/// A linked model's record points at its file (`externalPath`); only its
/// picture goes into the vault. Nothing here copies, moves or removes a
/// linked file: deleting the model deletes the RECORD (the vault folder holds
/// only the picture), unlinking a folder removes its records, and online
/// storage and library moves walk the vault and never see a linked file.
extension Shop {

    /// The folders linked on this book.
    var linkedFolders: [String] {
        guard case .object(let l)? = settingsDict["printLibrary"], case .array(let rows)? = l["linked"] else { return [] }
        return rows.compactMap { if case .string(let s) = $0, !s.isEmpty { s } else { nil } }
    }

    private func writeLinked(_ paths: [String]) throws {
        guard permitted("settings", "edit") else { throw Shop.MoveRefused(sentence: moveProblem ?? "") }
        guard let build = source.build else { throw CocoaError(.fileWriteNoPermission) }
        try StoreWriter.update(build) { root in
            var settings = Self.settings(root)
            var library: [String: JSONValue] = [:]
            if case .object(let l)? = settings["printLibrary"] { library = l }
            library["linked"] = .array(paths.map(JSONValue.string))
            settings["printLibrary"] = .object(library)
            root["settings"] = .object(settings)
        }
    }

    /// Link a folder and index what is in it.
    func linkFolder(_ url: URL) async {
        libraryMoveProblem = nil
        let path = url.standardizedFileURL.path
        guard !linkedFolders.contains(path) else { await rescanLinkedFolders(); return }
        // Not inside the library's own folders, nor around them: those are
        // the vault, and linking them would index every model twice.
        if let roots = libraryRoots, roots.roots.contains(where: {
            LibraryMove.under(path, $0) || LibraryMove.under($0, path)
        }) {
            libraryMoveProblem = words.callIt("mac.linked_not_vault"); return
        }
        do { try writeLinked(linkedFolders + [path]) }
        catch { libraryMoveProblem = String(describing: error); return }
        await load(source)
        await rescanLinkedFolders()
    }

    /// Stop indexing a folder. Its models leave the library; its FILES are
    /// not touched.
    func unlinkFolder(_ path: String) async {
        guard permitted("settings", "edit") else { return }
        libraryMoveProblem = nil
        guard let build = source.build else { return }
        do {
            try writeLinked(linkedFolders.filter { $0 != path })
            let gone = Set(files.filter { $0.isLinked && LibraryMove.under($0.externalPath ?? "", path) }.map(\.id))
            try StoreWriter.update(build) { root in
                var rows = Self.rows(root, "printFiles")
                rows.removeAll { Self.recordId($0).map(gone.contains) ?? false }
                root["printFiles"] = .array(rows)
            }
            // The vault folders of those records hold only their pictures.
            if let roots = libraryRoots {
                for id in gone {
                    let dir = URL(fileURLWithPath: roots.primary).appending(path: LibraryLocation.itemDirName(id))
                    let inside = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                    if inside.allSatisfy({ ["png", "jpg", "jpeg"].contains(($0 as NSString).pathExtension.lowercased()) }) {
                        try? Self.trash(dir)
                    }
                }
            }
            await load(source)
            libraryMoveNote = words.callIt("mac.linked_unlinked", ["n": .number(Double(gone.count))])
        } catch {
            libraryMoveProblem = String(describing: error)
        }
    }

    /// Index what is new in every linked folder, in place. A file already
    /// indexed (by its path) is left alone; one whose bytes the library
    /// already holds is counted as a duplicate, as an import would.
    ///
    /// `byPerson: false` is the once-per-book pass on load (`rescanLinkedIfDue`),
    /// which indexes folders the owner already linked and runs whoever is at
    /// the Mac. A person pressing Rescan adds to the library: inventory/create.
    ///
    /// ── A DRIVE OF TEN THOUSAND MODELS (Oct 2026) ────────────────────────
    ///
    /// Four things the shop's linked Google Drive needed, in the order they
    /// run here:
    ///
    ///   * STOP (`stopLibraryScan`): the walk and the indexing look at the
    ///     flag between files; what was indexed before stays, and the busy
    ///     flag is let go by the `defer` whatever happens.
    ///   * NO DOWNLOADS: an online-only file is indexed from its listing
    ///     (`LibraryImport.addOnline`), and filled in once it is here
    ///     (`fillNowLocal`).
    ///   * THE LINKED FOLDER'S NAME IS NOT A GROUP, and the grouping rule is
    ///     smarter (`ImportGrouping.folded`, `fitting`).
    ///   * THE RECORDS ALREADY THERE are filed again by the same rule, once
    ///     per book (`LinkedRegroup`), from the same walk.
    func rescanLinkedFolders(byPerson: Bool = true) async {
        if byPerson { guard permitted("inventory", "create") else { return } }
        // lock: system — when !byPerson: indexing folders the owner linked,
        // once per book on load.
        guard let build = source.build, StoreLock.weOwnIt(build), let roots = libraryRoots, let engine else { return }
        let folders = linkedFolders.filter { FileManager.default.fileExists(atPath: $0) }
        guard !folders.isEmpty, !libraryMoveBusy else { return }
        libraryMoveBusy = true
        let stop = ScanStop()
        libraryScanStop = stop
        defer { libraryMoveBusy = false; libraryMoveProgress = nil; libraryScanStop = nil }
        let stopped = { stop.isStopped || Task.isCancelled }
        let owns = { StoreLock.weOwnIt(build) }
        let who = { StoreLock.describe(StoreLock.verdict(for: build)) }
        let known = Set(files.compactMap(\.externalPath).map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let vaults = roots.roots + [roots.primary]

        // THE WALK, metadata only, on a dispatch queue (`PinWork`) — not a
        // detached Task holding a cooperative thread for a whole Drive.
        let settings = settingsDict
        let walked = await PinWork.run {
            Shop.linkedWalk(folders.map { URL(fileURLWithPath: $0) }, skippingAll: vaults, known: known,
                            settings: settings, stop: stop)
        }
        if stopped() { libraryMoveNote = words.callIt("mac.scan_stopped", ["n": .number(0)]); return }

        // THE RECORDS ALREADY HERE, filed again once per book.
        var regrouped = 0
        if LinkedRegroup.doneVersion(settingsDict) < LinkedRegroup.version {
            regrouped = (try? Self.regroupLinked(walked.map(\.plan), linked: linkedFolders,
                                                 storeURL: build.storeURL,
                                                 owns: owns, whoHasIt: who)) ?? 0
        }
        // THE ONES THAT WERE ONLINE AND ARE HERE NOW, filled in.
        await fillNowLocal(storeURL: build.storeURL, engine: engine, owns: owns, whoHasIt: who, stop: stop)

        let fresh = walked.flatMap(\.fresh)
        var report = LibraryImport.Report()
        if !fresh.isEmpty, !stopped() {
            report = await LibraryImport.addMany(
                fresh, storeURL: build.storeURL, libraryRoot: URL(fileURLWithPath: roots.primary),
                knownHashes: Set(files.compactMap(\.contentHash)),
                nameOfExisting: { [files] hash in files.first { $0.contentHash == hash }?.title },
                engine: engine, keepOriginal: true, inPlace: true,
                knownNameSizes: LibraryImport.nameSizes(of: files),
                isOnline: LinkedCloud.isOnlineOnly,
                owns: owns, whoHasIt: who,
                shouldStop: stopped,
                progress: { [weak self] done, total, url in
                    self?.libraryMoveProgress = (done, total, url.lastPathComponent)
                })
        }
        await load(source)

        // INDEXED FIRST, REFINED AFTER: the library is already filed by the
        // heuristic and on screen; the assistant (when the shop turned it on)
        // and the prints' pictures only improve on that, and Stop ends both.
        var plans = walked.map(\.plan)
        var assistant: SortAsk?
        if !stopped(), aiLibraryAllowed {
            let asked = await askAssistantToSort(plans, stop: stop)
            assistant = asked
            if asked.sorted > 0 || asked.loose > 0, !stopped() {
                plans = await PinWork.run { [settingsDict] in
                    walked.map { Shop.sortedPlan(root: $0.root, models: $0.models, images: $0.images,
                                                 settings: settingsDict, births: $0.plan.births) }
                }
                regrouped += (try? Self.regroupLinked(plans, linked: linkedFolders, storeURL: build.storeURL,
                                                      owns: owns, whoHasIt: who)) ?? 0
            }
        }
        var pictures = stopped() ? 0 : await fetchPrintPictures(plans, stop: stop)
        // "Check pictures" (its own switch): the ones the assistant confirms
        // against a print's own preview go on; the rest wait in the sheet.
        if !stopped(), aiPicturesAllowed {
            pictures += await checkPictures(plans, stop: stop).attached
        }
        if regrouped > 0 || pictures > 0 || assistant != nil { await load(source) }

        var lines: [String] = []
        if report.stopped || stopped() {
            lines.append(words.callIt("mac.scan_stopped", ["n": .number(Double(report.moved))]))
        } else if fresh.isEmpty {
            lines.append(words.callIt("mac.linked_up_to_date"))
        } else {
            lines.append(words.callIt("mac.linked_scanned", ["n": .number(Double(report.moved)),
                                                             "same": .number(Double(report.duplicates))]))
        }
        if report.online > 0 { lines.append(words.callIt("mac.linked_online", ["online": .number(Double(report.online))])) }
        if regrouped > 0 { lines.append(words.callIt("mac.linked_regrouped", ["n": .number(Double(regrouped))])) }
        if pictures > 0 { lines.append(words.callIt("mac.sort_pictures_added", ["n": .number(Double(pictures))])) }
        if let line = assistant?.line(words) { lines.append(line) }
        libraryMoveNote = lines.joined(separator: " ")
        if !report.failures.isEmpty {
            libraryMoveProblem = report.failures.prefix(3).joined(separator: "\n")
        }
    }

    /// Stop the linked or storage scan that is running, keeping what it has
    /// done. The load-time passes do not start again by themselves on this
    /// book this launch — see `rescanStorageIfDue`.
    func stopLibraryScan() {
        // Nothing running, nothing stopped: a Stop pressed as a scan ends (the
        // button is drawn a frame late) must not mark the book stopped and so
        // keep its load-time storage pass from running at all.
        guard let running = libraryScanStop else { return }
        running.stop()
        libraryScanStopping = true
        linkedScan?.cancel()
        storageScan?.cancel()
        if case .store(let build) = source { libraryScanStoppedBooks.insert(build.rawValue) }
    }

    /// "Regroup from folders": file the linked models by their folders again,
    /// with the groups the shop chose left alone (`LinkedRegroup`). The same
    /// refile the scan does once per book, on demand.
    func regroupLinkedFolders() async {
        guard permitted("inventory", "edit") else { return }
        guard let build = source.build, StoreLock.weOwnIt(build), let roots = libraryRoots else { return }
        let folders = linkedFolders.filter { FileManager.default.fileExists(atPath: $0) }
        guard !folders.isEmpty, !libraryMoveBusy else { return }
        libraryMoveProblem = nil
        libraryMoveBusy = true
        let stop = ScanStop()
        libraryScanStop = stop
        defer { libraryMoveBusy = false; libraryMoveProgress = nil; libraryScanStop = nil }
        let vaults = roots.roots + [roots.primary]
        let settings = settingsDict
        let walked = await PinWork.run {
            Shop.linkedWalk(folders.map { URL(fileURLWithPath: $0) }, skippingAll: vaults, known: [],
                            settings: settings, stop: stop)
        }
        if stop.isStopped || Task.isCancelled { return }
        do {
            let n = try Self.regroupLinked(walked.map(\.plan), linked: linkedFolders,
                                           storeURL: build.storeURL,
                                           owns: { StoreLock.weOwnIt(build) },
                                           whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) })
            await load(source)
            libraryMoveNote = words.callIt("mac.linked_regrouped", ["n": .number(Double(n))])
        } catch {
            libraryMoveProblem = String(describing: error)
        }
    }

    /// One linked folder as the walk found it.
    struct LinkedFound: Sendable {
        let root: URL
        /// Every model under it, indexed or not.
        let models: [URL]
        /// Every picture under it — names only, nothing read.
        var images: [URL] = []
        /// The folder sorted into prints (`PrintSort`), with whatever the
        /// shop's assistant already said laid over the heuristic.
        let plan: PrintSort.Plan
        /// The ones not indexed yet, grouped and with their photos.
        let fresh: [LibraryImport.Incoming]
    }

    /// Every model and picture under each linked folder, the folder sorted
    /// into prints (`PrintSort`, with the assistant's cached answers from
    /// `settings` laid over it), and the new models placed by that sort. Reads
    /// names and listings only — no file's bytes, so nothing online is
    /// fetched — and looks at `stop` every few hundred entries.
    nonisolated static func linkedWalk(_ folders: [URL], skippingAll roots: [String], known: Set<String>,
                                       settings: [String: JSONValue] = [:],
                                       stop: ScanStop?) -> [LinkedFound] {
        let vaults = roots.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        func isInVault(_ path: String) -> Bool {
            vaults.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
        }
        // NESTED LINKED FOLDERS: a model is the INNERMOST linked folder's,
        // and only that one walks it. Walked by both, it was filed by the outer
        // one at index time and judged by both at refile time — and each
        // "Regroup from folders" moved it from one's group to the other's and
        // back (alpha.66 review).
        let linkedPaths = folders.map { $0.standardizedFileURL.path }
        var out: [LinkedFound] = []
        for root in folders where !isInVault(root.standardizedFileURL.path) {
            if stop?.isStopped == true { break }
            let mine = root.standardizedFileURL.path
            let inner = linkedPaths.filter { $0 != mine && LibraryMove.under($0, mine) }
            func isInner(_ path: String) -> Bool { inner.contains { LibraryMove.under(path, $0) } }
            let walker = FileManager.default.enumerator(at: root,
                                                        includingPropertiesForKeys: LibraryImport.fileKeys + [.creationDateKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
            var models: [URL] = []
            var images: [URL] = []
            var seen = 0
            while let next = walker?.nextObject() as? URL {
                seen += 1
                if seen % 256 == 0, stop?.isStopped == true { break }
                // Regular files only, as the import walk: a symlink named
                // `x.stl` is a pointer elsewhere, not a model kept here.
                let ext = next.pathExtension.lowercased()
                let isModel = LibraryImport.kinds.contains(ext)
                guard isModel || ModelPhoto.kinds.contains(ext) else { continue }
                let path = next.standardizedFileURL.path
                guard LibraryImport.isRegularFile(next), !isInVault(path), !isInner(path) else { continue }
                if isModel { models.append(next) } else { images.append(next) }
            }
            models.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            images.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let births = Self.births(of: models + images, under: root)
            let plan = sortedPlan(root: root, models: models, images: images, settings: settings, births: births)
            let new = models.filter { !known.contains($0.standardizedFileURL.path) }
            let photos = ModelPhoto.candidates(for: new, everyModel: models, boundary: root)
            let fresh = new.map { url -> LibraryImport.Incoming in
                let p = plan.placement(of: url)
                var file = LibraryImport.Incoming(url: url, group: p?.group, title: p?.title)
                file.tags = p?.collection.map { [$0] } ?? []
                file.photos = photos[url] ?? []
                return file
            }
            out.append(LinkedFound(root: root, models: models, images: images, plan: plan, fresh: fresh))
        }
        return out
    }

    /// One linked folder sorted: the heuristic, then — when the book holds
    /// answers from the shop's assistant for any of its top-level folders,
    /// still matching what is on disk — again with those laid over it.
    nonisolated static func sortedPlan(root: URL, models: [URL], images: [URL],
                                       settings: [String: JSONValue],
                                       births: [String: Double] = [:]) -> PrintSort.Plan {
        let first = PrintSort.plan(root: root, models: models, images: images, births: births)
        var answers = SortCache.answers(settings, for: SortCache.units(first))
        answers.loose = LooseCache.answers(settings, root: root, present: LooseCache.present(first))
        guard answers != PrintSort.Answers() else { return first }
        return PrintSort.plan(root: root, models: models, images: images, answers: answers, births: births)
    }

    /// When each file directly inside `root` was created — its birth time,
    /// read from the listing (`creationDateKey`), never from the file's
    /// bytes — the order a copy job dropped the loose models in.
    nonisolated static func births(of urls: [URL], under root: URL) -> [String: Double] {
        var out: [String: Double] = [:]
        for url in urls {
            guard let rel = PrintSort.rel(url, under: root), !rel.contains("/"),
                  let made = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate else { continue }
            out[rel] = made.timeIntervalSince1970
        }
        return out
    }

    /// File the linked records again by their folders and mark the book as
    /// refiled, in ONE write through the store's chain. Returns how many
    /// records moved.
    ///
    /// `linked` is every folder linked on the book, here or not: the book is
    /// marked refiled only when all of them were walked (`LinkedRegroup.complete`).
    nonisolated static func regroupLinked(_ walked: [(root: URL, models: [URL])], linked: [String] = [],
                                          storeURL: URL,
                                          owns: @escaping () -> Bool,
                                          whoHasIt: @escaping () -> String?) throws -> Int {
        try regroupLinked(walked.map { PrintSort.plan(root: $0.root, models: $0.models, images: []) },
                          linked: linked, storeURL: storeURL, owns: owns, whoHasIt: whoHasIt)
    }

    /// The refile itself, over linked folders already sorted.
    nonisolated static func regroupLinked(_ plans: [PrintSort.Plan], linked: [String] = [],
                                          storeURL: URL,
                                          owns: @escaping () -> Bool,
                                          whoHasIt: @escaping () -> String?) throws -> Int {
        var moved = 0
        let walked = plans.map { (root: $0.root, models: $0.models) }
        // lock: callers — rescanLinkedFolders, regroupLinkedFolders, applyLinkedSort
        try StoreWriter.update(storeURL: storeURL, owns: owns, whoHasIt: whoHasIt) { root in
            // Judged against the rows ON DISK NOW, inside the chain, so a
            // group the shop changed a moment ago is seen as the shop's.
            var rows: [JSONValue] = []
            if case .array(let r)? = root["printFiles"] { rows = r }
            var changes: [LinkedRegroup.Change] = []
            for plan in plans {
                changes += LinkedRegroup.changes(rows: rows, plan: plan)
            }
            LinkedRegroup.apply(changes, to: &root)
            if LinkedRegroup.complete(linked: linked.isEmpty ? walked.map(\.root.path) : linked,
                                      walked: walked, rows: rows) {
                LinkedRegroup.markDone(&root)
            }
            moved = changes.count
        }
        return moved
    }

    /// Linked models indexed online only whose file is on this Mac now — the
    /// shop opened one, or made a folder available offline — measured,
    /// hashed and pictured the way a bucket model brought down is
    /// (`fillDownloaded`), with the picture in the record's vault folder.
    /// Stops when the scan is stopped.
    func fillNowLocal(storeURL: URL, engine: KhaytEngine, owns: @escaping () -> Bool,
                      whoHasIt: @escaping () -> String?, stop: ScanStop?) async {
        // lock: system — fills in models the library already lists, from files now on this Mac; part of the linked pass, adds and removes nothing.
        guard let roots = libraryRoots else { return }
        // Only a file in a folder this book links, or in its own library
        // folder (`addOnline` from the storage pass): `externalPath` arrives
        // by sync from the shop's other devices, and this pass reads what it
        // names unasked — a path anywhere else on this Mac is not read.
        let places = linkedFolders + roots.roots + [roots.primary]
        let waiting: [(id: String, path: String)] = fileRows.compactMap { row in
            guard case .object(let o) = row, let mark = o["indexedOnline"], mark != .null,
                  case .string(let id)? = o["id"], case .string(let p)? = o["externalPath"], !p.isEmpty,
                  places.contains(where: { !$0.isEmpty && LibraryMove.under(p, $0) }) else { return nil }
            return (id, p)
        }
        guard !waiting.isEmpty else { return }
        let here = await PinWork.run {
            waiting.filter { FileManager.default.fileExists(atPath: $0.path)
                && !LinkedCloud.isOnlineOnly(URL(fileURLWithPath: $0.path)) }
        }
        for item in here {
            if stop?.isStopped == true || Task.isCancelled { break }
            let pictures = Self.vaultFolder(item.id, roots: roots)
            try? FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
            _ = try? await Self.fillDownloaded(id: item.id, file: URL(fileURLWithPath: item.path), pictures: pictures,
                                               storeURL: storeURL, engine: engine, owns: owns, whoHasIt: whoHasIt)
        }
    }

    /// A record's vault folder — the one it already has, in whichever of the
    /// library's folders that is (it moves with the library), or a new one in
    /// the primary. Where a linked model's picture goes; never the shop's own
    /// folder the model sits in.
    static func vaultFolder(_ id: String, roots: LibraryLocation.Roots) -> URL {
        LibraryLocation.directory(for: id, roots: roots.roots)
            ?? URL(fileURLWithPath: roots.primary).appending(path: LibraryLocation.itemDirName(id))
    }

    /// A linked model the cloud has not downloaded, brought down by reading
    /// it — which is what makes a File Provider fetch a file — and filled
    /// in. Bring Back's answer for a linked model (`bringBack`).
    func bringDownLinked(_ file: LibraryFile) async {
        guard let path = file.externalPath, let build = source.build, let engine, let roots = libraryRoots else { return }
        let pictures = Self.vaultFolder(file.id, roots: roots)
        try? FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        do {
            // lock: system — reads a model the library already lists, as Bring Back does.
            if let same = try await Self.fillDownloaded(id: file.id, file: URL(fileURLWithPath: path), pictures: pictures,
                                                        storeURL: build.storeURL, engine: engine,
                                                        owns: { StoreLock.weOwnIt(build) },
                                                        whoHasIt: { StoreLock.describe(StoreLock.verdict(for: build)) }) {
                cloudLibraryProblem = words.callIt("mac.storage_downloaded_duplicate", ["name": .string(same)])
            }
        } catch {
            cloudLibraryProblem = words.callIt("mac.cloudlib_bring_back_failed") + " " + String(describing: error)
        }
    }
}
