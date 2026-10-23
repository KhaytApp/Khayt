import Foundation
import Security

// MARK: - The link itself

/// A private share link: `https://cloud.khaytapp.com/s/{grantId}#{linkSecret}`.
///
/// The part after `#` is the link secret, base64url without padding. A browser
/// never sends a fragment, so the cloud never receives it: it stores only what
/// the secret's key has sealed (`docs/vault-format.md` "Link keys").
///
/// **It never prints.** `description` and `debugDescription` name the grant
/// and say the secret is withheld, so a `print(link)`, a log line, an error
/// message or a test failure cannot carry it. Only `url` spells it out, and
/// only the Copy link and Send on WhatsApp buttons ask for that.
public struct VaultLink: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Where the share page is served: scheme and host of the cloud, no path.
    public let origin: String
    public let grantId: String
    let secret: Data

    public init(origin: String, grantId: String, secret: Data) throws {
        guard secret.count == VaultCrypto.keyBytes else { throw VaultCrypto.Failure.badInput("link secret must be 32 bytes") }
        _ = try VaultCrypto.id(grantId, "grantId")
        self.origin = origin; self.grantId = grantId; self.secret = secret
    }

    /// The whole link, secret included. For the clipboard and WhatsApp only.
    public var url: String { origin + "/s/" + grantId + "#" + VaultCrypto.base64url(secret) }

    public var description: String { "VaultLink(\(grantId), secret withheld)" }
    public var debugDescription: String { description }

    /// The link a recipient pasted: `…/s/{grantId}#{secret}`, any origin.
    public static func parse(_ text: String) throws -> VaultLink {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hash = t.firstIndex(of: "#"), let s = t.range(of: "/s/") else {
            throw VaultCrypto.Failure.badInput("not a Khayt share link")
        }
        let origin = String(t[..<s.lowerBound])
        let grantId = String(t[s.upperBound..<hash])
        let secret = try VaultCrypto.unbase64url(String(t[t.index(after: hash)...]))
        return try VaultLink(origin: origin, grantId: grantId, secret: secret)
    }

    /// The share page's origin for a cloud API address: the same scheme and
    /// host (`https://cloud.khaytapp.com/v1/…` serves `/s/…` beside it).
    public static func origin(forAPI api: String) -> String {
        guard let u = URLComponents(string: api), let scheme = u.scheme, let host = u.host else {
            return "https://cloud.khaytapp.com"
        }
        return scheme + "://" + host + (u.port.map { ":\($0)" } ?? "")
    }
}

// MARK: - Where the Mac keeps a link's secret

/// What this device remembers about a link it made: the secret (for "Copy
/// link" again later) and the link key (to add files to it later without
/// asking for its password again).
///
/// ── WHY THE KEYCHAIN, AND NOT THE BOOK OR A SEALED FIELD IN IT ──────────
///
/// A link secret is a bearer key to files: whoever holds the URL can open
/// them. So it is kept where it reaches the fewest places.
///
/// * **Not plain JSON in the book.** The book syncs to every device and is
///   handed to every paired phone through `/api/store`. A secret there would
///   be one missed `lib/store-secret-paths.js` entry away from every phone.
/// * **Not a sealed field in the book either** (`SafeStorage`). Sealed values
///   still travel with the book, into backups and restores, and are opened on
///   whichever Mac can open them. Nothing but this Mac needs the secret: the
///   recipient has it in the URL already.
/// * **This Mac's login Keychain**, one generic password per link, never
///   synchronised to iCloud (`kSecAttrSynchronizable: false`), as
///   `CloudKeyMemory` keeps the shop's DEK. The cost, accepted: "Copy link"
///   works only on the Mac that made the link. Another device sees the link,
///   its downloads and its events, and can revoke or extend it, which needs no
///   secret.
///
/// The link key is kept beside the secret. For a password link it is the
/// password's work, but anyone who can read this Keychain item can already
/// read the shop's DEK from the item beside it, and with it every file. It
/// adds no exposure, and adding a newer version to a password link then does
/// not ask for the password again. The PASSWORD itself is never stored.
public struct VaultLinkSecret: Sendable, Equatable, CustomStringConvertible {
    let secret: Data
    let linkKey: Data
    init(secret: Data, linkKey: Data) { self.secret = secret; self.linkKey = linkKey }

    public var description: String { "VaultLinkSecret(withheld)" }

    /// v1 || secret(32) || linkKey(32).
    var bytes: Data { Data([1]) + secret + linkKey }
    init?(bytes: Data) {
        let b = Data(bytes)
        guard b.count == 65, b.first == 1 else { return nil }
        secret = b.subdata(in: 1..<33); linkKey = b.subdata(in: 33..<65)
    }
}

public protocol VaultLinkSecretStore: Sendable {
    func save(_ s: VaultLinkSecret, shopId: String, grantId: String) async -> Bool
    func load(shopId: String, grantId: String) async -> VaultLinkSecret?
    func forget(shopId: String, grantId: String) async
}

/// The Keychain (see `VaultLinkSecret` for why). Security is on iOS too, so
/// this stays portable. Every call runs off the caller's actor, because
/// `SecItemCopyMatching` blocks and a Keychain prompt in front of it would
/// freeze a window.
public struct VaultLinkKeychain: VaultLinkSecretStore {
    public static let service = "Khayt Vault Link"
    public init() {}

    static func query(_ shopId: String, _ grantId: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: shopId + "/" + grantId,
         kSecAttrSynchronizable as String: false]
    }

    public func save(_ s: VaultLinkSecret, shopId: String, grantId: String) async -> Bool {
        let value = s.bytes
        return await Task.detached(priority: .utility) {
            let base = Self.query(shopId, grantId)
            SecItemDelete(base as CFDictionary)
            var add = base
            add[kSecValueData as String] = value
            add[kSecAttrLabel as String] = "Khayt share link (\(grantId))"
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }.value
    }

    public func load(shopId: String, grantId: String) async -> VaultLinkSecret? {
        let raw = await Task.detached(priority: .userInitiated) { () -> Data? in
            var q = Self.query(shopId, grantId)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
            return out as? Data
        }.value
        return raw.flatMap(VaultLinkSecret.init(bytes:))
    }

    public func forget(shopId: String, grantId: String) async {
        await Task.detached(priority: .utility) {
            _ = SecItemDelete(Self.query(shopId, grantId) as CFDictionary)
        }.value
    }
}

/// In memory, for tests and previews. Never the app's.
public final class VaultLinkMemoryStore: VaultLinkSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [String: VaultLinkSecret] = [:]
    public var refuses = false
    public init() {}
    public func save(_ s: VaultLinkSecret, shopId: String, grantId: String) async -> Bool {
        lock.withLock { if refuses { return false }; kept[shopId + "/" + grantId] = s; return true }
    }
    public func load(shopId: String, grantId: String) async -> VaultLinkSecret? {
        lock.withLock { kept[shopId + "/" + grantId] }
    }
    public func forget(shopId: String, grantId: String) async {
        _ = lock.withLock { kept.removeValue(forKey: shopId + "/" + grantId) }
    }
    public var count: Int { lock.withLock { kept.count } }
}

// MARK: - The grant routes

extension VaultClient {

    /// A grant's limits, as the contract names them. All optional.
    public struct GrantLimits: Codable, Sendable, Equatable {
        /// Downloads for the whole link, or for each file when `perFile`.
        public var maxDownloads: Int?
        public var perFile: Bool?
        /// An absolute ISO time, in the future.
        public var expiresAt: String?
        /// Seconds from the FIRST open. Whichever of the two ends first wins.
        public var validForSec: Int?
        public var maxDevices: Int?
        public init(maxDownloads: Int? = nil, perFile: Bool? = nil, expiresAt: String? = nil,
                    validForSec: Int? = nil, maxDevices: Int? = nil) {
            self.maxDownloads = maxDownloads; self.perFile = perFile; self.expiresAt = expiresAt
            self.validForSec = validForSec; self.maxDevices = maxDevices
        }
        var json: [String: Any] {
            var o: [String: Any] = [:]
            if let maxDownloads { o["maxDownloads"] = maxDownloads }
            if let perFile { o["perFile"] = perFile }
            if let expiresAt { o["expiresAt"] = expiresAt }
            if let validForSec { o["validForSec"] = validForSec }
            if let maxDevices { o["maxDevices"] = maxDevices }
            return o
        }
    }

    /// One file of a grant on the wire: a named version, its DK wrapped
    /// under the link key, and its link meta sealed under the same key.
    public struct GrantItem: Sendable, Equatable {
        public let fileId: String
        public let version: Int
        public let wrappedKey: Data
        public let linkMeta: Data
        var json: [String: Any] {
            ["fileId": fileId, "version": version, "wrappedKey": wrappedKey.base64EncodedString(),
             "linkMeta": linkMeta.base64EncodedString()]
        }
    }

    /// A grant as the cloud lists it.
    public struct Grant: Decodable, Sendable, Equatable, Identifiable {
        public struct Item: Decodable, Sendable, Equatable {
            public let fileId: String
            public let version: Int
            public let used: Int
            /// Nil when there is no download limit.
            public let remaining: Int?
            enum CodingKeys: String, CodingKey { case fileId, version, used, remaining }
            public init(from d: Decoder) throws {
                let c = try d.container(keyedBy: CodingKeys.self)
                fileId = try c.decode(String.self, forKey: .fileId)
                version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
                used = try c.decodeIfPresent(Int.self, forKey: .used) ?? 0
                remaining = try c.decodeIfPresent(Int.self, forKey: .remaining)
            }
        }
        public enum State: String, Sendable { case ok, revoked, expired, usedUp = "used-up", unknown }

        public let grantId: String
        public let state: State
        public let createdAt: String?
        public let revokedAt: String?
        public let firstOpenAt: String?
        /// The EFFECTIVE end: the earlier of the date and first open + validForSec.
        public let expiresAt: String?
        public let limits: GrantLimits
        public let password: Bool
        /// Sealed by this shop (`VaultLinks.openNote`). Base64.
        public let ownerNote: String?
        public let used: Int
        public let devices: Int
        public let items: [Item]
        public var id: String { grantId }

        enum CodingKeys: String, CodingKey {
            case grantId, state, createdAt, revokedAt, firstOpenAt, expiresAt, limits, password, ownerNote, used,
                 devices, items
        }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            grantId = try c.decode(String.self, forKey: .grantId)
            state = State(rawValue: try c.decodeIfPresent(String.self, forKey: .state) ?? "") ?? .unknown
            createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
            revokedAt = try c.decodeIfPresent(String.self, forKey: .revokedAt)
            firstOpenAt = try c.decodeIfPresent(String.self, forKey: .firstOpenAt)
            expiresAt = try c.decodeIfPresent(String.self, forKey: .expiresAt)
            limits = try c.decodeIfPresent(GrantLimits.self, forKey: .limits) ?? GrantLimits()
            password = try c.decodeIfPresent(Bool.self, forKey: .password) ?? false
            ownerNote = try c.decodeIfPresent(String.self, forKey: .ownerNote)
            used = try c.decodeIfPresent(Int.self, forKey: .used) ?? 0
            devices = try c.decodeIfPresent(Int.self, forKey: .devices) ?? 0
            items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
        }

        /// Downloads left on the whole link, or nil when it has no limit.
        /// For a per-file limit, the sum of what each file has left.
        public var remaining: Int? {
            guard let max = limits.maxDownloads else { return nil }
            if limits.perFile == true { return items.reduce(0) { $0 + ($1.remaining ?? 0) } }
            return Swift.max(0, max - used)
        }
    }

    public struct GrantEvent: Decodable, Sendable, Equatable, Identifiable {
        /// `open`, `ticket` (a download) or `refused`.
        public let at: String
        public let kind: String
        public let fileId: String?
        public let country: String?
        /// `phone`, `tablet`, `computer` or `other`. No IP, no user agent.
        public let deviceClass: String?
        public var id: String { at + "|" + kind + "|" + (fileId ?? "") }
    }

    /// What a PATCH changes. Any of these, together.
    public struct GrantPatch: Sendable, Equatable {
        public enum Expiry: Sendable, Equatable { case keep, at(String), never }
        public var addDownloads: Int?
        public var expiresAt: Expiry = .keep
        public var revoke = false
        public var items: [GrantItem] = []
        public var removeItems: [String] = []
        public init(addDownloads: Int? = nil, expiresAt: Expiry = .keep, revoke: Bool = false,
                    items: [GrantItem] = [], removeItems: [String] = []) {
            self.addDownloads = addDownloads; self.expiresAt = expiresAt; self.revoke = revoke
            self.items = items; self.removeItems = removeItems
        }
        var json: [String: Any] {
            var o: [String: Any] = [:]
            if let addDownloads { o["addDownloads"] = addDownloads }
            switch expiresAt {
            case .keep: break
            case .at(let iso): o["expiresAt"] = iso
            case .never: o["expiresAt"] = NSNull()
            }
            if revoke { o["revoke"] = true }
            if !items.isEmpty { o["items"] = items.map(\.json) }
            if !removeItems.isEmpty { o["removeItems"] = removeItems }
            return o
        }
    }

    static func createBody(grantId: String, items: [GrantItem], limits: GrantLimits?, password: Bool,
                           ownerNote: Data?) -> [String: Any] {
        var body: [String: Any] = ["grantId": grantId, "items": items.map(\.json)]
        if let limits, !limits.json.isEmpty { body["limits"] = limits.json }
        if password { body["password"] = true }
        if let ownerNote { body["ownerNote"] = ownerNote.base64EncodedString() }
        return body
    }

    /// POST /vault/grants. A taken id throws `.grantExists`. Returns createdAt.
    @discardableResult
    public func createGrant(grantId: String, items: [GrantItem], limits: GrantLimits?, password: Bool,
                            ownerNote: Data?) async throws -> String {
        guard grantId.count >= 22 else { throw VaultCrypto.Failure.badInput("grantId must be at least 22 characters") }
        _ = try VaultCrypto.id(grantId, "grantId")
        let o = try await call("POST", "/vault/grants",
                               body: Self.createBody(grantId: grantId, items: items, limits: limits,
                                                     password: password, ownerNote: ownerNote),
                               expect: [201])
        return (o["createdAt"] as? String) ?? ""
    }

    /// GET /vault/grants: every grant, newest first.
    public func grants() async throws -> [Grant] {
        struct List: Decodable { let grants: [Grant] }
        let (data, _) = try await raw("GET", "/vault/grants", body: nil, expect: [200])
        do { return try JSONDecoder().decode(List.self, from: data).grants }
        catch { throw Failure.badReply("grants") }
    }

    /// GET /vault/grants/{id}.
    public func grant(_ grantId: String) async throws -> Grant {
        let (data, _) = try await raw("GET", "/vault/grants/\(try VaultCrypto.id(grantId, "grantId"))",
                                      body: nil, expect: [200])
        do { return try JSONDecoder().decode(Grant.self, from: data) }
        catch { throw Failure.badReply("grant") }
    }

    /// PATCH /vault/grants/{id}: the grant as it is afterwards.
    @discardableResult
    public func patchGrant(_ grantId: String, _ patch: GrantPatch) async throws -> Grant {
        let (data, _) = try await raw("PATCH", "/vault/grants/\(try VaultCrypto.id(grantId, "grantId"))",
                                      body: patch.json, expect: [200])
        do { return try JSONDecoder().decode(Grant.self, from: data) }
        catch { throw Failure.badReply("grant") }
    }

    /// GET /vault/grants/{id}/events: newest first, the last 500.
    public func grantEvents(_ grantId: String) async throws -> [GrantEvent] {
        struct List: Decodable { let events: [GrantEvent] }
        let (data, _) = try await raw("GET", "/vault/grants/\(try VaultCrypto.id(grantId, "grantId"))/events",
                                      body: nil, expect: [200])
        do { return try JSONDecoder().decode(List.self, from: data).events }
        catch { throw Failure.badReply("events") }
    }
}

// MARK: - Making and keeping links

/// Private share links over vault files (phase 2 of the vault).
///
/// ── WHAT A LINK IS MADE OF ──────────────────────────────────────────────
///
/// For each file, the head version's DK is unwrapped with the vault key and
/// wrapped again under a key derived from a fresh link secret
/// (`VaultCrypto.linkKey`, with the password mixed in when there is one), and
/// a link meta record is sealed under the same key carrying the whole
/// manifest, so the share page checks every chunk against values the server
/// cannot change. The manifest comes from the version's OWN sealed record,
/// the same one a download pins (`VaultDownload`), never from the server's
/// listing.
///
/// ── WHAT NEVER LEAVES THIS DEVICE ───────────────────────────────────────
///
/// The link secret, the link key, the password and every DK. The cloud is
/// sent the grant id, the wraps, the sealed records and `password: true`.
/// The secret is kept only in `secrets` (the Keychain on the Mac).
///
/// ── A BIG SELECTION ─────────────────────────────────────────────────────
///
/// A grant body is at most 500 items and 16 MB. The grant is created with as
/// many items as fit, then grown with `PATCH {items}` in batches under the
/// same limits. If a later batch fails, the half-made link is revoked and its
/// secret forgotten, so a link is either whole or dead, never quietly partial.
public struct VaultLinks: Sendable {
    public let client: VaultClient
    public let keys: VaultKeys
    public let secrets: any VaultLinkSecretStore
    /// Where the share page is (`VaultLink.origin(forAPI:)`).
    public let origin: String

    /// The contract's limits on one request.
    public static let maxItems = 500
    public static let maxBodyBytes = 16 * 1024 * 1024
    public static let maxLinkMetaBytes = 256 * 1024
    public static let maxNoteBytes = 16 * 1024
    /// Grant ids are random; three in a row taken means something else is wrong.
    static let idAttempts = 3

    var maxItems = VaultLinks.maxItems
    var maxBodyBytes = VaultLinks.maxBodyBytes
    /// Test-only seams: `internal`, so only `@testable` code reaches them.
    var scryptN = VaultCrypto.linkScrypt.n
    var newGrantId: @Sendable () -> String = { VaultCrypto.newGrantId() }

    public init(client: VaultClient, keys: VaultKeys, secrets: any VaultLinkSecretStore, origin: String? = nil) {
        self.client = client; self.keys = keys; self.secrets = secrets
        self.origin = origin ?? VaultLink.origin(forAPI: client.connection.url)
    }

    var shopId: String { client.connection.shopId }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// A password under `VaultCrypto.linkPasswordMinimum` characters.
        case weakPassword
        case nothingToShare
        /// This file cannot be shared as it stands (trashed, no record, …).
        case notShareable(fileId: String, why: String)
        /// One item alone is over the request limit.
        case tooBig(fileId: String)
        /// Three fresh grant ids in a row were taken.
        case noFreeGrantId
        /// A later batch failed after the grant was made. The grant was
        /// revoked (`revoked`), so nothing half-shared is left live.
        case incomplete(grantId: String, sent: Int, total: Int, revoked: Bool, why: String)
        /// This device does not hold the link's secret (another Mac made it).
        case secretNotHere

        public var description: String {
            switch self {
            case .weakPassword: return "A link password needs at least \(VaultCrypto.linkPasswordMinimum) characters."
            case .nothingToShare: return "Nothing to share."
            case .notShareable(let id, let why): return "\(id) cannot be shared: \(why)."
            case .tooBig(let id): return "\(id) is too large to add to a link."
            case .noFreeGrantId: return "No free link id could be found."
            case .incomplete(let id, let sent, let total, let revoked, let why):
                return "The link \(id) got \(sent) of \(total) files (\(why))\(revoked ? "; it was revoked" : "")."
            case .secretNotHere: return "This link was made on another device."
            }
        }
    }

    /// One file to share: its last feed row and the seq this device last saw.
    public struct Source: Sendable {
        public let row: VaultClient.FeedFile
        public let lastSeenSeq: Int?
        public init(row: VaultClient.FeedFile, lastSeenSeq: Int?) { self.row = row; self.lastSeenSeq = lastSeenSeq }
    }

    /// The files for these library record ids, from the sync state. Records
    /// with no vault copy (or a trashed one) come back in `missing`.
    public static func sources(recordIds: [String], state: VaultSyncState) -> (sources: [Source], missing: [String]) {
        var out: [Source] = [], missing: [String] = [], seen: Set<String> = []
        for rid in recordIds {
            guard let fid = state.records[rid], let e = state.files[fid], !e.trashed, let row = e.row,
                  row.headVersion != nil else { missing.append(rid); continue }
            if seen.insert(fid).inserted { out.append(Source(row: row, lastSeenSeq: e.seq)) }
        }
        return (out, missing)
    }

    public struct Options: Sendable, Equatable {
        public var maxDownloads: Int?
        public var perFile = false
        public var expiresAt: Date?
        public var validForSec: Int?
        public var maxDevices: Int?
        /// Nil for none. Must pass `VaultCrypto.linkPasswordOk`.
        public var password: String?
        /// Sealed under the vault key; only this shop's devices read it.
        public var note: String?
        public init(maxDownloads: Int? = nil, perFile: Bool = false, expiresAt: Date? = nil, validForSec: Int? = nil,
                    maxDevices: Int? = nil, password: String? = nil, note: String? = nil) {
            self.maxDownloads = maxDownloads; self.perFile = perFile; self.expiresAt = expiresAt
            self.validForSec = validForSec; self.maxDevices = maxDevices; self.password = password; self.note = note
        }
        var limits: VaultClient.GrantLimits {
            VaultClient.GrantLimits(maxDownloads: maxDownloads, perFile: perFile && maxDownloads != nil ? true : nil,
                                    expiresAt: expiresAt.map(VaultLinks.iso), validForSec: validForSec,
                                    maxDevices: maxDevices)
        }
    }

    public struct Created: Sendable {
        public let link: VaultLink
        public let createdAt: String
        public let items: Int
        /// How many requests it took: 1 for the POST, plus each PATCH.
        public let requests: Int
        /// False when this device could not keep the secret: the link works,
        /// but "Copy link" will not be offered again later.
        public let secretKept: Bool
    }

    static func iso(_ d: Date) -> String { d.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: false)) }

    // MARK: Preparing items

    /// What sharing one file needs, worked out once (independent of the grant id).
    struct Prepared: Sendable {
        let fileId: String
        let version: Int
        let uploadId: String
        let dk: Data
        let meta: VaultCrypto.LinkMeta
    }

    func prepare(_ s: Source) throws -> Prepared {
        let row = s.row
        guard !row.purged, !row.trashed else { throw Failure.notShareable(fileId: row.fileId, why: "in the Trash") }
        guard let v = row.headVersion else { throw Failure.notShareable(fileId: row.fileId, why: "no current version") }
        guard let b64 = v.versionMeta, let sealed = Data(base64Encoded: b64) else {
            throw Failure.notShareable(fileId: row.fileId, why: "no version record")
        }
        // The manifest is the version's own sealed record, as a download pins it.
        let vm = try VaultCrypto.decryptVersionMeta(vaultKey: keys.vaultKey, fileId: row.fileId, uploadId: v.uploadId,
                                                    sealed: sealed, lastSeenSeq: s.lastSeenSeq)
        guard vm.chunkHashes.count == v.chunks, vm.size == v.plaintextSize else {
            throw Failure.notShareable(fileId: row.fileId, why: "the cloud's listing disagrees with the record")
        }
        let meta = try VaultMeta.open(row, vaultKey: keys.vaultKey, lastSeenSeq: nil).meta
        guard let wrapped = Data(base64Encoded: v.wrappedKey) else { throw VaultCrypto.Failure.badInput("wrappedKey") }
        let dk = try VaultCrypto.unwrapDkForShop(vaultKey: keys.vaultKey, wrapped: wrapped, fileId: row.fileId,
                                                 uploadId: v.uploadId)
        let lm = VaultCrypto.LinkMeta(uploadId: v.uploadId, chunkHashes: vm.chunkHashes, chunkBytes: vm.chunkBytes,
                                      manifestHash: vm.manifestHash, name: meta.name, size: vm.size, kind: meta.kind)
        return Prepared(fileId: row.fileId, version: v.version, uploadId: v.uploadId, dk: dk, meta: lm)
    }

    /// Seal prepared files for one grant under its link key.
    static func seal(_ p: [Prepared], grantId: String, linkKey: Data) throws -> [VaultClient.GrantItem] {
        try p.map {
            let wrapped = try VaultCrypto.wrapDkForGrant(linkKey: linkKey, dk: $0.dk, grantId: grantId,
                                                         fileId: $0.fileId, uploadId: $0.uploadId)
            let lm = try VaultCrypto.encryptLinkMeta(linkKey: linkKey, grantId: grantId, fileId: $0.fileId, meta: $0.meta)
            guard lm.base64EncodedString().utf8.count <= maxLinkMetaBytes else { throw Failure.tooBig(fileId: $0.fileId) }
            return VaultClient.GrantItem(fileId: $0.fileId, version: $0.version, wrappedKey: wrapped, linkMeta: lm)
        }
    }

    // MARK: Batching

    /// `{"items":[]}`: a PATCH that only adds items, before its items.
    static var patchEnvelope: Int { jsonBytes(["items": [Any]()]) }

    static func jsonBytes(_ o: Any) -> Int { (try? JSONSerialization.data(withJSONObject: o))?.count ?? Int.max }

    /// Split `items` into request batches: the first under `firstEnvelope`
    /// (the POST body with no items), the rest under `restEnvelope` (a PATCH
    /// with no items). Each batch has at most `maxItems` items, and its body
    /// at most `maxBytes`: the empty body plus each item's own JSON and one
    /// comma between items, which is exactly how `JSONSerialization` lays an
    /// array out.
    static func batches(_ items: [VaultClient.GrantItem], firstEnvelope: Int, restEnvelope: Int,
                        maxItems: Int, maxBytes: Int) throws -> [[VaultClient.GrantItem]] {
        var out: [[VaultClient.GrantItem]] = []
        var cur: [VaultClient.GrantItem] = []
        var size = firstEnvelope
        for item in items {
            let n = jsonBytes(item.json)
            let envelope = out.isEmpty ? firstEnvelope : restEnvelope
            guard envelope + n <= maxBytes, restEnvelope + n <= maxBytes else { throw Failure.tooBig(fileId: item.fileId) }
            let extra = n + (cur.isEmpty ? 0 : 1)
            if !cur.isEmpty && (cur.count >= maxItems || size + extra > maxBytes) {
                out.append(cur); cur = []; size = restEnvelope
                cur.append(item); size += n
                continue
            }
            cur.append(item); size += extra
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    // MARK: Creating

    /// Make a link to these files. See the type's notes for what is sent.
    public func create(_ sources: [Source], options: Options) async throws -> Created {
        guard !sources.isEmpty else { throw Failure.nothingToShare }
        let password = options.password.flatMap { $0.isEmpty ? nil : $0 }
        if let password, !VaultCrypto.linkPasswordOk(password) { throw Failure.weakPassword }
        let note = options.note.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let prepared = try sources.map(prepare)
        let limits = options.limits

        for _ in 0..<Self.idAttempts {
            let grantId = newGrantId()
            let secret = VaultCrypto.newLinkSecret()
            let linkKey = try VaultCrypto.linkKey(linkSecret: secret, grantId: grantId, password: password,
                                                  scryptN: scryptN)
            let sealedNote = try note.map { try Self.sealNote($0, vaultKey: keys.vaultKey, grantId: grantId) }
            if let sealedNote, sealedNote.base64EncodedString().utf8.count > Self.maxNoteBytes {
                throw VaultCrypto.Failure.badInput("the note is too long")
            }
            let items = try Self.seal(prepared, grantId: grantId, linkKey: linkKey)
            let first = Self.jsonBytes(VaultClient.createBody(grantId: grantId, items: [], limits: limits,
                                                              password: password != nil, ownerNote: sealedNote))
            let rest = Self.patchEnvelope
            let batches = try Self.batches(items, firstEnvelope: first, restEnvelope: rest,
                                           maxItems: maxItems, maxBytes: maxBodyBytes)
            let createdAt: String
            do {
                createdAt = try await client.createGrant(grantId: grantId, items: batches[0], limits: limits,
                                                         password: password != nil, ownerNote: sealedNote)
            } catch VaultClient.Failure.grantExists {
                continue   // someone, somewhere, has this id: a new id, a new secret, everything sealed again
            }
            // Kept BEFORE the rest is sent, so a half-made link can still be
            // found and revoked by this device if the app dies mid-way.
            let kept = await secrets.save(VaultLinkSecret(secret: secret, linkKey: linkKey), shopId: shopId,
                                          grantId: grantId)
            var sent = batches[0].count
            for batch in batches.dropFirst() {
                do {
                    try await client.patchGrant(grantId, VaultClient.GrantPatch(items: batch))
                    sent += batch.count
                } catch {
                    let revoked = (try? await client.patchGrant(grantId, VaultClient.GrantPatch(revoke: true))) != nil
                    await secrets.forget(shopId: shopId, grantId: grantId)
                    throw Failure.incomplete(grantId: grantId, sent: sent, total: items.count, revoked: revoked,
                                             why: String(describing: error))
                }
            }
            return Created(link: try VaultLink(origin: origin, grantId: grantId, secret: secret), createdAt: createdAt,
                           items: items.count, requests: batches.count, secretKept: kept)
        }
        throw Failure.noFreeGrantId
    }

    // MARK: Keeping

    public func list() async throws -> [VaultClient.Grant] { try await client.grants() }
    public func events(_ grantId: String) async throws -> [VaultClient.GrantEvent] { try await client.grantEvents(grantId) }

    /// The link again, for "Copy link", when this device made it.
    public func link(_ grantId: String) async -> VaultLink? {
        guard let s = await secrets.load(shopId: shopId, grantId: grantId) else { return nil }
        return try? VaultLink(origin: origin, grantId: grantId, secret: s.secret)
    }

    @discardableResult
    public func addDownloads(_ grantId: String, _ n: Int) async throws -> VaultClient.Grant {
        guard n > 0 else { throw VaultCrypto.Failure.badInput("addDownloads must be positive") }
        return try await client.patchGrant(grantId, VaultClient.GrantPatch(addDownloads: n))
    }

    /// A new end date, or none (`nil`).
    @discardableResult
    public func extend(_ grantId: String, to date: Date?) async throws -> VaultClient.Grant {
        try await client.patchGrant(grantId, VaultClient.GrantPatch(expiresAt: date.map { .at(Self.iso($0)) } ?? .never))
    }

    /// Revoke, and forget the secret: a dead link is never copied again.
    @discardableResult
    public func revoke(_ grantId: String) async throws -> VaultClient.Grant {
        let g = try await client.patchGrant(grantId, VaultClient.GrantPatch(revoke: true))
        await secrets.forget(shopId: shopId, grantId: grantId)
        return g
    }

    /// Add files to a link, or move files on it to their newer heads. Needs
    /// the link key this device kept when it made the link.
    @discardableResult
    public func addItems(_ grantId: String, _ sources: [Source]) async throws -> VaultClient.Grant {
        guard !sources.isEmpty else { throw Failure.nothingToShare }
        guard let kept = await secrets.load(shopId: shopId, grantId: grantId) else { throw Failure.secretNotHere }
        let items = try Self.seal(try sources.map(prepare), grantId: grantId, linkKey: kept.linkKey)
        let rest = Self.patchEnvelope
        var last: VaultClient.Grant?
        for batch in try Self.batches(items, firstEnvelope: rest, restEnvelope: rest, maxItems: maxItems,
                                      maxBytes: maxBodyBytes) {
            last = try await client.patchGrant(grantId, VaultClient.GrantPatch(items: batch))
        }
        return last!
    }

    @discardableResult
    public func removeItems(_ grantId: String, fileIds: [String]) async throws -> VaultClient.Grant {
        guard !fileIds.isEmpty else { throw Failure.nothingToShare }
        var last: VaultClient.Grant?
        for start in stride(from: 0, to: fileIds.count, by: maxItems) {
            let part = Array(fileIds[start..<min(fileIds.count, start + maxItems)])
            last = try await client.patchGrant(grantId, VaultClient.GrantPatch(removeItems: part))
        }
        return last!
    }

    // MARK: The owner's note

    /// The note is the shop's own memo about a link ("for Sara, the kit"). It
    /// is sealed under the vault key, so only the shop's devices read it, with
    /// AAD `"khayt-grant-note|" + grantId` so the server cannot move one
    /// link's note onto another. A client label, not part of format v1:
    /// the share page never sees it (`docs/vault-format.md` "Client state").
    static let noteAad = "khayt-grant-note"

    static func sealNote(_ text: String, vaultKey: Data, grantId: String) throws -> Data {
        try VaultCrypto.sealWithNonce(vaultKey, Data(text.utf8),
                                      aad: Data((noteAad + "|" + (try VaultCrypto.id(grantId, "grantId"))).utf8),
                                      nonce: nil)
    }

    /// The grant's note, or nil when it has none or it will not open.
    public func note(_ grant: VaultClient.Grant) -> String? {
        guard let b64 = grant.ownerNote, let sealed = Data(base64Encoded: b64),
              let id = try? VaultCrypto.id(grant.grantId, "grantId"),
              let pt = try? VaultCrypto.openWithNonce(keys.vaultKey, sealed, aad: Data((Self.noteAad + "|" + id).utf8))
        else { return nil }
        return String(data: pt, encoding: .utf8)
    }

    // MARK: The recipient's side

    /// What a recipient holding only the link (and the password) gets from
    /// one item the public route `GET /v1/s/{grantId}` lists: the file's DK
    /// and its link meta, whose manifest every chunk is then checked against.
    /// A wrong password, or none for a password link, throws
    /// `VaultCrypto.Failure.authentication`.
    public static func open(_ link: VaultLink, password: String?, fileId: String, wrappedKey: Data,
                            linkMeta: Data) throws -> (dk: Data, meta: VaultCrypto.LinkMeta) {
        try open(link, password: password, fileId: fileId, wrappedKey: wrappedKey, linkMeta: linkMeta,
                 scryptN: VaultCrypto.linkScrypt.n)
    }

    static func open(_ link: VaultLink, password: String?, fileId: String, wrappedKey: Data, linkMeta: Data,
                     scryptN: Int) throws -> (dk: Data, meta: VaultCrypto.LinkMeta) {
        let lk = try VaultCrypto.linkKey(linkSecret: link.secret, grantId: link.grantId,
                                         password: password.flatMap { $0.isEmpty ? nil : $0 }, scryptN: scryptN)
        let meta = try VaultCrypto.decryptLinkMeta(linkKey: lk, grantId: link.grantId, fileId: fileId, sealed: linkMeta)
        let dk = try VaultCrypto.unwrapDkForGrant(linkKey: lk, wrapped: wrappedKey, grantId: link.grantId,
                                                  fileId: fileId, uploadId: meta.uploadId)
        return (dk, meta)
    }
}
