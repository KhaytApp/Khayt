import Foundation
import Testing
@testable import KhaytCore

/// Selling vault files (`VaultProducts`) against `VaultStub`'s phase 3
/// routes. The release is OPENED by the stub with the product key, as the
/// cloud opens it, so a pass proves the format and not just the shape.
struct VaultProductsTests {

    typealias Bench = VaultClientTests.Bench

    func products(_ b: Bench) -> VaultProducts { VaultProducts(client: b.stub.client(), keys: b.keys) }

    /// Upload `n` small files and return their feed rows as sources.
    func uploaded(_ b: Bench, _ n: Int = 2) async throws -> [VaultLinks.Source] {
        for i in 0..<n {
            let src = b.file("model\(i).stl", VaultClientTests.bytes(1000 + i, seed: UInt8(i + 1)))
            _ = try await VaultUpload.run(b.job(src, key: "k\(i)"), client: b.stub.client(), keys: b.keys, spoolRoot: b.spool)
        }
        return try await b.stub.client().files(since: 0).files.map { VaultLinks.Source(row: $0, lastSeenSeq: nil) }
    }

    func draft(_ files: [String]) -> VaultProducts.Draft {
        var d = VaultProducts.Draft()
        d.title = .init(en: "Bracket set", ar: "طقم حوامل")
        d.provider = "stripe"
        d.checkoutUrl = "https://buy.stripe.com/test_123"
        d.priceText = "SAR 25"
        d.files = files
        return d
    }

    @Test("Products: create, list, edit and remove — the fields as the contract names them")
    func crud() async throws {
        let b = Bench()
        let src = try await uploaded(b, 1)
        let p = products(b)
        let made = try await p.create(draft(src.map(\.row.fileId)))
        #expect(made.title.ar == "طقم حوامل")
        #expect(made.files == src.map(\.row.fileId))
        #expect(made.delivery == .init(maxDownloads: 20, perFile: true, validDays: nil))
        let sent = try #require(b.stub.log.last { $0.method == "POST" && $0.url.hasSuffix("/vault/products") })
        let o = try #require(try JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
        #expect((o["title"] as? [String: String])?["en"] == "Bracket set")
        #expect((o["licence"] as? [String: String])?["code"] == "personal")
        #expect((o["delivery"] as? [String: Any])?["validDays"] is NSNull)
        #expect(o["providerProductId"] == nil, "an empty provider id is not sent")
        var edit = VaultProducts.Draft(made)
        edit.priceText = "SAR 30"
        #expect(try await p.update(made.productId, edit).priceText == "SAR 30")
        #expect(try await p.products().count == 1)
        try await p.remove(made.productId)
        #expect(try await p.products().first?.isRemoved == true)
        await #expect(throws: VaultProducts.Refusal.self) { _ = try await p.update(made.productId, edit) }
    }

    @Test("Products: a plan without publishing, and a file not in the vault, are refusals with reasons")
    func refusals() async throws {
        let b = Bench()
        let src = try await uploaded(b, 1)
        let p = products(b)
        do { _ = try await p.create(draft(["nope_not_a_file"])); Issue.record("accepted an unknown file") }
        catch let r as VaultProducts.Refusal { #expect(r.reason == "unknown-items" && r.fileIds == ["nope_not_a_file"]) }
        b.stub.noPublishing = true
        do { _ = try await p.create(draft(src.map(\.row.fileId))); Issue.record("accepted with no publishing") }
        catch let r as VaultProducts.Refusal { #expect(r.status == 402 && r.reason == "no-publishing") }
    }

    @Test("Release: a fresh product key, every file wrapped and sealed under it — and the cloud can open each")
    func release() async throws {
        let b = Bench()
        let src = try await uploaded(b, 2)
        let p = products(b)
        let made = try await p.create(draft(src.map(\.row.fileId)))
        let r = try await p.release(made.productId, files: src)
        #expect(r.items == 2)
        let held = try #require(b.stub.products[made.productId])
        let pk = try #require(held.pk)
        // The stub opened every item (or it would have answered bad-release);
        // here the test opens them again and lands on the right bytes.
        for item in held.release {
            let fid = item["fileId"] as! String, up = item["uploadId"] as! String
            let dk = try VaultCrypto.unwrapDkForProduct(productKey: pk, wrapped: Data(base64Encoded: item["wrappedKey"] as! String)!,
                                                        productId: made.productId, fileId: fid, uploadId: up)
            #expect(dk.count == 32)
            let meta = try VaultCrypto.decryptProductMeta(productKey: pk, productId: made.productId, fileId: fid,
                                                          uploadId: up, sealed: Data(base64Encoded: item["productMeta"] as! String)!)
            #expect(meta.name.hasPrefix("model"))
        }
        // A second release is a NEW key: nothing about a product is kept here.
        _ = try await p.release(made.productId, files: src)
        #expect(b.stub.products[made.productId]?.pk != pk)
        // The key travels as base64url without padding, and in the release body only.
        let bodies = b.stub.log.filter { $0.url.contains("/release") && $0.method == "POST" }
        #expect(bodies.count == 2)
        let pkText = VaultCrypto.base64url(pk)
        let others = b.stub.log.filter { !$0.url.contains("/release") }
        #expect(!others.contains { String(decoding: $0.body, as: UTF8.self).contains(pkText) })
        #expect(try await p.releaseState(made.productId).items.count == 2)
    }

    @Test("Release: a file outside the product, and dropping a file a buyer holds, are refused by name")
    func releaseRefusals() async throws {
        let b = Bench()
        let src = try await uploaded(b, 2)
        let p = products(b)
        let made = try await p.create(draft([src[0].row.fileId]))
        do { _ = try await p.release(made.productId, files: src); Issue.record("released a file outside the product") }
        catch let r as VaultProducts.Refusal { #expect(r.reason == "not-in-product" && r.fileIds == [src[1].row.fileId]) }

        var both = VaultProducts.Draft(made); both.files = src.map(\.row.fileId)
        _ = try await p.update(made.productId, both)
        _ = try await p.release(made.productId, files: src)
        _ = try await p.addBuyer(made.productId, email: "buyer@example.com", orderRef: "ORD-1")
        do { _ = try await p.release(made.productId, files: [src[0]]); Issue.record("dropped a file a buyer holds") }
        catch let r as VaultProducts.Refusal { #expect(r.status == 409 && r.reason == "release-drops-file") }
        // Named on purpose, it goes.
        #expect(try await p.release(made.productId, files: [src[0]], unrelease: [src[1].row.fileId]).items == 1)
    }

    @Test("Buyers: delivered by hand once per order, listed, and revoked; nothing secret comes back")
    func buyers() async throws {
        let b = Bench()
        let src = try await uploaded(b, 1)
        let p = products(b)
        let made = try await p.create(draft(src.map(\.row.fileId)))
        do { _ = try await p.addBuyer(made.productId, email: "a@example.com"); Issue.record("delivered before a release") }
        catch let r as VaultProducts.Refusal { #expect(r.reason == "not-released") }
        _ = try await p.release(made.productId, files: src)
        await #expect(throws: VaultLinks.Failure.self) { _ = try await p.addBuyer(made.productId, email: "not an address") }
        let first = try await p.addBuyer(made.productId, email: " a@example.com ", orderRef: "BANK-7", note: "Paid in cash")
        #expect(first.duplicate == nil)
        #expect(try await p.addBuyer(made.productId, email: "a@example.com", orderRef: "BANK-7").duplicate == true)
        let list = try await p.buyers(made.productId)
        #expect(list.count == 1 && list[0].buyerEmail == "a@example.com" && list[0].status == "paid")
        try await p.revokeBuyer(made.productId, grantId: first.grantId)
        #expect(try await p.buyers(made.productId).first?.status == "revoked")
    }

    @Test("Publishing off on the cloud is a refusal the Mac can say, not a crash")
    func publishOff() async throws {
        let b = Bench()
        let src = try await uploaded(b, 1)
        let p = products(b)
        let made = try await p.create(draft(src.map(\.row.fileId)))
        b.stub.publishOff = true
        do { _ = try await p.release(made.productId, files: src); Issue.record("released with publishing off") }
        catch let r as VaultProducts.Refusal { #expect(r.status == 503 && r.reason == "publish-off") }
    }

    @Test("Sales webhooks: set, listed without secrets, removed; Gumroad's address is shown once")
    func salesHooks() async throws {
        let b = Bench()
        let p = products(b)
        let url = try await p.setSalesHook("stripe", secret: "whsec_abc")
        #expect(url.hasSuffix("/stripe"))
        let gumroad = try await p.setSalesHook("gumroad", secret: nil)
        #expect(gumroad.contains("/gumroad/"))
        let list = try await p.salesHooks()
        #expect(Set(list.map(\.provider)) == ["stripe", "gumroad"])
        #expect(list.first { $0.provider == "gumroad" }?.url == nil)
        do { _ = try await p.setSalesHook("stripe", secret: "nope"); Issue.record("bad secret accepted") }
        catch let r as VaultProducts.Refusal { #expect(r.reason == "bad-secret") }
        await #expect(throws: VaultCrypto.Failure.self) { _ = try await p.setSalesHook("paypal", secret: "x") }
        try await p.removeSalesHook("stripe")
        #expect(try await p.salesHooks().map(\.provider) == ["gumroad"])
    }

    @Test("Previews: an image is added once by its hash, and only JPEG or PNG is sent")
    func previews() async throws {
        let b = Bench()
        let src = try await uploaded(b, 1)
        let p = products(b)
        let made = try await p.create(draft(src.map(\.row.fileId)))
        let img = Data([0x89, 0x50, 0x4e, 0x47, 1, 2, 3])
        let a = try await p.addPreview(made.productId, image: img, mime: "image/png")
        let again = try await p.addPreview(made.productId, image: img, mime: "image/png")
        #expect(a.hash == again.hash)
        await #expect(throws: VaultCrypto.Failure.self) { _ = try await p.addPreview(made.productId, image: img, mime: "image/gif") }
        #expect(try await p.setPreviews(made.productId, []).previews.isEmpty)
    }

    @Test("The product key never prints, and a refusal's words carry no secret")
    func nothingPrints() async throws {
        let r = VaultProducts.Refusal(status: 422, reason: "bad-release", error: "", fileIds: ["f1"], limit: nil)
        #expect(r.description.contains("bad-release"))
        let body = try VaultProducts.releaseBody(productId: "P000000000000000000001", prepared: [], unrelease: [],
                                                 productKey: Data(repeating: 9, count: 32))
        #expect((body["pk"] as? String)?.contains("=") == false)
        #expect(body["unrelease"] == nil)
    }
}
