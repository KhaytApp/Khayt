import Foundation
import CryptoKit

/// One version of a vault file, downloaded, verified and put in place.
///
/// ── WHERE THE TRUST COMES FROM ──────────────────────────────────────────
///
/// The manifestHash the server lists beside a version is the server's word,
/// and the cloud never checks it. What this pins is the version's OWN record
/// (`versionMeta`), sealed under the vault key, which only the shop's devices
/// hold, and bound to this file and this upload by its AAD. It carries the
/// whole manifest, so every chunk hash is known before the first chunk.
///
/// ── ONE PASS ────────────────────────────────────────────────────────────
///
/// `VaultCrypto.ChunkReader` is built over the record's chunk hashes, and it
/// checks them against the manifest hash before a single chunk is fetched.
/// Each chunk is then fetched into memory (4 MiB + 16 at most), pushed through
/// the reader, which checks its hash and opens it at its position, and its
/// plaintext is appended to a temporary file beside the destination. No
/// ciphertext is ever written to disk, and only one chunk is held at a time.
/// The file is renamed into place only after `finish()` succeeds. Plaintext
/// written before a failure is deleted with the temporary file, never used.
public enum VaultDownload {

    public struct Result: Sendable, Equatable {
        public let meta: VaultMeta
        /// The seq to remember for this file (rollback detection).
        public let seq: Int
        public let version: Int
        public let size: Int
        public let sha256: String
    }

    public enum Failure: Error, Equatable {
        /// No such version in this feed row.
        case noVersion
        /// The version has no sealed record, so nothing vouches for its chunks.
        case unvouched(uploadId: String)
        /// The server's listed manifestHash or size disagrees with the record.
        case serverManifestDiffers
        /// The chunk URLs did not cover the version.
        case chunksMissing
        /// The plaintext is not what the meta record says it should be.
        case contentDiffers
    }

    /// Download `version` (the head when nil) of `file` to `destination`,
    /// replacing whatever is there only once the bytes are proved.
    /// `lastSeenSeq` is checked against the head's record (an older version's
    /// record is older by right).
    @discardableResult
    public static func run(_ file: VaultClient.FeedFile, version: Int? = nil, client: VaultClient, keys: VaultKeys,
                           lastSeenSeq: Int?, to destination: URL,
                           progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil) async throws -> Result {
        let want = version ?? file.head
        guard let v = file.versions.first(where: { $0.version == want }) else { throw Failure.noVersion }
        let (meta, seq) = try VaultMeta.open(file, vaultKey: keys.vaultKey,
                                             lastSeenSeq: want == file.head ? lastSeenSeq : nil)

        // The record comes in the feed; the chunks route repeats it.
        var first = try await client.chunkURLs(fileId: file.fileId, version: v.version, from: 0)
        guard let b64 = v.versionMeta ?? first.versionMeta, let sealed = Data(base64Encoded: b64) else {
            throw Failure.unvouched(uploadId: v.uploadId)
        }
        let vm = try VaultCrypto.decryptVersionMeta(vaultKey: keys.vaultKey, fileId: file.fileId, uploadId: v.uploadId,
                                                    sealed: sealed, lastSeenSeq: want == file.head ? lastSeenSeq : nil)
        guard vm.chunkBytes == VaultCrypto.chunkBytes, vm.size == v.plaintextSize, vm.chunkHashes.count == v.chunks,
              v.manifestHash == vm.manifestHash else { throw Failure.serverManifestDiffers }
        guard let wrapped = Data(base64Encoded: v.wrappedKey) else { throw VaultCrypto.Failure.badInput("wrappedKey") }
        let dk = try VaultCrypto.unwrapDkForShop(vaultKey: keys.vaultKey, wrapped: wrapped,
                                                 fileId: file.fileId, uploadId: v.uploadId)
        let reader = try VaultCrypto.ChunkReader(dk: dk, fileId: file.fileId, uploadId: v.uploadId, size: vm.size,
                                                 chunkHashes: vm.chunkHashes, expectedManifestHash: vm.manifestHash)

        let fm = FileManager.default
        let part = destination.deletingLastPathComponent()
            .appending(path: "." + destination.lastPathComponent + ".vault-\(UUID().uuidString.prefix(8))")
        guard fm.createFile(atPath: part.path, contents: nil) else { throw POSIXError(.EIO) }
        var placed = false
        defer { if !placed { try? fm.removeItem(at: part) } }
        var sha = SHA256()
        do {
            let out = try FileHandle(forWritingTo: part)
            defer { try? out.close() }
            var next = 0
            while next < v.chunks {
                if next > 0 { first = try await client.chunkURLs(fileId: file.fileId, version: v.version, from: next) }
                let page = first.urls.filter { $0.index >= next }.sorted { $0.index < $1.index }
                guard page.first?.index == next else { throw Failure.chunksMissing }
                for c in page {
                    guard c.index == next else { break }
                    let pt = try reader.push(try await client.getChunk(c))
                    sha.update(data: pt)
                    try out.write(contentsOf: pt)
                    next += 1
                    progress?(next, v.chunks)
                }
            }
            _ = try reader.finish()
            try out.synchronize()
        }
        let digest = VaultCrypto.hex(Data(sha.finalize()))
        // The shop record that names this upload also names its plaintext.
        if meta.uploadId == v.uploadId, meta.sha256 != digest || meta.size != vm.size { throw Failure.contentDiffers }
        if rename(part.path, destination.path) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        placed = true
        return Result(meta: meta, seq: max(seq, want == file.head ? vm.seq : seq), version: v.version,
                      size: vm.size, sha256: digest)
    }
}
