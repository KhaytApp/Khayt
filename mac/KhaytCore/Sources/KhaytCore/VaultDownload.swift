import Foundation
import CryptoKit

/// One version of a vault file, downloaded, verified and put in place.
///
/// ── WHERE THE TRUST COMES FROM ──────────────────────────────────────────
///
/// The manifestHash the server lists beside a version is the server's word,
/// and the cloud never checks it. The one this pins is from the META RECORD,
/// sealed under the vault key, which only the shop's devices hold
/// (`VaultMeta.manifestHash(for:)`). A version the record cannot vouch for
/// is refused rather than read on the server's word.
///
/// ── TWO PASSES, BECAUSE OF THE READER ───────────────────────────────────
///
/// `VaultCrypto.ChunkReader` needs the manifest's chunk hashes before the
/// first chunk, and the cloud keeps only the manifest's HASH (meta is capped
/// at 64 KB, and 4096 chunk hashes would not fit). So the ciphertext chunks
/// are fetched to a temporary directory first, each hashed from disk; the
/// reader is built over those hashes, which checks them against the pinned
/// manifestHash before a single chunk is opened; then each chunk is pushed
/// through it from disk and its plaintext appended to a temporary file.
/// Only after `finish()` succeeds is that file renamed into place. Nothing
/// is ever whole in memory: one 4 MiB chunk at a time.
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
        /// The meta record does not pin this version's manifest.
        case unvouched(uploadId: String)
        /// The server's listed manifestHash disagrees with the pinned one.
        case serverManifestDiffers
        /// The chunk URLs did not cover the version.
        case chunksMissing
        /// The plaintext is not what the meta record says it should be.
        case contentDiffers
    }

    /// Download `version` (the head when nil) of `file` to `destination`,
    /// replacing whatever is there only once the bytes are proved.
    @discardableResult
    public static func run(_ file: VaultClient.FeedFile, version: Int? = nil, client: VaultClient, keys: VaultKeys,
                           lastSeenSeq: Int?, alsoVouched: [String: String] = [:], to destination: URL, download: S3.Download,
                           progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil) async throws -> Result {
        let want = version ?? file.head
        guard let v = file.versions.first(where: { $0.version == want }) else { throw Failure.noVersion }
        let (meta, seq) = try VaultMeta.open(file, vaultKey: keys.vaultKey, lastSeenSeq: lastSeenSeq)
        // `alsoVouched`: manifests this device took from earlier authenticated
        // records or its own uploads (`VaultSyncState.Entry.manifests`).
        guard let pinned = meta.manifestHash(for: v.uploadId) ?? alsoVouched[v.uploadId] else { throw Failure.unvouched(uploadId: v.uploadId) }
        guard v.manifestHash == pinned else { throw Failure.serverManifestDiffers }
        guard let wrapped = Data(base64Encoded: v.wrappedKey) else { throw VaultCrypto.Failure.badInput("wrappedKey") }
        let dk = try VaultCrypto.unwrapDkForShop(vaultKey: keys.vaultKey, wrapped: wrapped,
                                                 fileId: file.fileId, uploadId: v.uploadId)
        let size = v.plaintextSize
        guard try VaultCrypto.chunkCount(size: size) == v.chunks else {
            throw VaultCrypto.Failure.manifestMismatch("chunk count does not match size")
        }

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "khayt-vault-dl-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        // Pass 1: the ciphertext, chunk by chunk, to files.
        var hashes = [String](repeating: "", count: v.chunks)
        var from = 0
        while from < v.chunks {
            let page = try await client.chunkURLs(fileId: file.fileId, version: v.version, from: from)
            guard !page.isEmpty else { throw Failure.chunksMissing }
            for c in page where c.index >= from && c.index < v.chunks {
                let got = try await client.getChunk(c, download: download)
                let dest = work.appending(path: "c-\(c.index)")
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: got, to: dest)
                hashes[c.index] = try fileHash(dest)
                progress?(c.index + 1, v.chunks)
            }
            guard let top = page.map(\.index).max(), top >= from else { throw Failure.chunksMissing }
            from = top + 1
        }
        guard !hashes.contains("") else { throw Failure.chunksMissing }

        // Pass 2: through the reader, which checks the manifest first.
        let reader = try VaultCrypto.ChunkReader(dk: dk, fileId: file.fileId, uploadId: v.uploadId, size: size,
                                                 chunkHashes: hashes, expectedManifestHash: pinned)
        let part = destination.deletingLastPathComponent()
            .appending(path: "." + destination.lastPathComponent + ".vault-\(UUID().uuidString.prefix(8))")
        guard fm.createFile(atPath: part.path, contents: nil) else { throw POSIXError(.EIO) }
        var placed = false
        defer { if !placed { try? fm.removeItem(at: part) } }
        var sha = SHA256()
        do {
            let out = try FileHandle(forWritingTo: part)
            defer { try? out.close() }
            for i in 0..<v.chunks {
                let c = work.appending(path: "c-\(i)")
                let pt = try reader.push(try Data(contentsOf: c))
                try? fm.removeItem(at: c)
                sha.update(data: pt)
                try out.write(contentsOf: pt)
            }
            _ = try reader.finish()
            try out.synchronize()
        }
        let digest = VaultCrypto.hex(Data(sha.finalize()))
        // The record that pinned this upload also names its plaintext.
        if meta.uploadId == v.uploadId, meta.sha256 != digest || meta.size != size { throw Failure.contentDiffers }
        if rename(part.path, destination.path) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        placed = true
        return Result(meta: meta, seq: seq, version: v.version, size: size, sha256: digest)
    }

    static func fileHash(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var sha = SHA256()
        while let d = try h.read(upToCount: 1 << 20), !d.isEmpty { sha.update(data: d) }
        return VaultCrypto.hex(Data(sha.finalize()))
    }
}
