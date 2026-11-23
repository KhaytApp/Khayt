import Foundation
import Security
import CryptoKit

/// The phones that have enrolled with this Mac, and the check on a request one
/// of them signed.
///
/// ── WHY THE PIN STOPS TRAVELLING ───────────────────────────────────────────
///
/// The LAN server speaks plain http, so a PIN sent on every request can be read
/// by anything on the shop's Wi-Fi, and the PIN opens the whole book. A phone
/// sends it once, to `POST /api/devices`, with a fresh X25519 public key; this
/// Mac answers with one of its own, signed by the `LanIdentity` key the phone
/// already pinned, so a device in the middle cannot swap it. Both sides derive
/// the same 32-byte key, and from then on the phone signs each request with it
/// instead (docs/LAN_API.md, "POST /api/devices and signed requests").
/// Somebody listening learns neither the key nor the PIN, and a request they
/// copy is refused: it names its own time, and its nonce is remembered.
///
/// ── WHERE THE KEYS LIVE ────────────────────────────────────────────────────
///
/// In this Mac's login Keychain, beside the identity key, not synced and never
/// in the book. A backup, a restore or a second computer syncing the book
/// carries no phone's key, and a phone that meets another computer is told
/// `device-unknown` and enrols again.
///
/// ── A NEW PIN SIGNS EVERY PHONE OUT ─────────────────────────────────────────
///
/// Each device carries a tag of the PIN it enrolled under (an HMAC, keyed with
/// a secret kept here, so the tag does not give away the PIN). A device whose
/// tag no longer matches is removed when it is next seen. That holds whichever
/// app or computer changed the PIN, with no hook in any settings screen.
final class LanDevices: @unchecked Sendable {

    struct Device: Codable, Sendable {
        var id: String
        var name: String
        var key: Data
        var pinTag: Data
        var createdAt: Date
        var lastSeenAt: Date
        /// What enrolled: nil is a phone (every device saved before kinds
        /// existed), `kindConnector` a slicer plugin. See `isRestricted`.
        var kind: String? = nil
        /// What a CONNECTOR may see of the shop's prices in its tab:
        /// nil (none, the default), `price`, or `cost` (price, cost and
        /// margin). Only asked when the shop has turned prices on.
        var priceGrant: String? = nil
        /// A PHONE's role on the ladder (`lib/device-roles.js`): what its key
        /// opens. Kept as the text that was stored, never an enum: a role
        /// this build does not know must reach the shared rule as it is, which
        /// reads it as a viewer, not be dropped here and read as "no role".
        var role: String? = nil
        /// 1 once a role was ever written for this device. A phone with no
        /// `role` AND no `rolesVersion` enrolled with the owner PIN before
        /// roles existed, and is the owner, as it was (D-P1). A code-paired
        /// phone always carries 1, so one that lost its role is a viewer.
        var rolesVersion: Int? = nil

        /// Paired by a code approved on this Mac, not by the PIN: it holds
        /// no tag of any PIN, and a PIN change does not sign it out (D-P7).
        /// Both must hold: an empty tag alone (a damaged record) is not a
        /// code pairing, so such a device fails the PIN check and is removed
        /// rather than surviving as a pre-roles owner.
        var codePaired: Bool { pinTag.isEmpty && rolesVersion != nil }
    }

    /// The version `rolesVersion` is written as.
    static let rolesVersion = 1

    /// The grants a connector may hold, in order of what they show.
    static let priceGrants = ["price", "cost"]

    // ── A CONNECTOR OPENS ITS OWN ROUTES AND NOTHING ELSE ──────────────────
    //
    // A phone's key opens whatever the owner PIN opens, `/api/store` included:
    // the phone is the owner's. A connector (the Khayt for OrcaSlicer plugin)
    // runs inside somebody's slicer and only sends slices and reads a redacted
    // queue, so its key opens `/api/connectors/*` and is refused everywhere
    // else (`LanServer.connectorRefusal`). Any kind this build does not know
    // is held to the same rule: a newer app's device fails closed here.
    static let kindConnector = "connector"
    static let connectorPrefix = "/api/connectors/"

    /// True for every device that is not a phone.
    static func isRestricted(kind: String?) -> Bool { kind != nil }

    struct Saved: Codable {
        var salt: Data
        var devices: [Device]
        /// Phones the shop signed out, by id, with when. Answered
        /// `device-revoked` rather than `device-unknown`, so the phone drops
        /// its PIN and asks for it again instead of quietly enrolling anew
        /// with the one it kept. Optional: a store saved before it has none.
        var revoked: [String: Date]? = nil
        /// The key each signed-out PHONE had, kept for one purpose: signing
        /// the `device-revoked` refusal, so the phone can tell a real sign-out
        /// from something on the Wi-Fi forging one (`revokedReplyKey`). It
        /// opens nothing: `verify` only ever accepts an enrolled device.
        /// Forgotten with its `revoked` entry.
        var revokedKeys: [String: Data]? = nil
    }

    /// What the server answers a signed request.
    enum Verdict: Equatable {
        case pass
        /// 401 with `{"reason": reason}`, plus `now` for `device-clock`.
        case refused(String, now: Int?)
    }

    struct Enrolled: Equatable {
        let deviceId: String
        let publicKey: String
        let sig: String
    }

    /// Per kind: 32 phones and 32 connectors at most.
    static let maxDevices = 32
    /// Signed-out ids remembered; the oldest go first. An id is random, so a
    /// forgotten one is only a phone told `device-unknown` instead.
    static let maxRevoked = 256
    static let maxName = 60
    static let skew: TimeInterval = 120
    static let replayWindow: TimeInterval = 300
    /// More than any phone sends in five minutes. Past it, requests are
    /// refused rather than a remembered nonce forgotten early.
    static let maxNonces = 4096
    /// How stale `lastSeenAt` may be on disk; it orders replacement, nothing more.
    static let seenGranularity: TimeInterval = 3600

    static let salt = Data("khayt-device-v1".utf8)
    static let canonicalPrefix = "khayt-req-v1"
    static let enrolPrefix = "khayt-enrol:"

    private let lock = NSLock()
    private var saved: Saved
    private var seen: [String: [String: Date]] = [:]
    private let persist: (@Sendable (Data) -> Void)?
    /// The first whole second this store may accept a request from.
    ///
    /// The nonces above live in memory only, so a request captured in the
    /// last `skew` seconds before a restart could be replayed once after it:
    /// its clock still agreed and no nonce remembered it. A request timed
    /// before the store existed is refused instead — `device-clock`, with
    /// `now`, so a phone retries at once. Rounded UP, so a request signed in
    /// the very second the store started (before it, or after) is refused
    /// too; that costs a phone one retry, never a replay. Oct 2026 review.
    private let since: Int

    /// False when the Keychain could not be read, or held something this
    /// build cannot decode: phones still enrol, for this run only, and what is
    /// stored is left alone rather than overwritten with an empty list.
    let keeps: Bool

    /// `since`: when this store started taking requests — `Date()` for the
    /// app's own (`shared`). The default lets a test sign at a fixed clock.
    init(loaded: Data?, since: Date = .distantPast, persist: (@Sendable (Data) -> Void)?) {
        self.since = since == .distantPast ? Int.min : Int(since.timeIntervalSince1970.rounded(.up))
        if let loaded, let kept = try? JSONDecoder().decode(Saved.self, from: loaded) {
            saved = kept
            self.persist = persist
        } else {
            saved = Saved(salt: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }, devices: [])
            // Something is stored but unreadable: never write over it.
            self.persist = loaded == nil ? persist : nil
        }
        keeps = self.persist != nil
    }

    /// A store that lives and dies with the server: tests, and a Mac whose
    /// Keychain refused.
    static func inMemory() -> LanDevices { LanDevices(loaded: nil, persist: nil) }

    // MARK: - The Keychain

    static let service = "Khayt LAN Devices"
    static let account = "mac"

    private static var keychainBase: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    /// The app's store, read once.
    static let shared: LanDevices = {
        var q = keychainBase
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        // Only "nothing stored" starts a fresh list that is saved. A denied
        // or locked Keychain is not "no phones": it is enrolment for this run
        // only, with what is stored left as it was.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            NSLog("Khayt LAN devices: Keychain read failed (%d); enrolments will not be kept", status)
            return LanDevices(loaded: nil, since: Date(), persist: nil)
        }
        let loaded = status == errSecSuccess ? (out as? Data ?? Data()) : nil
        return LanDevices(loaded: loaded, since: Date(), persist: { data in
            let update = [kSecValueData as String: data] as CFDictionary
            var result = SecItemUpdate(keychainBase as CFDictionary, update)
            if result == errSecItemNotFound {
                var add = keychainBase
                add[kSecValueData as String] = data
                add[kSecAttrLabel as String] = "Khayt LAN devices"
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                result = SecItemAdd(add as CFDictionary, nil)
            }
            if result != errSecSuccess {
                NSLog("Khayt LAN devices: Keychain write failed (%d)", result)
            }
        })
    }()

    private func save() {
        guard let persist, let data = try? JSONEncoder().encode(saved) else { return }
        persist(data)
    }

    // MARK: - Who is enrolled

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return saved.devices.count
    }

    /// A paired phone as Settings lists it: never its key.
    struct Listed: Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        let createdAt: Date
        let lastSeenAt: Date
        var kind: String? = nil
        /// As stored: see `Device.role` and `Device.rolesVersion`. The role a
        /// phone HOLDS is the shared rule's reading of these (`roleOf`).
        var role: String? = nil
        var rolesVersion: Int? = nil
        var codePaired: Bool = false
        /// A connector's price grant: nil (none), `price` or `cost`.
        var priceGrant: String? = nil
    }

    /// Every paired phone, the one seen most recently first.
    func list() -> [Listed] {
        lock.lock(); defer { lock.unlock() }
        return saved.devices
            .map { d in
                Listed(id: d.id, name: d.name, createdAt: d.createdAt, lastSeenAt: d.lastSeenAt, kind: d.kind,
                       role: d.role, rolesVersion: d.rolesVersion, codePaired: d.codePaired,
                       priceGrant: d.kind == Self.kindConnector ? d.priceGrant.flatMap { Self.priceGrants.contains($0) ? $0 : nil } : nil)
            }
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    /// Sign one phone out: its key is forgotten, so its next signed request
    /// is refused `device-revoked` (and the phone asks for the PIN again). The other phones keep theirs — the PIN
    /// change that was the only way to cut off a lost phone signed out all
    /// of them. Returns whether it was paired.
    @discardableResult
    func remove(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let at = saved.devices.firstIndex(where: { $0.id == id }) else { return false }
        let gone = saved.devices.remove(at: at)
        seen[id] = nil
        var revoked = saved.revoked ?? [:]
        var keys = saved.revokedKeys ?? [:]
        revoked[id] = Date()
        // A phone's only: a connector's answers are sealed another way.
        if gone.kind == nil { keys[id] = gone.key }
        while revoked.count > Self.maxRevoked, let oldest = revoked.min(by: { $0.value < $1.value }) {
            revoked[oldest.key] = nil
            keys[oldest.key] = nil
        }
        saved.revoked = revoked
        saved.revokedKeys = keys.isEmpty ? nil : keys
        save()
        return true
    }

    /// The kind of an enrolled device, by the id a request names; nil for a
    /// phone or an id nobody enrolled. Says nothing about the signature,
    /// which `verify` judges: it only decides which routes may be asked.
    func kind(of id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return saved.devices.first(where: { $0.id == id })?.kind
    }

    /// An enrolled CONNECTOR's derived key and name, by id: what its answers
    /// are signed and its sealed bodies keyed with. Nil for a phone or an id
    /// nobody enrolled — a phone's key never leaves `verify`.
    func connector(_ id: String) -> (key: Data, name: String)? {
        lock.lock(); defer { lock.unlock() }
        guard let d = saved.devices.first(where: { $0.id == id }), d.kind == Self.kindConnector else { return nil }
        return (d.key, d.name)
    }

    /// What the shared rule is asked about a device (`lib/device-roles.js`
    /// `roleOf`, `allowsDevice`): its kind, role and rolesVersion exactly as
    /// stored, and nothing else. Nil for an id nobody enrolled.
    /// The name the shop sees for a device ("Turki's iPhone"), for saying who
    /// changed something. Nil for an id nobody enrolled.
    func name(of id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return saved.devices.first(where: { $0.id == id })?.name
    }

    func rulesRecord(_ id: String) -> [String: String]? {
        lock.lock(); defer { lock.unlock() }
        guard let d = saved.devices.first(where: { $0.id == id }) else { return nil }
        var out: [String: String] = [:]
        if let kind = d.kind { out["kind"] = kind }
        if let role = d.role { out["role"] = role }
        if let v = d.rolesVersion { out["rolesVersion"] = String(v) }
        return out
    }

    /// Give a PHONE a role. The caller has asked the shared rule whether the
    /// person may grant it (`grantable`); this only stores it, with
    /// `rolesVersion`, so the phone is never again read as a pre-roles owner.
    /// A connector, or an id nobody enrolled, is left alone. Takes effect on
    /// the phone's next request: nothing is re-keyed.
    @discardableResult
    func setRole(_ id: String, _ role: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let i = saved.devices.firstIndex(where: { $0.id == id }), saved.devices[i].kind == nil,
              !role.isEmpty, role.count <= 32 else { return false }
        // A phone paired with the owner PIN holds the PIN: given a lesser
        // role it could drop its key and send the PIN instead, and be the
        // owner again. So it is the owner or it is removed; a lesser role
        // needs pairing again by code (security review of the first draft).
        guard saved.devices[i].codePaired || role == "owner" else { return false }
        saved.devices[i].role = role
        saved.devices[i].rolesVersion = Self.rolesVersion
        save()
        return true
    }

    /// A PHONE's derived key, by id, for signing an answer back to it
    /// (`LanServer.signedForPhone`). Asked only after its request's own
    /// signature passed. Nil for a connector or an id nobody enrolled.
    func phoneKey(_ id: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let d = saved.devices.first(where: { $0.id == id }), d.kind == nil else { return nil }
        return d.key
    }

    /// A connector's price grant: nil (none), `price` or `cost`.
    func priceGrant(_ id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let d = saved.devices.first(where: { $0.id == id }), d.kind == Self.kindConnector,
              let g = d.priceGrant, Self.priceGrants.contains(g) else { return nil }
        return g
    }

    /// Set (or, with nil, take away) a connector's price grant. A phone, or an
    /// id nobody enrolled, is left alone.
    func setPriceGrant(_ id: String, _ grant: String?) {
        lock.lock(); defer { lock.unlock() }
        guard let i = saved.devices.firstIndex(where: { $0.id == id }),
              saved.devices[i].kind == Self.kindConnector else { return }
        saved.devices[i].priceGrant = grant.flatMap { Self.priceGrants.contains($0) ? $0 : nil }
        save()
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        saved.devices = []
        seen = [:]
        save()
    }

    private func tag(_ pin: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(pin.utf8), using: SymmetricKey(data: saved.salt)))
    }

    // MARK: - Enrolment

    enum EnrolError: Error, Equatable { case badKey }

    /// Enrol a phone that has just shown the PIN. `serverKey` and `deviceId`
    /// are for the tests that reproduce the shared vectors; the server lets
    /// both be fresh.
    func enrol(phonePublic: String, name: String, pin: String,
               identity: Curve25519.Signing.PrivateKey, now: Date,
               serverKey: Curve25519.KeyAgreement.PrivateKey = .init(),
               deviceId: String = LanDevices.freshId(), kind: String? = nil) throws -> Enrolled {
        guard let raw = Data(base64Encoded: phonePublic), raw.count == 32,
              let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw),
              let key = Self.derive(serverKey, theirs, deviceId: deviceId) else { throw EnrolError.badKey }
        let serverPublic = serverKey.publicKey.rawRepresentation.base64EncodedString()
        let sig = try identity.signature(for: Self.enrolMessage(deviceId: deviceId, serverPublic: serverPublic,
                                                                phonePublic: phonePublic))
        insert(id: deviceId, name: name, key: key, pin: pin, now: now, kind: kind)
        return Enrolled(deviceId: deviceId, publicKey: serverPublic, sig: sig.base64EncodedString())
    }

    /// Enrol a slicer plugin the owner approved (`LanConnectorPairing`). The
    /// Mac's answer was signed when the plugin asked; this only keeps the key
    /// both sides derived, as a `connector`, under the PIN in force now.
    func admitConnector(pluginPublic: String, serverKey: Curve25519.KeyAgreement.PrivateKey,
                        deviceId: String, name: String, pin: String, now: Date) throws {
        guard let raw = Data(base64Encoded: pluginPublic), raw.count == 32,
              let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw),
              let key = Self.derive(serverKey, theirs, deviceId: deviceId) else { throw EnrolError.badKey }
        insert(id: deviceId, name: name, key: key, pin: pin, now: now, kind: Self.kindConnector)
    }

    /// Enrol a phone a person approved by its check number
    /// (`LanConnectorPairing`, kind phone), with the role they chose. No PIN
    /// was shown, so it carries no PIN tag: a PIN change does not sign it out,
    /// Remove does (D-P7). `role` is stored with `rolesVersion`.
    func admitPhone(phonePublic: String, serverKey: Curve25519.KeyAgreement.PrivateKey,
                    deviceId: String, name: String, role: String, pin: String, now: Date) throws {
        guard let raw = Data(base64Encoded: phonePublic), raw.count == 32,
              let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw),
              let key = Self.derive(serverKey, theirs, deviceId: deviceId),
              !role.isEmpty, role.count <= 32 else { throw EnrolError.badKey }
        insert(id: deviceId, name: name, key: key, pin: pin, now: now, kind: nil, role: role, codePaired: true)
    }

    private func insert(id deviceId: String, name: String, key: Data, pin: String, now: Date, kind: String?,
                        role: String? = nil, codePaired: Bool = false) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxName))

        lock.lock(); defer { lock.unlock() }
        let current = tag(pin)
        // Anything enrolled under another PIN is gone now, not when next seen.
        // A code-paired phone holds no PIN tag and stays (D-P7).
        saved.devices.removeAll { (!$0.codePaired && $0.pinTag != current) || $0.id == deviceId }
        // A full store makes room within the SAME kind: a connector never
        // pushes out a phone (the shop would find it unpaired with no reason
        // shown), and a phone never pushes out a connector. Mac review, Nov 15.
        func sameKind(_ i: Int) -> Bool { saved.devices[i].kind == kind }
        while saved.devices.indices.filter(sameKind).count >= Self.maxDevices,
              let oldest = saved.devices.indices.filter(sameKind)
                .min(by: { saved.devices[$0].lastSeenAt < saved.devices[$1].lastSeenAt }) {
            seen.removeValue(forKey: saved.devices[oldest].id)
            saved.devices.remove(at: oldest)
        }
        saved.devices.append(Device(id: deviceId, name: trimmed, key: key, pinTag: codePaired ? Data() : current,
                                    createdAt: now, lastSeenAt: now, kind: kind,
                                    role: role, rolesVersion: role == nil ? nil : Self.rolesVersion))
        save()
    }

    static func freshId() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var rng = SystemRandomNumberGenerator()
        return "dev_" + String((0..<20).map { _ in alphabet.randomElement(using: &rng)! })
    }

    static func enrolMessage(deviceId: String, serverPublic: String, phonePublic: String) -> Data {
        Data((enrolPrefix + deviceId + ":" + serverPublic + ":" + phonePublic).utf8)
    }

    /// HKDF-SHA256 over the X25519 secret. Nil for a phone key that makes the
    /// all-zero secret (a low-order point), which would be a key anyone knows.
    static func derive(_ mine: Curve25519.KeyAgreement.PrivateKey, _ theirs: Curve25519.KeyAgreement.PublicKey,
                       deviceId: String) -> Data? {
        guard let shared = try? mine.sharedSecretFromKeyAgreement(with: theirs),
              shared.withUnsafeBytes({ $0.contains { $0 != 0 } }) else { return nil }
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data(deviceId.utf8),
                                              outputByteCount: 32).withUnsafeBytes { Data($0) }
    }

    // MARK: - A signed request

    /// `bodyHash`: the body's SHA-256 in lower-case hex when the body is not
    /// in hand yet — a connector's file upload, verified at its head against
    /// the hash its capture declared (`LanServer+Connector`).
    static func canonical(method: String, target: String, time: String, nonce: String, body: Data,
                          bodyHash: String? = nil) -> String {
        let hash = bodyHash ?? SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return [canonicalPrefix, method.uppercased(), target, time, nonce, hash].joined(separator: "\n")
    }

    static func mac(key: Data, canonical: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: SymmetricKey(data: key)))
    }

    static func plausibleId(_ id: String) -> Bool {
        guard id.hasPrefix("dev_") else { return false }
        let rest = id.dropFirst(4)
        return (12...40).contains(rest.count)
            && rest.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }

    static func plausibleNonce(_ nonce: String) -> Bool {
        nonce.count == 32 && nonce.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// Does this request carry the device headers at all? A request with
    /// them is judged by them alone, whatever PIN came with it.
    static func isSigned(_ headers: [String: String]) -> Bool {
        headers["x-khayt-device"] != nil
    }

    /// The whole check. `headOnly` is the large-upload head, which has no body
    /// yet: it asks only that the device is enrolled and its clock agrees, and
    /// spends no nonce. The route then makes the whole check on the body.
    ///
    /// `bodyHash` stands in for the body's own hash: a WHOLE check (nonce
    /// spent) on a head whose body has not been read, because the hash it
    /// will have was declared and signed before (a connector's file upload).
    func verify(headers: [String: String], method: String, target: String, body: Data,
                pin: String, now: Date, headOnly: Bool = false, bodyHash: String? = nil) -> Verdict {
        let auth = Verdict.refused("device-auth", now: nil)
        guard let id = headers["x-khayt-device"], Self.plausibleId(id),
              let timeText = headers["x-khayt-time"], let time = Int(timeText), String(time) == timeText,
              let nonce = headers["x-khayt-nonce"], Self.plausibleNonce(nonce),
              let macText = headers["x-khayt-mac"], let sent = Data(base64Encoded: macText), sent.count == 32
        else { return auth }

        lock.lock(); defer { lock.unlock() }
        guard let at = saved.devices.firstIndex(where: { $0.id == id }) else {
            return .refused(saved.revoked?[id] != nil ? "device-revoked" : "device-unknown", now: nil)
        }
        // A code-paired phone was never bound to a PIN (D-P7): only a phone or
        // connector that enrolled under one is signed out when it changes.
        guard saved.devices[at].codePaired || saved.devices[at].pinTag == tag(pin) else {
            saved.devices.remove(at: at)
            seen.removeValue(forKey: id)
            save()
            return .refused("device-unknown", now: nil)
        }
        let nowSeconds = Int(now.timeIntervalSince1970.rounded(.down))
        if !headOnly {
            let expected = Self.mac(key: saved.devices[at].key,
                                    canonical: Self.canonical(method: method, target: target, time: timeText,
                                                              nonce: nonce, body: body, bodyHash: bodyHash))
            guard Self.constantTimeEqual(expected, sent) else { return auth }
        }
        guard abs(time - nowSeconds) <= Int(Self.skew), time >= since else {
            return .refused("device-clock", now: nowSeconds)
        }
        if headOnly { return .pass }

        var nonces = (seen[id] ?? [:]).filter { now.timeIntervalSince($0.value) < Self.replayWindow }
        guard nonces[nonce] == nil, nonces.count < Self.maxNonces else {
            seen[id] = nonces
            return .refused("device-replay", now: nil)
        }
        nonces[nonce] = now
        seen[id] = nonces
        if now.timeIntervalSince(saved.devices[at].lastSeenAt) >= Self.seenGranularity {
            saved.devices[at].lastSeenAt = now
            save()
        }
        return .pass
    }

    /// Every byte looked at, whatever the first difference.
    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    /// The key to sign a `device-revoked` refusal with, or nil.
    ///
    /// ONLY for a request that the signed-out phone itself made: its id is on
    /// the revoked list, its old key is still held, the request's own MAC
    /// verifies under that key, and its clock agrees. Signing a refusal for a
    /// request nobody proved they made would hand anyone who names a phone's
    /// id a signed "you are signed out" to play back at that phone.
    /// Spends no nonce and changes nothing.
    func revokedReplyKey(headers: [String: String], method: String, target: String, body: Data, now: Date) -> Data? {
        guard let id = headers["x-khayt-device"], Self.plausibleId(id),
              let timeText = headers["x-khayt-time"], let time = Int(timeText), String(time) == timeText,
              let nonce = headers["x-khayt-nonce"], Self.plausibleNonce(nonce),
              let macText = headers["x-khayt-mac"], let sent = Data(base64Encoded: macText), sent.count == 32
        else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard saved.revoked?[id] != nil, let key = saved.revokedKeys?[id],
              !saved.devices.contains(where: { $0.id == id }) else { return nil }
        let expected = Self.mac(key: key, canonical: Self.canonical(method: method, target: target, time: timeText,
                                                                   nonce: nonce, body: body, bodyHash: nil))
        guard Self.constantTimeEqual(expected, sent) else { return nil }
        let nowSeconds = Int(now.timeIntervalSince1970.rounded(.down))
        guard abs(time - nowSeconds) <= Int(Self.skew) else { return nil }
        return key
    }

    /// The 401 body for a refusal.
    static func body(_ verdict: Verdict) -> String {
        guard case .refused(let reason, let now) = verdict else { return "{}" }
        if let now { return #"{"reason":"\#(reason)","now":\#(now)}"# }
        return #"{"reason":"\#(reason)"}"#
    }
}
