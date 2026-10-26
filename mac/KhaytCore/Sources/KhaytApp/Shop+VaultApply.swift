import Foundation
import KhaytCore

/// What another Mac did in the vault, applied to this Mac's library.
///
/// ── THE BUG THIS CLOSES ───────────────────────────────────────────────────
///
/// `VaultSync.pull()` has always said what changed — a file added, a new
/// version, a rename, a trash, a restore, a purge — and every caller threw it
/// away: the `head`s and read-backs inside `VaultRemote`, the Links and
/// Products sheets. Each of those pulls moved the feed on, so a change was
/// not merely unapplied, it was USED UP. Another Mac could put up a new
/// version of a model and this one kept printing the old one for ever.
///
/// Now every pull keeps what it said (`VaultSyncState.pending`) until this
/// applies it (`VaultApply`, in KhaytCore, where the vault stub tests it), and
/// only then is it settled. What a change does to a model's bytes and its
/// record is written down there; this is the app's half: who may, when, and
/// the book.
///
/// ── WHO, AND WHEN ─────────────────────────────────────────────────────────
///
/// * The staff lock. Bringing the library into line changes its records and
///   the files in its folders, which is an edit of the library
///   (`printFiles` → `inventory`). Locked, nothing is applied and nothing is
///   lost: the changes wait, and the next pass after someone who may has
///   signed in applies them.
/// * Never the sample book, and never a library whose remote is not the vault.
/// * At launch and every hour (the window's loop, beside
///   `verifyCloudCopiesIfDue`), and when the Library opens on the vault —
///   at most once a minute. Downloads and hashing never hold the main thread
///   or the cooperative pool (`OffPool`).
extension Shop {

    /// What a pass did, for its callers and tests.
    enum VaultApplyRun: Equatable {
        case locked, sample, notOnVault, busy, unavailable
        /// The book could not be written: nothing settled, all of it again next time.
        case notWritten
        case applied(settled: Int, held: Int)
    }

    /// At most one pass a minute from the screen's own trigger.
    nonisolated static let vaultApplyEvery: TimeInterval = 60

    func applyVaultChangesIfDue(now: Date = Date()) async {
        if let at = vaultAppliedAt, now.timeIntervalSince(at) < Self.vaultApplyEvery { return }
        await applyVaultChanges(now: now)
    }

    @discardableResult
    func applyVaultChanges(now: Date = Date()) async -> VaultApplyRun {
        // Background, so no sentence: the lock's own screen says who may.
        guard lockAllows(Self.lockArea(ofCollection: "printFiles"), "edit") else { return .locked }
        guard let build = source.build else { return .sample }
        guard libraryOnVault else { return .notOnVault }
        guard !vaultApplyBusy else { return .busy }
        vaultApplyBusy = true
        defer { vaultApplyBusy = false }
        vaultAppliedAt = now
        guard let engine, let roots = libraryRoots, let remote = await vaultRemote() else { return .unavailable }
        // The newest first, so a change already undone elsewhere is seen as undone.
        do { try await remote.sync.pull() } catch { return .unavailable }
        let library = Self.vaultLibrary(rows: fileRows, roots: roots)
        let outcome = await VaultApply.run(remote.sync, library: library, engine: engine, now: now)
        if !outcome.edits.isEmpty {
            let edits = outcome.edits, at = StoreWriter.iso(now), replaced = Set(outcome.replaced)
            do {
                try await StoreWriter.updateOffMain(build) { root in
                    Self.applyVaultEdits(edits, replaced: replaced, at: at, to: &root)
                }
            } catch {
                return .notWritten
            }
        }
        try? await remote.sync.settle(outcome.settled)
        if !outcome.edits.isEmpty || !outcome.replaced.isEmpty || !outcome.online.isEmpty
            || !outcome.conflicts.isEmpty {
            await load(source)
        }
        // A version that replaced a copy here leaves figures from the old
        // bytes: measured again now, by the shop's own Measure path.
        if await remeasureStaleVaultModels(build: build, engine: engine, roots: roots) > 0 { await load(source) }
        let rows = fileRows
        vaultKeptCopies = await PinWork.run { Self.vaultKeptCopies(rows: rows, roots: roots) }
        return .applied(settled: outcome.settled.count, held: outcome.held)
    }

    // MARK: - Figures from the old bytes

    /// Records whose figures are another version's (`figuresStaleFor`) and
    /// whose model is on this Mac, measured again — `readDownloaded` and
    /// `applyDownloaded`, what Measure and Measure Online use, with the old
    /// figures taken off first so the new ones replace them. At most
    /// `VaultApply.downloadsPerPass` a pass; one write for all of them. A
    /// model only online keeps its mark until it is brought back. Returns how
    /// many were measured.
    @discardableResult
    func remeasureStaleVaultModels(build: StoreReader.Build, engine: KhaytEngine,
                                   roots: LibraryLocation.Roots) async -> Int {
        guard lockAllows(Self.lockArea(ofCollection: "printFiles"), "edit") else { return 0 }
        let due = Array(files.filter { $0.figuresStale && !$0.isLinked }.prefix(VaultApply.downloadsPerPass))
        var reads: [String: DownloadedRead] = [:]
        for file in due {
            let found = await PinWork.run { () -> URL? in
                guard let url = Shop.modelFile(for: file, roots: roots.roots), !VaultApply.isKeptCopy(url) else { return nil }
                return url
            }
            guard let url = found else { continue }
            if let read = try? await Self.readDownloaded(file: url, pictures: nil, engine: engine) { reads[file.id] = read }
        }
        guard !reads.isEmpty else { return 0 }
        let batch = reads
        do {
            try await StoreWriter.updateOffMain(build) { book in Shop.applyRemeasured(batch, to: &book) }
        } catch { return 0 }
        return reads.count
    }

    /// The measure, written over figures that belong to older bytes: the
    /// slicer's figures and the mark go first, then `applyDownloaded`, which
    /// fills what is empty and writes the hash and geometry as it always does.
    /// The colour list is the shop's and stays; the overhang walk, kept with
    /// the hash it was made from, reads as out of date on its own
    /// (`LibraryFile.riskAnalysis`).
    nonisolated static func applyRemeasured(_ reads: [String: DownloadedRead], to book: inout [String: JSONValue]) {
        var rows = Shop.rows(book, "printFiles")
        for (i, row) in rows.enumerated() {
            guard case .object(var o) = row, let id = Shop.recordId(row), reads[id] != nil else { continue }
            // The old bytes' measurements: a new file that will not measure
            // must not keep them either.
            for k in ["parsed", "geometryKey", "geometryReader", "meshTried", "figuresStaleFor"] {
                o.removeValue(forKey: k)
            }
            rows[i] = .object(o)
        }
        book["printFiles"] = .array(rows)
        Shop.applyDownloaded(reads, to: &book)
    }

    // MARK: - Both kept: which one stays

    /// Every kept-both copy in the library's own folders, read off the disk
    /// (its marker), so the banner survives a relaunch. Off the main thread.
    nonisolated static func vaultKeptCopies(rows: [JSONValue], roots: LibraryLocation.Roots) -> [VaultKeptCopy] {
        var out: [VaultKeptCopy] = []
        for case .object(let r) in rows {
            guard case .string(let id)? = r["id"], !id.isEmpty else { continue }
            if case .string(let p)? = r["externalPath"], !p.isEmpty { continue }
            let folder = URL(fileURLWithPath: roots.primary).appending(path: LibraryLocation.itemDirName(id))
            var title = id
            if case .string(let n)? = r["name"], !n.isEmpty { title = n }
            for (copy, marker) in VaultApply.keptCopies(in: folder) {
                out.append(VaultKeptCopy(recordId: id, title: title, mine: folder.appending(path: marker.of),
                                         copy: copy, version: marker.version))
            }
        }
        return out
    }

    /// The shop chose. "Keep this Mac's": the vault's copy goes to the Trash,
    /// and the next backup makes this Mac's the vault's newest. "Use the
    /// vault's": this Mac's goes to the Trash and the vault's takes its name,
    /// its hash goes on the record, and its figures are measured again. The
    /// marker goes with the copy. Nothing is ever deleted outright.
    func resolveVaultConflict(_ kept: VaultKeptCopy, keepMine: Bool) async {
        guard permitted(Self.lockArea(ofCollection: "printFiles"), "edit") else { return }
        guard let build = source.build, let engine, let roots = libraryRoots else { return }
        let marker = VaultApply.keptMarkerURL(for: kept.copy)
        do {
            if keepMine {
                try Shop.trash(kept.copy)
                try? Shop.trash(marker)
            } else {
                let hash = await PinWork.run { try? LibraryImport.contentHash(of: kept.copy) } ?? nil
                guard let hash else { throw CloudLibrary.Failure.readBackDiffers }
                if FileManager.default.fileExists(atPath: kept.mine.path) { try Shop.trash(kept.mine) }
                try FileManager.default.moveItem(at: kept.copy, to: kept.mine)
                try? Shop.trash(marker)
                let id = kept.recordId
                try await StoreWriter.updateOffMain(build) { book in
                    _ = StoreWriter.changeRecord(&book, collection: "printFiles", id: id) { record in
                        if case .string(let was)? = record["contentHash"], was == hash { return }
                        record["contentHash"] = .string(hash)
                        record["figuresStaleFor"] = .string(hash)
                    }
                }
                await load(source)
                await remeasureStaleVaultModels(build: build, engine: engine, roots: roots)
            }
        } catch {
            moveProblem = said(error)
        }
        vaultKeptCopies.removeAll { $0 == kept }
        await load(source)
    }
}

/// A model another Mac changed after it was edited here, both copies kept
/// (`VaultApply.keep`): the shop's, and the vault's beside it.
struct VaultKeptCopy: Identifiable, Equatable, Sendable {
    var id: String { copy.path }
    let recordId: String
    let title: String
    let mine: URL
    let copy: URL
    let version: Int
}

extension Shop {

    /// The library as `VaultApply` needs it, from the book's rows. A
    /// record's bytes may be written only in its folder under the PRIMARY
    /// root: one found in a past location or the mirror is left alone (a new
    /// folder in front of it would hide its files), and a linked or
    /// adopted-in-place model is the shop's own file.
    nonisolated static func vaultLibrary(rows: [JSONValue], roots: LibraryLocation.Roots) -> VaultApply.Library {
        var records: [VaultApply.Record] = []
        for case .object(let r) in rows {
            func text(_ k: String) -> String? {
                if case .string(let s)? = r[k], !s.isEmpty { return s }
                return nil
            }
            guard let id = text("id") else { continue }
            records.append(.init(id: id, folderName: LibraryLocation.itemDirName(id),
                                 inPlace: text("externalPath") != nil, contentHash: text("contentHash"),
                                 vaultFileId: text("vaultFileId"), vaultTrashed: text("vaultTrashedAt") != nil))
        }
        let primary = roots.primary, all = roots.roots
        return VaultApply.Library(records: records) { record in
            let mine = URL(fileURLWithPath: primary).appending(path: record.folderName)
            guard let found = LibraryLocation.directory(for: record.id, roots: all) else { return mine }
            return found.standardizedFileURL.path == mine.standardizedFileURL.path ? found : nil
        }
    }

    /// `VaultApply`'s edits, on the book inside the write chain: each record
    /// changed in place, by id, and only if it is still there. Every field is
    /// optional on the way in, so a record from any older build takes them.
    ///
    /// * `vaultFileId` — the record's vault file (`docs/vault-format.md`).
    /// * `vaultTrashedAt` — in the vault's Trash, since then.
    /// * `vaultArchived` — the vault's trash is why it is archived, so the
    ///   vault's restore un-archives it. A model the shop archived itself
    ///   stays archived whatever the vault does.
    ///
    /// `replaced`: records whose local copy was replaced by another
    /// version; their figures are marked out of date (`figuresStaleFor`),
    /// as are any whose hash changes here.
    nonisolated static func applyVaultEdits(_ edits: [VaultApply.Edit], replaced: Set<String> = [], at: String,
                                            to root: inout [String: JSONValue]) {
        for edit in edits {
            _ = StoreWriter.changeRecord(&root, collection: "printFiles", id: edit.recordId) { record in
                switch edit {
                case .holds(_, let fileId, let sha, let size):
                    // Other bytes than the ones its figures were measured
                    // from: they are marked, never left to pass for current.
                    var was = ""
                    if case .string(let h)? = record["contentHash"] { was = h }
                    if replaced.contains(edit.recordId) || (!was.isEmpty && was.lowercased() != sha.lowercased()) {
                        record["figuresStaleFor"] = .string(sha)
                    }
                    record["vaultFileId"] = .string(fileId)
                    record.removeValue(forKey: "vaultPurgedAt")
                    record["contentHash"] = .string(sha)
                    if case .object(var source)? = record["sourceFile"] {
                        source["size"] = .number(Double(size))
                        record["sourceFile"] = .object(source)
                    }
                case .trashed(_, let fileId):
                    record["vaultFileId"] = .string(fileId)
                    if case .string(let t)? = record["vaultTrashedAt"], !t.isEmpty { break }
                    record["vaultTrashedAt"] = .string(at)
                    if case .string(let was)? = record["archivedAt"], !was.isEmpty { break }
                    record["archivedAt"] = .string(at)
                    record["vaultArchived"] = .bool(true)
                case .restored:
                    record.removeValue(forKey: "vaultTrashedAt")
                    if case .bool(true)? = record["vaultArchived"] {
                        record.removeValue(forKey: "archivedAt")
                        record.removeValue(forKey: "vaultArchived")
                    }
                case .purged:
                    // Stamped, so Library Health can tell a model whose only
                    // copy the vault deleted from one that was never there
                    // (`VaultOnlyCopies.deletedByPlan`). Kept until the vault
                    // holds it again (`.holds` clears it).
                    if case .string(let f)? = record["vaultFileId"], !f.isEmpty { record["vaultPurgedAt"] = .string(at) }
                    record.removeValue(forKey: "vaultFileId")
                    record.removeValue(forKey: "vaultTrashedAt")
                    record.removeValue(forKey: "vaultArchived")
                }
            }
        }
    }
}
