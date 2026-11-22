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
    }

    struct Saved: Codable {
        var salt: Data
        var devices: [Device]
        /// Phones the shop signed out, by id, with when. Answered
        /// `device-revoked` rather than `device-unknown`, so the phone drops
        /// its PIN and asks for it again instead of quietly enrolling anew
        /// with the one it kept. Optional: a store saved before it has none.
        var revoked: [String: Date]? = nil
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
    }

    /// Every paired phone, the one seen most recently first.
    func list() -> [Listed] {
        lock.lock(); defer { lock.unlock() }
        return saved.devices
            .map { Listed(id: $0.id, name: $0.name, createdAt: $0.createdAt, lastSeenAt: $0.lastSeenAt) }
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
        saved.devices.remove(at: at)
        seen[id] = nil
        var revoked = saved.revoked ?? [:]
        revoked[id] = Date()
        while revoked.count > Self.maxRevoked, let oldest = revoked.min(by: { $0.value < $1.value }) {
            revoked[oldest.key] = nil
        }
        saved.revoked = revoked
        save()
        return true
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
               deviceId: String = LanDevices.freshId()) throws -> Enrolled {
        guard let raw = Data(base64Encoded: phonePublic), raw.count == 32,
              let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw),
              let key = Self.derive(serverKey, theirs, deviceId: deviceId) else { throw EnrolError.badKey }
        let serverPublic = serverKey.publicKey.rawRepresentation.base64EncodedString()
        let sig = try identity.signature(for: Self.enrolMessage(deviceId: deviceId, serverPublic: serverPublic,
                                                                phonePublic: phonePublic))
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxName))

        lock.lock(); defer { lock.unlock() }
        let current = tag(pin)
        // Anything enrolled under another PIN is gone now, not when next seen.
        saved.devices.removeAll { $0.pinTag != current || $0.id == deviceId }
        while saved.devices.count >= Self.maxDevices,
              let oldest = saved.devices.indices.min(by: { saved.devices[$0].lastSeenAt < saved.devices[$1].lastSeenAt }) {
            seen.removeValue(forKey: saved.devices[oldest].id)
            saved.devices.remove(at: oldest)
        }
        saved.devices.append(Device(id: deviceId, name: trimmed, key: key, pinTag: current,
                                    createdAt: now, lastSeenAt: now))
        save()
        return Enrolled(deviceId: deviceId, publicKey: serverPublic, sig: sig.base64EncodedString())
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

    static func canonical(method: String, target: String, time: String, nonce: String, body: Data) -> String {
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
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
    func verify(headers: [String: String], method: String, target: String, body: Data,
                pin: String, now: Date, headOnly: Bool = false) -> Verdict {
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
        guard saved.devices[at].pinTag == tag(pin) else {
            saved.devices.remove(at: at)
            seen.removeValue(forKey: id)
            save()
            return .refused("device-unknown", now: nil)
        }
        let nowSeconds = Int(now.timeIntervalSince1970.rounded(.down))
        if !headOnly {
            let expected = Self.mac(key: saved.devices[at].key,
                                    canonical: Self.canonical(method: method, target: target, time: timeText,
                                                              nonce: nonce, body: body))
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

    /// The 401 body for a refusal.
    static func body(_ verdict: Verdict) -> String {
        guard case .refused(let reason, let now) = verdict else { return "{}" }
        if let now { return #"{"reason":"\#(reason)","now":\#(now)}"# }
        return #"{"reason":"\#(reason)"}"#
    }
}
