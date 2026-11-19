import Foundation
import Network
import CryptoKit
import KhaytCore

/// ── A PAIRED SLICER PLUGIN SENDS ITS SLICES (Khayt for OrcaSlicer) ───────
///
/// The routes a connector (`LanDevices.kindConnector`, paired through
/// `LanConnectorPairing`) may call, and nothing else
/// (docs: ~/Khayt-proposals/connector-routes-design.md, approved Nov 16):
///
///   GET    /api/connectors/self                 who am I, the shop's name, the limits
///   DELETE /api/connectors/self                 unpair from the plugin's side
///   POST   /api/connectors/slices               announce a capture (sealed, ≤ 64 KB)
///   PUT    /api/connectors/slices/{id}/file     the G-code, judged at its head
///   GET    /api/connectors/slices/{id}          that slice's state, nothing more
///
/// Every other `/api/connectors/*` path is 404 for every verb — there is no
/// pause, resume or stop, and no print is ever started from here.
///
/// ── DARK WHILE "PAIR A SLICER" IS OFF ────────────────────────────────────
///
/// Every route here answers the ordinary 404 while `LanConnectorPairing` is
/// disabled (the beta.38 flag, default OFF), exactly like the pairing.
///
/// ── INBOX-FIRST ──────────────────────────────────────────────────────────
///
/// A file lands in the "From slicer" inbox (`SlicerInbox`) and NOTHING in the
/// book is written: no job, quote, client, spool or activity row. What the
/// plugin asked for (`quote`, `job`, `attach`, `print`) is kept beside the
/// item as `suggested`, for the shop to act on or not.
///
/// ── WHAT IS SIGNED, WHAT IS SEALED ───────────────────────────────────────
///
/// Requests are signed as a phone's are (`khayt-req-v1`). Answers are signed
/// back (`x-khayt-reply-mac`), so a device on the Wi-Fi cannot forge "in the
/// inbox". The capture is sealed (AES-256-GCM under a key derived from the
/// pairing key): what was sliced, for whom by name, is not readable on the
/// Wi-Fi. The G-code itself goes in clear ON THE LAN ONLY, bound by the
/// SHA-256 the sealed capture declared and the signed head repeats. A Cloud
/// relay must NOT reuse this shape: there the file is sealed end to end.
extension LanServer {

    // MARK: - Limits

    nonisolated static let connectorMaxMetaBytes = 64 * 1024
    /// A sealed 64 KB capture, base64 and the envelope around it.
    nonisolated static let connectorMaxSealedBytes = 96 * 1024
    /// An announced slice waits this long for its file, then expires.
    nonisolated static let connectorAwaitSeconds: TimeInterval = 600
    /// A file whose bytes do not hash to what was declared may be sent once
    /// more; the second mismatch expires the slice.
    nonisolated static let connectorMaxAttempts = 2
    /// Slices remembered at most.
    nonisolated static let connectorMaxSlices = 1000
    /// An expired slice is forgotten a day after it expired; one that left
    /// the inbox, a week after (Dev Hub, Nov 16).
    nonisolated static let connectorKeepExpired: TimeInterval = 24 * 3600
    nonisolated static let connectorKeepLeft: TimeInterval = 7 * 24 * 3600

    struct ConnectorRateRule: Sendable { let limit: Int; let window: TimeInterval }
    /// Per connector, by bucket. The queue's own (1 per 10 s) comes with its route.
    nonisolated static let connectorRates: [String: ConnectorRateRule] = [
        "all": .init(limit: 600, window: 3600),
        "announce": .init(limit: 30, window: 3600),
        "file": .init(limit: 30, window: 3600),
        // The tab polls every 15 s while visible, 60 s hidden, with an ETag.
        "queue": .init(limit: 1, window: 10),
        // Once after each export, and again after a quantity change settles
        // (600 ms): a person at a stepper, not a loop.
        "price": .init(limit: 120, window: 3600),
    ]

    nonisolated static let connectorSealSalt = "khayt-connector-seal-v1"
    /// A price request's facts, opened (plan: ≤ 8 KB).
    nonisolated static let connectorPriceMaxBytes = 8 * 1024
    nonisolated static let connectorEtagSalt = "khayt-connector-etag-v1"
    nonisolated static let connectorReplyPrefix = "khayt-reply-v1"
    /// The header a file upload names its body's hash in; the signature
    /// covers it (the canonical request carries that hash).
    nonisolated static let connectorHashHeader = "x-khayt-content-sha256"

    /// On while pairing a slicer is: the window's own answer in a test bench,
    /// else the app's flag.
    var connectorsOn: Bool { host.connectorPairing?.enabledHere ?? LanConnectorPairing.enabled }

    // MARK: - Slices

    enum SliceState: String, Sendable, Codable {
        case awaitingFile = "awaiting-file"
        /// A file is arriving for it now; shown as `awaiting-file`.
        case receiving
        case inInbox = "in-inbox"
        /// Taken into a job/the library, or thrown away, by the shop. Which
        /// one is the shop's business, not the plugin's.
        case leftInbox = "left-inbox"
        case expired
    }

    struct ConnectorSlice: Sendable, Equatable {
        let id: String
        let connectorId: String
        /// The file name, the suggestion and the slots: in memory only, never
        /// on disk (a file name can hold a client's name). Empty for a slice
        /// read back after a restart, which is why such a slice cannot take a
        /// file any more (`loadSlices`).
        let name: String
        let bytes: Int
        let sha256: String
        let suggested: JSONValue
        let slots: JSONValue?
        let uploadBy: Date
        var state: SliceState
        var attempts = 0
        var inboxId: String?
        /// When `state` last changed, on the wall clock (`host.now`).
        var changedAt: Date

        /// What is kept on disk: ids, state, hash, size, times. No names.
        struct Saved: Codable, Equatable {
            var id, connectorId, sha256: String
            var bytes: Int
            var state: SliceState
            var uploadBy, changedAt: Date
            var attempts: Int
            var inboxId: String?
        }
        var saved: Saved {
            Saved(id: id, connectorId: connectorId, sha256: sha256, bytes: bytes, state: state,
                  uploadBy: uploadBy, changedAt: changedAt, attempts: attempts, inboxId: inboxId)
        }
    }

    /// 16 characters of RFC 4648 base32: 80 random bits.
    nonisolated static func freshSliceId() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var rng = SystemRandomNumberGenerator()
        return String((0..<16).map { _ in alphabet.randomElement(using: &rng)! })
    }

    nonisolated static func plausibleSliceId(_ id: String) -> Bool {
        id.count == 16 && id.allSatisfy { ("A"..."Z").contains($0) || ("2"..."7").contains($0) }
    }

    /// Expire what waited past `uploadBy`, forget what is old, keep the map
    /// bounded. On the wall clock: the records outlive the app.
    func pruneSlices() {
        loadSlices()
        let now = host.now()
        for (id, slice) in connectorSlices {
            switch slice.state {
            case .awaitingFile where now > slice.uploadBy:
                setSlice(id, .expired)
            case .expired where now.timeIntervalSince(slice.changedAt) > Self.connectorKeepExpired,
                 .leftInbox where now.timeIntervalSince(slice.changedAt) > Self.connectorKeepLeft:
                connectorSlices[id] = nil
            default: break
            }
        }
        if connectorSlices.count > Self.connectorMaxSlices {
            let oldest = connectorSlices.values.sorted { $0.changedAt < $1.changedAt }
                .prefix(connectorSlices.count - Self.connectorMaxSlices)
            for slice in oldest { connectorSlices[slice.id] = nil }
        }
    }

    /// A slice's state, and when it changed.
    func setSlice(_ id: String, _ state: SliceState) {
        guard connectorSlices[id] != nil else { return }
        connectorSlices[id]?.state = state
        connectorSlices[id]?.changedAt = host.now()
    }

    // MARK: - Kept across a restart (beside the inbox, never in the book)

    /// Read the records once, on first use. A slice that was waiting for its
    /// file (or receiving one) when the app stopped is expired: its file name
    /// was never written down, so it could not be filed — the plugin announces
    /// again. The rest are kept for the plugin's "where is it" and the dedupe.
    func loadSlices() {
        guard !slicesLoaded else { return }
        slicesLoaded = true
        guard let dir = host.sliceFolder,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [String: ConnectorSlice] = [:]
        for file in names where file.hasSuffix(".json") {
            let url = dir.appending(path: file)
            guard let data = try? Data(contentsOf: url), let s = try? decoder.decode(ConnectorSlice.Saved.self, from: data),
                  Self.plausibleSliceId(s.id), file == s.id + ".json" else {
                try? FileManager.default.removeItem(at: url) // scratch: an unreadable slice record
                continue
            }
            let waiting = s.state == .awaitingFile || s.state == .receiving
            loaded[s.id] = ConnectorSlice(
                id: s.id, connectorId: s.connectorId, name: "", bytes: s.bytes, sha256: s.sha256,
                suggested: .object([:]), slots: nil, uploadBy: s.uploadBy,
                state: waiting ? .expired : s.state, attempts: s.attempts, inboxId: s.inboxId,
                changedAt: waiting ? host.now() : s.changedAt)
        }
        connectorSlices = loaded
    }

    /// Write what changed, remove what went: one small JSON per slice,
    /// written atomically. Called from `connectorSlices`' observer.
    func persistSlices(old: [String: ConnectorSlice]) {
        guard let dir = host.sliceFolder else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        for (id, slice) in connectorSlices where old[id]?.saved != slice.saved {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = try? encoder.encode(slice.saved) {
                try? data.write(to: dir.appending(path: id + ".json"), options: .atomic)
            }
        }
        for id in old.keys where connectorSlices[id] == nil {
            try? FileManager.default.removeItem(at: dir.appending(path: id + ".json")) // scratch: a forgotten slice's record
        }
    }

    /// The slice by id, only for the connector that announced it: anyone
    /// else's is the same "not here" as none at all.
    func ownSlice(_ id: String, connector: String) -> ConnectorSlice? {
        pruneSlices()
        guard let slice = connectorSlices[id], slice.connectorId == connector else { return nil }
        return slice
    }

    // MARK: - Paths

    enum ConnectorPath: Equatable {
        case pair, me, slices, slice(String), sliceFile(String), queue, price, unknown
    }

    /// Exact shapes only, never a prefix match. Nil when not a connector path.
    nonisolated static func connectorPath(_ path: String) -> ConnectorPath? {
        guard path.hasPrefix(LanDevices.connectorPrefix) else { return nil }
        let rest = String(path.dropFirst(LanDevices.connectorPrefix.count))
        if rest == "pair" || rest.hasPrefix("pair/") { return .pair }
        if rest == "self" { return .me }
        if rest == "slices" { return .slices }
        if rest == "queue" { return .queue }
        if rest == "price" { return .price }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2, parts[0] == "slices", plausibleSliceId(parts[1]) { return .slice(parts[1]) }
        if parts.count == 3, parts[0] == "slices", plausibleSliceId(parts[1]), parts[2] == "file" {
            return .sliceFile(parts[1])
        }
        return .unknown
    }

    /// The file upload, from the request line alone (`readRequest`).
    nonisolated static func isConnectorFileUpload(method: String, target: String) -> Bool {
        guard method.uppercased() == "PUT" else { return false }
        let raw = String(target.split(separator: "?", maxSplits: 1).first ?? "")
        if case .sliceFile? = connectorPath(routePath(raw)) { return true }
        return false
    }

    func connectorNotFound() async -> Response {
        .json(404, (try? await host.engine.lanNotFoundBody(endpoints: Self.endpoints)) ?? #"{"error":"Not found"}"#)
    }

    // MARK: - Who is asking

    struct ConnectorCaller {
        let id: String
        let name: String
        let key: Data
        let nonce: String
    }

    enum ConnectorGate {
        case pass(ConnectorCaller)
        case refused(Response)
    }

    /// A signed request from an enrolled connector, or the refusal: 421 off
    /// the local network, 401 unsigned or a bad signature, 403
    /// `connector-only` for a phone's key, the PIN or an API token.
    /// `bodyHash` verifies a head whose body is not read yet.
    func connectorGate(_ request: Request, bodyHash: String? = nil) -> ConnectorGate {
        guard Self.hostIsLocal(request.headers["host"]) else {
            return .refused(.json(421, #"{"error":"host-not-local"}"#))
        }
        let only = Response.json(403, #"{"ok":false,"reason":"connector-only"}"#)
        guard LanDevices.isSigned(request.headers), let id = request.headers["x-khayt-device"] else {
            let other = request.headers["x-khayt-pin"] != nil || request.headers["authorization"] != nil
            return .refused(other ? only : .json(401, #"{"reason":"device-auth"}"#))
        }
        // A connector was enrolled under the PIN in force; with none set (or
        // one too short) nothing signed opens, as for a phone (`pinGate`).
        guard !host.pin.isEmpty, !Self.pinTooShort(host.pin) else {
            return .refused(.json(401, #"{"reason":"device-unknown"}"#))
        }
        let verdict = host.devices.verify(headers: request.headers, method: request.method,
                                          target: request.target.isEmpty ? request.path : request.target,
                                          body: request.body, pin: host.pin, now: host.now(),
                                          bodyHash: bodyHash)
        guard verdict == .pass else { return .refused(.json(401, LanDevices.body(verdict))) }
        // Signed, and good — by a phone, which these routes are not for.
        guard let known = host.devices.connector(id) else { return .refused(only) }
        return .pass(ConnectorCaller(id: id, name: known.name, key: known.key,
                                     nonce: request.headers["x-khayt-nonce"] ?? ""))
    }

    /// One step of a per-connector limit: nil when allowed (and counted),
    /// else the 429 with `Retry-After`.
    func connectorRate(_ id: String, _ bucket: String) -> Response? {
        guard let rule = Self.connectorRates[bucket] else { return nil }
        let now = host.lockoutClock()
        var hits = (connectorHits[id]?[bucket] ?? []).filter { now - $0 < rule.window }
        if hits.count >= rule.limit, let oldest = hits.first {
            connectorHits[id, default: [:]][bucket] = hits
            let wait = max(1, Int((oldest + rule.window - now).rounded(.up)))
            var r = Response.json(429, #"{"ok":false,"reason":"rate","retryAfter":\#(wait)}"#)
            r.headers["Retry-After"] = String(wait)
            return r
        }
        hits.append(now)
        connectorHits[id, default: [:]][bucket] = hits
        if connectorHits.count > 4 * LanDevices.maxDevices {
            connectorHits = connectorHits.filter { entry in
                entry.value.values.contains { times in times.last.map { now - $0 < 3600 } ?? false }
            }
        }
        return nil
    }

    // MARK: - Signing answers, sealing bodies

    nonisolated static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// `HMAC(K, "khayt-reply-v1\n" + requestNonce + "\n" + status + "\n" + sha256hex(body))`, base64.
    nonisolated static func replyMac(key: Data, nonce: String, status: Int, body: Data) -> String {
        let text = [connectorReplyPrefix, nonce, String(status), hex(SHA256.hash(data: body))].joined(separator: "\n")
        return Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key)))
            .base64EncodedString()
    }

    func signedReply(_ response: Response, for caller: ConnectorCaller) -> Response {
        var r = response
        r.headers["x-khayt-reply-mac"] = Self.replyMac(key: caller.key, nonce: caller.nonce,
                                                       status: r.status, body: r.body)
        r.headers["Cache-Control"] = "no-store"
        return r
    }

    /// `HKDF-SHA256(K, salt "khayt-connector-seal-v1", info connectorId)`, 32 bytes.
    nonisolated static func sealKey(_ key: Data, connectorId: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key), salt: Data(connectorSealSalt.utf8),
                               info: Data(connectorId.utf8), outputByteCount: 32)
    }

    /// The queue's ETag: `HMAC-SHA256(HKDF(K, salt "khayt-connector-etag-v1",
    /// info connectorId), content)`, 32 hex digits, quoted.
    ///
    /// The ETag travels in the clear while the queue itself is sealed. A plain
    /// SHA-256 of the content (as it was) let anyone on the network confirm a
    /// guess about a shop's queue (job numbers and stages are a small space)
    /// without the key. Keyed by the connector's own key, it says only "same
    /// as before", and two plugins never share one. The plugin only echoes it.
    nonisolated static func queueEtag(_ content: String, key: Data, connectorId: String) -> String {
        let etagKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key),
                                             salt: Data(connectorEtagSalt.utf8),
                                             info: Data(connectorId.utf8), outputByteCount: 32)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(content.utf8), using: etagKey)
        return "\"" + String(hex(Data(mac)).prefix(32)) + "\""
    }

    /// What a sealed body is bound to: `METHOD + " " + path`, so a capture
    /// cannot be replayed as another route's body.
    nonisolated static func sealAad(method: String, path: String) -> Data {
        Data((method.uppercased() + " " + path).utf8)
    }

    /// `{"v":1,"alg":"A256GCM","nonce":b64(12),"ct":b64(ciphertext ‖ tag)}`.
    nonisolated static func seal(_ plain: Data, key: SymmetricKey, aad: Data,
                                 nonce: AES.GCM.Nonce = AES.GCM.Nonce()) -> Data? {
        guard let box = try? AES.GCM.seal(plain, using: key, nonce: nonce, authenticating: aad) else { return nil }
        let envelope: JSONValue = .object([
            "v": .number(1), "alg": .string("A256GCM"),
            "nonce": .string(box.nonce.withUnsafeBytes { Data($0) }.base64EncodedString()),
            "ct": .string((box.ciphertext + box.tag).base64EncodedString()),
        ])
        return Data(jsonText(envelope).utf8)
    }

    /// The plain bytes of a sealed body, or nil when anything about it is off.
    nonisolated static func unseal(_ sealed: Data, key: SymmetricKey, aad: Data) -> Data? {
        guard case .object(let e)? = try? JSONDecoder().decode(JSONValue.self, from: sealed),
              case .number(let v)? = e["v"], v == 1, case .string("A256GCM")? = e["alg"],
              case .string(let n)? = e["nonce"], let nonceData = Data(base64Encoded: n), nonceData.count == 12,
              case .string(let c)? = e["ct"], let ct = Data(base64Encoded: c), ct.count >= 16,
              let nonce = try? AES.GCM.Nonce(data: nonceData),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ct.dropLast(16), tag: ct.suffix(16))
        else { return nil }
        return try? AES.GCM.open(box, using: key, authenticating: aad)
    }

    // MARK: - The routes

    /// The connector routes, or nil when `path` is not one (the pairing
    /// routes are `route`'s own). Runs before any other route.
    func connectorRoute(_ request: Request, path: String) async -> Response? {
        guard let shape = Self.connectorPath(path), shape != .pair else { return nil }
        guard connectorsOn else { return await connectorNotFound() }
        let method = request.method == "HEAD" ? "GET" : request.method
        let allowed: [String]
        switch shape {
        case .pair, .unknown: return await connectorNotFound()
        case .me: allowed = ["GET", "DELETE"]
        case .slices: allowed = ["POST"]
        case .slice: allowed = ["GET"]
        case .sliceFile: allowed = ["PUT"]
        case .queue: allowed = ["GET"]
        case .price: allowed = ["POST"]
        }
        guard allowed.contains(method) else {
            var r = Response.json(405, #"{"ok":false,"reason":"method"}"#)
            r.headers["Allow"] = allowed.joined(separator: ", ")
            return r
        }
        // The file was judged, verified and spooled at its head
        // (`readConnectorFile`); here it is only filed.
        if case .sliceFile(let sliceId) = shape {
            guard let sha = request.spooledSha256, let id = request.headers["x-khayt-device"],
                  let known = host.devices.connector(id) else { return await connectorNotFound() }
            let caller = ConnectorCaller(id: id, name: known.name, key: known.key,
                                         nonce: request.headers["x-khayt-nonce"] ?? "")
            return signedReply(await connectorFileArrived(request, sliceId: sliceId, sha: sha, caller: caller), for: caller)
        }
        let caller: ConnectorCaller
        switch connectorGate(request) {
        case .refused(let r): return r
        case .pass(let c): caller = c
        }
        if let limited = connectorRate(caller.id, "all") { return signedReply(limited, for: caller) }
        let answer: Response
        switch (shape, method) {
        case (.me, "GET"): answer = await connectorSelf(caller)
        case (.me, _):
            connectorSlices = connectorSlices.filter { $0.value.connectorId != caller.id }
            connectorHits[caller.id] = nil
            host.devices.remove(caller.id)
            answer = .json(200, #"{"ok":true}"#)
        case (.slices, _):
            if let limited = connectorRate(caller.id, "announce") { return signedReply(limited, for: caller) }
            answer = await connectorAnnounce(request, path: path, caller: caller)
        case (.slice(let sliceId), _):
            answer = connectorSliceState(sliceId, caller: caller)
        case (.queue, _):
            if let limited = connectorRate(caller.id, "queue") { return signedReply(limited, for: caller) }
            answer = await connectorQueue(request, path: path, caller: caller)
        case (.price, _):
            if let limited = connectorRate(caller.id, "price") { return signedReply(limited, for: caller) }
            answer = await connectorPrice(request, path: path, caller: caller)
        default:
            answer = await connectorNotFound()
        }
        return signedReply(answer, for: caller)
    }

    func connectorSelf(_ caller: ConnectorCaller) async -> Response {
        let shop = (try? await host.engine.lanQuoteShopName(store: .object(host.store()))) ?? "Khayt"
        let body: JSONValue = .object([
            "connectorId": .string(caller.id),
            "name": .string(caller.name),
            "shop": .object(["name": .string(shop)]),
            "limits": .object([
                "maxFileBytes": .number(Double(min(host.slicerMaxBytes, Self.maxInflate))),
                "maxMetaBytes": .number(Double(Self.connectorMaxMetaBytes)),
            ]),
            "scopes": .array(connectorScopes(caller.id).map(JSONValue.string)),
        ])
        return .json(200, Self.jsonText(body))
    }

    /// What this connector may do right now. `price:read` (and `cost:read`
    /// with the second grant) only while the shop shows prices in OrcaSlicer
    /// AND has granted this device: the tab draws a price block only then.
    func connectorScopes(_ id: String) -> [String] {
        var scopes = ["slices:send", "queue:read"]
        if let grant = connectorPriceGrant(id) {
            scopes.append("price:read")
            if grant == "cost" { scopes.append("cost:read") }
        }
        return scopes
    }

    /// The grant that is in force: none while the shop's switch is off.
    func connectorPriceGrant(_ id: String) -> String? {
        guard host.connectorPrices(), host.slicePriceContext != nil else { return nil }
        return host.devices.priceGrant(id)
    }

    /// The keys a device with the `price` grant sees; `cost` adds `cost` and
    /// `margin`. An ALLOW-list: a key the rule adds later is not passed on
    /// until somebody decides who may see it.
    nonisolated static let priceKeys = ["currency", "qty", "unit", "total", "rounded", "basis"]
    nonisolated static let costKeys = ["cost", "margin"]

    /// `POST /api/connectors/price`: the shop's price for a sliced plate, from
    /// the plugin's slice facts, priced by the shared rule
    /// (`lib/connector-price.js`) and sealed. Nothing is stored: no job, no
    /// quote, no inbox item, no log of the figures.
    ///
    /// Off (the shop's switch, or no grant for this device) is a 200
    /// `{"prices":"off"}`, never a 404: a 404 already means "an older Mac, or
    /// pairing switched off", and the tab must not say that when the shop
    /// simply chose not to show prices. A device granted `price` never sees
    /// the cost or margin, though the rule always works them out.
    func connectorPrice(_ request: Request, path: String, caller: ConnectorCaller) async -> Response {
        guard request.body.count <= Self.connectorMaxSealedBytes else {
            return .json(413, #"{"ok":false,"reason":"too-large"}"#)
        }
        let key = Self.sealKey(caller.key, connectorId: caller.id)
        let aad = Self.sealAad(method: "POST", path: path)
        guard let plain = Self.unseal(request.body, key: key, aad: aad) else {
            return .json(400, #"{"ok":false,"reason":"seal"}"#)
        }
        guard plain.count <= Self.connectorPriceMaxBytes else {
            return .json(413, #"{"ok":false,"reason":"too-large"}"#)
        }
        guard let facts = try? JSONDecoder().decode(JSONValue.self, from: plain) else {
            return .json(400, #"{"ok":false,"reason":"not-json"}"#)
        }
        var answer: [String: JSONValue] = ["prices": .string("off")]
        if let grant = connectorPriceGrant(caller.id), let context = host.slicePriceContext?() {
            guard case .object(let priced)? = try? await host.engine.connectorPrice(facts: facts, context: context) else {
                return .json(500, #"{"ok":false,"reason":"price"}"#)
            }
            answer = Self.priceAnswer(priced, grant: grant)
        }
        guard let sealed = Self.seal(Data(Self.jsonText(.object(answer)).utf8), key: key, aad: aad) else {
            return .json(500, #"{"ok":false,"reason":"seal"}"#)
        }
        return Response(status: 200, headers: ["Content-Type": "application/json"], body: sealed)
    }

    /// What one grant sees of the rule's answer: `{"prices":"on", ...}`.
    nonisolated static func priceAnswer(_ priced: [String: JSONValue], grant: String) -> [String: JSONValue] {
        var out: [String: JSONValue] = ["prices": .string("on")]
        if let why = priced["unpriced"] {
            out["unpriced"] = why
            return out
        }
        for key in priceKeys { if let v = priced[key] { out[key] = v } }
        if grant == "cost" { for key in costKeys { if let v = priced[key] { out[key] = v } } }
        return out
    }

    func connectorSliceState(_ sliceId: String, caller: ConnectorCaller) -> Response {
        guard let slice = ownSlice(sliceId, connector: caller.id) else {
            return .json(404, #"{"ok":false,"reason":"unknown-slice"}"#)
        }
        var state = slice.state
        if state == .receiving { state = .awaitingFile }
        if state == .inInbox, let inboxId = slice.inboxId, !host.slicerInbox().contains(where: { $0.id == inboxId }) {
            state = .leftInbox
            setSlice(sliceId, .leftInbox)
        }
        return .json(200, Self.jsonText(["sliceId": .string(sliceId), "state": .string(state.rawValue)]))
    }

    /// `POST /api/connectors/slices`: open the capture, check it with the
    /// shared rule (`lib/connector-slice.js`), and hand back where to send
    /// the file — or say the same bytes are already in the inbox.
    func connectorAnnounce(_ request: Request, path: String, caller: ConnectorCaller) async -> Response {
        guard request.body.count <= Self.connectorMaxSealedBytes else {
            return .json(413, #"{"ok":false,"reason":"too-large"}"#)
        }
        let key = Self.sealKey(caller.key, connectorId: caller.id)
        guard let plain = Self.unseal(request.body, key: key, aad: Self.sealAad(method: "POST", path: path)) else {
            return .json(400, #"{"ok":false,"reason":"seal"}"#)
        }
        guard plain.count <= Self.connectorMaxMetaBytes else {
            return .json(413, #"{"ok":false,"reason":"too-large"}"#)
        }
        guard let input = try? JSONDecoder().decode(JSONValue.self, from: plain) else {
            return .json(400, #"{"ok":false,"reason":"not-json"}"#)
        }
        let maxFile = min(host.slicerMaxBytes, Self.maxInflate)
        guard case .object(let checked)? = try? await host.engine.connectorCheckSlice(input, maxFileBytes: maxFile) else {
            return .json(500, #"{"ok":false,"reason":"check"}"#)
        }
        guard case .bool(true)? = checked["ok"], case .object(let capture)? = checked["capture"],
              case .object(let file)? = capture["file"],
              case .string(let name)? = file["name"], case .number(let bytes)? = file["bytes"],
              case .string(let sha)? = file["sha256"] else {
            var refusal: [String: JSONValue] = ["ok": .bool(false), "reason": checked["reason"] ?? .string("capture")]
            if let field = checked["field"] { refusal["field"] = field }
            return .json(422, Self.jsonText(refusal))
        }
        let suggested = capture["suggested"] ?? .object(["intent": .string("inbox")])
        let dropped = checked["dropped"] ?? .array([])
        pruneSlices()

        // The same bytes already waiting, whichever way they came in.
        if let held = host.slicerInbox().first(where: { $0.sha256 == sha }) {
            host.slicerDuplicateSeen(name)
            let mine = connectorSlices.values.first { $0.connectorId == caller.id && $0.inboxId == held.id }
            let sliceId = mine?.id ?? Self.freshSliceId()
            if mine == nil {
                connectorSlices[sliceId] = ConnectorSlice(
                    id: sliceId, connectorId: caller.id, name: name, bytes: Int(bytes), sha256: sha,
                    suggested: suggested, slots: capture["filaments"],
                    uploadBy: host.now(), state: .inInbox, inboxId: held.id, changedAt: host.now())
            }
            return .json(200, Self.jsonText(["sliceId": .string(sliceId), "state": .string("in-inbox"),
                                             "duplicate": .bool(true)]))
        }
        // Announced already and still waiting for its file: the same slice.
        if let waiting = connectorSlices.values.first(where: {
            $0.connectorId == caller.id && $0.sha256 == sha && ($0.state == .awaitingFile || $0.state == .receiving)
        }) {
            return .json(200, Self.jsonText(["sliceId": .string(waiting.id), "state": .string("awaiting-file"),
                                             "uploadBy": .string(Self.isoTime(waiting.uploadBy))]))
        }
        guard host.slicerInbox().count < SlicerInbox.maxWaiting else {
            return .json(409, #"{"ok":false,"reason":"inbox-full"}"#)
        }
        let sliceId = Self.freshSliceId()
        let uploadBy = host.now().addingTimeInterval(Self.connectorAwaitSeconds)
        connectorSlices[sliceId] = ConnectorSlice(
            id: sliceId, connectorId: caller.id, name: name, bytes: Int(bytes), sha256: sha,
            suggested: suggested, slots: capture["filaments"],
            uploadBy: uploadBy, state: .awaitingFile, changedAt: host.now())
        var answer: [String: JSONValue] = [
            "sliceId": .string(sliceId), "state": .string("awaiting-file"),
            "uploadBy": .string(Self.isoTime(uploadBy)), "dropped": dropped,
        ]
        // Asked, and not done: v1 never starts a print, or makes a job.
        if case .object(let s) = suggested, case .string(let intent)? = s["intent"], intent != "inbox" {
            answer["intentHonoured"] = .bool(false)
        }
        return .json(201, Self.jsonText(answer))
    }

    /// `GET /api/connectors/queue`: the redacted queue (`lib/connector-queue.js`:
    /// job number, stage, machine, and the file THIS connector sent — never a
    /// title, a client, a price or a note), sealed, with an ETag over
    /// everything but its time. `If-None-Match` that still holds is a 304.
    func connectorQueue(_ request: Request, path: String, caller: ConnectorCaller) async -> Response {
        let store = host.store()
        let shop = (try? await host.engine.lanQuoteShopName(store: .object(store))) ?? "Khayt"
        guard let pair = try? await host.engine.connectorQueue(
                book: .object(store), connectorId: caller.id, nowMs: host.now().timeIntervalSince1970 * 1000,
                shopName: shop, inboxWaiting: host.slicerInbox().count),
              pair.count == 2 else {
            return .json(500, #"{"ok":false,"reason":"queue"}"#)
        }
        let etag = Self.queueEtag(pair[1], key: caller.key, connectorId: caller.id)
        if let asked = request.headers["if-none-match"],
           asked.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains(etag) {
            var r = Response(status: 304, headers: [:], body: Data())
            r.headers["ETag"] = etag
            return r
        }
        let key = Self.sealKey(caller.key, connectorId: caller.id)
        guard let sealed = Self.seal(Data(pair[0].utf8), key: key, aad: Self.sealAad(method: "GET", path: path)) else {
            return .json(500, #"{"ok":false,"reason":"seal"}"#)
        }
        var r = Response(status: 200, headers: ["Content-Type": "application/json"], body: sealed)
        r.headers["ETag"] = etag
        return r
    }

    nonisolated static func isoTime(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// The file is on disk and hashed; file it, or say why not.
    func connectorFileArrived(_ request: Request, sliceId: String, sha: String,
                              caller: ConnectorCaller) async -> Response {
        guard let file = request.bodyFile else { return .json(404, #"{"ok":false,"reason":"unknown-slice"}"#) }
        // The spool's own folder (`readConnectorFile`), whatever happens below.
        defer {
            let dir = file.deletingLastPathComponent()
            if dir.lastPathComponent.hasPrefix("khayt-connector-") { try? FileManager.default.removeItem(at: dir) } // scratch
        }
        guard var slice = connectorSlices[sliceId], slice.connectorId == caller.id, slice.state == .receiving else {
            return .json(404, #"{"ok":false,"reason":"unknown-slice"}"#)
        }
        guard sha == slice.sha256 else {
            slice.attempts += 1
            let retry = slice.attempts < Self.connectorMaxAttempts
            slice.state = retry ? .awaitingFile : .expired
            slice.changedAt = host.now()
            connectorSlices[sliceId] = slice
            return .json(422, #"{"ok":false,"reason":"hash-mismatch","retry":\#(retry)}"#)
        }
        let origin = SlicerOrigin(connectorId: caller.id, connectorName: caller.name, sliceId: sliceId,
                                  sha256: sha, suggested: slice.suggested, slots: slice.slots)
        do {
            let item = try await host.connectorReceive(file, slice.name, origin)
            setSlice(sliceId, .inInbox)
            connectorSlices[sliceId]?.inboxId = item.id
            return .json(201, Self.jsonText(["sliceId": .string(sliceId), "state": .string("in-inbox")]))
        } catch let same as SlicerInbox.Duplicate {
            setSlice(sliceId, .inInbox)
            connectorSlices[sliceId]?.inboxId = same.item.id
            return .json(200, Self.jsonText(["sliceId": .string(sliceId), "state": .string("in-inbox"),
                                             "duplicate": .bool(true)]))
        } catch is SlicerInbox.Full {
            setSlice(sliceId, .awaitingFile)
            return .json(409, #"{"ok":false,"reason":"inbox-full"}"#)
        } catch {
            setSlice(sliceId, .awaitingFile)
            return .json(500, #"{"ok":false,"reason":"store"}"#)
        }
    }

    // MARK: - The file, judged from its head

    /// `PUT /api/connectors/slices/{id}/file`: every question answered from
    /// the head before ONE byte of body is read (the #2497 path), each
    /// refusal answered and then lingered on:
    ///
    /// 1. off → 404; unsigned/bad signature → 401; not a connector → 403.
    ///    The signature is checked WHOLE here: the canonical request holds
    ///    the body's hash, which the head names (`x-khayt-content-sha256`), so
    ///    the nonce is spent and a stranger never gets a body read.
    /// 2. the head's hash must be the one the capture declared → 409.
    /// 3. the slice: unknown/someone else's/expired → 404; not waiting → 409.
    /// 4. Content-Length exactly the declared bytes (400), within the cap (413).
    /// 5. per-connector file rate → 429; the 2 upload slots shared with the
    ///    OctoPrint path → 503; the disk → 507.
    /// Then `100 Continue`, and the body is spooled and hashed as it lands.
    func readConnectorFile(_ connection: NWConnection, on queue: DispatchQueue, requestLine: [String],
                           headers: [String: String], start: Data, length: Int, remote: String,
                           slot: LargeBodySlot) async throws -> Request {
        let target = requestLine[1]
        let components = URLComponents(string: target.hasPrefix("/") ? "http://localhost\(target)" : target)
        let path = Self.routePath(components?.path ?? target)
        guard connectorsOn, case .sliceFile(let sliceId)? = Self.connectorPath(path) else {
            throw ReadRefusal.refused(await connectorNotFound())
        }
        let probe = Request(method: "PUT", path: components?.path ?? target, query: [:], headers: headers,
                            body: Data(), remote: remote, target: target)
        let declared = (headers[Self.connectorHashHeader] ?? "").lowercased()
        // Without the hash there is nothing to check the signature against.
        guard declared.count == 64, declared.allSatisfy({ $0.isHexDigit }) else {
            throw ReadRefusal.refused(.json(400, #"{"ok":false,"reason":"no-hash"}"#))
        }
        let caller: ConnectorCaller
        switch connectorGate(probe, bodyHash: declared) {
        case .refused(let r): throw ReadRefusal.refused(r)
        case .pass(let c): caller = c
        }
        func refuse(_ status: Int, _ body: String) -> ReadRefusal {
            .refused(signedReply(.json(status, body), for: caller))
        }
        if let limited = connectorRate(caller.id, "all") ?? connectorRate(caller.id, "file") {
            throw ReadRefusal.refused(signedReply(limited, for: caller))
        }
        guard var slice = ownSlice(sliceId, connector: caller.id), slice.state != .expired else {
            throw refuse(404, #"{"ok":false,"reason":"unknown-slice"}"#)
        }
        guard slice.state == .awaitingFile else { throw refuse(409, #"{"ok":false,"reason":"not-awaiting-file"}"#) }
        guard declared == slice.sha256 else { throw refuse(409, #"{"ok":false,"reason":"hash-not-declared"}"#) }
        guard length <= min(host.slicerMaxBytes, Self.maxInflate) else { throw refuse(413, #"{"ok":false,"reason":"too-large"}"#) }
        guard length == slice.bytes else { throw refuse(400, #"{"ok":false,"reason":"length-mismatch"}"#) }
        guard slicerUploads < Self.maxSlicerUploads else { throw refuse(503, #"{"ok":false,"reason":"busy"}"#) }
        try? FileManager.default.createDirectory(at: host.slicerScratch, withIntermediateDirectories: true)
        if let free = (try? FileManager.default.attributesOfFileSystem(forPath: host.slicerScratch.path))?[.systemFreeSize]
            as? NSNumber, free.int64Value < Int64(length) * 2 + 512 * 1024 * 1024 {
            throw refuse(507, #"{"ok":false,"reason":"disk"}"#)
        }
        slicerUploads += 1
        slot.slicer = true
        slice.state = .receiving
        slice.changedAt = host.now()
        connectorSlices[sliceId] = slice
        do {
            if (headers["expect"] ?? "").lowercased() == "100-continue" {
                try await Self.sendRaw(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), on: connection)
            }
            // Under its own name, in a folder of its own: the Mac reads a file's
            // figures by its extension (`SlicerFigures`), and a ".part" is
            // nothing it reads. The folder goes once the file is filed.
            let dir = host.slicerScratch.appending(path: "khayt-connector-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appending(path: slice.name)
            let sha: String
            do {
                sha = try await Self.spool(connection, on: queue, start: start, length: length, to: file, idle: readTimeout)
            } catch {
                try? FileManager.default.removeItem(at: dir) // scratch: a body that never arrived whole
                throw error
            }
            var request = Request(method: "PUT", path: components?.path ?? target, query: [:], headers: headers,
                                  body: Data(), remote: remote, target: target, bodyFile: file)
            request.spooledSha256 = sha
            return request
        } catch {
            // The client went, or stalled: the slice may be sent again.
            if connectorSlices[sliceId]?.state == .receiving { setSlice(sliceId, .awaitingFile) }
            throw error
        }
    }
}
