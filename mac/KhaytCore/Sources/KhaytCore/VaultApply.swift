import Foundation
import CryptoKit

/// Brings this device's library into line with what the vault's feed said
/// (`VaultSync.pendingChanges`): another device added a file, put up a new
/// version of one, renamed it, trashed, restored or purged it.
///
/// ── WHAT IT TOUCHES, AND WHAT IT NEVER DOES ─────────────────────────────
///
/// It writes bytes only inside a record's OWN folder in Khayt's library
/// (`Library.folder`), and only three ways:
///
/// * a `.cloud` sidecar naming the vault copy, for a model that is not on
///   this device: online-only, fetched on use by Bring Back, which verifies
///   size and SHA-256 against the sidecar;
/// * the new version over a local copy NOBODY HAS TOUCHED since the last
///   sync (it still hashes to the version this device held, `Pending.base`),
///   downloaded beside it, proved, and renamed over — the bytes it replaces
///   are an older version the vault keeps;
/// * the other device's version BESIDE a local copy the shop has edited
///   since: both kept, `<name> (vault v<N>).<ext>`, and said.
///
/// It never deletes a model, never writes a linked or adopted-in-place file
/// (the shop's own folder), never writes a folder outside the primary root,
/// and never writes the book: it returns `Edit`s for the app to write
/// through the store's write chain, and the app settles the changes only
/// once they are written.
///
/// ── AGAINST THE VAULT AS IT IS NOW ──────────────────────────────────────
///
/// A pending change says WHICH file to look at. What is done is decided by
/// that file's state now (`VaultSync.load()`), so a change applied late, or
/// twice, or after a later one, does the right thing: a trash undone by a
/// restore before it was applied archives nothing.
public enum VaultApply {

    /// One library record, as much as applying a change needs.
    public struct Record: Sendable, Equatable {
        public var id: String
        /// `LibraryLocation.itemDirName(id)`: the folder the key names.
        public var folderName: String
        /// Linked, or adopted in place: the model is the shop's own file
        /// somewhere else, and its bytes are never written here.
        public var inPlace: Bool
        public var contentHash: String?
        public var vaultFileId: String?
        public var vaultTrashed: Bool

        public init(id: String, folderName: String, inPlace: Bool = false, contentHash: String? = nil,
                    vaultFileId: String? = nil, vaultTrashed: Bool = false) {
            self.id = id; self.folderName = folderName; self.inPlace = inPlace; self.contentHash = contentHash
            self.vaultFileId = vaultFileId; self.vaultTrashed = vaultTrashed
        }
    }

    /// The library this device has.
    public struct Library: Sendable {
        public var records: [String: Record]
        var byFolder: [String: String] = [:]
        var byVaultFile: [String: String] = [:]
        /// Khayt's own folder for a record WHEN ITS BYTES MAY BE WRITTEN
        /// THERE: the one it has under the primary root, or the one to make
        /// there. Nil when its folder is somewhere else (a past location, the
        /// mirror): writing a new one in front of it would hide its files.
        public var folder: @Sendable (Record) -> URL?

        public init(records: [Record], folder: @escaping @Sendable (Record) -> URL?) {
            var byId: [String: Record] = [:]
            for r in records where byId[r.id] == nil {
                byId[r.id] = r
                if byFolder[r.folderName] == nil { byFolder[r.folderName] = r.id }
                if let f = r.vaultFileId, byVaultFile[f] == nil { byVaultFile[f] = r.id }
            }
            self.records = byId
            self.folder = folder
        }
    }

    /// A change to a record, for the app to write.
    public enum Edit: Equatable, Sendable {
        /// The record's copy is now these bytes (on this device, or a
        /// sidecar for them): `vaultFileId`, and `contentHash` /
        /// `sourceFile.size` where they differ.
        case holds(recordId: String, fileId: String, sha256: String, size: Int)
        /// In the vault's Trash: `vaultTrashedAt`, and archived when it was not.
        case trashed(recordId: String, fileId: String)
        /// Out of the Trash: archived again only if the vault archived it.
        case restored(recordId: String)
        /// Gone from the vault for good: the link dropped, the record kept.
        case purged(recordId: String)

        public var recordId: String {
            switch self {
            case .holds(let r, _, _, _), .trashed(let r, _), .restored(let r), .purged(let r): r
            }
        }
    }

    /// Both kept: the shop's file, and the other device's version(s) beside it.
    public struct Conflict: Equatable, Sendable {
        public var recordId: String
        public var kept: URL
        public var copies: [URL]
    }

    public struct Outcome: Sendable {
        public var edits: [Edit] = []
        /// Applied (or nothing to do): the app settles these once `edits` are written.
        public var settled: [VaultSync.Pending] = []
        /// Records whose local copy was replaced by a newer version.
        public var replaced: [String] = []
        /// Records now online-only on this device (a sidecar written or renewed).
        public var online: [String] = []
        public var conflicts: [Conflict] = []
        /// Left pending for a later pass: a record not here yet, a trash in
        /// its grace period, a download that failed.
        public var held = 0
        /// Why a change could not be applied this time (not for the shop's eyes).
        public var problems: [String] = []
    }

    /// A trash is applied to the record only after this long. A vault trash
    /// from another device today comes from Delete Completely, which also
    /// deletes the record: the book's own sync should carry THAT, and an
    /// archive stamped here first would outrank its tombstone.
    public static let trashGrace: TimeInterval = 3600
    /// How long a change waits for its record to arrive with the book's sync.
    public static let recordWait: TimeInterval = 7 * 86_400
    /// Downloads in one pass; the rest wait for the next.
    public static let downloadsPerPass = 25

    /// The name a kept-both copy goes by: `part.stl` → `part (vault v3).stl`.
    public static func keptName(_ filename: String, version: Int) -> String {
        let ext = (filename as NSString).pathExtension
        let stem = ext.isEmpty ? filename : String(filename.dropLast(ext.count + 1))
        return ext.isEmpty ? "\(stem) (vault v\(version))" : "\(stem) (vault v\(version)).\(ext)"
    }

    /// The record folder and file a library key names:
    /// `[prefix/]print-files/<folder>/<filename>` (`S3.objectKey`). Nil for
    /// anything else, or a name that could step out of the folder.
    public static func place(of key: String) -> (folder: String, filename: String)? {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let i = parts.lastIndex(of: "print-files"), parts.count == i + 3 else { return nil }
        let folder = parts[i + 1], name = parts[i + 2]
        for s in [folder, name] where s.isEmpty || s == "." || s == ".." || s.hasPrefix(".") || s.contains("\\") {
            return nil
        }
        return (folder, name)
    }

    // MARK: - The pass

    public static func run(_ sync: VaultSync, library: Library, engine: KhaytEngine,
                           now: Date = Date()) async -> Outcome {
        var out = Outcome()
        var downloads = 0
        let st = sync.load()
        for p in sync.pendingChanges() {
            let verdict: Verdict
            do {
                verdict = try await one(p, sync: sync, state: st, library: library, engine: engine, now: now,
                                        downloads: &downloads, out: &out)
            } catch {
                verdict = .held
                out.problems.append("\(p.change.fileId): \(error)")
            }
            switch verdict {
            case .done: out.settled.append(p)
            case .held: out.held += 1
            }
        }
        return out
    }

    enum Verdict { case done, held }

    /// Keeps a change waiting for its record, for a while.
    static func waiting(_ p: VaultSync.Pending, now: Date) -> Verdict {
        now.timeIntervalSince(p.at) < recordWait ? .held : .done
    }

    /// The record a file belongs to and the name of its file in that
    /// record's folder, from the key in its meta record.
    static func target(_ meta: VaultMeta, fileId: String, state: VaultSyncState,
                       library: Library) -> (Record, String)? {
        let key = meta.key ?? state.keys.first { $0.value == fileId }?.key
        guard let key, let place = place(of: key) else { return nil }
        // The FOLDER the key names decides: that is where the bytes live.
        // The meta's record id only stands in when no record owns it.
        let id = library.byFolder[place.folder]
            ?? meta.recordId.flatMap { library.records[$0]?.folderName == place.folder ? $0 : nil }
        guard let id, let record = library.records[id] else { return nil }
        return (record, place.filename)
    }

    /// The state entry's current meta, opened.
    static func currentMeta(_ e: VaultSyncState.Entry, keys: VaultKeys) -> VaultMeta? {
        guard let row = e.row else { return nil }
        return try? VaultMeta.open(row, vaultKey: keys.vaultKey, lastSeenSeq: nil).meta
    }

    static func one(_ p: VaultSync.Pending, sync: VaultSync, state st: VaultSyncState, library: Library,
                    engine: KhaytEngine, now: Date, downloads: inout Int, out: inout Outcome) async throws -> Verdict {
        switch p.change {
        case .refused:
            return .done

        case .purged(let fileId, let recordId):
            let id = library.byVaultFile[fileId] ?? recordId
            if let id, let r = library.records[id], r.vaultFileId == fileId || r.vaultTrashed {
                out.edits.append(.purged(recordId: id))
            }
            return .done

        case .trashed(let fileId, _):
            // Purged since (the purge says so), or restored since: nothing.
            guard let e = st.files[fileId], e.trashed else { return .done }
            guard now.timeIntervalSince(p.at) >= trashGrace else { return .held }
            guard let meta = currentMeta(e, keys: sync.keys),
                  let (record, _) = target(meta, fileId: fileId, state: st, library: library) else {
                // Its record is gone: deleted with it, by the book's sync.
                return .done
            }
            if !record.vaultTrashed { out.edits.append(.trashed(recordId: record.id, fileId: fileId)) }
            return .done

        case .restored(let fileId, _):
            guard let e = st.files[fileId], !e.trashed else { return .done }
            guard let meta = currentMeta(e, keys: sync.keys),
                  let (record, _) = target(meta, fileId: fileId, state: st, library: library) else { return .done }
            if record.vaultTrashed { out.edits.append(.restored(recordId: record.id)) }
            return .done

        case .appeared(let fileId, _), .changed(let fileId, _):
            return try await bytes(p, fileId: fileId, versions: nil, sync: sync, state: st, library: library,
                                   engine: engine, now: now, downloads: &downloads, out: &out)

        case .conflict(let fileId, _, let versions):
            return try await bytes(p, fileId: fileId, versions: versions, sync: sync, state: st, library: library,
                                   engine: engine, now: now, downloads: &downloads, out: &out)
        }
    }

    /// A new file, a new head, or a conflict: the record's copy brought
    /// into line. `versions` (a conflict) are kept side by side.
    static func bytes(_ p: VaultSync.Pending, fileId: String, versions: [Int]?, sync: VaultSync,
                      state st: VaultSyncState, library: Library, engine: KhaytEngine, now: Date,
                      downloads: inout Int, out: inout Outcome) async throws -> Verdict {
        // Purged since, or in the Trash (its `.trashed` change deals with
        // the record): no bytes brought down for it.
        guard let e = st.files[fileId], !e.trashed, let row = e.row, let head = row.headVersion,
              let meta = currentMeta(e, keys: sync.keys) else { return .done }
        guard let (record, filename) = target(meta, fileId: fileId, state: st, library: library) else {
            return waiting(p, now: now)
        }
        // The shop's own file, or a folder this device must not write.
        guard !record.inPlace, let folder = library.folder(record) else { return .done }
        let local = folder.appending(path: filename)
        // What the head's bytes hash to, when the meta record is the head's own.
        let newSha = meta.uploadId == head.uploadId ? meta.sha256 : nil
        func holds(_ sha: String, _ size: Int, changedHere: Bool) {
            Self.holds(record, fileId: fileId, sha: sha, size: size, changedHere: changedHere, out: &out)
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: local.path) else {
            guard let sha = newSha else { return .done }
            switch try await markOnline(local, key: meta.key ?? "", sha: sha, size: head.plaintextSize,
                                        engine: engine) {
            case .wrote:
                if !out.online.contains(record.id) { out.online.append(record.id) }
                holds(sha, head.plaintextSize, changedHere: true)
            case .already: holds(sha, head.plaintextSize, changedHere: false)
            case .left: break
            }
            return .done
        }
        let here = try await OffPool.digest(local)
        if let versions {
            // Keep both: every newer version that is not the shop's own bytes.
            // The first listed is the head this device knew, when there was one.
            let older = versions.count > 1 ? versions.first : nil
            var copies: [URL] = []
            for v in versions where v != older {
                let name = folder.appending(path: keptName(filename, version: v))
                if fm.fileExists(atPath: name.path) { continue }
                guard downloads < downloadsPerPass else { return .held }
                downloads += 1
                let got = try await fetch(row, version: v, beside: local, sync: sync, seq: e.seq)
                if got.sha256 == here.sha256 { try? fm.removeItem(at: got.url); continue }
                try move(got.url, to: name)
                copies.append(name)
            }
            if !copies.isEmpty { out.conflicts.append(Conflict(recordId: record.id, kept: local, copies: copies)) }
            return .done
        }
        if here.sha256 == newSha {
            holds(here.sha256, here.size, changedHere: false)
            return .done
        }
        // Untouched since this device last synced it: the new version over it.
        if let base = p.base, here.sha256 == base {
            guard downloads < downloadsPerPass else { return .held }
            downloads += 1
            let got = try await fetch(row, version: nil, beside: local, sync: sync, seq: e.seq)
            // Edited while the download ran: kept as it is, the new one beside.
            let again = try await OffPool.digest(local)
            if again.sha256 != here.sha256 {
                let name = folder.appending(path: keptName(filename, version: head.version))
                if fm.fileExists(atPath: name.path) { try? fm.removeItem(at: got.url) } else { try move(got.url, to: name) }
                out.conflicts.append(Conflict(recordId: record.id, kept: local, copies: [name]))
                return .done
            }
            try move(got.url, to: local)
            out.replaced.append(record.id)
            holds(got.sha256, got.size, changedHere: true)
            return .done
        }
        // Edited here since (or never known to match): keep both.
        let name = folder.appending(path: keptName(filename, version: head.version))
        if !fm.fileExists(atPath: name.path) {
            guard downloads < downloadsPerPass else { return .held }
            downloads += 1
            let got = try await fetch(row, version: nil, beside: local, sync: sync, seq: e.seq)
            if got.sha256 == here.sha256 {
                try? fm.removeItem(at: got.url)
                holds(here.sha256, here.size, changedHere: false)
                return .done
            }
            try move(got.url, to: name)
            out.conflicts.append(Conflict(recordId: record.id, kept: local, copies: [name]))
        }
        return .done
    }

    /// No copy on this device: a `.cloud` sidecar naming the vault's, which
    /// Bring Back fetches and proves on use. One already there for these
    /// bytes is left; one for an older vault version is renewed; one naming
    /// another remote (a bucket, a Drive) is the shop's, and left.
    enum Online { case wrote, already, left }

    /// The record's copy online: a sidecar written or renewed (`wrote`), one
    /// already there for these bytes (`already`), or nothing done (`left`).
    static func markOnline(_ local: URL, key: String, sha: String, size: Int,
                           engine: KhaytEngine) async throws -> Online {
        // A sidecar cannot say a 0-byte file (`parseSidecar` refuses it).
        guard size > 0, !key.isEmpty else { return .left }
        let fm = FileManager.default
        let sidecar = local.deletingLastPathComponent().appending(path: local.lastPathComponent + ".cloud")
        if let text = try? String(contentsOf: sidecar, encoding: .utf8),
           let side = try await engine.parseSidecar(text) {
            if side.sha256.lowercased() == sha.lowercased() { return .already }
            guard side.provider == "vault" || side.key == key else { return .left }
        }
        try fm.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = try await engine.sidecarText(size: size, sha256: sha, key: key, provider: "vault",
                                                at: ISO8601DateFormatter().string(from: Date()))
        try Data(text.utf8).write(to: sidecar, options: .atomic)
        return .wrote
    }

    /// The record's copy is these bytes: said to the book only where it
    /// does not already say so — a write that changes nothing is not made.
    ///
    /// ── NOT A WRITE PER RECORD ────────────────────────────────────────────
    ///
    /// A record whose copy already matches is NOT stamped just to add
    /// `vaultFileId`: the first pass after an update sees every file in the
    /// vault, and stamping thousands of records would make this Mac's copy of
    /// each the newest in the book's last-writer-wins sync, over any edit
    /// another Mac made to them meanwhile. So the book is written when its
    /// hash is wrong, or when this pass changed the bytes on this device.
    static func holds(_ record: Record, fileId: String, sha: String, size: Int, changedHere: Bool,
                      out: inout Outcome) {
        let hashDiffers = record.contentHash?.lowercased() != sha.lowercased()
        let stale = record.contentHash != nil && hashDiffers
        guard stale || (changedHere && (hashDiffers || record.vaultFileId != fileId)) else { return }
        out.edits.append(.holds(recordId: record.id, fileId: fileId, sha256: sha, size: size))
    }

    /// One version, downloaded and proved, into a hidden file beside `local`
    /// (so no listing sees it half there).
    static func fetch(_ row: VaultClient.FeedFile, version: Int?, beside local: URL, sync: VaultSync,
                      seq: Int?) async throws -> (url: URL, sha256: String, size: Int) {
        let dest = local.deletingLastPathComponent()
            .appending(path: ".\(local.lastPathComponent).vault-in-\(UUID().uuidString.prefix(8))")
        do {
            let r = try await VaultDownload.run(row, version: version, client: sync.client, keys: sync.keys,
                                                lastSeenSeq: version == nil ? seq : nil, to: dest)
            return (dest, r.sha256, r.size)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
    }

    /// A proved download into its place in one rename: a model is never half
    /// there. The download is gone either way.
    static func move(_ file: URL, to place: URL) throws {
        defer { try? FileManager.default.removeItem(at: file) }
        if rename(file.path, place.path) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

/// Blocking file work off Swift's cooperative pool: a model can be a
/// gigabyte, and hashing one inside a task holds a pool thread for all of it
/// (CI's runner has three; see the LAN suite's 22-minute timeouts).
enum OffPool {
    static let queue = DispatchQueue(label: "app.khayt.vault-apply", qos: .utility)

    static func digest(_ url: URL) async throws -> (sha256: String, size: Int) {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<(sha256: String, size: Int), Error>) in
            queue.async {
                do {
                    let h = try FileHandle(forReadingFrom: url)
                    defer { try? h.close() }
                    var sha = SHA256()
                    var size = 0
                    while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty {
                        sha.update(data: chunk); size += chunk.count
                    }
                    c.resume(returning: (VaultCrypto.hex(Data(sha.finalize())), size))
                } catch {
                    c.resume(throwing: error)
                }
            }
        }
    }
}
