import Foundation
import CryptoKit

/// The keys a vault client needs, from the shop's DEK (`CloudKeyMemory` on
/// the Mac). The DEK itself is kept only to derive the dedupe tag.
public struct VaultKeys: Sendable {
    let shopDek: Data
    public let vaultKey: Data

    public init(shopDek: Data) throws {
        self.shopDek = try VaultCrypto.key32(shopDek, "shop DEK")
        self.vaultKey = try VaultCrypto.vaultKey(shopDek: shopDek)
    }

    public func dedupeTag(plaintextSha256: Data) throws -> String {
        try VaultCrypto.dedupeTag(shopDek: shopDek, plaintextSha256: plaintextSha256)
    }
}

/// The JSON inside a shop meta record (`docs/vault-format.md` "Shop meta
/// record"). The format fixes only `seq`; the rest is this client's. What a
/// download pins is not this, but each version's own sealed record
/// (`VaultCrypto.decryptVersionMeta`), which every version has.
public struct VaultMeta: Codable, Equatable, Sendable {
    public var seq: Int
    /// The upload this record was sealed for, and its pinned manifest.
    public var uploadId: String
    public var manifestHash: String
    /// Plaintext size and SHA-256 of that upload.
    public var size: Int
    public var sha256: String
    /// What the shop calls it, its folder inside the library ("" for the
    /// root) and its kind (`stl`, `3mf`, …).
    public var name: String
    public var path: String
    public var kind: String
    /// The `LibraryRemote` key it was put under (`VaultRemote`).
    public var key: String?
    /// The library record's id (`docs/vault-format.md` "Client state").
    public var recordId: String?

    public init(seq: Int, uploadId: String, manifestHash: String, size: Int, sha256: String,
                name: String, path: String = "", kind: String = "", key: String? = nil,
                recordId: String? = nil) {
        self.seq = seq; self.uploadId = uploadId; self.manifestHash = manifestHash
        self.size = size; self.sha256 = sha256; self.name = name; self.path = path; self.kind = kind
        self.key = key; self.recordId = recordId
    }

    public func sealed(vaultKey: Data, fileId: String) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try VaultCrypto.encryptMeta(vaultKey: vaultKey, fileId: fileId, uploadId: uploadId,
                                           json: try enc.encode(self))
    }

    /// Open a feed row's meta. It is sealed for the upload that was the head
    /// when it was written, which need not be today's head (a version may be
    /// committed without new meta), so each version is tried, newest first.
    /// The record must also name the upload it was sealed for.
    public static func open(_ file: VaultClient.FeedFile, vaultKey: Data,
                            lastSeenSeq: Int?) throws -> (meta: VaultMeta, seq: Int) {
        guard let b64 = file.meta, let sealed = Data(base64Encoded: b64) else {
            throw VaultCrypto.Failure.badInput("file has no meta record")
        }
        let order = file.versions.sorted { ($0.version == file.head ? 1 : 0, $0.version) > ($1.version == file.head ? 1 : 0, $1.version) }
        for v in order {
            guard let (json, seq) = try? VaultCrypto.decryptMeta(vaultKey: vaultKey, fileId: file.fileId,
                                                                   uploadId: v.uploadId, sealed: sealed,
                                                                   lastSeenSeq: nil) else { continue }
            guard let m = try? JSONDecoder().decode(VaultMeta.self, from: json), m.uploadId == v.uploadId,
                  m.seq == seq else {
                throw VaultCrypto.Failure.badInput("meta record is not a Khayt client record")
            }
            // Rollback is judged once the record is known to be authentic.
            _ = try VaultCrypto.checkMetaSeq(seq, lastSeen: lastSeenSeq)
            return (m, seq)
        }
        throw VaultCrypto.Failure.authentication
    }
}

/// A resumable upload of one file into the vault.
///
/// ── THE ORDER, AND WHY ──────────────────────────────────────────────────
///
/// 1. Hash the plaintext (streamed) and compute the dedupe tag. A 409
///    duplicate means the shop already has these bytes: adopt that version,
///    upload nothing.
/// 2. POST, and only then encrypt: `uploadId` is in every chunk's AAD and in
///    the chunk key, so nothing can be sealed before the cloud answers.
/// 3. Seal each chunk under a fresh DK into the SPOOL, a directory on disk,
///    seal the version's own record (its whole manifest) and the shop meta,
///    then write the spool's state as `sealed` in one atomic rename. The raw
///    DK is never written anywhere; only its wrap under the vault key is.
/// 4. PUT the parts, three at a time, each from its spool file, recording
///    each one sent.
/// 5. /complete with the wrapped DK, the version record and the meta. A
///    409 parts-missing re-PUTs the STORED ciphertext.
///
/// **Never re-encrypt.** A crash after step 3 resumes from the spool: the
/// same uploadId, the same sealed bytes, fresh presigned URLs. A crash before
/// it (the DK lost with the process) abandons that upload and starts a new
/// one with a new DK and a new uploadId, which is the only safe way: sealing
/// chunk i of the same upload twice reuses (chunkKey, nonce_i)
/// (`docs/vault-format.md` "Chunks").
///
/// **Memory is bounded** by the concurrency: one 4 MiB chunk in hand per
/// part in flight. The file is read from disk a chunk at a time and never
/// whole. The spool costs the file's size again on disk until the upload
/// commits, and is removed then.
public enum VaultUpload {

    public static let concurrency = 3

    public struct Job: Sendable {
        /// The plaintext on disk.
        public var source: URL
        /// Names this upload's spool, so a later run finds it: one spool per
        /// library record (or key). Any string; it is hashed into a name.
        public var spoolKey: String
        /// Nil for a new file.
        public var fileId: String?
        /// The head this device last saw, for the cloud's conflict check.
        public var baseVersion: Int?
        /// The last `seq` this device saw for the file; the new head gets one more.
        public var lastSeq: Int?
        public var name: String
        public var path: String
        public var kind: String
        public var key: String?
        public var recordId: String?
        public var deviceId: String?

        public init(source: URL, spoolKey: String, fileId: String? = nil, baseVersion: Int? = nil,
                    lastSeq: Int? = nil, name: String,
                    path: String = "", kind: String = "", key: String? = nil, recordId: String? = nil,
                    deviceId: String? = nil) {
            self.source = source; self.spoolKey = spoolKey; self.fileId = fileId
            self.baseVersion = baseVersion; self.lastSeq = lastSeq
            self.name = name; self.path = path; self.kind = kind; self.key = key
            self.recordId = recordId; self.deviceId = deviceId
        }
    }

    public enum Outcome: Sendable, Equatable {
        /// A new version. `conflict`: another device committed first; both are kept.
        case committed(VaultClient.Committed, meta: VaultMeta)
        /// The shop already had these bytes, at this file and version.
        case adopted(fileId: String, version: Int, sha256: String, size: Int)
    }

    public struct Progress: Sendable, Equatable {
        public enum Phase: String, Sendable { case hashing, sealing, sending, completing }
        public let phase: Phase
        public let done: Int
        public let total: Int
    }

    public enum Failure: Error, Equatable {
        /// The file changed while it was being sealed; nothing was sent.
        case sourceChanged
        /// /complete kept reporting parts missing.
        case partsStillMissing([Int])
    }

    /// What the spool keeps between runs. Ciphertext and wraps only.
    struct SpoolState: Codable, Equatable {
        var v = 1
        var sourceSha256: String
        var size: Int
        var fileId: String
        var uploadId: String
        var version: Int
        var sizes: [Int]
        /// False until every chunk is on disk and the wraps below are set.
        var sealed: Bool
        var chunkHashes: [String] = []
        var manifestHash: String = ""
        var wrappedKey: String = ""
        var versionMeta: String = ""
        var meta: String = ""
        var metaJSON: VaultMeta?
        var sent: [Int] = []
    }

    // MARK: - Running one

    public static func run(_ job: Job, client: VaultClient, keys: VaultKeys, spoolRoot: URL,
                           concurrency: Int = concurrency,
                           progress: (@Sendable (Progress) -> Void)? = nil) async throws -> Outcome {
        let fm = FileManager.default
        let dir = spoolDir(spoolRoot, job.spoolKey)
        let hashed = try await Task.detached { try plaintextDigest(job.source) }.value
        progress?(Progress(phase: .hashing, done: hashed.size, total: hashed.size))

        // A spool from an earlier run: resume it when it is sealed and still
        // these bytes; otherwise give its upload up and clear it.
        if let state = loadState(dir) {
            if state.sealed, state.sourceSha256 == hashed.sha256, spoolIntact(dir, state) {
                do {
                    return try await send(state, dir: dir, client: client, concurrency: concurrency, progress: progress)
                } catch VaultClient.Failure.uploadExpired {
                    // fall through to a new upload
                } catch VaultClient.Failure.notFound(let r) where r == "unknown-upload" || r == "unknown-file" {
                    // the same
                }
            }
            try? await client.abandon(uploadId: state.uploadId)
            try? fm.removeItem(at: dir)
        }

        let sizes = try sealedSizes(size: hashed.size)
        let tag = try keys.dedupeTag(plaintextSha256: hashed.digest)
        let start: VaultClient.UploadStart
        do {
            start = try await client.startUpload(fileId: job.fileId, baseVersion: job.baseVersion, sizes: sizes,
                                                 tag: tag, deviceId: job.deviceId)
        } catch VaultClient.Failure.duplicate(let fileId, let version) {
            return .adopted(fileId: fileId, version: version, sha256: hashed.sha256, size: hashed.size)
        }

        // Written BEFORE sealing, so a crash mid-seal leaves an uploadId the
        // next run can abandon, rather than a reservation held for 24 hours.
        var state = SpoolState(sourceSha256: hashed.sha256, size: hashed.size, fileId: start.fileId,
                               uploadId: start.uploadId, version: start.version, sizes: sizes, sealed: false)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try saveState(state, dir)
            state = try await Task.detached { [state] in
                try seal(job, state: state, keys: keys, dir: dir, progress: progress)
            }.value
            try saveState(state, dir)
        } catch {
            try? await client.abandon(uploadId: start.uploadId)
            try? fm.removeItem(at: dir)
            throw error
        }
        return try await send(state, dir: dir, client: client, concurrency: concurrency,
                              firstPage: start.parts, progress: progress)
    }

    /// Every chunk's ciphertext size: plaintext + 16, a 0-byte file one 16-byte chunk.
    public static func sealedSizes(size: Int) throws -> [Int] {
        let n = try VaultCrypto.chunkCount(size: size)
        let cb = VaultCrypto.chunkBytes, tag = VaultCrypto.tagBytes
        return (0..<n).map { i in i < n - 1 ? cb + tag : (size - (n - 1) * cb) + tag }
    }

    // MARK: - Steps

    static func plaintextDigest(_ url: URL) throws -> (digest: Data, sha256: String, size: Int) {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var sha = SHA256()
        var size = 0
        while let d = try h.read(upToCount: VaultCrypto.chunkBytes), !d.isEmpty {
            sha.update(data: d); size += d.count
        }
        let digest = Data(sha.finalize())
        return (digest, VaultCrypto.hex(digest), size)
    }

    /// Seal every chunk into the spool under a fresh DK, re-hashing the
    /// plaintext as it goes: bytes that changed since the first hash refuse.
    static func seal(_ job: Job, state: SpoolState, keys: VaultKeys, dir: URL,
                     progress: (@Sendable (Progress) -> Void)?) throws -> SpoolState {
        var s = state
        let dk = VaultCrypto.newDataKey()
        let h = try FileHandle(forReadingFrom: job.source)
        defer { try? h.close() }
        var sha = SHA256()
        var hashes: [String] = []
        let n = s.sizes.count
        for i in 0..<n {
            let pt = (try h.read(upToCount: VaultCrypto.chunkBytes)) ?? Data()
            guard pt.count + VaultCrypto.tagBytes == s.sizes[i] else { throw Failure.sourceChanged }
            sha.update(data: pt)
            let sealed = try VaultCrypto.encryptChunk(dk: dk, fileId: s.fileId, uploadId: s.uploadId,
                                                      index: i, last: i == n - 1, plaintext: pt)
            try sealed.write(to: chunkFile(dir, i), options: .atomic)
            hashes.append(VaultCrypto.chunkHash(sealed))
            progress?(Progress(phase: .sealing, done: i + 1, total: n))
        }
        if let extra = try h.read(upToCount: 1), !extra.isEmpty { throw Failure.sourceChanged }
        guard VaultCrypto.hex(Data(sha.finalize())) == s.sourceSha256 else { throw Failure.sourceChanged }
        s.chunkHashes = hashes
        s.manifestHash = try VaultCrypto.manifestHash(size: s.size, chunkHashes: hashes)
        s.wrappedKey = try VaultCrypto.wrapDkForShop(vaultKey: keys.vaultKey, dk: dk, fileId: s.fileId,
                                                     uploadId: s.uploadId).base64EncodedString()
        let meta = VaultMeta(seq: (job.lastSeq ?? 0) + 1, uploadId: s.uploadId, manifestHash: s.manifestHash,
                             size: s.size, sha256: s.sourceSha256, name: job.name, path: job.path, kind: job.kind,
                             key: job.key, recordId: job.recordId)
        _ = try VaultCrypto.checkMetaSeq(meta.seq, lastSeen: nil)
        // The version's own record: its whole manifest, so a reader can check
        // every chunk as it streams.
        s.versionMeta = try VaultCrypto.encryptVersionMeta(vaultKey: keys.vaultKey, fileId: s.fileId, uploadId: s.uploadId,
                                                           size: s.size, chunkHashes: hashes, seq: meta.seq)
            .base64EncodedString()
        s.meta = try meta.sealed(vaultKey: keys.vaultKey, fileId: s.fileId).base64EncodedString()
        s.metaJSON = meta
        s.sealed = true
        return s
    }

    /// PUT what is not sent yet, then /complete; re-PUT what it says is missing.
    static func send(_ state: SpoolState, dir: URL, client: VaultClient, concurrency: Int,
                     firstPage: [VaultClient.Part] = [],
                     progress: (@Sendable (Progress) -> Void)?) async throws -> Outcome {
        var s = state
        let n = s.sizes.count
        let todo = (0..<n).filter { !Set(s.sent).contains($0) }
        try await putParts(todo, state: &s, dir: dir, client: client, concurrency: concurrency,
                           firstPage: firstPage, progress: progress)
        guard let wrapped = Data(base64Encoded: s.wrappedKey), let meta = Data(base64Encoded: s.meta),
              let versionMeta = Data(base64Encoded: s.versionMeta), !versionMeta.isEmpty,
              let metaJSON = s.metaJSON else { throw VaultCrypto.Failure.badInput("spool is not sealed") }
        for _ in 0..<3 {
            progress?(Progress(phase: .completing, done: n, total: n))
            do {
                let done = try await client.complete(uploadId: s.uploadId, manifestHash: s.manifestHash,
                                                     wrappedKey: wrapped, versionMeta: versionMeta, meta: meta)
                try? FileManager.default.removeItem(at: dir)
                return .committed(done, meta: metaJSON)
            } catch VaultClient.Failure.partsMissing(let missing) {
                // The stored ciphertext again: the very bytes sealed the first time.
                let again = missing.filter { $0 >= 0 && $0 < n }
                s.sent.removeAll { again.contains($0) }
                try saveState(s, dir)
                try await putParts(again, state: &s, dir: dir, client: client, concurrency: concurrency,
                                   firstPage: [], progress: progress)
            }
        }
        throw Failure.partsStillMissing((0..<n).filter { !Set(s.sent).contains($0) })
    }

    /// The parts in `indexes`, at most `concurrency` at once, each recorded
    /// in the spool as it lands. URLs come from `firstPage` where it has
    /// them, else from fresh `parts?from=` pages.
    static func putParts(_ indexes: [Int], state s: inout SpoolState, dir: URL, client: VaultClient,
                         concurrency: Int, firstPage: [VaultClient.Part],
                         progress: (@Sendable (Progress) -> Void)?) async throws {
        guard !indexes.isEmpty else { return }
        var urls = Dictionary(firstPage.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
        let total = s.sizes.count
        let uploadId = s.uploadId, sizes = s.sizes
        var queue = indexes.sorted()[...]
        // The next part with a URL, fetching a fresh page when the map has none.
        func nextPart() async throws -> VaultClient.Part? {
            guard let i = queue.popFirst() else { return nil }
            if urls[i] == nil {
                for p in try await client.parts(uploadId: uploadId, from: i) { urls[p.index] = p }
            }
            guard let p = urls[i], p.size == sizes[i] else { throw VaultClient.Failure.badReply("part \(i)") }
            return p
        }
        try await withThrowingTaskGroup(of: Int.self) { group in
            var inFlight = 0
            while inFlight < max(1, concurrency), let p = try await nextPart() {
                group.addTask { try await putOne(p, dir: dir, client: client) }
                inFlight += 1
            }
            while let done = try await group.next() {
                s.sent.append(done)
                try saveState(s, dir)
                progress?(Progress(phase: .sending, done: s.sent.count, total: total))
                if let p = try await nextPart() {
                    group.addTask { try await putOne(p, dir: dir, client: client) }
                }
            }
        }
    }

    static func putOne(_ p: VaultClient.Part, dir: URL, client: VaultClient) async throws -> Int {
        let body = try Data(contentsOf: chunkFile(dir, p.index))
        try await client.put(p, body: body)
        return p.index
    }

    // MARK: - The spool on disk

    static func spoolDir(_ root: URL, _ key: String) -> URL {
        root.appending(path: "up-" + VaultCrypto.hex(VaultCrypto.sha256(Data(key.utf8))).prefix(32), directoryHint: .isDirectory)
    }

    static func chunkFile(_ dir: URL, _ i: Int) -> URL { dir.appending(path: "chunk-\(i)") }

    static func loadState(_ dir: URL) -> SpoolState? {
        guard let d = try? Data(contentsOf: dir.appending(path: "state.json")) else { return nil }
        return try? JSONDecoder().decode(SpoolState.self, from: d)
    }

    static func saveState(_ s: SpoolState, _ dir: URL) throws {
        try JSONEncoder().encode(s).write(to: dir.appending(path: "state.json"), options: .atomic)
    }

    /// Every sealed chunk is still there and still the bytes the manifest
    /// names. A spool that fails this is abandoned, never re-sealed.
    static func spoolIntact(_ dir: URL, _ s: SpoolState) -> Bool {
        guard s.chunkHashes.count == s.sizes.count else { return false }
        for (i, want) in s.chunkHashes.enumerated() {
            guard let d = try? Data(contentsOf: chunkFile(dir, i)), d.count == s.sizes[i],
                  VaultCrypto.chunkHash(d) == want else { return false }
        }
        return true
    }
}
