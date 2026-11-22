import Foundation
@testable import KhaytCore

/// Phase 2 of the vault in the stub: grants, as `docs/api-contract.md`
/// "Phase 2 — access links" in khayt-cloud describes them, with the limits a
/// client has to respect enforced (at most 500 items and 16 MB a body, linkMeta
/// at most 256 KB, padded base64 blobs, a client-chosen id of 22–64 id
/// characters, an id used anywhere is 409). Plus the public `GET /v1/s/{id}`
/// a recipient's page calls, with no shop token.
///
/// Phase 2b too: the email lock on POST and PATCH (`bad-email-lock`,
/// `mail-off`), a takedown (`takedown`: the grant reads `disabled` and takes
/// only a revoke, 409 `disabled` otherwise), a shop whose links are off (403
/// `links-disabled`), and `recipient` on the events of a locked link.
extension VaultStub {

    struct Grant {
        var grantId: String
        var items: [String: (version: Int, wrappedKey: String, linkMeta: String, used: Int)] = [:]
        var order: [String] = []
        var limits: [String: Any] = [:]
        var password = false
        var ownerNote: String?
        var revoked = false
        var used = 0
        var events: [[String: Any]] = []
        var createdAt = "2026-10-23T09:00:00Z"
        /// Phase 2b: the addresses it is locked to, and a takedown.
        var emailLock: [String]?
        var disabledAt: String?
        var disabledReason: String?
    }

    static let maxGrantBody = 16 * 1024 * 1024

    /// The cloud's `cleanEmailLock` (`src/vault.js`): 1 to 50 entries as SENT
    /// (before de-duplicating), each trimmed, lower-cased and matching
    /// `^[^\s@]+@[^\s@]+\.[^\s@]+$` within 254 characters. Nil if it fails.
    static func cleanEmailLock(_ v: Any?) -> [String]? {
        guard let list = v as? [Any], (1...50).contains(list.count) else { return nil }
        var out: [String] = []
        for e in list {
            guard let s = (e as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), s.count <= 254,
                  s.wholeMatch(of: /[^\s@]+@[^\s@]+\.[^\s@]+/) != nil else { return nil }
            if !out.contains(s) { out.append(s) }
        }
        return out
    }

    static func isGrantId(_ s: String) -> Bool {
        (22...64).contains(s.utf8.count) && s.utf8.allSatisfy(VaultCrypto.isIdByte)
    }

    func grantRoute(_ m: String, _ url: URL, _ parts: [String], _ raw: Data, _ b: [String: Any]) -> (Data, URLResponse) {
        switch (m, parts.count) {
        case ("POST", 1): return createGrant(url, raw, b)
        case ("GET", 1): return reply(url, 200, ["grants": grants.values.sorted { $0.grantId < $1.grantId }.map(grantJSON)])
        case ("GET", 2):
            guard let g = grants[parts[1]] else { return reply(url, 404, ["reason": "unknown-grant"]) }
            return reply(url, 200, grantJSON(g))
        case ("PATCH", 2): return patchGrant(url, parts[1], raw, b)
        case ("GET", 3) where parts[2] == "events":
            guard let g = grants[parts[1]] else { return reply(url, 404, ["reason": "unknown-grant"]) }
            return reply(url, 200, ["events": Array(g.events.reversed())])
        default: return reply(url, 404, ["error": "Not found", "reason": "no-route"])
        }
    }

    /// Check a list of items against the contract; the error reply, or nil.
    func checkItems(_ url: URL, _ list: [[String: Any]]) -> (Data, URLResponse)? {
        guard list.count <= 500 else { return reply(url, 422, ["error": "at most 500 items"]) }
        var seen: Set<String> = [], unknown: [String] = []
        for it in list {
            guard let fid = it["fileId"] as? String, let v = it["version"] as? Int,
                  let wk = it["wrappedKey"] as? String, Self.paddedBase64(wk),
                  let lm = it["linkMeta"] as? String, Self.paddedBase64(lm) else {
                return reply(url, 422, ["error": "item shape (blobs are standard base64 with padding)"])
            }
            guard lm.utf8.count <= 256 * 1024 else { return reply(url, 422, ["error": "linkMeta over 256 KB"]) }
            guard seen.insert(fid).inserted else { return reply(url, 422, ["error": "each file once"]) }
            guard let f = files[fid], !f.purged, f.trashedAt == nil, versions["\(fid)|\(v)"] != nil else {
                unknown.append(fid); continue
            }
        }
        if !unknown.isEmpty { return reply(url, 422, ["error": "x", "reason": "unknown-items", "fileIds": unknown]) }
        return nil
    }

    func createGrant(_ url: URL, _ raw: Data, _ b: [String: Any]) -> (Data, URLResponse) {
        grantPosts += 1
        guard raw.count <= Self.maxGrantBody else { return reply(url, 413, ["error": "body over 16 MB"]) }
        guard let gid = b["grantId"] as? String, Self.isGrantId(gid) else { return reply(url, 422, ["error": "grantId"]) }
        if takenGrantIds.contains(gid) || grants[gid] != nil {
            return reply(url, 409, ["error": "x", "reason": "grant-exists"])
        }
        guard let list = b["items"] as? [[String: Any]], !list.isEmpty else { return reply(url, 422, ["error": "items"]) }
        if let bad = checkItems(url, list) { return bad }
        if vaultOver { return overReply(url) }
        var lock: [String]?
        if b.keys.contains("emailLock") {
            guard let l = Self.cleanEmailLock(b["emailLock"]) else { return reply(url, 422, ["reason": "bad-email-lock"]) }
            lock = l
        }
        if let note = b["ownerNote"] {
            guard let n = note as? String, Self.paddedBase64(n), n.utf8.count <= 16 * 1024 else {
                return reply(url, 422, ["error": "ownerNote"])
            }
        }
        if let p = b["password"], !(p is Bool) { return reply(url, 422, ["error": "password is a boolean"]) }
        // The server's order: mail-off before the store is asked, then the ban.
        if lock != nil, mailOff { return reply(url, 422, ["reason": "mail-off"]) }
        if linksDisabled { return reply(url, 403, ["reason": "links-disabled"]) }
        let active = grants.values.filter { !$0.revoked }.count
        if active >= maxActiveLinks { return reply(url, 402, ["reason": "links-full", "limit": maxActiveLinks]) }
        var g = Grant(grantId: gid)
        for it in list { add(it, to: &g) }
        g.limits = (b["limits"] as? [String: Any]) ?? [:]
        g.password = (b["password"] as? Bool) ?? false
        g.ownerNote = b["ownerNote"] as? String
        g.emailLock = lock
        grants[gid] = g
        return reply(url, 201, ["grantId": gid, "createdAt": g.createdAt])
    }

    func add(_ it: [String: Any], to g: inout Grant) {
        let fid = it["fileId"] as! String
        let used = g.items[fid]?.used ?? 0   // a file keeps its download count
        if g.items[fid] == nil { g.order.append(fid) }
        g.items[fid] = (it["version"] as! Int, it["wrappedKey"] as! String, it["linkMeta"] as! String, used)
    }

    func patchGrant(_ url: URL, _ gid: String, _ raw: Data, _ b: [String: Any]) -> (Data, URLResponse) {
        grantPatches += 1
        if failPatchNumber == grantPatches { return reply(url, 500, ["error": "boom"]) }
        if failRevoke, b["revoke"] as? Bool == true { return reply(url, 503, ["error": "down"]) }
        guard raw.count <= Self.maxGrantBody else { return reply(url, 413, ["error": "body over 16 MB"]) }
        var lock: [String]?
        if let v = b["emailLock"], !(v is NSNull) {
            guard let l = Self.cleanEmailLock(v) else { return reply(url, 422, ["reason": "bad-email-lock"]) }
            guard !mailOff else { return reply(url, 422, ["reason": "mail-off"]) }
            lock = l
        }
        guard var g = grants[gid] else { return reply(url, 404, ["reason": "unknown-grant"]) }
        // A link Khayt turned off takes a revoke and nothing else.
        if g.disabledAt != nil, b.keys.contains(where: { $0 != "revoke" }) {
            return reply(url, 409, ["error": "Khayt turned this link off; it can only be revoked", "reason": "disabled"])
        }
        if b.keys.contains("emailLock") { g.emailLock = lock }
        if let list = b["items"] as? [[String: Any]] {
            if let bad = checkItems(url, list) { return bad }
            for it in list { add(it, to: &g) }
        }
        if let rm = b["removeItems"] as? [String] {
            for f in rm { g.items[f] = nil; g.order.removeAll { $0 == f } }
        }
        if let n = b["addDownloads"] as? Int {
            g.limits["maxDownloads"] = ((g.limits["maxDownloads"] as? Int) ?? 0) + n
        }
        if b.keys.contains("expiresAt") { g.limits["expiresAt"] = b["expiresAt"] is NSNull ? nil : b["expiresAt"] }
        if b["revoke"] as? Bool == true { g.revoked = true }
        grants[gid] = g
        return reply(url, 200, grantJSON(g))
    }

    func grantJSON(_ g: Grant) -> [String: Any] {
        let max = g.limits["maxDownloads"] as? Int
        // `disabled` outranks the rest.
        let state = g.disabledAt != nil ? "disabled" : g.revoked ? "revoked" : "ok"
        return ["grantId": g.grantId, "state": state, "createdAt": g.createdAt,
                "emailLock": g.emailLock ?? NSNull(), "disabledAt": g.disabledAt ?? NSNull(),
                "disabledReason": g.disabledReason ?? NSNull(),
                "revokedAt": g.revoked ? "2026-10-23T10:00:00Z" : NSNull(), "firstOpenAt": NSNull(),
                "expiresAt": g.limits["expiresAt"] ?? NSNull(), "limits": g.limits, "password": g.password,
                "ownerNote": g.ownerNote ?? NSNull(), "used": g.used, "devices": 0,
                "items": g.order.map { f in
                    ["fileId": f, "version": g.items[f]!.version, "used": g.items[f]!.used,
                     "remaining": max.map { $0 - g.used } ?? NSNull()] as [String: Any]
                }]
    }

    /// `GET /v1/s/{grantId}`: what the share page reads, without a token.
    ///
    /// An email-locked link wants the `kvs` cookie that `email-verify` sets.
    /// The stub's cookie is simply `kvs=<address>` (the cloud's is a token it
    /// keeps the hash of); an address not on the lock proves nothing.
    func publicGrant(_ url: URL, cookie: String? = nil) -> (Data, URLResponse) {
        let gid = String(url.path.dropFirst("/v1/s/".count))
        guard var g = grants[gid] else { return reply(url, 404, ["error": "Not found"]) }
        if g.disabledAt != nil { return reply(url, 410, ["reason": "disabled"]) }
        if g.revoked { return reply(url, 410, ["reason": "revoked"]) }
        var recipient: String?
        if let lock = g.emailLock {
            let proven = cookie.flatMap { $0.hasPrefix("kvs=") ? String($0.dropFirst(4)).lowercased() : nil }
            guard let proven, lock.contains(proven) else {
                return reply(url, 403, ["reason": "email-required", "emailLock": true])
            }
            recipient = proven
        }
        g.events.append(["at": "2026-10-23T09:3\(g.events.count % 10):00Z", "kind": "open", "country": "SA",
                         "deviceClass": "phone", "recipient": recipient ?? NSNull()])
        grants[gid] = g
        let items: [[String: Any]] = g.order.map { f in
            let it = g.items[f]!
            guard let file = files[f], file.trashedAt == nil, !file.purged,
                  let v = versions["\(f)|\(it.version)"] else { return ["fileId": f, "removed": true] }
            return ["fileId": f, "version": it.version, "uploadId": v.uploadId, "bytes": v.bytes, "chunks": v.chunks,
                    "wrappedKey": it.wrappedKey, "linkMeta": it.linkMeta, "remaining": NSNull()]
        }
        return reply(url, 200, ["grantId": gid, "items": items, "password": g.password, "limits": g.limits,
                                "emailLock": g.emailLock != nil, "recipient": recipient ?? NSNull(),
                                "remaining": NSNull(), "expiresAt": g.limits["expiresAt"] ?? NSNull()])
    }

    // MARK: - Test helpers

    /// A committed file put straight into the stub, sealed as a real upload
    /// would seal it, but with no chunk bytes behind it: a link is made from
    /// the records alone, so a 2,400-chunk file costs nothing to have.
    @discardableResult
    func seed(keys: VaultKeys, name: String, chunks n: Int = 1) throws -> String {
        lock.lock(); defer { lock.unlock() }
        let fileId = id(), uploadId = id()
        let size = (n - 1) * VaultCrypto.chunkBytes + 100
        let hashes = (0..<n).map { _ in VaultCrypto.hex(VaultCrypto.random(32)) }
        let vm = try VaultCrypto.encryptVersionMeta(vaultKey: keys.vaultKey, fileId: fileId, uploadId: uploadId,
                                                    size: size, chunkHashes: hashes, seq: 1)
        let mh = try VaultCrypto.manifestHash(size: size, chunkHashes: hashes)
        let meta = try VaultMeta(seq: 1, uploadId: uploadId, manifestHash: mh, size: size,
                                 sha256: String(repeating: "0", count: 64), name: name, kind: "stl")
            .sealed(vaultKey: keys.vaultKey, fileId: fileId)
        let wrapped = try VaultCrypto.wrapDkForShop(vaultKey: keys.vaultKey, dk: VaultCrypto.newDataKey(),
                                                    fileId: fileId, uploadId: uploadId)
        versions["\(fileId)|1"] = Version(fileId: fileId, version: 1, uploadId: uploadId, bytes: size + n * 16, chunks: n,
                                          wrappedKey: wrapped.base64EncodedString(), manifestHash: mh,
                                          versionMeta: vm.base64EncodedString(),
                                          tag: VaultCrypto.hex(VaultCrypto.random(32)), deviceId: "mac-a")
        rev += 1
        files[fileId] = File(fileId: fileId, nextVersion: 2, head: 1, meta: meta.base64EncodedString(), metaRev: 1,
                             trashedAt: nil, rev: rev)
        return fileId
    }

    func grant(_ id: String) -> Grant? { lock.lock(); defer { lock.unlock() }; return grants[id] }
    func revokeElsewhere(_ id: String) { lock.lock(); defer { lock.unlock() }; grants[id]?.revoked = true }
    /// The admin takedown (`POST /v1/admin/vault/grants/{id}`), on or off.
    func takedown(_ id: String, reason: String?, on: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        grants[id]?.disabledAt = on ? "2026-10-23T11:00:00Z" : nil
        grants[id]?.disabledReason = on ? reason : nil
    }
    var log: [Logged] { lock.lock(); defer { lock.unlock() }; return requestLog }
    func objectBytes(_ fileId: String, _ version: Int, _ i: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }; return objects[key(fileId, version, i)]
    }
}
