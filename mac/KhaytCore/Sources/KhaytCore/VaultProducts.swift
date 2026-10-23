import Foundation

/// Selling vault files through makerrun.com — the shop's side of khayt-cloud
/// `docs/api-contract.md` "Phase 3a" and "Phase 3b".
///
/// ── WHAT IS PUBLIC, WHAT THE CLOUD CAN READ ────────────────────────────────
///
/// A PRODUCT is a listing, and it is plaintext and public: its title,
/// description, price text, licence, previews and checkout link are what
/// makerrun shows. Its `files` (vault fileIds) are the owner's only.
///
/// A RELEASE is the trust change, and the only one: for every file in it,
/// this Mac wraps that version's file key under a fresh product key and sends
/// the key with it (`lib/vault-crypto.js` "Published files"), so the cloud
/// can deliver to a buyer while this Mac is asleep. A file never released is
/// never readable by the cloud. The product key is made here, sent once and
/// kept nowhere on this Mac; it never prints.
///
/// Nobody here takes money. A buyer pays at the creator's own checkout; the
/// cloud makes the buyer's link when the creator's provider tells it, or when
/// the creator delivers by hand (`addBuyer`).
public struct VaultProducts: Sendable {
    public let client: VaultClient
    public let keys: VaultKeys

    public init(client: VaultClient, keys: VaultKeys) { self.client = client; self.keys = keys }

    // MARK: - What the cloud refused

    /// A refusal the cloud named, by its `reason`. Anything it did not name
    /// is `VaultClient.Failure` (`vaultOff` for the 404 with no reason, which
    /// is a cloud with no vault switched on).
    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public let status: Int
        /// e.g. `no-publishing`, `products-full`, `checkout-host`, `release-drops-file`,
        /// `publish-off`, `not-released`, `mail-off`, `links-disabled`, `role`.
        public let reason: String
        /// The cloud's own words for a 422 with no reason.
        public let error: String
        /// The files a refusal names (`not-in-product`, `unknown-items`,
        /// `release-drops-file`, `bad-release`).
        public let fileIds: [String]
        public let limit: Int?
        public var description: String {
            "Khayt Cloud refused (\(status) \(reason.isEmpty ? error : reason))"
                + (fileIds.isEmpty ? "" : " for \(fileIds.count) file(s)")
        }
    }

    static func failure(_ code: Int, _ data: Data) -> Error {
        let o = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        let reason = (o["reason"] as? String) ?? ""
        var ids = (o["fileIds"] as? [String]) ?? []
        if let one = o["fileId"] as? String { ids.append(one) }
        // A 404 with no reason is the vault switched off; 401 and 429 are the
        // client's own. Everything else the cloud explained is a Refusal.
        if code == 404 && reason.isEmpty || code == 401 || code == 429 { return VaultClient.failure(code, data) }
        guard !reason.isEmpty || code == 422 || code == 503 || code == 409 || code == 402 || code == 403 else {
            return VaultClient.failure(code, data)
        }
        return Refusal(status: code, reason: reason, error: (o["error"] as? String) ?? "", fileIds: ids,
                       limit: (o["limit"] as? NSNumber)?.intValue)
    }

    func send(_ method: String, _ tail: String, body: [String: Any]? = nil, data: Data? = nil,
              contentType: String? = nil, expect: Set<Int>) async throws -> (Data, Int) {
        var request = try CloudReader.request(client.connection, token: client.token, method: method, tail: tail)
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let data {
            request.httpBody = data
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (bytes, response) = try await client.fetch(request)
        let code = S3.status(response)
        if expect.contains(code) { return (bytes, code) }
        throw Self.failure(code, bytes)
    }

    func decode<T: Decodable>(_ type: T.Type, _ data: Data, _ what: String) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw VaultClient.Failure.badReply(what) }
    }

    static func pid(_ productId: String) throws -> String { try VaultCrypto.id(productId, "productId") }

    // MARK: - Products (phase 3a)

    public struct Text2: Codable, Sendable, Equatable {
        public var en: String
        public var ar: String
        public init(en: String = "", ar: String = "") { self.en = en; self.ar = ar }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            en = (try? c.decodeIfPresent(String.self, forKey: .en)) ?? ""
            ar = (try? c.decodeIfPresent(String.self, forKey: .ar)) ?? ""
        }
        enum CodingKeys: String, CodingKey { case en, ar }
        var json: [String: Any] { ["en": en, "ar": ar] }
    }

    public struct Licence: Codable, Sendable, Equatable {
        public var code: String
        public var name: String
        public var url: String?
        public init(code: String, name: String, url: String? = nil) { self.code = code; self.name = name; self.url = url }
        var json: [String: Any] {
            var o: [String: Any] = ["code": code, "name": name]
            if let url, !url.isEmpty { o["url"] = url }
            return o
        }
    }

    /// What each buyer's link allows (phase 3b): downloads, per file or for
    /// the whole link, and days from the sale (nil for no end).
    public struct Delivery: Codable, Sendable, Equatable {
        public var maxDownloads: Int
        public var perFile: Bool
        public var validDays: Int?
        public init(maxDownloads: Int = 20, perFile: Bool = true, validDays: Int? = nil) {
            self.maxDownloads = maxDownloads; self.perFile = perFile; self.validDays = validDays
        }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            maxDownloads = (try? c.decodeIfPresent(Int.self, forKey: .maxDownloads)) ?? 20
            perFile = (try? c.decodeIfPresent(Bool.self, forKey: .perFile)) ?? true
            validDays = (try? c.decodeIfPresent(Int.self, forKey: .validDays)) ?? nil
        }
        enum CodingKeys: String, CodingKey { case maxDownloads, perFile, validDays }
        var json: [String: Any] {
            var o: [String: Any] = ["maxDownloads": maxDownloads, "perFile": perFile]
            o["validDays"] = validDays.map { $0 as Any } ?? NSNull()
            return o
        }
    }

    public struct Preview: Codable, Sendable, Equatable, Identifiable {
        public let hash: String
        public let width: Int
        public let height: Int
        public let mime: String
        public let bytes: Int
        public var id: String { hash }
    }

    /// A product as its owner reads it.
    public struct Product: Decodable, Sendable, Equatable, Identifiable {
        public let productId: String
        public let status: String
        public let kind: String
        public let provider: String
        public let checkoutUrl: String
        public let providerProductId: String?
        public let priceText: String?
        public let title: Text2
        public let description: Text2
        public let defaultLang: String
        public let licence: Licence
        public let files: [String]
        public let previews: [Preview]
        public let makerrunListable: Bool
        public let delivery: Delivery
        public let createdAt: String?
        public let updatedAt: String?
        public var id: String { productId }
        public var isRemoved: Bool { status == "removed" }

        enum CodingKeys: String, CodingKey {
            case productId, status, kind, provider, checkoutUrl, providerProductId, priceText, title, description,
                 defaultLang, licence, files, previews, makerrunListable, delivery, createdAt, updatedAt
        }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            productId = try c.decode(String.self, forKey: .productId)
            status = (try? c.decode(String.self, forKey: .status)) ?? "active"
            kind = (try? c.decode(String.self, forKey: .kind)) ?? "paid"
            provider = (try? c.decode(String.self, forKey: .provider)) ?? "other"
            checkoutUrl = (try? c.decode(String.self, forKey: .checkoutUrl)) ?? ""
            providerProductId = try? c.decodeIfPresent(String.self, forKey: .providerProductId)
            priceText = try? c.decodeIfPresent(String.self, forKey: .priceText)
            title = (try? c.decode(Text2.self, forKey: .title)) ?? Text2()
            description = (try? c.decode(Text2.self, forKey: .description)) ?? Text2()
            defaultLang = (try? c.decode(String.self, forKey: .defaultLang)) ?? "en"
            licence = (try? c.decode(Licence.self, forKey: .licence)) ?? Licence(code: "", name: "")
            files = (try? c.decode([String].self, forKey: .files)) ?? []
            previews = (try? c.decode([Preview].self, forKey: .previews)) ?? []
            makerrunListable = (try? c.decode(Bool.self, forKey: .makerrunListable)) ?? false
            delivery = (try? c.decode(Delivery.self, forKey: .delivery)) ?? Delivery()
            createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
            updatedAt = try? c.decodeIfPresent(String.self, forKey: .updatedAt)
        }
    }

    /// What a create or an edit sends. Every field is the whole value: the
    /// cloud replaces each field it is given.
    public struct Draft: Sendable, Equatable {
        public var title = Text2()
        public var description = Text2()
        public var kind = "paid"
        public var provider = "stripe"
        public var checkoutUrl = ""
        public var providerProductId = ""
        public var priceText = ""
        public var licence = Licence(code: "personal", name: "Personal use")
        public var files: [String] = []
        public var status = "active"
        public var delivery = Delivery()
        public init() {}
        public init(_ p: Product) {
            title = p.title; description = p.description; kind = p.kind; provider = p.provider
            checkoutUrl = p.checkoutUrl; providerProductId = p.providerProductId ?? ""; priceText = p.priceText ?? ""
            licence = p.licence; files = p.files; status = p.status == "removed" ? "active" : p.status
            delivery = p.delivery
        }
        var json: [String: Any] {
            var o: [String: Any] = [
                "title": title.json, "description": description.json, "kind": kind, "provider": provider,
                "checkoutUrl": checkoutUrl.trimmingCharacters(in: .whitespacesAndNewlines),
                "priceText": priceText, "licence": licence.json, "files": files, "status": status,
                "delivery": delivery.json,
            ]
            let ppid = providerProductId.trimmingCharacters(in: .whitespaces)
            if !ppid.isEmpty { o["providerProductId"] = ppid }
            return o
        }
    }

    /// The providers the cloud takes, in its order.
    public static let providers = ["stripe", "gumroad", "lemonsqueezy", "payhip", "streampay", "salla", "zid",
                                   "kofi", "etsy", "moyasar", "patreon", "medusa", "other"]

    public func products() async throws -> [Product] {
        struct List: Decodable { let products: [Product] }
        let (data, _) = try await send("GET", "/vault/products", expect: [200])
        return try decode(List.self, data, "products").products
    }

    public func create(_ draft: Draft) async throws -> Product {
        let (data, _) = try await send("POST", "/vault/products", body: draft.json, expect: [201])
        return try decode(Product.self, data, "product")
    }

    public func update(_ productId: String, _ draft: Draft) async throws -> Product {
        let (data, _) = try await send("PATCH", "/vault/products/\(try Self.pid(productId))", body: draft.json, expect: [200])
        return try decode(Product.self, data, "product")
    }

    /// Reorder the previews, dropping any not listed.
    public func setPreviews(_ productId: String, _ hashes: [String]) async throws -> Product {
        let (data, _) = try await send("PATCH", "/vault/products/\(try Self.pid(productId))",
                                       body: ["previews": hashes], expect: [200])
        return try decode(Product.self, data, "product")
    }

    /// Remove a product. Its listing answers 410 for ever; its buyers keep their links.
    public func remove(_ productId: String) async throws {
        _ = try await send("DELETE", "/vault/products/\(try Self.pid(productId))", expect: [204])
    }

    /// Add a preview image (JPEG or PNG, at most 2 MB; the cloud strips its metadata).
    public func addPreview(_ productId: String, image: Data, mime: String) async throws -> Preview {
        guard mime == "image/jpeg" || mime == "image/png" else { throw VaultCrypto.Failure.badInput("preview type") }
        let (data, _) = try await send("POST", "/vault/products/\(try Self.pid(productId))/previews",
                                       data: image, contentType: mime, expect: [200, 201])
        return try decode(Preview.self, data, "preview")
    }

    public func removePreview(_ productId: String, hash: String) async throws {
        guard hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw VaultCrypto.Failure.badInput("preview hash")
        }
        _ = try await send("DELETE", "/vault/products/\(try Self.pid(productId))/previews/\(hash)", expect: [204])
    }

    // MARK: - Connections (makerrun)

    public struct Connection: Decodable, Sendable, Equatable {
        public let client: String
        public let name: String?
        public let shopName: String?
        public let updatedAt: String?
    }

    public func connections() async throws -> [Connection] {
        struct List: Decodable { let connections: [Connection] }
        let (data, _) = try await send("GET", "/vault/connections", expect: [200])
        return try decode(List.self, data, "connections").connections
    }

    public func disconnect(_ client: String) async throws {
        _ = try await send("DELETE", "/vault/connections/\(try VaultCrypto.id(client, "client"))", expect: [204])
    }

    // MARK: - Release (phase 3b)

    public struct ReleaseState: Decodable, Sendable, Equatable {
        public struct Item: Decodable, Sendable, Equatable { public let fileId: String; public let version: Int }
        public let releasedAt: String?
        public let items: [Item]
    }

    public func releaseState(_ productId: String) async throws -> ReleaseState {
        let (data, _) = try await send("GET", "/vault/products/\(try Self.pid(productId))/release", expect: [200])
        return try decode(ReleaseState.self, data, "release")
    }

    public struct Released: Decodable, Sendable, Equatable {
        public let releasedAt: String
        public let items: Int
        public let grantsUpdated: Int
        public let grantsQueued: Int
    }

    /// The body of a release, with a FRESH product key. Static and separate
    /// so the shape is tested without a network; the key is in the body only.
    static func releaseBody(productId: String, prepared: [VaultLinks.Prepared], unrelease: [String],
                            productKey pk: Data) throws -> [String: Any] {
        let items: [[String: Any]] = try prepared.map {
            let wrapped = try VaultCrypto.wrapDkForProduct(productKey: pk, dk: $0.dk, productId: productId,
                                                           fileId: $0.fileId, uploadId: $0.uploadId)
            let meta = try VaultCrypto.encryptProductMeta(productKey: pk, productId: productId, fileId: $0.fileId,
                                                          uploadId: $0.uploadId, meta: $0.meta)
            return ["fileId": $0.fileId, "version": $0.version, "uploadId": $0.uploadId,
                    "wrappedKey": wrapped.base64EncodedString(), "productMeta": meta.base64EncodedString()]
        }
        var body: [String: Any] = ["pk": VaultCrypto.base64url(pk), "items": items]
        if !unrelease.isEmpty { body["unrelease"] = unrelease }
        return body
    }

    /// Release the product's files for sale: the COMPLETE set, each file at
    /// its current version. From this moment the cloud can read these
    /// versions (and only these) while they are on sale or reachable through
    /// a buyer's link. `unrelease` names files deliberately taken out that
    /// existing buyers' links still hold.
    public func release(_ productId: String, files: [VaultLinks.Source],
                        unrelease: [String] = []) async throws -> Released {
        let id = try Self.pid(productId)
        guard !files.isEmpty else { throw VaultLinks.Failure.nothingToShare }
        let prepared = try files.map { try VaultLinks.prepare($0, keys: keys) }
        let body = try Self.releaseBody(productId: id, prepared: prepared, unrelease: unrelease,
                                        productKey: VaultCrypto.newProductKey())
        let (data, _) = try await send("POST", "/vault/products/\(id)/release", body: body, expect: [200])
        return try decode(Released.self, data, "release")
    }

    // MARK: - Buyers

    public struct Buyer: Decodable, Sendable, Equatable, Identifiable {
        public let provider: String
        public let orderId: String
        public let buyerEmail: String
        public let status: String
        public let createdAt: String?
        public let grantId: String
        public let note: String?
        public let used: Int
        public let remaining: Int?
        public var id: String { grantId }
        enum CodingKeys: String, CodingKey {
            case provider, orderId, buyerEmail, status, createdAt, grantId, note, used, remaining
        }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            provider = (try? c.decode(String.self, forKey: .provider)) ?? ""
            orderId = (try? c.decode(String.self, forKey: .orderId)) ?? ""
            buyerEmail = (try? c.decode(String.self, forKey: .buyerEmail)) ?? ""
            status = (try? c.decode(String.self, forKey: .status)) ?? ""
            createdAt = try? c.decodeIfPresent(String.self, forKey: .createdAt)
            grantId = try c.decode(String.self, forKey: .grantId)
            note = try? c.decodeIfPresent(String.self, forKey: .note)
            used = (try? c.decode(Int.self, forKey: .used)) ?? 0
            remaining = try? c.decodeIfPresent(Int.self, forKey: .remaining)
        }
    }

    public func buyers(_ productId: String) async throws -> [Buyer] {
        struct List: Decodable { let buyers: [Buyer] }
        let (data, _) = try await send("GET", "/vault/products/\(try Self.pid(productId))/buyers", expect: [200])
        return try decode(List.self, data, "buyers").buyers
    }

    public struct Delivered: Decodable, Sendable, Equatable {
        public let grantId: String
        public let status: String
        public let duplicate: Bool?
    }

    /// Deliver by hand: a bank transfer, an order from somewhere else. The
    /// cloud emails the buyer their link; no secret comes back here.
    public func addBuyer(_ productId: String, email: String, orderRef: String? = nil,
                         note: String? = nil) async throws -> Delivered {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard VaultLinks.isEmail(address) else { throw VaultLinks.Failure.notAnEmail(address) }
        var body: [String: Any] = ["email": address]
        if let r = orderRef?.trimmingCharacters(in: .whitespaces), !r.isEmpty { body["orderRef"] = r }
        if let n = note?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { body["note"] = String(n.prefix(500)) }
        let (data, _) = try await send("POST", "/vault/products/\(try Self.pid(productId))/buyers",
                                       body: body, expect: [200, 201])
        return try decode(Delivered.self, data, "buyer")
    }

    public func revokeBuyer(_ productId: String, grantId: String) async throws {
        _ = try await send("POST", "/vault/products/\(try Self.pid(productId))/buyers/"
                           + "\(try VaultCrypto.id(grantId, "grantId"))/revoke", expect: [200])
    }

    // MARK: - Sales webhooks

    public static let salesProviders = ["stripe", "lemonsqueezy", "gumroad"]

    public struct SalesHook: Decodable, Sendable, Equatable {
        public let provider: String
        public let url: String?
        public let createdAt: String?
        public let lastEventAt: String?
    }

    public func salesHooks() async throws -> [SalesHook] {
        struct List: Decodable { let providers: [SalesHook] }
        let (data, _) = try await send("GET", "/vault/sales", expect: [200])
        return try decode(List.self, data, "sales").providers
    }

    /// Set a provider's signing secret (or, for Gumroad, nil to have the cloud
    /// make one). Returns the address to give the provider — for Gumroad it
    /// carries the secret and is shown only now.
    public func setSalesHook(_ provider: String, secret: String?) async throws -> String {
        guard Self.salesProviders.contains(provider) else { throw VaultCrypto.Failure.badInput("provider") }
        var body: [String: Any] = [:]
        if let s = secret?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { body["secret"] = s }
        let (data, _) = try await send("PUT", "/vault/sales/\(provider)", body: body, expect: [200])
        struct Reply: Decodable { let url: String }
        return try decode(Reply.self, data, "sales hook").url
    }

    public func removeSalesHook(_ provider: String) async throws {
        guard Self.salesProviders.contains(provider) else { throw VaultCrypto.Failure.badInput("provider") }
        _ = try await send("DELETE", "/vault/sales/\(provider)", expect: [204])
    }
}
