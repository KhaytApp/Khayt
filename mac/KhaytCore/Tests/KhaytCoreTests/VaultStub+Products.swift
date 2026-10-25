import Foundation
@testable import KhaytCore

/// Phases 3a and 3b of the vault in the stub, as khayt-cloud
/// `docs/api-contract.md` describes them: products (owner view), previews,
/// connections, the release (every item OPENED with the product key, as the
/// cloud does, so a test proves the Mac's format rather than its shape),
/// buyers and the sales webhook settings. The product key a release carries
/// is kept, so a test can open what the cloud would.
extension VaultStub {

    struct Product {
        var o: [String: Any]
        var release: [[String: Any]] = []
        var releasedAt: String?
        var pk: Data?
        var buyers: [[String: Any]] = []
    }

    func productRoute(_ m: String, _ url: URL, _ parts: [String], _ raw: Data, _ body: [String: Any],
                      contentType: String?) -> (Data, URLResponse) {
        if publishOff, ["release", "buyers"].contains(parts.count > 2 ? parts[2] : ""), m == "POST" {
            return reply(url, 503, ["reason": "publish-off"])
        }
        switch (m, parts.count) {
        case ("GET", 1): return reply(url, 200, ["products": products.values.map(\.o)])
        case ("POST", 1):
            guard !noPublishing else { return reply(url, 402, ["reason": "no-publishing"]) }
            if vaultOver { return overReply(url) }
            guard let files = body["files"] as? [String], !files.isEmpty else { return reply(url, 422, ["error": "files"]) }
            let unknown = files.filter { self.files[$0]?.head == nil }
            if !unknown.isEmpty { return reply(url, 422, ["reason": "unknown-items", "fileIds": unknown]) }
            guard let checkout = body["checkoutUrl"] as? String, checkout.hasPrefix("https://") else {
                return reply(url, 422, ["error": "checkoutUrl", "reason": "bad-checkout-url"])
            }
            let pid = "P" + String(format: "%021d", products.count + 1)
            var o = body
            o["productId"] = pid; o["status"] = body["status"] ?? "active"; o["previews"] = [Any]()
            o["makerrunListable"] = true; o["defaultLang"] = "en"
            products[pid] = Product(o: o)
            return reply(url, 201, o)
        case ("GET", 2):
            guard let p = products[parts[1]] else { return reply(url, 404, ["reason": "unknown-product"]) }
            return reply(url, 200, p.o)
        case ("PATCH", 2):
            guard var p = products[parts[1]] else { return reply(url, 404, ["reason": "unknown-product"]) }
            if p.o["status"] as? String == "removed" { return reply(url, 409, ["reason": "removed"]) }
            if vaultOver { return overReply(url) }
            for (k, v) in body where k != "previews" { p.o[k] = v }
            if let order = body["previews"] as? [String] {
                let have = (p.o["previews"] as? [[String: Any]]) ?? []
                p.o["previews"] = order.compactMap { h in have.first { $0["hash"] as? String == h } }
            }
            products[parts[1]] = p
            return reply(url, 200, p.o)
        case ("DELETE", 2):
            guard var p = products[parts[1]] else { return reply(url, 404, ["reason": "unknown-product"]) }
            p.o["status"] = "removed"; p.pk = nil; p.release = []
            products[parts[1]] = p
            return (Data(), HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        case ("POST", 3) where parts[2] == "previews":
            guard var p = products[parts[1]] else { return reply(url, 404, ["reason": "unknown-product"]) }
            guard contentType == "image/jpeg" || contentType == "image/png" else { return reply(url, 415, ["error": "type"]) }
            if vaultOver { return overReply(url) }
            let hash = VaultCrypto.hex(VaultCrypto.sha256(raw))
            let prev: [String: Any] = ["hash": hash, "width": 10, "height": 10, "mime": contentType!, "bytes": raw.count]
            var list = (p.o["previews"] as? [[String: Any]]) ?? []
            if !list.contains(where: { $0["hash"] as? String == hash }) { list.append(prev) }
            p.o["previews"] = list
            products[parts[1]] = p
            return reply(url, 201, prev)
        case ("DELETE", 4) where parts[2] == "previews":
            // Allowed over the plan, like every removal.
            guard var p = products[parts[1]] else { return reply(url, 404, ["reason": "unknown-product"]) }
            p.o["previews"] = ((p.o["previews"] as? [[String: Any]]) ?? []).filter { $0["hash"] as? String != parts[3] }
            products[parts[1]] = p
            return (Data(), HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        case ("GET", 3) where parts[2] == "release":
            guard let p = products[parts[1]] else { return reply(url, 404, ["reason": "unknown-product"]) }
            return reply(url, 200, ["releasedAt": p.releasedAt as Any? ?? NSNull(),
                                    "items": p.release.map { ["fileId": $0["fileId"]!, "version": $0["version"]!] }])
        case ("POST", 3) where parts[2] == "release":
            if vaultOver && !noPublishing { return overReply(url) }
            return release(url, parts[1], body)
        case ("GET", 3) where parts[2] == "buyers":
            guard let p = products[parts[1]] else { return reply(url, 404, ["reason": "unknown-product"]) }
            return reply(url, 200, ["buyers": p.buyers])
        case ("POST", 3) where parts[2] == "buyers":
            guard var p = products[parts[1]] else { return reply(url, 404, ["reason": "unknown-product"]) }
            guard p.releasedAt != nil else { return reply(url, 503, ["reason": "not-released"]) }
            if let ref = body["orderRef"] as? String, let had = p.buyers.first(where: { $0["orderId"] as? String == ref }) {
                return reply(url, 200, ["grantId": had["grantId"]!, "status": had["status"]!, "duplicate": true])
            }
            let gid = "G" + String(format: "%021d", p.buyers.count + 1)
            p.buyers.insert(["provider": "manual", "orderId": body["orderRef"] ?? gid, "buyerEmail": body["email"] ?? "",
                             "status": "paid", "grantId": gid, "used": 0, "remaining": 20,
                             "note": body["note"] as Any? ?? NSNull()], at: 0)
            products[parts[1]] = p
            return reply(url, 201, ["grantId": gid, "status": "paid"])
        case ("POST", 5) where parts[2] == "buyers" && parts[4] == "revoke":
            guard var p = products[parts[1]], let i = p.buyers.firstIndex(where: { $0["grantId"] as? String == parts[3] })
            else { return reply(url, 404, ["reason": "unknown-buyer"]) }
            p.buyers[i]["status"] = "revoked"
            products[parts[1]] = p
            return reply(url, 200, ["grantId": parts[3], "status": "revoked"])
        default: return reply(url, 404, ["error": "Not found", "reason": "no-route"])
        }
    }

    /// The cloud's release checks, in its order, then the swap.
    func release(_ url: URL, _ pid: String, _ b: [String: Any]) -> (Data, URLResponse) {
        guard var p = products[pid] else { return reply(url, 404, ["reason": "unknown-product"]) }
        if p.o["status"] as? String == "removed" { return reply(url, 409, ["reason": "removed"]) }
        guard let pkText = b["pk"] as? String, !pkText.contains("="), !pkText.contains("+"), !pkText.contains("/"),
              let pk = try? VaultCrypto.unbase64url(pkText), pk.count == 32,
              let items = b["items"] as? [[String: Any]], !items.isEmpty else { return reply(url, 422, ["error": "shape"]) }
        let inProduct = Set((p.o["files"] as? [String]) ?? [])
        let outside = items.compactMap { $0["fileId"] as? String }.filter { !inProduct.contains($0) }
        if !outside.isEmpty { return reply(url, 422, ["reason": "not-in-product", "fileIds": outside]) }
        var unknown: [String] = []
        for it in items {
            let fid = it["fileId"] as? String ?? "", v = it["version"] as? Int ?? 0
            guard let ver = versions["\(fid)|\(v)"], ver.uploadId == it["uploadId"] as? String,
                  files[fid]?.trashedAt == nil else { unknown.append(fid); continue }
        }
        if !unknown.isEmpty { return reply(url, 422, ["reason": "unknown-items", "fileIds": unknown]) }
        for it in items {
            let fid = it["fileId"] as! String, up = it["uploadId"] as! String
            guard let w = (it["wrappedKey"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let m = (it["productMeta"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  (try? VaultCrypto.unwrapDkForProduct(productKey: pk, wrapped: w, productId: pid, fileId: fid,
                                                       uploadId: up)) != nil,
                  let meta = try? VaultCrypto.decryptProductMeta(productKey: pk, productId: pid, fileId: fid,
                                                                 uploadId: up, sealed: m),
                  meta.manifestHash == versions["\(fid)|\(it["version"] as! Int)"]?.manifestHash
            else { return reply(url, 422, ["reason": "bad-release", "fileId": fid]) }
        }
        let held = Set(p.release.compactMap { $0["fileId"] as? String })
        let now = Set(items.compactMap { $0["fileId"] as? String })
        let unrelease = Set((b["unrelease"] as? [String]) ?? [])
        let live = p.buyers.contains { $0["status"] as? String == "paid" }
        let dropped = held.subtracting(now).subtracting(unrelease)
        if live, !dropped.isEmpty { return reply(url, 409, ["reason": "release-drops-file", "fileIds": dropped.sorted()]) }
        p.pk = pk; p.release = items; p.releasedAt = "2026-10-24T10:00:00Z"
        products[pid] = p
        return reply(url, 200, ["releasedAt": p.releasedAt!, "items": items.count,
                                "grantsUpdated": p.buyers.filter { $0["status"] as? String == "paid" }.count,
                                "grantsQueued": 0])
    }

    func salesRoute(_ m: String, _ url: URL, _ parts: [String], _ body: [String: Any]) -> (Data, URLResponse) {
        if parts.count == 1, m == "GET" {
            return reply(url, 200, ["providers": salesHooks.keys.sorted().map {
                ["provider": $0, "url": $0 == "gumroad" ? NSNull() : "https://cloud.test/v1/vault/sales/\(Self.shopId)/\($0)" as Any,
                 "createdAt": "2026-10-24T09:00:00Z", "lastEventAt": NSNull()] as [String: Any]
            }])
        }
        guard parts.count == 2, ["stripe", "lemonsqueezy", "gumroad"].contains(parts[1]) else {
            return reply(url, 404, ["error": "Not found"])
        }
        let provider = parts[1]
        switch m {
        case "PUT":
            var secret = body["secret"] as? String ?? ""
            if provider == "gumroad", secret.isEmpty { secret = String(repeating: "s", count: 32) }
            if provider == "stripe", !secret.hasPrefix("whsec_") { return reply(url, 422, ["reason": "bad-secret"]) }
            salesHooks[provider] = secret
            let tail = provider == "gumroad" ? "gumroad/\(secret)" : provider
            return reply(url, 200, ["provider": provider, "url": "https://cloud.test/v1/vault/sales/\(Self.shopId)/\(tail)"])
        case "DELETE":
            salesHooks[provider] = nil
            return (Data(), HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        default: return reply(url, 404, ["error": "Not found"])
        }
    }
}
