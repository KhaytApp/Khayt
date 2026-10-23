import Foundation
@testable import KhaytCore

/// Khayt Cloud's vault routes, in memory, in process: the contract
/// (`docs/api-contract.md` "Vault" in khayt-cloud) and the rules of its
/// `src/vault.js` + `src/store.js`, plus the object store behind the
/// presigned URLs. Nothing here reaches a network.
///
/// It also misbehaves on request: a PUT that "succeeds" but stores nothing
/// (parts-missing), a transport that dies after N PUTs (a crash), a chunk
/// changed at rest (tampering), an older meta served (rollback).
final class VaultStub: @unchecked Sendable {
    static let api = "https://cloud.test"
    static let shopId = "shop_test"
    static let token = "tok"

    let lock = NSLock()
    var limitBytes = 1 << 40
    var partsPerPage = 256
    var rev = 0
    var files: [String: File] = [:]
    var versions: [String: Version] = [:]   // "fileId|version"
    var uploads: [String: Upload] = [:]
    var objects: [String: Data] = [:]

    // Misbehaviour and counters.
    var dropPutsOnce: Set<Int> = []
    var droppedBodies: [Int: Data] = [:]
    var failAfterPuts: Int?
    var puts = 0
    var putsByKey: [String: Int] = [:]
    var bodiesByKey: [String: [Data]] = [:]
    var starts = 0
    var abandoned: [String] = []
    var seq = 0

    // Phase 2: grants (`VaultStub+Grants.swift`). Every request is logged,
    // so a test can prove what never went over the wire.
    var requestLog: [Logged] = []
    var grants: [String: Grant] = [:]
    /// Ids another shop holds: a POST naming one gets 409 grant-exists.
    var takenGrantIds: Set<String> = []
    var grantPosts = 0
    var grantPatches = 0
    /// Fail the PATCH with this 1-based number (a later batch dying).
    var failPatchNumber: Int?
    /// Refuse every revoke (a cleanup that cannot reach the cloud).
    var failRevoke = false
    var maxActiveLinks = 100
    /// Phase 2b: a cloud that cannot send email (422 mail-off on a lock), and
    /// a shop whose links Khayt turned off (403 links-disabled on a POST).
    var mailOff = false
    var linksDisabled = false
    // Phase 3 (`VaultStub+Products.swift`).
    var products: [String: Product] = [:]
    var salesHooks: [String: String] = [:]
    var noPublishing = false
    var publishOff = false
    struct Logged { let method: String; let url: String; let body: Data; let headers: [String: String] }

    struct File { var fileId: String; var nextVersion = 1; var head: Int?; var meta: String?; var metaRev = 0
                  var trashedAt: String?; var rev = 0; var purged = false }
    struct Version { var fileId: String; var version: Int; var uploadId: String; var bytes: Int; var chunks: Int
                     var wrappedKey: String; var manifestHash: String; var versionMeta: String; var tag: String
                     var deviceId: String? }
    struct Upload { var uploadId: String; var fileId: String; var version: Int; var sizes: [Int]; var tag: String
                    var baseVersion: Int?; var deviceId: String? }

    struct Crash: Error {}

    func id() -> String { seq += 1; return "id" + String(format: "%020d", seq) }

    var connection: CloudReader.Connection {
        CloudReader.Connection(url: Self.api, shopId: Self.shopId, storedToken: "")
    }
    func client() -> VaultClient { VaultClient(connection: connection, token: Self.token, fetch: fetch) }
    var fetch: S3.Fetch { { [self] r in try handle(r) } }

    // MARK: - Routing

    func handle(_ r: URLRequest) throws -> (Data, URLResponse) {
        lock.lock(); defer { lock.unlock() }
        let url = r.url!
        requestLog.append(Logged(method: r.httpMethod ?? "GET", url: url.absoluteString, body: r.httpBody ?? Data(),
                                 headers: r.allHTTPHeaderFields ?? [:]))
        if url.host == "store.test" { return try object(r) }
        // The public link route: no shop token, as a browser calls it.
        if url.path.hasPrefix("/v1/s/") { return publicGrant(url, cookie: r.value(forHTTPHeaderField: "Cookie")) }
        guard r.value(forHTTPHeaderField: "Authorization") == "Bearer " + Self.token else { return reply(url, 401, ["error": "no"]) }
        guard r.value(forHTTPHeaderField: "x-delta-capable") == "1" else { return reply(url, 400, ["error": "header"]) }
        let prefix = "/v1/shops/\(Self.shopId)/vault/"
        guard url.path.hasPrefix(prefix) else { return reply(url, 404, ["error": "Not found"]) }
        let parts = url.path.dropFirst(prefix.count).split(separator: "/").map(String.init)
        let q = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value ?? "") } ?? [],
                           uniquingKeysWith: { a, _ in a })
        let body = (r.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let m = r.httpMethod ?? "GET"
        switch (m, parts.count, parts.first) {
        case ("GET", 1, "usage"): return usage(url)
        case (_, _, "grants"): return grantRoute(m, url, parts, r.httpBody ?? Data(), body)
        case (_, _, "products"): return productRoute(m, url, parts, r.httpBody ?? Data(), body,
                                                     contentType: r.value(forHTTPHeaderField: "Content-Type"))
        case (_, _, "sales"): return salesRoute(m, url, parts, body)
        case ("POST", 1, "uploads"): return start(url, body)
        case ("GET", 3, "uploads") where parts[2] == "parts":
            guard let up = uploads[parts[1]] else { return reply(url, 404, ["error": "x", "reason": "unknown-upload"]) }
            return reply(url, 200, ["parts": partList(up, from: Int(q["from"] ?? "0") ?? 0)])
        case ("POST", 3, "uploads") where parts[2] == "complete": return complete(url, parts[1], body)
        case ("DELETE", 2, "uploads"):
            guard uploads.removeValue(forKey: parts[1]) != nil else { return reply(url, 404, ["reason": "unknown-upload"]) }
            abandoned.append(parts[1])
            return reply(url, 200, ["ok": true])
        case ("GET", 1, "files"): return feed(url, since: Int(q["since"] ?? "0") ?? 0, limit: Int(q["limit"] ?? "1000") ?? 1000)
        case ("PUT", 3, "files") where parts[2] == "meta": return setMeta(url, parts[1], body)
        case ("POST", 3, "files") where parts[2] == "restore": return trash(url, parts[1], false)
        case ("DELETE", 2, "files"):
            return q["purge"] == "1" ? purge(url, parts[1]) : trash(url, parts[1], true)
        case ("GET", 5, "files") where parts[2] == "v" && parts[4] == "chunks":
            guard let v = versions["\(parts[1])|\(parts[3])"] else { return reply(url, 404, ["reason": "unknown-version"]) }
            let from = Int(q["from"] ?? "0") ?? 0, count = min(256, Int(q["count"] ?? "256") ?? 256)
            let urls = (from..<min(v.chunks, from + count)).map {
                ["index": $0, "url": "https://store.test/o/\(key(v.fileId, v.version, $0))"] as [String: Any]
            }
            return reply(url, 200, ["urls": urls, "expiresAt": "later", "versionMeta": v.versionMeta])
        case ("DELETE", 4, "files") where parts[2] == "v":
            let k = "\(parts[1])|\(parts[3])"
            guard versions[k] != nil, var f = files[parts[1]] else { return reply(url, 404, ["reason": "unknown-version"]) }
            if f.head == Int(parts[3]) { return reply(url, 409, ["reason": "head"]) }
            versions[k] = nil; rev += 1; f.rev = rev; files[parts[1]] = f
            return reply(url, 200, ["ok": true])
        default: return reply(url, 404, ["error": "Not found", "reason": "no-route"])
        }
    }

    func reply(_ url: URL, _ code: Int, _ o: [String: Any]) -> (Data, URLResponse) {
        (try! JSONSerialization.data(withJSONObject: o), HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }

    func key(_ fileId: String, _ version: Int, _ i: Int) -> String { "v1/\(Self.shopId)/\(fileId)/\(version)/\(i)" }

    // MARK: - The object store

    func object(_ r: URLRequest) throws -> (Data, URLResponse) {
        let url = r.url!
        let k = String(url.path.dropFirst("/o/".count))
        if r.httpMethod == "PUT" {
            if let n = failAfterPuts, puts >= n { throw Crash() }
            let body = r.httpBody ?? Data()
            let signed = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "size" }?.value ?? "") ?? -1
            guard r.value(forHTTPHeaderField: "Content-Length") == String(signed), body.count == signed else {
                return (Data(), HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!)
            }
            puts += 1
            putsByKey[k, default: 0] += 1
            bodiesByKey[k, default: []].append(body)
            let idx = Int(k.split(separator: "/").last!)!
            if dropPutsOnce.contains(idx) { dropPutsOnce.remove(idx); droppedBodies[idx] = body }
            else { objects[k] = body }
            return (Data(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        guard let d = objects[k] else { return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!) }
        return (d, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    // MARK: - Routes

    func used() -> Int {
        versions.values.reduce(0) { $0 + $1.bytes } + uploads.values.reduce(0) { $0 + $1.sizes.reduce(0, +) }
    }

    func usage(_ url: URL) -> (Data, URLResponse) {
        reply(url, 200, ["limits": ["maxVaultBytes": limitBytes, "maxVaultFileBytes": 5 << 30],
                         "used": ["current": used(), "versions": 0, "trash": 0, "uploading": 0, "total": used()],
                         "links": ["active": 0], "egress": ["month": "2026-10", "bytes": 0]])
    }

    func partList(_ up: Upload, from: Int) -> [[String: Any]] {
        (from..<min(up.sizes.count, from + partsPerPage)).map {
            ["index": $0, "size": up.sizes[$0],
             "url": "https://store.test/o/\(key(up.fileId, up.version, $0))?size=\(up.sizes[$0])&sig=x"]
        }
    }

    func start(_ url: URL, _ b: [String: Any]) -> (Data, URLResponse) {
        if limitBytes == 0 { return reply(url, 402, ["error": "x", "reason": "no-vault"]) }
        guard b["chunkBytes"] as? Int == VaultCrypto.chunkBytes, let sizes = b["sizes"] as? [Int], !sizes.isEmpty,
              let tag = b["tag"] as? String, tag.count == 64 else { return reply(url, 422, ["error": "shape"]) }
        let full = VaultCrypto.chunkBytes + 16
        for (i, n) in sizes.enumerated() {
            let last = i == sizes.count - 1, min = sizes.count == 1 ? 16 : 17
            if !last && n != full || last && (n < min || n > full) { return reply(url, 422, ["error": "sizes[\(i)]"]) }
        }
        starts += 1
        for f in files.values where f.head != nil && f.trashedAt == nil && !f.purged {
            if versions["\(f.fileId)|\(f.head!)"]?.tag == tag {
                return reply(url, 409, ["error": "dup", "reason": "duplicate", "fileId": f.fileId, "version": f.head!])
            }
        }
        var f: File
        if let fid = b["fileId"] as? String {
            guard let have = files[fid], !have.purged else { return reply(url, 404, ["reason": "unknown-file"]) }
            f = have
        } else { f = File(fileId: id()) }
        let bytes = sizes.reduce(0, +)
        if used() + bytes > limitBytes {
            return reply(url, 402, ["error": "full", "reason": "vault-full", "used": used(), "limit": limitBytes])
        }
        let version = f.nextVersion; f.nextVersion += 1
        files[f.fileId] = f
        let up = Upload(uploadId: id(), fileId: f.fileId, version: version, sizes: sizes, tag: tag,
                        baseVersion: b["baseVersion"] as? Int, deviceId: b["deviceId"] as? String)
        uploads[up.uploadId] = up
        return reply(url, 201, ["uploadId": up.uploadId, "fileId": f.fileId, "version": version,
                                "expiresAt": "tomorrow", "parts": partList(up, from: 0)])
    }

    func complete(_ url: URL, _ uploadId: String, _ b: [String: Any]) -> (Data, URLResponse) {
        guard let up = uploads[uploadId] else { return reply(url, 404, ["reason": "unknown-upload"]) }
        guard let mh = b["manifestHash"] as? String, mh.count == 64, let wk = b["wrappedKey"] as? String,
              Self.paddedBase64(wk) else {
            return reply(url, 422, ["error": "shape"])
        }
        // khayt-cloud #130: required, at most 256 KB, standard base64 with padding.
        guard let vm = b["versionMeta"] as? String, !vm.isEmpty, vm.utf8.count <= 256 * 1024, Self.paddedBase64(vm) else {
            return reply(url, 422, ["error": "versionMeta is required (standard base64, at most 256 KB)"])
        }
        if let m = b["meta"] as? String, !Self.paddedBase64(m) { return reply(url, 422, ["error": "meta must be base64"]) }
        let bad = up.sizes.indices.filter { objects[key(up.fileId, up.version, $0)]?.count != up.sizes[$0] }
        if !bad.isEmpty { return reply(url, 409, ["reason": "parts-missing", "indexes": bad]) }
        var f = files[up.fileId]!
        let meta = b["meta"] as? String
        if f.head == nil && meta == nil { return reply(url, 422, ["error": "meta is required for a new file"]) }
        let conflict = f.head != nil && f.head != up.baseVersion
        versions["\(f.fileId)|\(up.version)"] = Version(fileId: f.fileId, version: up.version, uploadId: uploadId,
                                                        bytes: up.sizes.reduce(0, +), chunks: up.sizes.count,
                                                        wrappedKey: wk, manifestHash: mh, versionMeta: vm, tag: up.tag,
                                                        deviceId: up.deviceId)
        f.head = up.version
        if let meta { f.meta = meta; f.metaRev += 1 }
        rev += 1; f.rev = rev
        files[f.fileId] = f
        uploads[uploadId] = nil
        return reply(url, 201, ["fileId": f.fileId, "version": up.version, "rev": rev, "conflict": conflict])
    }

    func feed(_ url: URL, since: Int, limit: Int) -> (Data, URLResponse) {
        let changed = files.values.filter { $0.rev > since && ($0.head != nil || $0.purged) }.sorted { $0.rev < $1.rev }
        let page = Array(changed.prefix(limit))
        let more = changed.count > limit
        let rows: [[String: Any]] = page.map { f in
            if f.purged { return ["fileId": f.fileId, "purged": true] }
            let vs = versions.values.filter { $0.fileId == f.fileId }.sorted { $0.version < $1.version }.map {
                ["version": $0.version, "bytes": $0.bytes, "chunks": $0.chunks, "chunkBytes": VaultCrypto.chunkBytes,
                 "uploadId": $0.uploadId, "wrappedKey": $0.wrappedKey, "manifestHash": $0.manifestHash,
                 "versionMeta": $0.versionMeta,
                 "createdAt": "now", "deviceId": $0.deviceId ?? NSNull()] as [String: Any]
            }
            return ["fileId": f.fileId, "head": f.head!, "meta": f.meta ?? NSNull(), "metaRev": f.metaRev,
                    "trashedAt": f.trashedAt ?? NSNull(), "purgeAt": NSNull(), "versions": vs]
        }
        return reply(url, 200, ["rev": more ? page.last!.rev : rev, "more": more, "files": rows])
    }

    func setMeta(_ url: URL, _ fileId: String, _ b: [String: Any]) -> (Data, URLResponse) {
        guard var f = files[fileId], f.head != nil, !f.purged else { return reply(url, 404, ["reason": "unknown-file"]) }
        guard let meta = b["meta"] as? String, Self.paddedBase64(meta), let base = b["baseMetaRev"] as? Int else {
            return reply(url, 422, ["error": "meta must be standard base64"])
        }
        if f.metaRev != base { return reply(url, 409, ["reason": "stale", "metaRev": f.metaRev, "meta": f.meta ?? NSNull()]) }
        f.meta = meta; f.metaRev += 1; rev += 1; f.rev = rev; files[fileId] = f
        return reply(url, 200, ["metaRev": f.metaRev, "rev": rev])
    }

    func trash(_ url: URL, _ fileId: String, _ on: Bool) -> (Data, URLResponse) {
        guard var f = files[fileId], f.head != nil, !f.purged else { return reply(url, 404, ["reason": "unknown-file"]) }
        if on && f.trashedAt == nil { f.trashedAt = "now"; rev += 1; f.rev = rev }
        if !on && f.trashedAt != nil { f.trashedAt = nil; rev += 1; f.rev = rev }
        files[fileId] = f
        return reply(url, 200, ["ok": true, "rev": rev])
    }

    func purge(_ url: URL, _ fileId: String) -> (Data, URLResponse) {
        guard var f = files[fileId], f.head != nil, !f.purged else { return reply(url, 404, ["reason": "unknown-file"]) }
        for k in versions.keys where k.hasPrefix(fileId + "|") { versions[k] = nil }
        f.purged = true; f.head = nil; f.meta = nil; rev += 1; f.rev = rev; files[fileId] = f
        return reply(url, 200, ["ok": true, "purged": true])
    }

    /// Standard base64 WITH padding, as the cloud insists: the alphabet with
    /// + and /, a length that is a multiple of 4, and at most two `=` at the end.
    static func paddedBase64(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count % 4 == 0 else { return false }
        var pad = 0
        for (i, c) in s.utf8.enumerated() {
            if c == UInt8(ascii: "=") { pad += 1; if i < s.utf8.count - 2 { return false }; continue }
            if pad > 0 { return false }
            let ok = (65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c)
                || c == UInt8(ascii: "+") || c == UInt8(ascii: "/")
            if !ok { return false }
        }
        return pad <= 2
    }

    // MARK: - Test helpers

    func tamper(fileId: String, version: Int, index: Int) {
        lock.lock(); defer { lock.unlock() }
        let k = key(fileId, version, index)
        var d = objects[k]!
        d[d.startIndex + 5] ^= 0x01
        objects[k] = d
    }

    func setStoredMeta(_ fileId: String, _ meta: String) {
        lock.lock(); defer { lock.unlock() }
        files[fileId]!.meta = meta; files[fileId]!.metaRev += 1; rev += 1; files[fileId]!.rev = rev
    }

    func storedMeta(_ fileId: String) -> String? { lock.lock(); defer { lock.unlock() }; return files[fileId]?.meta }
}
