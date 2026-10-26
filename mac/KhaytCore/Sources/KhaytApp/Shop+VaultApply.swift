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
            let edits = outcome.edits, at = StoreWriter.iso(now)
            do {
                try await StoreWriter.updateOffMain(build) { root in Self.applyVaultEdits(edits, at: at, to: &root) }
            } catch {
                return .notWritten
            }
        }
        try? await remote.sync.settle(outcome.settled)
        if !outcome.conflicts.isEmpty {
            vaultConflictNote = words.callIt("mac.vault_kept_both", ["n": .number(Double(outcome.conflicts.count))])
        }
        if !outcome.edits.isEmpty || !outcome.replaced.isEmpty || !outcome.online.isEmpty
            || !outcome.conflicts.isEmpty {
            await load(source)
        }
        return .applied(settled: outcome.settled.count, held: outcome.held)
    }

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
    nonisolated static func applyVaultEdits(_ edits: [VaultApply.Edit], at: String,
                                            to root: inout [String: JSONValue]) {
        for edit in edits {
            _ = StoreWriter.changeRecord(&root, collection: "printFiles", id: edit.recordId) { record in
                switch edit {
                case .holds(_, let fileId, let sha, let size):
                    record["vaultFileId"] = .string(fileId)
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
                    record.removeValue(forKey: "vaultFileId")
                    record.removeValue(forKey: "vaultTrashedAt")
                    record.removeValue(forKey: "vaultArchived")
                }
            }
        }
    }
}
