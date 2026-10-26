import Foundation

/// This device's memory of the vault: the feed's `rev`, the last `seq` seen
/// per file, and which library record and which `LibraryRemote` key each
/// vault file belongs to.
///
/// ── WHERE IT LIVES, AND WHY NOT IN THE BOOK OR THE LIBRARY ──────────────
///
/// In the app's own per-device folder, the book's folder on the Mac:
/// `<app folder>/vault-state.<shopId>.<hash of the root's path>.json`
/// (`VaultSync.stateURL(appFolder:libraryRoot:shopId:)`).
///
/// * Not in the book: the book syncs to every device, and the last-seen
///   `seq` is worth something only as THIS device's memory. A value another
///   device wrote is the very thing a rolled-back server could also serve.
/// * Not in or beside the library root: a root, or its parent, can be iCloud,
///   a NAS or a shared folder (`LibraryLocation`), which would carry the file
///   to other devices. Nothing is ever read from beside the root either: a
///   file there could be planted by anyone who can write that folder, and no
///   released build wrote one (an unreleased branch did; beta.6 review).
/// * The root's path is hashed into the name, so two libraries on one Mac
///   keep two states.
///
/// It holds ciphertext and wraps only (the last feed row of each file), never
/// a key. Losing it costs a full re-pull and the rollback memory, nothing else.
public struct VaultSyncState: Codable, Equatable, Sendable {
    public var v = 1
    public var shopId: String
    public var deviceId: String
    /// The feed position: `GET /files?since=rev` next.
    public var rev = 0
    public var files: [String: Entry] = [:]
    /// `LibraryRemote` key → fileId.
    public var keys: [String: String] = [:]
    /// Library record id → fileId. The record's own field is `vaultFileId`
    /// (see `docs/vault-format.md` "Client state"); this index is the copy
    /// that lets a record that lost the field be matched again.
    public var records: [String: String] = [:]
    /// What `pull` has said that the app has not applied yet
    /// (`VaultSync.pendingChanges` / `settle`). EVERY pull appends here,
    /// whoever asked for it, so an incidental one (a `head`, a backup's
    /// read-back) cannot use a change up.
    ///
    /// NIL — the key absent — is a state file written before this existed:
    /// its next pull seeds it with every file it already knows, once, so
    /// what the older build pulled and threw away is brought into line too.
    public var pending: [VaultSync.Pending]?

    public struct Entry: Codable, Equatable, Sendable {
        /// The last meta `seq` this device accepted, for rollback.
        public var seq: Int?
        public var head: Int?
        public var metaRev = 0
        public var trashed = false
        public var recordId: String?
        /// The last feed row, as the cloud sent it.
        public var row: VaultClient.FeedFile?
        /// The plaintext SHA-256 of the head this device accepted (its meta's
        /// `sha256`). Absent on an entry written before it existed; the row
        /// then answers (`VaultSync.acceptedSha256`).
        public var sha256: String?
    }

    public init(shopId: String, deviceId: String) { self.shopId = shopId; self.deviceId = deviceId }
}

/// Pulls the vault's delta feed into `VaultSyncState` and says what changed,
/// as an EFFECTS LIST for the caller to apply to the library. It never
/// writes the book and never touches a model file itself.
///
/// ── CONFLICTS: BYTES ARE NEVER LAST-WRITER-WINS ─────────────────────────
///
/// The cloud always commits and keeps every version. `.conflict` is said when
///
/// * this device's own upload committed with `conflict: true` (another
///   device had moved the head first), or
/// * the head moved while the caller has unsynced local edits to that record
///   (`localEdits`), or
/// * the head moved past more than one new version from more than one device
///   since this device last looked: parallel edits, not a sequence.
///
/// The caller keeps BOTH: the local file stays, and the other version is
/// brought down beside it. Meta (renames, moves) is metadata, and the cloud
/// already refuses a stale write of it (409 stale), so it merges.
public struct VaultSync: Sendable {
    public let client: VaultClient
    public let keys: VaultKeys
    public let stateURL: URL
    public let deviceId: String

    public init(client: VaultClient, keys: VaultKeys, stateURL: URL, deviceId: String) {
        self.client = client; self.keys = keys; self.stateURL = stateURL; self.deviceId = deviceId
    }

    /// The state for the library at `libraryRoot`, kept in `appFolder` (on
    /// the Mac, the book's folder: `StoreReader.Build.vaultStateFolder()`).
    public init(client: VaultClient, keys: VaultKeys, appFolder: URL, libraryRoot: URL, deviceId: String) {
        let url = Self.stateURL(appFolder: appFolder, libraryRoot: libraryRoot, shopId: client.connection.shopId)
        self.init(client: client, keys: keys, stateURL: url, deviceId: deviceId)
    }

    public func with(fetch: @escaping S3.Fetch) -> VaultSync {
        VaultSync(client: client.with(fetch: fetch), keys: keys, stateURL: stateURL, deviceId: deviceId)
    }

    static func safe(_ s: String) -> String {
        String(s.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "_" })
    }

    /// `<appFolder>/vault-state.<shopId>.<first 16 hex of sha256(root path)>.json`.
    public static func stateURL(appFolder: URL, libraryRoot: URL, shopId: String) -> URL {
        let path = libraryRoot.standardizedFileURL.path
        let h = VaultCrypto.hex(VaultCrypto.sha256(Data(path.utf8))).prefix(16)
        return appFolder.appending(path: "vault-state.\(safe(shopId)).\(h).json")
    }

    public enum Change: Codable, Equatable, Sendable {
        /// A file this device has not seen.
        case appeared(fileId: String, meta: VaultMeta)
        /// A new head, or new meta (a rename or a move), with no conflict.
        case changed(fileId: String, meta: VaultMeta)
        /// Keep both: `versions` are the ones to keep side by side.
        case conflict(fileId: String, recordId: String?, versions: [Int])
        case trashed(fileId: String, recordId: String?)
        case restored(fileId: String, recordId: String?)
        /// Gone from the cloud for good; drop the link (the local copy stays).
        case purged(fileId: String, recordId: String?)
        /// A row whose meta would not open, or is older than one already seen
        /// (`rollback`). Its last good state is kept.
        case refused(fileId: String, reason: String)

        public var fileId: String {
            switch self {
            case .appeared(let f, _), .changed(let f, _), .conflict(let f, _, _), .trashed(let f, _),
                 .restored(let f, _), .purged(let f, _), .refused(let f, _): f
            }
        }
    }

    /// A change `pull` said, kept until the app has applied it.
    public struct Pending: Codable, Equatable, Sendable {
        public var change: Change
        /// For a head that moved: the plaintext SHA-256 of the version this
        /// device held BEFORE it — what a local copy nobody has touched since
        /// the last sync still hashes to. Nil when there was none.
        public var base: String?
        /// When this device first heard of it.
        public var at: Date

        public init(change: Change, base: String? = nil, at: Date = Date()) {
            self.change = change; self.base = base; self.at = at
        }
    }

    /// At most this many kept, the newest: a Mac locked for months must not
    /// grow its state file without end. Each is applied against the vault as
    /// it is NOW (`VaultApply`), so the oldest are the least worth keeping.
    public static let pendingCap = 5000

    // MARK: - State

    public func load() -> VaultSyncState {
        if let d = try? Data(contentsOf: stateURL),
           let s = try? JSONDecoder().decode(VaultSyncState.self, from: d),
           s.shopId == client.connection.shopId { return s }
        return VaultSyncState(shopId: client.connection.shopId, deviceId: deviceId)
    }

    func save(_ s: VaultSyncState) throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        try enc.encode(s).write(to: stateURL, options: .atomic)
    }

    /// One state file, one writer at a time, across awaits.
    func locked<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        let lock = await VaultStateLocks.shared.lock(for: stateURL.path)
        await lock.acquire()
        do { let r = try await body(); await lock.release(); return r }
        catch { await lock.release(); throw error }
    }

    // MARK: - Pulling the feed

    /// Every page since the last `rev`, applied and saved page by page.
    /// `localEdits`: library record ids with local changes not yet uploaded.
    @discardableResult
    public func pull(localEdits: Set<String> = []) async throws -> [Change] {
        try await locked {
            var st = load()
            if st.pending == nil { st.pending = seed(st) }
            var out: [Change] = []
            while true {
                let page = try await client.files(since: st.rev)
                for f in page.files { apply(f, to: &st, changes: &out, localEdits: localEdits) }
                st.rev = max(st.rev, page.rev)
                try save(st)
                if !page.more || page.files.isEmpty { break }
            }
            return out
        }
    }

    func apply(_ f: VaultClient.FeedFile, to st: inout VaultSyncState, changes out: inout [Change],
               localEdits: Set<String>, now: Date = Date()) {
        let old = st.files[f.fileId]
        let held = old.flatMap(acceptedSha256)
        // Said to the caller AND kept for the app (`pending`).
        func say(_ c: Change) {
            out.append(c)
            var list = st.pending ?? []
            if !list.contains(where: { $0.change == c && $0.base == held }) {
                list.append(Pending(change: c, base: held, at: now))
            }
            if list.count > Self.pendingCap { list.removeFirst(list.count - Self.pendingCap) }
            st.pending = list
        }
        if f.purged {
            if let old {
                say(.purged(fileId: f.fileId, recordId: old.recordId))
                st.files[f.fileId] = nil
                st.keys = st.keys.filter { $0.value != f.fileId }
                st.records = st.records.filter { $0.value != f.fileId }
            }
            return
        }
        let opened: (meta: VaultMeta, seq: Int)
        do { opened = try VaultMeta.open(f, vaultKey: keys.vaultKey, lastSeenSeq: old?.seq) }
        catch VaultCrypto.Failure.rollback(let seq, let lastSeen) {
            say(.refused(fileId: f.fileId, reason: "rollback: seq \(seq) < \(lastSeen)")); return
        } catch {
            say(.refused(fileId: f.fileId, reason: "meta: \(error)")); return
        }
        let meta = opened.meta
        var e = old ?? VaultSyncState.Entry()
        e.seq = opened.seq
        e.metaRev = f.metaRev
        e.row = f
        e.recordId = meta.recordId ?? e.recordId
        let wasTrashed = old?.trashed ?? false
        e.trashed = f.trashed
        e.head = f.head
        e.sha256 = meta.sha256
        st.files[f.fileId] = e
        if let key = meta.key, st.keys[key] == nil { st.keys[key] = f.fileId }
        if let r = meta.recordId, st.records[r] == nil { st.records[r] = f.fileId }

        guard let old else {
            say(.appeared(fileId: f.fileId, meta: meta))
            // First seen already in the Trash (a full re-pull, or a file
            // added and deleted elsewhere between two looks).
            if f.trashed { say(.trashed(fileId: f.fileId, recordId: e.recordId)) }
            return
        }
        if !wasTrashed && f.trashed { say(.trashed(fileId: f.fileId, recordId: e.recordId)) }
        if wasTrashed && !f.trashed { say(.restored(fileId: f.fileId, recordId: e.recordId)) }
        if f.head != old.head {
            let base = old.head ?? 0
            let newer = f.versions.filter { $0.version > base }
            let devices = Set(newer.map { $0.deviceId ?? "" })
            let edited = e.recordId.map(localEdits.contains) ?? false
            if edited || (newer.count > 1 && devices.count > 1) {
                say(.conflict(fileId: f.fileId, recordId: e.recordId,
                              versions: (old.head.map { [$0] } ?? []) + newer.map(\.version)))
            } else {
                say(.changed(fileId: f.fileId, meta: meta))
            }
        } else if f.metaRev != old.metaRev, old.row != nil {
            // (An entry with no row yet is this device's own upload, noted by
            // `record`: its first sight in the feed is not news.)
            say(.changed(fileId: f.fileId, meta: meta))
        }
    }

    /// The plaintext SHA-256 of the head this device last accepted for an
    /// entry: its own field, else (an entry from before the field) its row's
    /// meta, opened.
    func acceptedSha256(_ e: VaultSyncState.Entry) -> String? {
        if let s = e.sha256 { return s }
        guard let row = e.row else { return nil }
        return try? VaultMeta.open(row, vaultKey: keys.vaultKey, lastSeenSeq: nil).meta.sha256
    }

    /// What a state file from before `pending` had already pulled, said
    /// again: every file it knows as `.appeared` (and `.trashed` where it is),
    /// so the app brings the library into line with the vault as it is now.
    func seed(_ st: VaultSyncState) -> [Pending] {
        var out: [Pending] = []
        for (fileId, e) in st.files.sorted(by: { $0.key < $1.key }) {
            guard let row = e.row,
                  let meta = try? VaultMeta.open(row, vaultKey: keys.vaultKey, lastSeenSeq: nil).meta else { continue }
            out.append(Pending(change: .appeared(fileId: fileId, meta: meta)))
            if e.trashed { out.append(Pending(change: .trashed(fileId: fileId, recordId: e.recordId))) }
        }
        return Array(out.suffix(Self.pendingCap))
    }

    // MARK: - What the app has not applied yet

    /// Every change said since the app last settled, oldest first. A state
    /// file from before `pending` is seeded by the next `pull`, not here.
    public func pendingChanges() -> [Pending] { load().pending ?? [] }

    /// The app applied these: forget them. Anything said since stays.
    public func settle(_ done: [Pending]) async throws {
        guard !done.isEmpty else { return }
        try await locked {
            var st = load()
            var list = st.pending ?? []
            for d in done { if let i = list.firstIndex(of: d) { list.remove(at: i) } }
            st.pending = list
            try save(st)
        }
    }

    // MARK: - After an upload

    /// Note this device's own upload, so the next pull does not mistake it
    /// for someone else's. When the cloud said `conflict`, the head this
    /// device knew is left as it was and the feed is pulled at once: the
    /// head then moves past the other device's version AND this one, and
    /// `pull` says `.conflict` with both (and any others) listed.
    @discardableResult
    public func record(_ outcome: VaultUpload.Outcome, key: String?, recordId: String?) async throws -> [Change] {
        let conflict: Bool = try await locked {
            var st = load()
            let fileId: String
            var conflict = false
            switch outcome {
            case .committed(let c, let meta):
                fileId = c.fileId
                var e = st.files[fileId] ?? VaultSyncState.Entry()
                e.seq = max(e.seq ?? 0, meta.seq)
                e.recordId = recordId ?? e.recordId
                if c.conflict { conflict = true } else { e.head = c.version; e.sha256 = meta.sha256 }
                st.files[fileId] = e
            case .adopted(let fid, _, _, _):
                fileId = fid
            }
            if let key { st.keys[key] = fileId }
            if let recordId { st.records[recordId] = fileId }
            try save(st)
            return conflict
        }
        return conflict ? try await pull(localEdits: recordId.map { [$0] } ?? []) : []
    }

    /// The other half of `pull`: keep a rename or a move in the vault, with
    /// no bytes re-sent. `merge` is given the current record and returns the
    /// new one; on a stale base it is given the newer record and run again.
    /// The record stays sealed for the upload it pins, and its seq stays.
    @discardableResult
    public func setMeta(fileId: String, merge: @Sendable (VaultMeta) -> VaultMeta) async throws -> VaultMeta {
        for _ in 0..<4 {
            let st = load()
            guard let e = st.files[fileId], let row = e.row else { throw VaultClient.Failure.notFound("unknown-file") }
            let current = try VaultMeta.open(row, vaultKey: keys.vaultKey, lastSeenSeq: e.seq).meta
            var next = merge(current)
            next.uploadId = current.uploadId
            next.manifestHash = current.manifestHash
            next.size = current.size
            next.sha256 = current.sha256
            next.seq = current.seq
            let sealed = try next.sealed(vaultKey: keys.vaultKey, fileId: fileId)
            do {
                _ = try await client.setMeta(fileId: fileId, meta: sealed, baseMetaRev: row.metaRev)
                try await pull()
                return next
            } catch VaultClient.Failure.stale {
                // The newer record reaches us through the feed, where it is
                // opened against the versions it may be sealed for.
                try await pull()
            }
        }
        throw VaultClient.Failure.stale(metaRev: load().files[fileId]?.metaRev ?? 0, meta: nil)
    }
}

/// One async lock per state file path, so two pulls (or a pull and an
/// upload's bookkeeping) never interleave their load-modify-save.
actor VaultStateLocks {
    static let shared = VaultStateLocks()
    private var locks: [String: AsyncLock] = [:]
    func lock(for path: String) -> AsyncLock {
        if let l = locks[path] { return l }
        let l = AsyncLock(); locks[path] = l; return l
    }
}

actor AsyncLock {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

// MARK: - The vault as a LibraryRemote

/// The vault behind `LibraryRemote.vault`: the same opaque keys as a bucket
/// or a Drive, mapped to vault files through `VaultSyncState.keys`.
///
/// **The verified rule holds unchanged.** `head` answers with no etag, which
/// `etagVerdict` calls unusable, so `CloudLibrary.ensureInBucket` proves a
/// vault copy by downloading it (`getFile`, which itself pins every chunk
/// to the version's own sealed record) and comparing SHA-256 before any
/// local copy is removed. `verify` is the cheaper HEAD-equivalent for callers
/// that want one: a fresh feed, the meta record opened, and its pinned
/// sha256, size and manifest compared with what the cloud lists for the head.
public struct VaultRemote: Sendable {
    public let sync: VaultSync
    /// Where uploads keep their sealed chunks until they commit.
    public let spoolRoot: URL

    public init(sync: VaultSync, spoolRoot: URL) {
        self.sync = sync; self.spoolRoot = spoolRoot
    }

    public func with(fetch: @escaping S3.Fetch) -> VaultRemote {
        VaultRemote(sync: sync.with(fetch: fetch), spoolRoot: spoolRoot)
    }

    /// The head row of the file `key` names, after a fresh pull.
    func current(_ key: String) async throws -> (fileId: String, entry: VaultSyncState.Entry)? {
        try await sync.pull()
        let st = sync.load()
        guard let id = st.keys[key], let e = st.files[id] else { return nil }
        return (id, e)
    }

    public func put(_ key: String, data: Data) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: spoolRoot, withIntermediateDirectories: true)
        let tmp = spoolRoot.appending(path: "put-\(UUID().uuidString)")
        try data.write(to: tmp)
        defer { try? fm.removeItem(at: tmp) }
        try await putFile(key, file: tmp)
    }

    /// Upload `file` under `key`: a new version of the file the key already
    /// names, or a new file. Streamed; see `VaultUpload`.
    @discardableResult
    public func putFile(_ key: String, file: URL, recordId: String? = nil,
                        progress: (@Sendable (VaultUpload.Progress) -> Void)? = nil) async throws -> VaultUpload.Outcome {
        let cur = try await current(key)
        let live = cur.flatMap { $0.entry.trashed ? nil : $0 }
        let name = String(key.split(separator: "/").last ?? Substring(key))
        let job = VaultUpload.Job(source: file, spoolKey: "key:" + key, fileId: live?.fileId,
                                  baseVersion: live?.entry.head, lastSeq: live?.entry.seq,
                                  name: name,
                                  kind: (name as NSString).pathExtension.lowercased(), key: key,
                                  recordId: recordId ?? live?.entry.recordId, deviceId: sync.deviceId)
        let outcome = try await VaultUpload.run(job, client: sync.client, keys: sync.keys, spoolRoot: spoolRoot,
                                                progress: progress)
        try await sync.record(outcome, key: key, recordId: recordId)
        return outcome
    }

    public func getFile(_ key: String) async throws -> URL? {
        guard let cur = try await current(key), !cur.entry.trashed, let row = cur.entry.row else { return nil }
        let dest = FileManager.default.temporaryDirectory.appending(path: "khayt-vault-\(UUID().uuidString)")
        try await VaultDownload.run(row, client: sync.client, keys: sync.keys, lastSeenSeq: cur.entry.seq, to: dest)
        return dest
    }

    public func get(_ key: String) async throws -> Data? {
        guard let url = try await getFile(key) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url)
    }

    public func head(_ key: String) async throws -> S3.Head? {
        guard let cur = try await current(key), !cur.entry.trashed,
              let v = cur.entry.row?.headVersion else { return nil }
        return S3.Head(size: v.plaintextSize, etag: nil)
    }

    /// The HEAD-equivalent: the cloud's head for `key` is an upload whose
    /// authenticated record pins exactly these bytes.
    public func verify(_ key: String, sha256: String, size: Int) async throws -> Bool {
        guard let cur = try await current(key), !cur.entry.trashed, let row = cur.entry.row,
              let v = row.headVersion else { return false }
        let meta = try VaultMeta.open(row, vaultKey: sync.keys.vaultKey, lastSeenSeq: cur.entry.seq).meta
        guard let b64 = v.versionMeta, let sealed = Data(base64Encoded: b64) else { return false }
        let vm = try VaultCrypto.decryptVersionMeta(vaultKey: sync.keys.vaultKey, fileId: cur.fileId,
                                                    uploadId: v.uploadId, sealed: sealed, lastSeenSeq: nil)
        return meta.uploadId == v.uploadId && meta.manifestHash == vm.manifestHash && v.manifestHash == vm.manifestHash
            && meta.sha256 == sha256 && meta.size == size && vm.size == size && v.plaintextSize == size
    }

    /// To the vault's Trash (30 days). A file another key also names is
    /// only unlinked from this one.
    public func delete(_ key: String) async throws {
        guard let cur = try await current(key) else { return }
        let st = sync.load()
        let shared = st.keys.contains { $0.key != key && $0.value == cur.fileId }
        if shared {
            try await sync.locked {
                var s = sync.load(); s.keys[key] = nil; try sync.save(s)
            }
            return
        }
        if !cur.entry.trashed { try await sync.client.trash(fileId: cur.fileId) }
        try await sync.pull()
    }

    public func trashedCopy(_ key: String) async throws -> S3.Head? {
        guard let cur = try await current(key), cur.entry.trashed,
              let v = cur.entry.row?.headVersion else { return nil }
        return S3.Head(size: v.plaintextSize, etag: nil)
    }

    public func restoreFromTrash(_ key: String) async throws -> Bool {
        guard let cur = try await current(key), cur.entry.trashed else { return false }
        try await sync.client.restore(fileId: cur.fileId)
        try await sync.pull()
        return true
    }

    public func keys(under prefix: String) async throws -> [String] {
        try await sync.pull()
        let st = sync.load()
        return st.keys.filter { $0.key.hasPrefix(prefix) && st.files[$0.value].map { !$0.trashed } == true }
            .map(\.key).sorted()
    }
}
