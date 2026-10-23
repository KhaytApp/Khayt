import Foundation

/// The Khayt Vault routes of Khayt Cloud, typed: `docs/api-contract.md`
/// "Vault" in khayt-cloud, phase 1 (storage and sync). Phase 2's grant
/// routes (private share links) are in `VaultLinks.swift`.
///
/// Every route goes through `CloudReader.request`, so the vault sends the same
/// `x-delta-capable` header as every other request this app makes (see the
/// note there: one call site without it closes delta sync for the whole shop).
///
/// Bytes never pass through the cloud's Node. An upload's parts are PUT to
/// presigned URLs and a download's chunks are fetched from presigned URLs,
/// with NO Authorization header: a shop token sent to object storage would be
/// a token handed to a third party.
///
/// **Wire encoding.** Blobs (`wrappedKey`, `meta`, `versionMeta`) are
/// standard base64 with padding of the raw bytes `VaultCrypto` makes. IDs are
/// base64url without padding. Hashes and tags are lowercase hex, as the format says.
public struct VaultClient: Sendable {
    public let connection: CloudReader.Connection
    let token: String
    let fetch: S3.Fetch

    /// `token` is the shop token already opened (`Secrets`), held only for
    /// the life of this value.
    public init(connection: CloudReader.Connection, token: String, fetch: @escaping S3.Fetch) {
        self.connection = connection; self.token = token; self.fetch = fetch
    }

    /// The same client over another transport, e.g. the bounded one a caller
    /// of `LibraryRemote` passes.
    public func with(fetch: @escaping S3.Fetch) -> VaultClient {
        VaultClient(connection: connection, token: token, fetch: fetch)
    }

    // MARK: - Errors

    /// What the cloud said, by its `reason` where it gave one.
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// 402 vault-full: this upload's reservation would pass the plan's limit.
        case vaultFull(used: Int, limit: Int)
        /// 402 no-vault: the plan has none.
        case noVault
        /// 402 read-only: the plan lapsed or was downgraded; reads still work.
        case readOnly
        /// 413 file-too-large: one file over the plan's `maxVaultFileBytes`.
        case fileTooLarge(limit: Int)
        /// 409 duplicate: a committed head in this shop already has the tag.
        case duplicate(fileId: String, version: Int)
        /// 409 parts-missing: re-PUT the STORED ciphertext of these parts.
        case partsMissing([Int])
        /// 409 stale: the meta changed since `baseMetaRev`. Carries the current one.
        case stale(metaRev: Int, meta: Data?)
        /// 409 head: the current version cannot be pruned.
        case isHead
        /// 410 upload-expired: 24 hours passed; start a new upload.
        case uploadExpired
        /// 404 with a reason: unknown-file, unknown-upload, unknown-version.
        case notFound(String)
        /// 404 without a reason: the vault is not switched on for this cloud.
        case vaultOff
        /// 401: the token is not accepted.
        case notAccepted
        /// 403: a viewer, or a purge without owner/manager.
        case notAllowed
        /// 422: the cloud refused the request's shape.
        case invalid(String)
        case rateLimited
        case http(Int, String)
        /// A reply this client cannot read.
        case badReply(String)
        /// A presigned PUT or GET that object storage refused.
        case transfer(method: String, index: Int, status: Int)
        /// 409 grant-exists: some shop already used this grantId. Pick another.
        case grantExists
        /// 402 links-full: the plan's active links are used up.
        case linksFull(limit: Int)
        /// 402 no-links: the plan has no share links (Free).
        case noLinks
        /// 422 unknown-items: these files are not live, committed files here.
        case unknownItems([String])
        /// 422 downloads-cap: this plan caps a link's downloads at `limit`.
        case downloadsCap(limit: Int)
        /// 422 not-yet: a feature the cloud has not built (the email lock).
        case notYet

        public var description: String {
            switch self {
            case .vaultFull(let used, let limit): return "The vault is full (\(used) of \(limit) bytes used)."
            case .noVault: return "This shop's plan has no vault."
            case .readOnly: return "The vault is read-only: the plan lapsed or no longer includes it."
            case .fileTooLarge(let limit): return "The file is larger than this plan allows (\(limit) bytes)."
            case .duplicate(let fileId, let version): return "The vault already holds this file (\(fileId) v\(version))."
            case .partsMissing(let i): return "The cloud is missing \(i.count) part(s) of the upload."
            case .stale: return "The file's details changed on another device."
            case .isHead: return "That is the current version and cannot be removed."
            case .uploadExpired: return "The upload expired; it has to start again."
            case .notFound(let why): return "Not found in the vault (\(why))."
            case .vaultOff: return "Khayt Cloud has no vault switched on."
            case .notAccepted: return "Khayt Cloud did not accept this shop's token. It may have been reset."
            case .notAllowed: return "This sign-in may not do that."
            case .invalid(let why): return "Khayt Cloud refused the request: \(why)"
            case .rateLimited: return "Khayt Cloud asked to slow down; try again shortly."
            case .http(let code, let why): return "Khayt Cloud answered \(code)\(why.isEmpty ? "" : ": " + why)."
            case .badReply(let why): return "Khayt Cloud's reply could not be read (\(why))."
            case .transfer(let m, let i, let s): return "Storage refused \(m) of part \(i) (\(s))."
            case .grantExists: return "That link id is taken already."
            case .linksFull(let limit): return "This plan's share links are all in use (\(limit))."
            case .noLinks: return "This shop's plan has no share links."
            case .unknownItems(let ids): return "\(ids.count) file(s) are no longer in the vault."
            case .downloadsCap(let limit): return "This plan allows at most \(limit) downloads per link."
            case .notYet: return "Khayt Cloud does not offer that yet."
            }
        }
    }

    // MARK: - Shapes

    /// One presigned PUT: exactly `size` bytes, `Content-Length` signed in.
    public struct Part: Codable, Sendable, Equatable {
        public let index: Int
        public let size: Int
        public let url: String
    }

    public struct UploadStart: Sendable, Equatable {
        public let uploadId: String
        public let fileId: String
        public let version: Int
        public let expiresAt: String
        /// At most 256; `parts(uploadId:from:)` gives the rest.
        public let parts: [Part]
    }

    public struct Committed: Codable, Sendable, Equatable {
        public let fileId: String
        public let version: Int
        public let rev: Int
        /// `baseVersion` was no longer the head: both versions are kept.
        public let conflict: Bool
        public init(fileId: String, version: Int, rev: Int, conflict: Bool) {
            self.fileId = fileId; self.version = version; self.rev = rev; self.conflict = conflict
        }
    }

    public struct Version: Codable, Sendable, Equatable {
        public let version: Int
        /// CIPHERTEXT bytes: plaintext + 16 per chunk.
        public let bytes: Int
        public let chunks: Int
        public let chunkBytes: Int
        public let uploadId: String
        public let wrappedKey: String
        /// As the server stores it, which it never checks. Readers pin the
        /// one in the version's own sealed record instead (`VaultDownload`).
        public let manifestHash: String
        /// This version's sealed record (`VaultCrypto.decryptVersionMeta`):
        /// its whole manifest, size and seq. Base64.
        public let versionMeta: String?
        public let createdAt: String?
        public let deviceId: String?

        /// The plaintext size the ciphertext implies.
        public var plaintextSize: Int { bytes - chunks * VaultCrypto.tagBytes }
    }

    /// One row of the delta feed. A purged file is `{fileId, purged: true}`
    /// and nothing else.
    public struct FeedFile: Codable, Sendable, Equatable {
        public let fileId: String
        public let purged: Bool
        public let head: Int?
        public let meta: String?
        public let metaRev: Int
        public let trashedAt: String?
        public let purgeAt: String?
        public let versions: [Version]

        enum CodingKeys: String, CodingKey { case fileId, purged, head, meta, metaRev, trashedAt, purgeAt, versions }

        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            fileId = try c.decode(String.self, forKey: .fileId)
            purged = try c.decodeIfPresent(Bool.self, forKey: .purged) ?? false
            head = try c.decodeIfPresent(Int.self, forKey: .head)
            meta = try c.decodeIfPresent(String.self, forKey: .meta)
            metaRev = try c.decodeIfPresent(Int.self, forKey: .metaRev) ?? 0
            trashedAt = try c.decodeIfPresent(String.self, forKey: .trashedAt)
            purgeAt = try c.decodeIfPresent(String.self, forKey: .purgeAt)
            versions = try c.decodeIfPresent([Version].self, forKey: .versions) ?? []
        }

        public var headVersion: Version? { versions.first { $0.version == head } }
        public var trashed: Bool { trashedAt != nil }
    }

    public struct Feed: Codable, Sendable, Equatable {
        public let rev: Int
        public let more: Bool
        public let files: [FeedFile]
    }

    public struct ChunkURL: Codable, Sendable, Equatable {
        public let index: Int
        public let url: String
    }

    public struct Usage: Codable, Sendable, Equatable {
        public struct Used: Codable, Sendable, Equatable {
            public let current, versions, trash, uploading, total: Int
        }
        public struct Limits: Codable, Sendable, Equatable {
            public let maxVaultBytes: Int
            public let maxVaultFileBytes: Int?
        }
        public let limits: Limits
        public let used: Used
    }

    // MARK: - Uploads

    /// POST /vault/uploads. `sizes` are CIPHERTEXT chunk sizes (`sealedSizes`).
    /// A 409 duplicate throws `.duplicate`: link to that file, upload nothing.
    public func startUpload(fileId: String?, baseVersion: Int?, sizes: [Int], tag: String,
                            deviceId: String?) async throws -> UploadStart {
        if let fileId { _ = try VaultCrypto.id(fileId, "fileId") }
        var body: [String: Any] = ["chunkBytes": VaultCrypto.chunkBytes, "sizes": sizes, "tag": tag]
        if let fileId { body["fileId"] = fileId }
        if let baseVersion { body["baseVersion"] = baseVersion }
        if let deviceId { body["deviceId"] = String(deviceId.prefix(64)) }
        let o = try await call("POST", "/vault/uploads", body: body, expect: [201])
        guard let uploadId = o["uploadId"] as? String, let fid = o["fileId"] as? String,
              let version = int(o["version"]) else { throw Failure.badReply("upload start") }
        _ = try VaultCrypto.id(uploadId, "uploadId")
        _ = try VaultCrypto.id(fid, "fileId")
        return UploadStart(uploadId: uploadId, fileId: fid, version: version,
                           expiresAt: (o["expiresAt"] as? String) ?? "", parts: try parts(of: o))
    }

    /// GET /uploads/{id}/parts?from=i: fresh presigned PUTs from part i.
    public func parts(uploadId: String, from: Int) async throws -> [Part] {
        let o = try await call("GET", "/vault/uploads/\(try VaultCrypto.id(uploadId, "uploadId"))/parts?from=\(from)",
                               body: nil, expect: [200])
        return try parts(of: o)
    }

    /// POST /uploads/{id}/complete. `versionMeta` is always required; `meta`
    /// is required on a file's first version.
    public func complete(uploadId: String, manifestHash: String, wrappedKey: Data, versionMeta: Data,
                         meta: Data?) async throws -> Committed {
        var body: [String: Any] = ["manifestHash": manifestHash, "wrappedKey": wrappedKey.base64EncodedString(),
                                   "versionMeta": versionMeta.base64EncodedString()]
        if let meta { body["meta"] = meta.base64EncodedString() }
        let o = try await call("POST", "/vault/uploads/\(try VaultCrypto.id(uploadId, "uploadId"))/complete",
                               body: body, expect: [201])
        guard let fileId = o["fileId"] as? String, let version = int(o["version"]), let rev = int(o["rev"]) else {
            throw Failure.badReply("complete")
        }
        return Committed(fileId: fileId, version: version, rev: rev, conflict: (o["conflict"] as? Bool) ?? false)
    }

    /// DELETE /uploads/{id}: give the upload up and release its reservation.
    public func abandon(uploadId: String) async throws {
        _ = try await call("DELETE", "/vault/uploads/\(try VaultCrypto.id(uploadId, "uploadId"))", body: nil, expect: [200])
    }

    /// PUT one part's ciphertext to its presigned URL: exactly `part.size`
    /// bytes, no Authorization.
    public func put(_ part: Part, body: Data) async throws {
        guard body.count == part.size else { throw Failure.transfer(method: "PUT", index: part.index, status: 0) }
        var r = URLRequest(url: try presigned(part.url))
        r.httpMethod = "PUT"
        r.httpBody = body
        r.timeoutInterval = 300
        r.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        let (_, response) = try await fetch(r)
        let code = S3.status(response)
        guard (200..<300).contains(code) else { throw Failure.transfer(method: "PUT", index: part.index, status: code) }
    }

    // MARK: - Files

    /// GET /vault/files?since=rev&limit=n: one page of the delta feed.
    public func files(since: Int, limit: Int = 1000) async throws -> Feed {
        let (data, _) = try await raw("GET", "/vault/files?since=\(since)&limit=\(min(1000, max(1, limit)))",
                                      body: nil, expect: [200])
        do { return try JSONDecoder().decode(Feed.self, from: data) }
        catch { throw Failure.badReply("feed") }
    }

    /// PUT /files/{id}/meta. A stale base throws `.stale` with the current meta.
    public func setMeta(fileId: String, meta: Data, baseMetaRev: Int) async throws -> (metaRev: Int, rev: Int) {
        let o = try await call("PUT", "/vault/files/\(try VaultCrypto.id(fileId, "fileId"))/meta",
                               body: ["meta": meta.base64EncodedString(), "baseMetaRev": baseMetaRev], expect: [200])
        guard let metaRev = int(o["metaRev"]), let rev = int(o["rev"]) else { throw Failure.badReply("meta") }
        return (metaRev, rev)
    }

    public struct ChunkPage: Codable, Sendable, Equatable {
        public let urls: [ChunkURL]
        /// The version's sealed record, as in the feed. Base64.
        public let versionMeta: String?
    }

    /// GET …/v/{n}/chunks?from&count≤256: presigned GETs, 15 minutes each.
    public func chunkURLs(fileId: String, version: Int, from: Int, count: Int = 256) async throws -> ChunkPage {
        let (data, _) = try await raw("GET",
                                      "/vault/files/\(try VaultCrypto.id(fileId, "fileId"))/v/\(version)/chunks?from=\(from)&count=\(min(256, max(1, count)))",
                                      body: nil, expect: [200])
        do { return try JSONDecoder().decode(ChunkPage.self, from: data) }
        catch { throw Failure.badReply("chunks") }
    }

    /// Fetch one chunk from its presigned URL, into memory: one chunk is
    /// 4 MiB + 16 at most, and the caller holds one at a time.
    public func getChunk(_ chunk: ChunkURL) async throws -> Data {
        var r = URLRequest(url: try presigned(chunk.url))
        r.httpMethod = "GET"
        r.timeoutInterval = 300
        let (data, response) = try await fetch(r)
        let code = S3.status(response)
        guard (200..<300).contains(code) else { throw Failure.transfer(method: "GET", index: chunk.index, status: code) }
        guard data.count <= VaultCrypto.chunkBytes + VaultCrypto.tagBytes else {
            throw Failure.transfer(method: "GET", index: chunk.index, status: code)
        }
        return data
    }

    /// DELETE /files/{id}: to Trash for 30 days.
    public func trash(fileId: String) async throws {
        _ = try await call("DELETE", "/vault/files/\(try VaultCrypto.id(fileId, "fileId"))", body: nil, expect: [200])
    }

    /// DELETE /files/{id}?purge=1: gone now (owner or manager).
    public func purge(fileId: String) async throws {
        _ = try await call("DELETE", "/vault/files/\(try VaultCrypto.id(fileId, "fileId"))?purge=1", body: nil, expect: [200])
    }

    /// POST /files/{id}/restore: out of Trash.
    public func restore(fileId: String) async throws {
        _ = try await call("POST", "/vault/files/\(try VaultCrypto.id(fileId, "fileId"))/restore", body: nil, expect: [200])
    }

    /// DELETE /files/{id}/v/{n}: prune one old version (`.isHead` for the current one).
    public func prune(fileId: String, version: Int) async throws {
        _ = try await call("DELETE", "/vault/files/\(try VaultCrypto.id(fileId, "fileId"))/v/\(version)",
                           body: nil, expect: [200])
    }

    /// GET /vault/usage, for the usage bar.
    public func usage() async throws -> Usage {
        let (data, _) = try await raw("GET", "/vault/usage", body: nil, expect: [200])
        do { return try JSONDecoder().decode(Usage.self, from: data) }
        catch { throw Failure.badReply("usage") }
    }

    // MARK: - Plumbing

    /// Presigned URLs must be https in production. The stub's are too.
    func presigned(_ s: String) throws -> URL {
        guard let u = URL(string: s), u.scheme == "https" else { throw Failure.badReply("presigned url") }
        return u
    }

    private func parts(of o: [String: Any]) throws -> [Part] {
        guard let list = o["parts"] as? [[String: Any]] else { throw Failure.badReply("parts") }
        return try list.map {
            guard let i = int($0["index"]), let n = int($0["size"]), let u = $0["url"] as? String else {
                throw Failure.badReply("part")
            }
            return Part(index: i, size: n, url: u)
        }
    }

    func int(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.rounded() == d ? Int(d) : nil
    }

    func call(_ method: String, _ tail: String, body: [String: Any]?, expect: Set<Int>) async throws -> [String: Any] {
        let (data, _) = try await raw(method, tail, body: body, expect: expect)
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure.badReply(method + " " + tail)
        }
        return o
    }

    func raw(_ method: String, _ tail: String, body: [String: Any]?, expect: Set<Int>) async throws -> (Data, Int) {
        var request = try CloudReader.request(connection, token: token, method: method, tail: tail)
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await fetch(request)
        let code = S3.status(response)
        if expect.contains(code) { return (data, code) }
        throw Self.failure(code, data)
    }

    /// The cloud's answer as a `Failure`, by its `reason` first.
    static func failure(_ code: Int, _ data: Data) -> Failure {
        let o = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        let reason = (o["reason"] as? String) ?? ""
        let error = (o["error"] as? String) ?? ""
        let n = { (k: String) -> Int in (o[k] as? NSNumber)?.intValue ?? 0 }
        switch (code, reason) {
        case (402, "vault-full"): return .vaultFull(used: n("used"), limit: n("limit"))
        case (402, "no-vault"): return .noVault
        case (402, "read-only"): return .readOnly
        case (402, "links-full"): return .linksFull(limit: n("limit"))
        case (402, "no-links"): return .noLinks
        case (409, "grant-exists"): return .grantExists
        case (422, "unknown-items"): return .unknownItems((o["fileIds"] as? [String]) ?? [])
        case (422, "downloads-cap"): return .downloadsCap(limit: n("limit"))
        case (422, "not-yet"): return .notYet
        case (413, _): return .fileTooLarge(limit: n("limit"))
        case (409, "duplicate"):
            return .duplicate(fileId: (o["fileId"] as? String) ?? "", version: n("version"))
        case (409, "parts-missing"): return .partsMissing(((o["indexes"] as? [NSNumber]) ?? []).map(\.intValue))
        case (409, "stale"):
            return .stale(metaRev: n("metaRev"), meta: (o["meta"] as? String).flatMap { Data(base64Encoded: $0) })
        case (409, "head"): return .isHead
        case (410, "upload-expired"): return .uploadExpired
        case (404, ""): return .vaultOff
        case (404, _): return .notFound(reason)
        case (401, _): return .notAccepted
        case (403, _): return .notAllowed
        case (422, _): return .invalid(error)
        case (429, _): return .rateLimited
        default: return .http(code, reason.isEmpty ? error : reason)
        }
    }
}
